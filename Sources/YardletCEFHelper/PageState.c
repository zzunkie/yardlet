// The renderer's side of the memory saver (docs/BROWSER_HOST.md §3 "Memory saver"). Before the browser host ends a
// hidden tab's renderer, as Chrome's Memory Saver discards a tab, it asks each of the tab's frames what Chrome
// would not discard: media playing out loud, form fields the page did not load with. The main frame's renderer
// also says whether it holds frames of another tab (Chromium puts same-site pages of one profile, and their
// iframes, in one process), since ending that process would end the other tab's page as well. CEF tells a
// renderer of every browser that has a frame in it (OnBrowserCreated), and of its end.

#include "PageState.h"

#include <dlfcn.h>
#include <string.h>

#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_values_capi.h"

// The browser host (YardletCEFBridge.c) names the same two messages and flags.
static const char kPageStateQuery[] = "YardletPageStateQuery";
static const char kPageStateAnswer[] = "YardletPageState";
enum {
    kPageStatePlaying = 1,
    kPageStateEdited = 2,
    kPageStateMedia = 4,
    kPageStateMain = 8,
    kPageStateShared = 16,
    kPageStateUnknown = 32
};

// Audible media playback, whether the frame has media at all, and fields whose
// value differs from the one the page loaded with (Chrome's "partially filled forms"): typed or picked text,
// a changed choice or check box, a chosen file. Read only; the page is not changed.
static const char kPageStateScript[] =
    "(function(){var r=0;"
    "var m=document.querySelectorAll('audio,video');if(m.length)r|=4;"
    "for(var i=0;i<m.length;i++){var e=m[i];if(!e.paused&&!e.ended&&!e.muted&&e.volume>0)r|=1;}"
    "var f=document.querySelectorAll('input,textarea,select');"
    "for(var j=0;j<f.length&&!(r&2);j++){var x=f[j];if(x.disabled)continue;var t=(x.type||'').toLowerCase();"
    "if(x.tagName==='SELECT'){for(var k=0;k<x.options.length;k++){if(x.options[k].selected!==x.options[k].defaultSelected){r|=2;break;}}}"
    "else if(t==='checkbox'||t==='radio'){if(x.checked!==x.defaultChecked)r|=2;}"
    "else if(t==='file'){if(x.files&&x.files.length)r|=2;}"
    "else if(t!=='hidden'&&t!=='submit'&&t!=='button'&&t!=='reset'&&t!=='image'&&!x.readOnly&&x.value!==x.defaultValue)r|=2;}"
    "return r;})()";

static __typeof__(&cef_process_message_create) p_cef_process_message_create;
static __typeof__(&cef_string_utf8_to_utf16) p_cef_string_utf8_to_utf16;
static __typeof__(&cef_string_utf16_clear) p_cef_string_utf16_clear;
static __typeof__(&cef_string_userfree_utf16_free) p_cef_string_userfree_utf16_free;

#define RELEASE(object)                                           \
    do {                                                          \
        if (object) (object)->base.release(&(object)->base);      \
    } while (0)

// The browsers with a frame in this renderer, by CEF identifier, once for each browser object CEF made here: CEF makes
// one per page (blink::WebView), and may make a browser's next one before its last goes ("When browsing cross-origin a
// new browser will be created before the old browser with the same identifier is destroyed"). Only the renderer's main
// thread uses it.
enum { kMaximumBrowsers = 512 };
static int g_browsers[kMaximumBrowsers];
static int g_browser_count;
/// Browser objects made past the table, which leave the renderer answering as shared until they go.
static int g_overflow;

int yardlet_page_state_init(void *framework) {
    p_cef_process_message_create = (__typeof__(p_cef_process_message_create))dlsym(framework, "cef_process_message_create");
    p_cef_string_utf8_to_utf16 = (__typeof__(p_cef_string_utf8_to_utf16))dlsym(framework, "cef_string_utf8_to_utf16");
    p_cef_string_utf16_clear = (__typeof__(p_cef_string_utf16_clear))dlsym(framework, "cef_string_utf16_clear");
    p_cef_string_userfree_utf16_free =
        (__typeof__(p_cef_string_userfree_utf16_free))dlsym(framework, "cef_string_userfree_utf16_free");
    return p_cef_process_message_create && p_cef_string_utf8_to_utf16 && p_cef_string_utf16_clear
        && p_cef_string_userfree_utf16_free;
}

void yardlet_page_state_browser_created(cef_browser_t *browser) {
    if (browser == NULL) return;
    if (g_browser_count < kMaximumBrowsers) g_browsers[g_browser_count++] = browser->get_identifier(browser);
    else g_overflow++;
}

void yardlet_page_state_browser_destroyed(cef_browser_t *browser) {
    if (browser == NULL) return;
    int identifier = browser->get_identifier(browser);
    for (int index = 0; index < g_browser_count; index++) {
        if (g_browsers[index] != identifier) continue;
        g_browsers[index] = g_browsers[--g_browser_count];
        return;
    }
    if (g_overflow > 0) g_overflow--;
}

/// Whether this renderer holds a frame of a browser other than `identifier`.
static int holds_another_browser(int identifier) {
    if (g_overflow > 0) return 1;
    for (int index = 0; index < g_browser_count; index++) {
        if (g_browsers[index] != identifier) return 1;
    }
    return 0;
}

static int name_is(cef_process_message_t *message, const char *expected) {
    cef_string_userfree_t name = message->get_name(message);
    cef_string_t wanted = {0};
    p_cef_string_utf8_to_utf16(expected, strlen(expected), &wanted);
    int same = name != NULL && name->length == wanted.length
        && memcmp(name->str, wanted.str, wanted.length * sizeof(*wanted.str)) == 0;
    p_cef_string_utf16_clear(&wanted);
    if (name) p_cef_string_userfree_utf16_free(name);
    return same;
}

/// Runs kPageStateScript in the frame's page; kPageStateUnknown when it could not run.
static int read_page(cef_frame_t *frame) {
    cef_v8_context_t *context = frame->get_v8_context(frame);
    if (context == NULL) return kPageStateUnknown;
    int flags = kPageStateUnknown;
    if (context->enter(context)) {
        cef_string_t code = {0}, url = {0};
        p_cef_string_utf8_to_utf16(kPageStateScript, strlen(kPageStateScript), &code);
        cef_v8_value_t *value = NULL;
        cef_v8_exception_t *exception = NULL;
        if (context->eval(context, &code, &url, 0, &value, &exception) && value && value->is_int(value)) {
            flags = value->get_int_value(value) & (kPageStatePlaying | kPageStateEdited | kPageStateMedia);
        }
        RELEASE(value);
        RELEASE(exception);
        p_cef_string_utf16_clear(&code);
        context->exit(context);
    }
    RELEASE(context);
    return flags;
}

int yardlet_page_state_message(cef_browser_t *browser, cef_frame_t *frame, cef_process_message_t *message) {
    if (browser == NULL || frame == NULL || message == NULL || !name_is(message, kPageStateQuery)) return 0;
    cef_list_value_t *arguments = message->get_argument_list(message);
    int query = arguments && arguments->get_size(arguments) > 0 ? arguments->get_int(arguments, 0) : 0;
    RELEASE(arguments);
    int flags = read_page(frame);
    if (frame->is_main(frame)) flags |= kPageStateMain;
    if (holds_another_browser(browser->get_identifier(browser))) flags |= kPageStateShared;

    cef_string_t name = {0};
    p_cef_string_utf8_to_utf16(kPageStateAnswer, strlen(kPageStateAnswer), &name);
    cef_process_message_t *answer = p_cef_process_message_create(&name);
    p_cef_string_utf16_clear(&name);
    if (answer == NULL) return 1;
    cef_list_value_t *values = answer->get_argument_list(answer);
    if (values) {
        values->set_int(values, 0, query);
        values->set_int(values, 1, flags);
    }
    RELEASE(values);
    // Passing the message gives the frame our reference.
    frame->send_process_message(frame, PID_BROWSER, answer);
    return 1;
}
