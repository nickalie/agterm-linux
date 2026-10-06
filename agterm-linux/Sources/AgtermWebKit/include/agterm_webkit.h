#ifndef AGTERM_WEBKIT_H
#define AGTERM_WEBKIT_H

// The contract between the app and libagterm-webkit.so, the one piece linked against WebKitGTK. The app
// dlopens the plugin and reads everything through `agterm_webkit_api_v1`, so it runs without WebKitGTK and
// never sees a WebKit type. Bump AGTERM_WEBKIT_ABI on any change to these structs.

#include <gtk/gtk.h>
#include <stdbool.h>

#define AGTERM_WEBKIT_ABI 3
#define AGTERM_WEBKIT_ENTRY "agterm_webkit_api_v1"

// Where a navigation lands. WebKitGTK does not say whether a navigation targets the main frame or a
// subframe, so the app checks origins again on the main frame's response.
typedef enum {
    AGTERM_WEB_NAVIGATION_FRAME = 0,
    AGTERM_WEB_NAVIGATION_NEW_WINDOW = 1,
    AGTERM_WEB_RESPONSE_MAIN_FRAME = 2,
    AGTERM_WEB_RESPONSE_SUBFRAME = 3,
} agterm_web_target;

typedef enum {
    AGTERM_WEB_LOAD_STARTED = 0,
    AGTERM_WEB_LOAD_COMMITTED = 1,
    AGTERM_WEB_LOAD_FINISHED = 2,
    AGTERM_WEB_LOAD_FAILED = 3,
    // superseded or stopped: never a failed page
    AGTERM_WEB_LOAD_CANCELLED = 4,
    // WebKit's frame-load-interrupted: a policy cancel, or a response it cannot show
    AGTERM_WEB_LOAD_INTERRUPTED = 5,
    AGTERM_WEB_PROCESS_TERMINATED = 6,
} agterm_web_load_event;

typedef struct {
    void *context;
    // decide is asked about every navigation and main or sub-frame response; true lets it proceed. A
    // `file:` URI the app allows is loaded through the plugin's grant scheme instead.
    bool (*decide)(void *context, const char *uri, agterm_web_target target, bool user_activated);
    void (*load)(void *context, agterm_web_load_event event, const char *message);
    // changed follows the address, the title and the history
    void (*changed)(void *context);
    // input is a native key or button press on the page, which script cannot synthesize
    void (*input)(void *context);
    void (*focus)(void *context);
    // request is a page's control request as JSON; the app answers it once through `answer`, with `reply`
    void (*request)(void *context, const char *json, void *reply);
} agterm_web_callbacks;

// The page bridge's scripts, NULL for a page without one. `adapter` and `relay` run in agterm's isolated
// world, the only one the native handler is registered in; `helper` runs in the page's world.
typedef struct {
    const char *adapter;
    const char *relay;
    const char *helper;
} agterm_web_bridge;

typedef struct {
    unsigned abi;
    // create returns a floating GtkWidget. transparent leaves the canvas undrawn; theme_script runs at
    // document start in an isolated world, page JavaScript or not. A NULL storage_dir gives the page an
    // in-memory session of its own; every page naming the same directory shares the session saved there.
    GtkWidget *(*create)(const agterm_web_callbacks *callbacks, bool javascript, bool transparent,
                         const char *theme_script, const agterm_web_bridge *bridge, const char *storage_dir);
    void (*set_theme_script)(GtkWidget *view, const char *theme_script);
    void (*load_uri)(GtkWidget *view, const char *uri);
    // load_html shows text with no base URI, so the page can reach no file
    void (*load_html)(GtkWidget *view, const char *html);
    // load_file serves `path` and anything else under `grant_root`, nothing outside it
    void (*load_file)(GtkWidget *view, const char *path, const char *grant_root);
    void (*reload)(GtkWidget *view);
    void (*go_back)(GtkWidget *view);
    void (*go_forward)(GtkWidget *view);
    bool (*can_go_back)(GtkWidget *view);
    bool (*can_go_forward)(GtkWidget *view);
    // uri and title return newly allocated strings for g_free, or NULL; uri reports a granted file as file:
    char *(*uri)(GtkWidget *view);
    char *(*title)(GtkWidget *view);
    // close stops the view and drops its callbacks, so nothing reaches a released context
    void (*close)(GtkWidget *view);
    void (*set_zoom)(GtkWidget *view, double zoom);
    // answer resolves a request with a JSON result, or rejects it with `error`, and frees `reply`
    void (*answer)(void *reply, const char *result_json, const char *error);
    // clear_storage removes all website data saved in storage_dir and calls done once WebKit is finished,
    // with NULL or the reason it failed
    void (*clear_storage)(const char *storage_dir, void (*done)(void *context, const char *error), void *context);
} agterm_webkit_api;

typedef const agterm_webkit_api *(*agterm_webkit_entry)(void);

#endif
