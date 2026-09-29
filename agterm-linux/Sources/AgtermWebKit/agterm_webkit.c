#include "agterm_webkit.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <webkit/webkit.h>

// A file page loads through this scheme rather than file:, so every read passes `serve`, which answers only
// under the view's grant. file: stays a local scheme WebKit refuses to a non-local origin.
#define GRANT_SCHEME "agterm-file"
#define PAGE_KEY "agterm-page"

typedef struct {
    agterm_web_callbacks callbacks;
    bool active;
    char *grant_root;
    WebKitUserContentManager *content;
} page;

static page *page_of(GtkWidget *view) {
    return view ? g_object_get_data(G_OBJECT(view), PAGE_KEY) : NULL;
}

static void page_free(gpointer data) {
    page *state = data;
    g_free(state->grant_root);
    g_clear_object(&state->content);
    g_free(state);
}

// app_uri reports a granted file as the file: URI it stands for, so the app sees one spelling
static char *app_uri(const char *uri) {
    if (uri && g_str_has_prefix(uri, GRANT_SCHEME ":")) return g_strconcat("file:", uri + strlen(GRANT_SCHEME ":"), NULL);
    return g_strdup(uri);
}

static bool inside(const char *root, const char *path) {
    size_t length = strlen(root);
    if (strcmp(root, "/") == 0) return path[0] == '/';
    return strncmp(root, path, length) == 0 && path[length] == '/';
}

static void refuse(WebKitURISchemeRequest *request, GIOErrorEnum code, const char *message) {
    GError *error = g_error_new_literal(G_IO_ERROR, code, message);
    webkit_uri_scheme_request_finish_error(request, error);
    g_error_free(error);
}

static void serve(WebKitURISchemeRequest *request, gpointer data) {
    (void)data;
    page *state = page_of(GTK_WIDGET(webkit_uri_scheme_request_get_web_view(request)));
    GUri *uri = g_uri_parse(webkit_uri_scheme_request_get_uri(request), G_URI_FLAGS_NONE, NULL);
    const char *path = uri ? g_uri_get_path(uri) : NULL;
    char resolved[PATH_MAX];
    if (!state || !state->grant_root || !path || !realpath(path, resolved) || !inside(state->grant_root, resolved)) {
        refuse(request, G_IO_ERROR_PERMISSION_DENIED, "outside the page's granted directory");
        if (uri) g_uri_unref(uri);
        return;
    }
    g_uri_unref(uri);
    GFile *file = g_file_new_for_path(resolved);
    GError *error = NULL;
    GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_TYPE "," G_FILE_ATTRIBUTE_STANDARD_SIZE,
                                        G_FILE_QUERY_INFO_NONE, NULL, &error);
    GFileInputStream *stream = NULL;
    if (info && g_file_info_get_file_type(info) != G_FILE_TYPE_REGULAR) {
        refuse(request, G_IO_ERROR_IS_DIRECTORY, "not a file");
    } else if (info && (stream = g_file_read(file, NULL, &error))) {
        char *type = g_content_type_guess(resolved, NULL, 0, NULL);
        char *mime = g_content_type_get_mime_type(type);
        webkit_uri_scheme_request_finish(request, G_INPUT_STREAM(stream), g_file_info_get_size(info),
                                         mime ? mime : "application/octet-stream");
        g_free(mime);
        g_free(type);
        g_object_unref(stream);
    } else {
        webkit_uri_scheme_request_finish_error(request, error);
    }
    g_clear_error(&error);
    g_clear_object(&info);
    g_object_unref(file);
}

static void register_scheme(void) {
    static gsize registered = 0;
    if (g_once_init_enter(&registered)) {
        webkit_web_context_register_uri_scheme(webkit_web_context_get_default(), GRANT_SCHEME, serve, NULL, NULL);
        g_once_init_leave(&registered, 1);
    }
}

static bool decide(page *state, const char *uri, agterm_web_target target, bool user_activated) {
    if (!state->active) return false;
    char *reported = app_uri(uri);
    bool allowed = state->callbacks.decide(state->callbacks.context, reported ? reported : "", target, user_activated);
    g_free(reported);
    return allowed;
}

static gboolean on_decide_policy(WebKitWebView *view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type,
                                 gpointer data) {
    (void)view;
    page *state = data;
    switch (type) {
    case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION:
    case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: {
        WebKitNavigationAction *action =
            webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
        bool clicked = webkit_navigation_action_get_navigation_type(action) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED;
        bool window = type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION;
        bool allowed = decide(state, uri, window ? AGTERM_WEB_NAVIGATION_NEW_WINDOW : AGTERM_WEB_NAVIGATION_FRAME, clicked);
        // a real file: address would bypass the grant, and nothing says which frame it targets
        if (allowed && !window && !g_str_has_prefix(uri, "file:")) {
            webkit_policy_decision_use(decision);
        } else {
            webkit_policy_decision_ignore(decision);
        }
        return TRUE;
    }
    case WEBKIT_POLICY_DECISION_TYPE_RESPONSE: {
        WebKitResponsePolicyDecision *response = WEBKIT_RESPONSE_POLICY_DECISION(decision);
        // nothing is saved to disk: WebKit reports an unshowable main resource as interrupted
        if (!webkit_response_policy_decision_is_mime_type_supported(response)) {
            webkit_policy_decision_ignore(decision);
            return TRUE;
        }
        bool main = webkit_response_policy_decision_is_main_frame_main_resource(response);
        const char *uri = webkit_uri_response_get_uri(webkit_response_policy_decision_get_response(response));
        if (decide(state, uri, main ? AGTERM_WEB_RESPONSE_MAIN_FRAME : AGTERM_WEB_RESPONSE_SUBFRAME, false)) {
            webkit_policy_decision_use(decision);
        } else {
            webkit_policy_decision_ignore(decision);
        }
        return TRUE;
    }
    default:
        return FALSE;
    }
}

static void emit_load(page *state, agterm_web_load_event event, const char *message) {
    if (state->active) state->callbacks.load(state->callbacks.context, event, message);
}

static void emit_changed(page *state) {
    if (state->active) state->callbacks.changed(state->callbacks.context);
}

static void on_load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
    (void)view;
    page *state = data;
    switch (event) {
    case WEBKIT_LOAD_STARTED: emit_load(state, AGTERM_WEB_LOAD_STARTED, NULL); break;
    case WEBKIT_LOAD_COMMITTED: emit_load(state, AGTERM_WEB_LOAD_COMMITTED, NULL); break;
    case WEBKIT_LOAD_FINISHED: emit_load(state, AGTERM_WEB_LOAD_FINISHED, NULL); break;
    default: break;
    }
}

// true suppresses WebKit's own error page: the panel shows the failure
static gboolean on_load_failed(WebKitWebView *view, WebKitLoadEvent event, char *uri, GError *error, gpointer data) {
    (void)view;
    (void)event;
    (void)uri;
    page *state = data;
    if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) {
        emit_load(state, AGTERM_WEB_LOAD_CANCELLED, error->message);
    } else if (error->domain == WEBKIT_POLICY_ERROR
               && (error->code == WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE
                   || error->code == WEBKIT_POLICY_ERROR_CANNOT_SHOW_MIME_TYPE)) {
        emit_load(state, AGTERM_WEB_LOAD_INTERRUPTED, error->message);
    } else {
        emit_load(state, AGTERM_WEB_LOAD_FAILED, error->message);
    }
    return TRUE;
}

static void on_terminated(WebKitWebView *view, WebKitWebProcessTerminationReason reason, gpointer data) {
    (void)view;
    (void)reason;
    emit_load(data, AGTERM_WEB_PROCESS_TERMINATED, "web content process terminated");
}

static void on_notify(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object;
    (void)spec;
    emit_changed(data);
}

static void on_history(WebKitBackForwardList *list, WebKitBackForwardListItem *added, gpointer removed, gpointer data) {
    (void)list;
    (void)added;
    (void)removed;
    emit_changed(data);
}

static GtkWidget *on_create(WebKitWebView *view, WebKitNavigationAction *action, gpointer data) {
    (void)view;
    (void)action;
    (void)data;
    return NULL;
}

// a script dialog answers as dismissed: cancel for confirm, null for prompt
static gboolean on_script_dialog(WebKitWebView *view, WebKitScriptDialog *dialog, gpointer data) {
    (void)view;
    (void)data;
    if (webkit_script_dialog_get_dialog_type(dialog) == WEBKIT_SCRIPT_DIALOG_CONFIRM) {
        webkit_script_dialog_confirm_set_confirmed(dialog, FALSE);
    }
    return TRUE;
}

static gboolean on_file_chooser(WebKitWebView *view, WebKitFileChooserRequest *request, gpointer data) {
    (void)view;
    (void)data;
    webkit_file_chooser_request_cancel(request);
    return TRUE;
}

static gboolean on_permission(WebKitWebView *view, WebKitPermissionRequest *request, gpointer data) {
    (void)view;
    (void)data;
    webkit_permission_request_deny(request);
    return TRUE;
}

static gboolean on_refused(WebKitWebView *view, gpointer data) {
    (void)view;
    (void)data;
    return TRUE;
}

static gboolean on_notification(WebKitWebView *view, WebKitNotification *notification, gpointer data) {
    (void)view;
    (void)notification;
    (void)data;
    return TRUE;
}

// the menu keeps editing and history; anything that opens a window or saves a file goes
static gboolean on_context_menu(WebKitWebView *view, WebKitContextMenu *menu, WebKitHitTestResult *hit, gpointer data) {
    (void)view;
    (void)hit;
    (void)data;
    static const WebKitContextMenuAction refused[] = {
        WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK_IN_NEW_WINDOW, WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_LINK_TO_DISK,
        WEBKIT_CONTEXT_MENU_ACTION_OPEN_IMAGE_IN_NEW_WINDOW, WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_IMAGE_TO_DISK,
        WEBKIT_CONTEXT_MENU_ACTION_OPEN_FRAME_IN_NEW_WINDOW, WEBKIT_CONTEXT_MENU_ACTION_OPEN_VIDEO_IN_NEW_WINDOW,
        WEBKIT_CONTEXT_MENU_ACTION_OPEN_AUDIO_IN_NEW_WINDOW, WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_VIDEO_TO_DISK,
        WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_AUDIO_TO_DISK, WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT,
        WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK,
    };
    GList *items = g_list_copy(webkit_context_menu_get_items(menu));
    for (GList *node = items; node; node = node->next) {
        WebKitContextMenuAction action = webkit_context_menu_item_get_stock_action(node->data);
        for (size_t index = 0; index < G_N_ELEMENTS(refused); index++) {
            if (action == refused[index]) {
                webkit_context_menu_remove(menu, node->data);
                break;
            }
        }
    }
    g_list_free(items);
    return FALSE;
}

static void on_download(WebKitNetworkSession *session, WebKitDownload *download, gpointer data) {
    (void)session;
    (void)data;
    webkit_download_cancel(download);
}

// observe only: the event stays the page's
static gboolean on_event(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data) {
    (void)controller;
    page *state = data;
    GdkEventType type = gdk_event_get_event_type(event);
    if (state->active && (type == GDK_KEY_PRESS || type == GDK_BUTTON_PRESS || type == GDK_TOUCH_BEGIN)) {
        state->callbacks.input(state->callbacks.context);
    }
    return FALSE;
}

static void on_focus(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    page *state = data;
    if (state->active) state->callbacks.focus(state->callbacks.context);
}

static void install_theme(page *state, const char *theme_script) {
    webkit_user_content_manager_remove_all_scripts(state->content);
    if (!theme_script) return;
    WebKitUserScript *script = webkit_user_script_new_for_world(theme_script, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                                                                "agterm-theme", NULL, NULL);
    webkit_user_content_manager_add_script(state->content, script);
    webkit_user_script_unref(script);
}

static GtkWidget *create(const agterm_web_callbacks *callbacks, bool javascript, bool transparent,
                         const char *theme_script) {
    register_scheme();
    page *state = g_new0(page, 1);
    state->callbacks = *callbacks;
    state->active = true;
    state->content = webkit_user_content_manager_new();
    install_theme(state, theme_script);

    WebKitSettings *settings = webkit_settings_new();
    webkit_settings_set_enable_javascript_markup(settings, javascript);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, FALSE);
    webkit_settings_set_allow_file_access_from_file_urls(settings, FALSE);
    webkit_settings_set_allow_universal_access_from_file_urls(settings, FALSE);
    webkit_settings_set_enable_developer_extras(settings, FALSE);
    webkit_settings_set_enable_fullscreen(settings, FALSE);
    webkit_settings_set_media_playback_requires_user_gesture(settings, TRUE);

    // an in-memory session per page: cookies and storage last as long as this overlay and reach no other
    WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
    g_signal_connect(session, "download-started", G_CALLBACK(on_download), NULL);
    GtkWidget *view = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", session, "settings", settings,
                                              "user-content-manager", state->content, NULL));
    g_object_unref(session);
    g_object_unref(settings);
    g_object_set_data_full(G_OBJECT(view), PAGE_KEY, state, page_free);

    if (transparent) {
        GdkRGBA clear = {0, 0, 0, 0};
        webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(view), &clear);
    }
    g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), state);
    g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), state);
    g_signal_connect(view, "load-failed", G_CALLBACK(on_load_failed), state);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(on_terminated), state);
    g_signal_connect(view, "notify::uri", G_CALLBACK(on_notify), state);
    g_signal_connect(view, "notify::title", G_CALLBACK(on_notify), state);
    g_signal_connect(webkit_web_view_get_back_forward_list(WEBKIT_WEB_VIEW(view)), "changed", G_CALLBACK(on_history), state);
    g_signal_connect(view, "create", G_CALLBACK(on_create), state);
    g_signal_connect(view, "script-dialog", G_CALLBACK(on_script_dialog), state);
    g_signal_connect(view, "run-file-chooser", G_CALLBACK(on_file_chooser), state);
    g_signal_connect(view, "permission-request", G_CALLBACK(on_permission), state);
    g_signal_connect(view, "enter-fullscreen", G_CALLBACK(on_refused), state);
    g_signal_connect(view, "show-notification", G_CALLBACK(on_notification), state);
    g_signal_connect(view, "context-menu", G_CALLBACK(on_context_menu), state);

    GtkEventController *input = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(input, GTK_PHASE_CAPTURE);
    g_signal_connect(input, "event", G_CALLBACK(on_event), state);
    gtk_widget_add_controller(view, input);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_focus), state);
    gtk_widget_add_controller(view, focus);
    return view;
}

static void set_theme_script(GtkWidget *view, const char *theme_script) {
    page *state = page_of(view);
    if (state) install_theme(state, theme_script);
}

static void load_uri(GtkWidget *view, const char *uri) {
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), uri);
}

static void load_html(GtkWidget *view, const char *html) {
    webkit_web_view_load_html(WEBKIT_WEB_VIEW(view), html, NULL);
}

static void load_file(GtkWidget *view, const char *path, const char *grant_root) {
    page *state = page_of(view);
    char resolved[PATH_MAX];
    char *uri = g_filename_to_uri(path, NULL, NULL);
    if (!state || !uri) {
        g_free(uri);
        return;
    }
    g_free(state->grant_root);
    state->grant_root = realpath(grant_root, resolved) ? g_strdup(resolved) : NULL;
    char *granted = g_strconcat(GRANT_SCHEME ":", uri + strlen("file:"), NULL);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), granted);
    g_free(granted);
    g_free(uri);
}

static void reload(GtkWidget *view) { webkit_web_view_reload(WEBKIT_WEB_VIEW(view)); }
static void go_back(GtkWidget *view) { webkit_web_view_go_back(WEBKIT_WEB_VIEW(view)); }
static void go_forward(GtkWidget *view) { webkit_web_view_go_forward(WEBKIT_WEB_VIEW(view)); }
static bool can_go_back(GtkWidget *view) { return webkit_web_view_can_go_back(WEBKIT_WEB_VIEW(view)); }
static bool can_go_forward(GtkWidget *view) { return webkit_web_view_can_go_forward(WEBKIT_WEB_VIEW(view)); }
static char *uri(GtkWidget *view) { return app_uri(webkit_web_view_get_uri(WEBKIT_WEB_VIEW(view))); }
static char *title(GtkWidget *view) { return g_strdup(webkit_web_view_get_title(WEBKIT_WEB_VIEW(view))); }

static void close_view(GtkWidget *view) {
    page *state = page_of(view);
    if (state) state->active = false;
    webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(view));
}

static const agterm_webkit_api api = {
    .abi = AGTERM_WEBKIT_ABI,
    .create = create,
    .set_theme_script = set_theme_script,
    .load_uri = load_uri,
    .load_html = load_html,
    .load_file = load_file,
    .reload = reload,
    .go_back = go_back,
    .go_forward = go_forward,
    .can_go_back = can_go_back,
    .can_go_forward = can_go_forward,
    .uri = uri,
    .title = title,
    .close = close_view,
};

__attribute__((visibility("default"))) const agterm_webkit_api *agterm_webkit_api_v1(void) { return &api; }
