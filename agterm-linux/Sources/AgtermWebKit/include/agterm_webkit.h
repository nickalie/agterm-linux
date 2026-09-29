#ifndef AGTERM_WEBKIT_H
#define AGTERM_WEBKIT_H

// The contract between the app and libagterm-webkit.so, the one piece linked against WebKitGTK. The app
// dlopens the plugin and reads everything through `agterm_webkit_api_v1`, so it runs without WebKitGTK and
// never sees a WebKit type. Bump AGTERM_WEBKIT_ABI on any change to these structs.

#include <gtk/gtk.h>
#include <stdbool.h>

#define AGTERM_WEBKIT_ABI 1
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
} agterm_web_callbacks;

typedef struct {
    unsigned abi;
    // create returns a floating GtkWidget. transparent leaves the canvas undrawn; theme_script runs at
    // document start in an isolated world, page JavaScript or not.
    GtkWidget *(*create)(const agterm_web_callbacks *callbacks, bool javascript, bool transparent,
                         const char *theme_script);
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
} agterm_webkit_api;

typedef const agterm_webkit_api *(*agterm_webkit_entry)(void);

#endif
