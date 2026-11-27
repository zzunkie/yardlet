// The renderer's side of a page's focused field (docs/BROWSER_HOST.md §4). CEF 154's windowless view
// tells the browser process nothing about the focused field's type (OnVirtualKeyboardRequested carries
// only `inputmode`, and only when an input method may show), so each renderer reports a focus change in
// its frames, what kind of text the newly focused element takes (none, an <input type=password>, or
// another text field and the keyboard it asks for), and answers the browser host's question about a
// frame's focused field after a new document commits (a page from the back-forward cache keeps its
// focused field and reports no change). Yardlet's panel turns on secure keyboard entry and Roman input
// sources while a password field has the keyboard, as Safari and Chrome do; a remote device shows its
// own keyboard while any text field has it.

#include "FocusedField.h"
#include "PageState.h"

#include <dlfcn.h>
#include <string.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_dom_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_values_capi.h"

// The browser host (YardletCEFBridge.c) names the same two messages.
static const char kFocusedFieldMessage[] = "YardletFocusedField";
static const char kFocusedFieldQuery[] = "YardletFocusedFieldQuery";

static __typeof__(&cef_process_message_create) p_cef_process_message_create;
static __typeof__(&cef_string_utf8_to_utf16) p_cef_string_utf8_to_utf16;
static __typeof__(&cef_string_utf16_clear) p_cef_string_utf16_clear;
static __typeof__(&cef_string_userfree_utf16_free) p_cef_string_userfree_utf16_free;

#define RELEASE(object)                                           \
    do {                                                          \
        if (object) (object)->base.release(&(object)->base);      \
    } while (0)

// Every handler here is a process-lifetime static: CEF may add and release references, but they are
// never freed.
static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) { (void)self; }
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) { (void)self; return 0; }
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) { (void)self; return 1; }
static int CEF_CALLBACK static_has_at_least_one_ref(cef_base_ref_counted_t *self) { (void)self; return 1; }

static void init_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = static_add_ref;
    base->release = static_release;
    base->has_one_ref = static_has_one_ref;
    base->has_at_least_one_ref = static_has_at_least_one_ref;
}

// What the focused element takes, as the browser host (YardletCEFBridge.c, YardletCEFEventEditableField)
// reads the number.
enum {
    kFieldNone = 0,
    kFieldText = 1,
    kFieldPassword = 2,
    kFieldEmail = 3,
    kFieldURL = 4,
    kFieldTelephone = 5,
    kFieldNumeric = 6,
    kFieldDecimal = 7,
    kFieldSearch = 8,
};

/// Whether the element has the attribute. Borrows the node's reference.
static int has_attribute(cef_domnode_t *node, const char *name) {
    cef_string_t wanted = {0};
    p_cef_string_utf8_to_utf16(name, strlen(name), &wanted);
    int has = node->has_element_attribute(node, &wanted);
    p_cef_string_utf16_clear(&wanted);
    return has;
}

/// The element's `inputmode` as a field kind, or kFieldNone when it has none Yardlet reads. Borrows the
/// node's reference.
static int input_mode_kind(cef_domnode_t *node) {
    cef_string_t name = {0};
    p_cef_string_utf8_to_utf16("inputmode", strlen("inputmode"), &name);
    cef_string_userfree_t value = node->get_element_attribute(node, &name);
    p_cef_string_utf16_clear(&name);
    if (value == NULL) return kFieldNone;
    // ASCII only, lowercased: HTML reads the attribute's keywords case-insensitively.
    char mode[16] = {0};
    size_t length = 0;
    for (; length < value->length && length < sizeof(mode) - 1; length++) {
        __typeof__(*value->str) c = value->str[length];
        if (c > 0x7f) break;
        mode[length] = (char)((c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c);
    }
    int complete = length == value->length;
    p_cef_string_userfree_utf16_free(value);
    if (!complete) return kFieldNone;
    static const struct { const char *mode; int kind; } modes[] = {
        {"text", kFieldText}, {"email", kFieldEmail}, {"url", kFieldURL}, {"tel", kFieldTelephone},
        {"numeric", kFieldNumeric}, {"decimal", kFieldDecimal}, {"search", kFieldSearch},
    };
    for (size_t index = 0; index < sizeof(modes) / sizeof(modes[0]); index++) {
        if (strcmp(mode, modes[index].mode) == 0) return modes[index].kind;
    }
    return kFieldNone;
}

/// What text the focused element takes: none for a control that takes no typing (a button, a checkbox, a
/// select, a date picker, a disabled or read-only field), the keyboard a text field asks for by its type or
/// its `inputmode`, and always kFieldPassword for an <input type=password>. Takes the node's reference.
static int field_kind(cef_domnode_t *node) {
    if (node == NULL) return kFieldNone;
    int kind = kFieldNone;
    if (node->is_form_control_element(node)) {
        switch (node->get_form_control_element_type(node)) {
        case DOM_FORM_CONTROL_TYPE_INPUT_PASSWORD: kind = kFieldPassword; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_TEXT:
        case DOM_FORM_CONTROL_TYPE_TEXT_AREA: kind = kFieldText; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_EMAIL: kind = kFieldEmail; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_URL: kind = kFieldURL; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_TELEPHONE: kind = kFieldTelephone; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_NUMBER: kind = kFieldNumeric; break;
        case DOM_FORM_CONTROL_TYPE_INPUT_SEARCH: kind = kFieldSearch; break;
        default: break;
        }
        // A password field stays one whatever else it says, so the panel's secure input never misses it.
        if (kind != kFieldNone && kind != kFieldPassword
            && (!node->is_editable(node) || has_attribute(node, "readonly") || has_attribute(node, "disabled"))) {
            kind = kFieldNone;
        }
    } else if (node->is_element(node) && node->is_editable(node)) {
        // contenteditable, or an element inside one.
        kind = kFieldText;
    }
    if (kind != kFieldNone && kind != kFieldPassword) {
        int mode = input_mode_kind(node);
        if (mode != kFieldNone) kind = mode;
    }
    RELEASE(node);
    return kind;
}

/// Sends the frame's focused field to the browser process: whether it is a password field (the first
/// argument, as before the kinds), its kind, and whether focus moved (1) or the host asked (0). Borrows the
/// frame's reference.
static void report(cef_frame_t *frame, int kind, int focus_moved) {
    if (frame == NULL) return;
    cef_string_t name = {0};
    p_cef_string_utf8_to_utf16(kFocusedFieldMessage, strlen(kFocusedFieldMessage), &name);
    cef_process_message_t *message = p_cef_process_message_create(&name);
    p_cef_string_utf16_clear(&name);
    if (message == NULL) return;
    cef_list_value_t *arguments = message->get_argument_list(message);
    if (arguments) {
        arguments->set_bool(arguments, 0, kind == kFieldPassword);
        arguments->set_int(arguments, 1, kind);
        arguments->set_bool(arguments, 2, focus_moved);
    }
    RELEASE(arguments);
    // Passing the message gives the frame our reference.
    frame->send_process_message(frame, PID_BROWSER, message);
}

static void CEF_CALLBACK render_on_focused_node_changed(cef_render_process_handler_t *self, cef_browser_t *browser,
                                                        cef_frame_t *frame, cef_domnode_t *node) {
    (void)self;
    report(frame, field_kind(node), 1);
    RELEASE(frame);
    RELEASE(browser);
}

// cef_frame_t.visit_dom calls the visitor before it returns.
static int g_visited_kind;

static void CEF_CALLBACK visit_focused_field(cef_domvisitor_t *self, cef_domdocument_t *document) {
    (void)self;
    g_visited_kind = document ? field_kind(document->get_focused_node(document)) : kFieldNone;
    RELEASE(document);
}

static cef_domvisitor_t g_visitor;

static int message_is(cef_process_message_t *message, const char *expected) {
    cef_string_userfree_t name = message->get_name(message);
    cef_string_t wanted = {0};
    p_cef_string_utf8_to_utf16(expected, strlen(expected), &wanted);
    int same = name != NULL && name->length == wanted.length
        && memcmp(name->str, wanted.str, wanted.length * sizeof(*wanted.str)) == 0;
    p_cef_string_utf16_clear(&wanted);
    if (name) p_cef_string_userfree_utf16_free(name);
    return same;
}

static int CEF_CALLBACK render_on_process_message_received(cef_render_process_handler_t *self, cef_browser_t *browser,
                                                           cef_frame_t *frame, cef_process_id_t source_process,
                                                           cef_process_message_t *message) {
    (void)self;
    int handled = 0;
    if (source_process == PID_BROWSER && yardlet_page_state_message(browser, frame, message)) {
        handled = 1;
    } else if (source_process == PID_BROWSER && frame != NULL && message != NULL && message_is(message, kFocusedFieldQuery)) {
        handled = 1;
        g_visited_kind = kFieldNone;
        // Passing the visitor gives up a reference, which a static ignores.
        frame->visit_dom(frame, &g_visitor);
        report(frame, g_visited_kind, 0);
    }
    RELEASE(message);
    RELEASE(frame);
    RELEASE(browser);
    return handled;
}

static void CEF_CALLBACK render_on_browser_created(cef_render_process_handler_t *self, cef_browser_t *browser,
                                                   cef_dictionary_value_t *extra_info) {
    (void)self;
    yardlet_page_state_browser_created(browser);
    RELEASE(extra_info);
    RELEASE(browser);
}

static void CEF_CALLBACK render_on_browser_destroyed(cef_render_process_handler_t *self, cef_browser_t *browser) {
    (void)self;
    yardlet_page_state_browser_destroyed(browser);
    RELEASE(browser);
}

static cef_render_process_handler_t g_render_process_handler;
static cef_app_t g_app;

static cef_render_process_handler_t *CEF_CALLBACK app_get_render_process_handler(cef_app_t *self) {
    (void)self;
    return &g_render_process_handler;
}

cef_app_t *yardlet_helper_app(void *framework) {
    p_cef_process_message_create = (__typeof__(p_cef_process_message_create))dlsym(framework, "cef_process_message_create");
    p_cef_string_utf8_to_utf16 = (__typeof__(p_cef_string_utf8_to_utf16))dlsym(framework, "cef_string_utf8_to_utf16");
    p_cef_string_utf16_clear = (__typeof__(p_cef_string_utf16_clear))dlsym(framework, "cef_string_utf16_clear");
    p_cef_string_userfree_utf16_free =
        (__typeof__(p_cef_string_userfree_utf16_free))dlsym(framework, "cef_string_userfree_utf16_free");
    // Without them the renderer reports nothing and the panel never turns secure input on.
    if (!p_cef_process_message_create || !p_cef_string_utf8_to_utf16 || !p_cef_string_utf16_clear
        || !p_cef_string_userfree_utf16_free || !yardlet_page_state_init(framework)) {
        return NULL;
    }
    memset(&g_visitor, 0, sizeof(g_visitor));
    init_base(&g_visitor.base, sizeof(g_visitor));
    g_visitor.visit = visit_focused_field;

    memset(&g_render_process_handler, 0, sizeof(g_render_process_handler));
    init_base(&g_render_process_handler.base, sizeof(g_render_process_handler));
    g_render_process_handler.on_focused_node_changed = render_on_focused_node_changed;
    g_render_process_handler.on_process_message_received = render_on_process_message_received;
    g_render_process_handler.on_browser_created = render_on_browser_created;
    g_render_process_handler.on_browser_destroyed = render_on_browser_destroyed;

    memset(&g_app, 0, sizeof(g_app));
    init_base(&g_app.base, sizeof(g_app));
    g_app.get_render_process_handler = app_get_render_process_handler;
    return &g_app;
}
