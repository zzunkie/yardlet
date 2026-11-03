// CEF C API bridge for the Yardlet browser host process (windowless rendering). The framework
// is opened with dlopen at run time (CEF's required macOS pattern), so this file resolves each
// C API function it uses instead of linking against the framework.

#include "YardletCEFBridge.h"

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_accessibility_handler_capi.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_audio_handler_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_image_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_menu_model_capi.h"
#include "include/capi/cef_parser_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_registration_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_drag_data_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_task_manager_capi.h"
#include "include/capi/cef_values_capi.h"

#define YARDLET_CEF_FUNCTIONS(X)            \
    X(cef_api_hash)                         \
    X(cef_initialize)                       \
    X(cef_run_message_loop)                 \
    X(cef_quit_message_loop)                \
    X(cef_shutdown)                         \
    X(cef_browser_host_create_browser_sync) \
    X(cef_request_context_create_context)   \
    X(cef_request_context_get_global_context) \
    X(cef_string_utf8_to_utf16)             \
    X(cef_string_utf16_to_utf8)             \
    X(cef_string_utf16_clear)               \
    X(cef_string_utf16_set)                 \
    X(cef_string_utf8_clear)                \
    X(cef_string_userfree_utf16_free)       \
    X(cef_string_list_alloc)                \
    X(cef_string_list_append)               \
    X(cef_string_list_size)                 \
    X(cef_string_list_value)                \
    X(cef_string_list_free)                 \
    X(cef_drag_data_create)                 \
    X(cef_process_message_create)           \
    X(cef_value_create)                     \
    X(cef_dictionary_value_create)          \
    X(cef_write_json)                       \
    X(cef_task_manager_get)

#define YARDLET_DECLARE_POINTER(name) static __typeof__(&name) p_##name;
YARDLET_CEF_FUNCTIONS(YARDLET_DECLARE_POINTER)
#undef YARDLET_DECLARE_POINTER

static void *g_library;
static YardletCEFCallbacks g_callbacks;

#define YARDLET_RELEASE(object)                                   \
    do {                                                          \
        if (object) (object)->base.release(&(object)->base);      \
    } while (0)

// MARK: - Strings

static void set_string(cef_string_t *target, const char *utf8) {
    if (utf8 == NULL) return;
    p_cef_string_utf8_to_utf16(utf8, strlen(utf8), target);
}

static char *copy_string(const cef_string_t *source) {
    if (source == NULL || source->str == NULL || source->length == 0) return strdup("");
    cef_string_utf8_t converted = {0};
    p_cef_string_utf16_to_utf8(source->str, source->length, &converted);
    char *result = strndup(converted.str ? converted.str : "", converted.length);
    p_cef_string_utf8_clear(&converted);
    return result;
}

static void emit(int tab, YardletCEFEvent event, const cef_string_t *text, const cef_string_t *detail,
                 int number) {
    if (g_callbacks.event == NULL) return;
    char *text_utf8 = text ? copy_string(text) : NULL;
    char *detail_utf8 = detail ? copy_string(detail) : NULL;
    g_callbacks.event(tab, (int)event, text_utf8, detail_utf8, number);
    free(text_utf8);
    free(detail_utf8);
}

// MARK: - Static reference counting
// Every handler below is a process-lifetime static. CEF may add and release references, but the
// objects are never freed.

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

// MARK: - Browser table
// One host holds every task's tabs and their pages' popups, up to 9 tabs a task (Yardlet's
// maxTabsPerSession) for as many tasks as the person keeps open. Until 2026-10-27 the table held 16, and
// once 16 were open no tab of any task opened (yardlet_cef_create_browser returns -1 then).

enum { kMaximumBrowsers = 256 };

typedef struct {
    int inUse;
    int tab;
    /// CEF browser identifier, -1 while cef_browser_host_create_browser_sync is running,
    /// kWaitingForProfile until the request context's profile has loaded, or kPopupPending from a page's
    /// new-window request until CEF makes the popup.
    int identifier;
    /// The address a browser waiting for its profile is made at, or a popup opens at.
    char *waitingURL;
    /// A popup's opener: its CEF identifier, the popup_id it asked with, its tab, and whether the page
    /// asked for the new window behind (a background-tab click).
    int openerIdentifier, popupID, openerTab, popupBehind;
    cef_browser_t *browser;
    cef_registration_t *devtoolsRegistration;
    /// Chromium's hang monitor found the tab's renderer unresponsive: held until it answers again, so
    /// the person (or a reload for the agent) can wait or end the renderer.
    cef_unresponsive_process_callback_t *unresponsive;
    double width, height, scale, screenX, screenY;
    /// When the view's size or scale last changed (CLOCK_MONOTONIC seconds), for the frames captured across it.
    double resizedAt;
    /// The windowless frame rate last given to CEF (the panel's display refresh rate).
    int frameRate;
    /// Yardlet's last focus command: a panel showing this tab has the keyboard.
    int focused;
    /// The page's focused field is a password field, as its renderer last said (YardletCEFEventPasswordField),
    /// and the identifier of the frame it is in (malloc'd), or NULL.
    int passwordFocused;
    char *passwordFrame;
    /// The request context the browser was made in: its index in g_contexts plus one, 0 for the global one.
    int contextHandle;
    int sharedTexture;
    /// Yardlet closed the tab: the page's beforeunload, which CEF still fires on a forced close, is
    /// answered with Leave (see jsdialog_on_before_unload_dialog).
    int closing;
    /// The page's leave-page question Yardlet was last asked (its dialog id): a close that cannot wait
    /// answers it Leave (yardlet_cef_close_browser).
    int leaveDialog;
    /// The memory saver ended the tab's renderer (yardlet_cef_discard): its end is a discard, not a crash.
    int discarding;
    /// When the page last began to play sound in its current document (monotonic_seconds), 0 before.
    double audibleAt;
    /// The page uses the camera or the microphone (OnMediaAccessChange).
    int capturing;
    /// Spellings of the passwords the vault filled into the page (yardlet_cef_guard_filled_values), each ended by
    /// a NUL, until the main frame starts another document: no navigation of the tab goes to an address that
    /// carries one. malloc'd, or NULL.
    char *filledValues;
    size_t filledValuesLength;
} BrowserSlot;

static BrowserSlot g_browsers[kMaximumBrowsers];
/// The browsers made at most, popups included: kMaximumBrowsers, or fewer for a QA run
/// (yardlet_cef_set_browser_limit).
static int g_browser_limit = kMaximumBrowsers;
enum { kWaitingForProfile = -2, kPopupPending = -3 };
static void release_media_prompts(int tab);
/// Tabs the host opens for pages' new windows; Yardlet numbers the tabs it opens from 1.
static int g_next_popup_tab = 1 << 30;

// MARK: - Chrome settings for windowless tabs
// Every profile gets a few of Chrome's own settings turned off, as a person would in Chrome's settings,
// where Chrome would go on in a browser window that a windowless tab does not have.
//
// Passkeys: a new passkey goes to this Mac (Touch ID) before a phone, as in Chrome. On a Mac with iCloud
// Drive on, Chromium makes new passkeys in iCloud Keychain first (ShouldCreateInICloudKeychain), which
// this browser cannot reach: the host has no Apple browser passkey entitlement and the page no window.
// With iCloud Keychain missing, create() went to the next choice, a phone's QR code, while Touch ID
// waited behind "Save another way". The setting does nothing else.
//
// Cards and addresses: once a page submits a card or an address, Chromium's autofill offers to save it
// in Chrome's bubble, which takes the tab's Chrome window without checking there is one
// (SaveCardBubbleControllerImpl::DoShowBubble, AddressBubblesController). On a windowless tab that ended
// the whole host, and every tab with it, as a person paid by card (2026-10-25). With both off, autofill
// takes neither from a submitted form and offers nothing. Addresses off also stops form history
// (autocomplete), whose suggestions need the tab's view in a window (CanShowRootPopup) and so never
// showed here.
//
// Passwords: Chrome's own password saving stays off, as a person turns off "Offer to save passwords":
// Yardlet's password manager keeps sign-ins in the keychain, and a profile's Login Data is a file any
// process of the person's can read.
static void turn_off_preference(cef_request_context_t *context, const char *name) {
    cef_value_t *value = p_cef_value_create();
    if (value == NULL) return;
    value->set_bool(value, 0);
    cef_string_t key = {0};
    cef_string_t error = {0};
    set_string(&key, name);
    // set_preference takes the value's reference.
    if (!context->base.set_preference(&context->base, &key, value, &error)) {
        char *message = copy_string(&error);
        fprintf(stderr, "Yardlet Browser Host: %s not set: %s\n", name, message);
        free(message);
    }
    p_cef_string_utf16_clear(&key);
    p_cef_string_utf16_clear(&error);
}

static void set_windowless_preferences(cef_request_context_t *context) {
    if (context == NULL) return;
    turn_off_preference(context, "webauthn.create_in_icloud_keychain");
    turn_off_preference(context, "autofill.credit_card_enabled");
    turn_off_preference(context, "autofill.profile_enabled");
    turn_off_preference(context, "credentials_enable_service");
    turn_off_preference(context, "credentials_enable_autosignin");
}

// MARK: - Request contexts
// A task's tabs share one request context with its own cache folder (cookies, storage, cache), so tasks
// do not see each other's sign-ins (docs/BROWSER_SESSION_ISOLATION.md). A context lives while a browser
// or a cookie copy holds it and is released after the last one; Chromium then lets go of the folder.
// Chromium loads a profile on disk asynchronously and makes no browser in it before then (a cookie
// manager waits on its own), so a browser for a context not ready yet is made when it is.

typedef struct {
    int inUse;
    char *path;
    cef_request_context_t *context;
    int users;
    int ready;
} ContextSlot;

/// A context for every browser, and room for the contexts a cookie copy holds while it runs.
enum { kMaximumContexts = kMaximumBrowsers + 32 };
static ContextSlot g_contexts[kMaximumContexts];
/// Each context's handler; its position in this table names the context.
static cef_request_context_handler_t g_context_handlers[kMaximumContexts];
static char *g_accept_languages;

static void make_waiting_browsers(int handle);

static void CEF_CALLBACK context_initialized(cef_request_context_handler_t *self,
                                             cef_request_context_t *request_context) {
    int index = (int)(self - g_context_handlers);
    ContextSlot *slot = index >= 0 && index < kMaximumContexts && g_contexts[index].inUse ? &g_contexts[index] : NULL;
    // A context let go before it loaded can report after another took its place (no context yet: the
    // report comes during its own create call).
    if (slot && slot->context && request_context) {
        request_context->base.base.add_ref(&request_context->base.base);  // is_same takes a reference
        if (!slot->context->is_same(slot->context, request_context)) slot = NULL;
    }
    set_windowless_preferences(request_context);
    if (request_context) request_context->base.base.release(&request_context->base.base);
    if (slot == NULL) return;
    slot->ready = 1;
    make_waiting_browsers(index + 1);
}

/// The context for `path`, made on first use, with one more user: its handle (index plus one), 0 for the
/// global context (an empty path), -1 when Chromium could not make it.
static int acquire_context(const char *path) {
    if (path == NULL || path[0] == '\0') return 0;
    for (int index = 0; index < kMaximumContexts; index++) {
        if (g_contexts[index].inUse && strcmp(g_contexts[index].path, path) == 0) {
            g_contexts[index].users++;
            return index + 1;
        }
    }
    for (int index = 0; index < kMaximumContexts; index++) {
        if (g_contexts[index].inUse) continue;
        cef_request_context_settings_t settings;
        memset(&settings, 0, sizeof(settings));
        settings.size = sizeof(settings);
        settings.persist_session_cookies = 1;
        set_string(&settings.cache_path, path);
        set_string(&settings.accept_language_list, g_accept_languages);
        // In use before Chromium has it: a profile already loaded reports ready during the call.
        g_contexts[index] = (ContextSlot){1, strdup(path), NULL, 1, 0};
        cef_request_context_handler_t *handler = &g_context_handlers[index];
        init_base(&handler->base, sizeof(*handler));
        handler->on_request_context_initialized = context_initialized;
        cef_request_context_t *context = p_cef_request_context_create_context(&settings, handler);
        p_cef_string_utf16_clear(&settings.cache_path);
        p_cef_string_utf16_clear(&settings.accept_language_list);
        if (context == NULL) {
            free(g_contexts[index].path);
            memset(&g_contexts[index], 0, sizeof(g_contexts[index]));
            return -1;
        }
        g_contexts[index].context = context;
        return index + 1;
    }
    return -1;
}

// A request context's reference count sits under its preference manager base.
#define YARDLET_RELEASE_CONTEXT(context)                                          \
    do {                                                                          \
        if (context) (context)->base.base.release(&(context)->base.base);         \
    } while (0)

static void release_context(int handle) {
    if (handle <= 0 || handle > kMaximumContexts) return;
    ContextSlot *slot = &g_contexts[handle - 1];
    if (!slot->inUse || --slot->users > 0) return;
    YARDLET_RELEASE_CONTEXT(slot->context);
    free(slot->path);
    memset(slot, 0, sizeof(*slot));
}

/// A new reference to the context of `handle` (the global one for 0); the caller releases it.
static cef_request_context_t *context_reference(int handle) {
    if (handle <= 0) return p_cef_request_context_get_global_context();
    cef_request_context_t *context = g_contexts[handle - 1].context;
    context->base.base.add_ref(&context->base.base);
    return context;
}

// CEF asks for the render handler and the accessibility handler without saying which browser they
// are for, so every slot has its own client, render handler and accessibility handler; the
// handler's position in this table names the slot. The structures live for the whole process and
// are never cleared, because CEF may still release a closed browser's client later.
typedef struct {
    cef_client_t client;
    cef_render_handler_t renderHandler;
    cef_accessibility_handler_t accessibilityHandler;
} SlotClient;

static SlotClient g_slot_clients[kMaximumBrowsers];

static int opener_of(cef_browser_t *browser) {
    cef_browser_host_t *host = browser->get_host(browser);
    if (host == NULL) return 0;
    int opener = host->get_opener_identifier(host);
    YARDLET_RELEASE(host);
    return opener;
}

static BrowserSlot *slot_for_browser(cef_browser_t *browser) {
    if (browser == NULL) return NULL;
    int identifier = browser->get_identifier(browser);
    BrowserSlot *pending = NULL;
    int hasPopup = 0;
    for (int index = 0; index < kMaximumBrowsers; index++) {
        BrowserSlot *slot = &g_browsers[index];
        if (!slot->inUse) continue;
        if (slot->identifier == identifier) return slot;
        if (slot->identifier == -1) pending = slot;
        if (slot->identifier == kPopupPending) hasPopup = 1;
    }
    // A popup is made after OnBeforePopup returns, and its first queries come before OnAfterCreated:
    // it is the oldest slot reserved for a popup of its opener.
    int opener = hasPopup ? opener_of(browser) : 0;
    for (int index = 0; opener != 0 && index < kMaximumBrowsers; index++) {
        BrowserSlot *slot = &g_browsers[index];
        if (slot->inUse && slot->identifier == kPopupPending && slot->openerIdentifier == opener) {
            slot->identifier = identifier;
            return slot;
        }
    }
    // Render handler queries arrive during creation, before the identifier is known.
    if (pending) pending->identifier = identifier;
    return pending;
}

/// A slot for another browser, or NULL when g_browser_limit are in use.
static BrowserSlot *free_slot(void) {
    BrowserSlot *free = NULL;
    int used = 0;
    for (int index = 0; index < kMaximumBrowsers; index++) {
        if (g_browsers[index].inUse) used++;
        else if (free == NULL) free = &g_browsers[index];
    }
    return used < g_browser_limit ? free : NULL;
}

static BrowserSlot *slot_for_tab(int tab) {
    for (int index = 0; index < kMaximumBrowsers; index++) {
        if (g_browsers[index].inUse && g_browsers[index].tab == tab) return &g_browsers[index];
    }
    return NULL;
}

static int tab_of(cef_browser_t *browser) {
    BrowserSlot *slot = slot_for_browser(browser);
    return slot ? slot->tab : -1;
}

static cef_browser_host_t *host_for_tab(int tab) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL) return NULL;
    return slot->browser->get_host(slot->browser);
}

// MARK: - Password fields
// CEF 154's windowless view tells the browser process nothing about the focused field's type
// (OnVirtualKeyboardRequested carries only `inputmode`, and only when an input method may show), so each
// renderer reports it (YardletCEFHelper's FocusedField.c): a focus change in one of its frames, and the
// answer to a question about a frame's focused field. Yardlet's panel turns on secure keyboard entry and
// Roman input sources while that field has the keyboard, as Safari and Chrome do (BrowserHostView).

static const char kFocusedFieldMessage[] = "YardletFocusedField";
static const char kFocusedFieldQuery[] = "YardletFocusedFieldQuery";

/// Borrows the frame's reference.
static void set_password_focus(BrowserSlot *slot, int focused, cef_frame_t *frame) {
    free(slot->passwordFrame);
    slot->passwordFrame = NULL;
    if (focused && frame) {
        cef_string_userfree_t identifier = frame->get_identifier(frame);
        slot->passwordFrame = copy_string(identifier);
        if (identifier) p_cef_string_userfree_utf16_free(identifier);
    }
    if (slot->passwordFocused == focused) return;
    slot->passwordFocused = focused;
    emit(slot->tab, YardletCEFEventPasswordField, NULL, NULL, focused);
}

/// Whether the frame is the one the focused password field is in. Borrows the frame's reference.
static int is_password_frame(const BrowserSlot *slot, cef_frame_t *frame) {
    if (slot->passwordFrame == NULL || frame == NULL) return 0;
    cef_string_userfree_t value = frame->get_identifier(frame);
    char *identifier = copy_string(value);
    if (value) p_cef_string_userfree_utf16_free(value);
    int same = strcmp(identifier, slot->passwordFrame) == 0;
    free(identifier);
    return same;
}

/// Asks the frame's renderer for its focused field; the answer comes as a focus report. Borrows the
/// frame's reference.
static void ask_focused_field(cef_frame_t *frame) {
    cef_string_t name = {0};
    set_string(&name, kFocusedFieldQuery);
    cef_process_message_t *message = p_cef_process_message_create(&name);
    p_cef_string_utf16_clear(&name);
    // Passing the message gives the frame our reference.
    if (message) frame->send_process_message(frame, PID_RENDERER, message);
}

// The memory saver's question to a page's renderers (YardletCEFHelper's PageState.c names the same two).
static const char kPageStateQuery[] = "YardletPageStateQuery";
static const char kPageStateAnswer[] = "YardletPageState";

static void page_state_answered(BrowserSlot *slot, cef_process_message_t *message) {
    cef_list_value_t *arguments = message->get_argument_list(message);
    int complete = arguments && arguments->get_size(arguments) > 1;
    int query = complete ? arguments->get_int(arguments, 0) : 0;
    int flags = complete ? arguments->get_int(arguments, 1) : YardletPageStateUnknown;
    YARDLET_RELEASE(arguments);
    char text[16];
    snprintf(text, sizeof text, "%d", query);
    cef_string_t detail = {0};
    set_string(&detail, text);
    emit(slot->tab, YardletCEFEventPageState, NULL, &detail, flags);
    p_cef_string_utf16_clear(&detail);
}

static int CEF_CALLBACK client_on_process_message_received(cef_client_t *self, cef_browser_t *browser,
                                                           cef_frame_t *frame, cef_process_id_t source_process,
                                                           cef_process_message_t *message) {
    (void)self;
    int handled = 0;
    cef_string_userfree_t name = message ? message->get_name(message) : NULL;
    char *name_utf8 = name ? copy_string(name) : NULL;
    if (name) p_cef_string_userfree_utf16_free(name);
    BrowserSlot *slot = slot_for_browser(browser);
    if (source_process == PID_RENDERER && name_utf8 && strcmp(name_utf8, kFocusedFieldMessage) == 0) {
        handled = 1;
        // A frame a new document replaced says nothing about the page now.
        if (slot && frame && frame->is_valid(frame)) {
            cef_list_value_t *arguments = message->get_argument_list(message);
            int focused = arguments && arguments->get_size(arguments) > 0 && arguments->get_bool(arguments, 0);
            YARDLET_RELEASE(arguments);
            set_password_focus(slot, focused, frame);
        }
    } else if (source_process == PID_RENDERER && name_utf8 && strcmp(name_utf8, kPageStateAnswer) == 0) {
        handled = 1;
        if (slot) page_state_answered(slot, message);
    }
    free(name_utf8);
    YARDLET_RELEASE(message);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
    return handled;
}

// MARK: - URL policy (BrowserURLPolicy.swift keeps the same list)

static int url_is_allowed(const char *url) {
    static const char *const allowed[] = {"http", "https", "file", "about", "data"};
    const char *colon = strchr(url, ':');
    if (colon == NULL || colon == url) return 0;
    size_t length = (size_t)(colon - url);
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); index++) {
        if (strlen(allowed[index]) == length && strncasecmp(url, allowed[index], length) == 0) return 1;
    }
    return 0;
}

static int string_is_allowed(const cef_string_t *url) {
    char *utf8 = copy_string(url);
    int allowed = url_is_allowed(utf8);
    free(utf8);
    return allowed;
}

// Another app's address (mailto:, tel:, zoommtg:, slack: …): Chromium hands it to the system, as Chrome does,
// rather than loading it. The host loads none of them; Yardlet asks the person whether to open the app,
// by Chrome's rules (YardletCEFEventExternalProtocol). Chromium's own schemes are refused as before, and so
// are the ones Chrome never hands to another app (external_protocol_handler.cc kDeniedSchemes) and a
// one-letter scheme, which is a Windows drive (C:/…).
static int is_external_scheme(const cef_string_t *url) {
    static const char *const refused[] = {
        "blob", "filesystem", "ws", "wss", "chrome", "chrome-extension", "chrome-untrusted", "chrome-error",
        "chrome-search", "chrome-native", "devtools", "isolated-app",
        "afp", "applescript", "data", "disk", "disks", "file", "hcp", "ie.http", "javascript", "mk", "ms-help",
        "nntp", "res", "shell", "vbscript", "view-source", "vnd.ms.radio"};
    char *utf8 = copy_string(url);
    const char *colon = strchr(utf8, ':');
    size_t length = colon ? (size_t)(colon - utf8) : 0;
    int external = length >= 2 && isalpha((unsigned char)utf8[0]);
    for (size_t index = 1; external && index < length; index++) {
        unsigned char character = (unsigned char)utf8[index];
        if (!isalnum(character) && character != '+' && character != '-' && character != '.') external = 0;
    }
    for (size_t index = 0; external && index < sizeof(refused) / sizeof(refused[0]); index++) {
        if (strlen(refused[index]) == length && strncasecmp(utf8, refused[index], length) == 0) external = 0;
    }
    free(utf8);
    return external;
}

// MARK: - Filled values kept out of addresses
// A form sent by GET (as one without method="post" is) puts its fields in the address it goes to, and a page's
// script can build such an address too. One that carries a password the vault filled would show it in the address
// field, the tab's saved page, the history and every tool result that names the page, so it is refused here,
// before the request is sent (docs/BROWSER_VAULT_DESIGN.md, "Filled values and addresses").

enum { kMaximumFilledValues = 16 * 1024 };

static void clear_filled_values(BrowserSlot *slot) {
    free(slot->filledValues);
    slot->filledValues = NULL;
    slot->filledValuesLength = 0;
}

/// Adds NUL-ended copies of `strings` to a buffer; 0 when memory ran out.
static int append_strings(char **buffer, size_t *length, const char *const *strings, int count) {
    size_t added = 0;
    for (int index = 0; index < count; index++) added += strings[index] ? strlen(strings[index]) + 1 : 0;
    if (added == 0) return 1;
    char *grown = realloc(*buffer, *length + added);
    if (grown == NULL) return 0;
    *buffer = grown;
    for (int index = 0; index < count; index++) {
        if (strings[index] == NULL) continue;
        size_t size = strlen(strings[index]) + 1;
        memcpy(*buffer + *length, strings[index], size);
        *length += size;
    }
    return 1;
}

/// Undoes percent-encoding once, and with `plus` a form's `+` for a space, into `out` (as long as `in`).
static size_t url_decoded(const char *in, size_t length, char *out, int plus) {
    size_t written = 0;
    for (size_t index = 0; index < length; index++) {
        if (in[index] == '%' && index + 2 < length && isxdigit((unsigned char)in[index + 1])
            && isxdigit((unsigned char)in[index + 2])) {
            char hex[3] = {in[index + 1], in[index + 2], 0};
            out[written++] = (char)strtol(hex, NULL, 16);
            index += 2;
        } else {
            out[written++] = plus && in[index] == '+' ? ' ' : in[index];
        }
    }
    return written;
}

static int text_carries_filled_value(const BrowserSlot *slot, const char *text, size_t length) {
    for (size_t at = 0; at < slot->filledValuesLength; at += strlen(slot->filledValues + at) + 1) {
        const char *value = slot->filledValues + at;
        size_t size = strlen(value);
        if (size > 0 && memmem(text, length, value, size) != NULL) return 1;
    }
    return 0;
}

/// Whether text carries a value the vault filled into the slot's page: as written, or with one or two rounds of
/// percent-encoding undone (an address inside another's query), each with or without `+` for a space.
static int bytes_carry_filled_value(const BrowserSlot *slot, const char *text, size_t length) {
    int found = text_carries_filled_value(slot, text, length);
    char *once = found ? NULL : malloc(length + 1);
    char *twice = found ? NULL : malloc(length + 1);
    for (int first = 0; !found && once && twice && first < 2; first++) {
        size_t onceLength = url_decoded(text, length, once, first);
        found = text_carries_filled_value(slot, once, onceLength);
        for (int second = 0; !found && second < 2; second++) {
            found = text_carries_filled_value(slot, twice, url_decoded(once, onceLength, twice, second));
        }
    }
    free(twice);
    free(once);
    return found;
}

static int url_carries_filled_value(const BrowserSlot *slot, const cef_string_t *url) {
    if (slot == NULL || slot->filledValues == NULL || url == NULL) return 0;
    char *raw = copy_string(url);
    int found = bytes_carry_filled_value(slot, raw, strlen(raw));
    free(raw);
    return found;
}

int yardlet_cef_guard_filled_values(int tab, const char *const *values, int count) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL) return 0;
    size_t added = 0;
    for (int index = 0; index < count; index++) added += values[index] ? strlen(values[index]) + 1 : 0;
    // A page filled again and again keeps its latest values.
    if (slot->filledValuesLength + added > kMaximumFilledValues) clear_filled_values(slot);
    return append_strings(&slot->filledValues, &slot->filledValuesLength, values, count);
}

/// Tells Yardlet that `frame`'s page asked to open another app's address (number: 1 with a user gesture).
static void emit_external_protocol(int tab, cef_frame_t *frame, const cef_string_t *url, int user_gesture) {
    cef_string_userfree_t source = frame ? frame->get_url(frame) : NULL;
    emit(tab, YardletCEFEventExternalProtocol, url, source, user_gesture ? 1 : 0);
    if (source) p_cef_string_userfree_utf16_free(source);
}

// Chromium's PDF viewer: a PDF page's frame loads the viewer from Chrome's built-in PDF extension, as
// in Chrome. Refusing it left every PDF a blank page. Only a frame inside a page may go there; a tab
// still never opens it.
static int is_pdf_viewer_frame(cef_frame_t *frame, const cef_string_t *url) {
    static const char prefix[] = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/";
    if (frame == NULL || frame->is_main(frame)) return 0;
    char *utf8 = copy_string(url);
    int matches = strncmp(utf8, prefix, sizeof(prefix) - 1) == 0;
    free(utf8);
    return matches;
}

// MARK: - DevTools observer

static int CEF_CALLBACK devtools_on_message(cef_dev_tools_message_observer_t *self,
                                            cef_browser_t *browser, const void *message,
                                            size_t message_size) {
    (void)self;
    int tab = tab_of(browser);
    YARDLET_RELEASE(browser);
    if (g_callbacks.devTools) g_callbacks.devTools(tab, (const char *)message, message_size);
    return 1;
}

static cef_dev_tools_message_observer_t g_devtools_observer;

// MARK: - Render handler

static void CEF_CALLBACK render_get_view_rect(cef_render_handler_t *self, cef_browser_t *browser,
                                              cef_rect_t *rect) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    rect->x = 0;
    rect->y = 0;
    rect->width = slot && slot->width >= 1 ? (int)slot->width : 1;
    rect->height = slot && slot->height >= 1 ? (int)slot->height : 1;
    YARDLET_RELEASE(browser);
}

static int CEF_CALLBACK render_get_screen_point(cef_render_handler_t *self, cef_browser_t *browser,
                                                int view_x, int view_y, int *screen_x, int *screen_y) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    *screen_x = view_x + (slot ? (int)slot->screenX : 0);
    *screen_y = view_y + (slot ? (int)slot->screenY : 0);
    YARDLET_RELEASE(browser);
    return 1;
}

static int CEF_CALLBACK render_get_screen_info(cef_render_handler_t *self, cef_browser_t *browser,
                                               cef_screen_info_t *info) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    info->device_scale_factor = slot ? (float)slot->scale : 1.0f;
    info->depth = 24;
    info->depth_per_component = 8;
    info->rect.width = slot ? (int)slot->width : 1;
    info->rect.height = slot ? (int)slot->height : 1;
    info->available_rect = info->rect;
    YARDLET_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK render_on_popup_show(cef_render_handler_t *self, cef_browser_t *browser,
                                              int show) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventPopupShow, NULL, NULL, show);
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK render_on_popup_size(cef_render_handler_t *self, cef_browser_t *browser,
                                              const cef_rect_t *rect) {
    (void)self;
    if (g_callbacks.popupRect) {
        YardletCEFRect value = {rect->x, rect->y, rect->width, rect->height};
        g_callbacks.popupRect(tab_of(browser), value);
    }
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK render_on_paint(cef_render_handler_t *self, cef_browser_t *browser,
                                         cef_paint_element_type_t type, size_t dirty_count,
                                         cef_rect_t const *dirty_rects, const void *buffer, int width,
                                         int height) {
    (void)self; (void)dirty_count; (void)dirty_rects;
    if (g_callbacks.paint) g_callbacks.paint(tab_of(browser), (int)type, buffer, width, height);
    YARDLET_RELEASE(browser);
}

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

// Chromium's capture makes its frames at the size the page last drew at, and the view's new size reaches the
// page a frame later: in between, each frame holds the view's new size fit into the old one between black bars
// (`content_rect` short of the frame, on every step of a resize, 136 of about 400 frames while a divider was
// dragged). Shown, the page shrinks or loses its sides behind bars and jumps back; the panel keeps the frame
// before it instead. A difference that lasts (the page held at another size than the view, as during an agent's
// full-page screenshot) is shown once the view's size has stayed a second.
static int is_resize_letterbox(cef_browser_t *browser, const cef_accelerated_paint_info_common_t *extra) {
    if (extra->size < offsetof(cef_accelerated_paint_info_common_t, source_size)) return 0;
    if (extra->content_rect.x == 0 && extra->content_rect.y == 0
        && extra->content_rect.width == extra->coded_size.width
        && extra->content_rect.height == extra->coded_size.height) return 0;
    BrowserSlot *slot = slot_for_browser(browser);
    return slot != NULL && monotonic_seconds() - slot->resizedAt < 1;
}

static void CEF_CALLBACK render_on_accelerated_paint(cef_render_handler_t *self,
                                                     cef_browser_t *browser,
                                                     cef_paint_element_type_t type,
                                                     size_t dirty_count,
                                                     cef_rect_t const *dirty_rects,
                                                     const cef_accelerated_paint_info_t *info) {
    (void)self; (void)dirty_count; (void)dirty_rects;
    if (info && type == PET_VIEW && is_resize_letterbox(browser, &info->extra)) {
        YARDLET_RELEASE(browser);
        return;
    }
    if (g_callbacks.acceleratedPaint && info) {
        g_callbacks.acceleratedPaint(tab_of(browser), (int)type, info->shared_texture_io_surface,
                                     (int)info->format);
    }
    YARDLET_RELEASE(browser);
}

static int CEF_CALLBACK render_start_dragging(cef_render_handler_t *self, cef_browser_t *browser,
                                              struct _cef_drag_data_t *drag_data,
                                              cef_drag_operations_mask_t allowed_ops, int x, int y) {
    (void)self; (void)allowed_ops; (void)x; (void)y;
    YARDLET_RELEASE(drag_data);
    YARDLET_RELEASE(browser);
    return 0;  // Drag and drop out of the panel is not part of the spike.
}

static void CEF_CALLBACK render_on_ime_composition_range_changed(
    cef_render_handler_t *self, cef_browser_t *browser, const cef_range_t *selected_range,
    size_t count, cef_rect_t const *bounds) {
    (void)self; (void)selected_range;
    if (g_callbacks.compositionBounds && count > 0) {
        YardletCEFRect *rects = calloc(count, sizeof(YardletCEFRect));
        for (size_t index = 0; index < count; index++) {
            rects[index] = (YardletCEFRect){bounds[index].x, bounds[index].y, bounds[index].width,
                                            bounds[index].height};
        }
        g_callbacks.compositionBounds(tab_of(browser), rects, (int)count);
        free(rects);
    }
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK render_on_scroll_offset_changed(cef_render_handler_t *self, cef_browser_t *browser,
                                                         double x, double y) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    int tab = slot ? slot->tab : -1;
    // CEF reports device pixels; the contract uses view points.
    double scale = slot && slot->scale > 0 ? slot->scale : 1;
    YARDLET_RELEASE(browser);
    if (g_callbacks.scrollOffset && tab >= 0) g_callbacks.scrollOffset(tab, x / scale, y / scale);
}

static void CEF_CALLBACK render_update_drag_cursor(cef_render_handler_t *self, cef_browser_t *browser,
                                                   cef_drag_operations_mask_t operation) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventDragOperation, NULL, NULL, (int)operation);
    YARDLET_RELEASE(browser);
}

static cef_render_handler_t g_render_handler;

// MARK: - Context menu handler

enum { kMaximumMenus = 8 };
typedef struct {
    int id;
    cef_run_context_menu_callback_t *callback;
} PendingMenu;
static PendingMenu g_menus[kMaximumMenus];
static int g_next_menu_id = 1;

static char *menu_title(cef_menu_model_t *model, size_t index) {
    cef_string_userfree_t label = model->get_label_at(model, index);
    char *title = label ? copy_string(label) : strdup("");
    if (label) p_cef_string_userfree_utf16_free(label);
    // Drop Windows-style mnemonics ("&Copy" → "Copy", "&&" → "&").
    char *read = title, *write = title;
    while (*read) {
        if (*read == '&') {
            read++;
            if (*read == '\0') break;
        }
        *write++ = *read++;
    }
    *write = '\0';
    return title;
}

static int CEF_CALLBACK menu_run_context_menu(cef_context_menu_handler_t *self,
                                              cef_browser_t *browser, cef_frame_t *frame,
                                              cef_context_menu_params_t *params,
                                              cef_menu_model_t *model,
                                              cef_run_context_menu_callback_t *callback) {
    (void)self;
    int tab = tab_of(browser);
    int x = params ? params->get_xcoord(params) : 0;
    int y = params ? params->get_ycoord(params) : 0;
    size_t count = model ? model->get_count(model) : 0;
    PendingMenu *pending = NULL;
    for (int index = 0; index < kMaximumMenus; index++) {
        if (g_menus[index].callback == NULL) { pending = &g_menus[index]; break; }
    }
    if (pending == NULL || g_callbacks.contextMenu == NULL || count == 0) {
        callback->cancel(callback);
        YARDLET_RELEASE(callback);
    } else {
        pending->id = g_next_menu_id++;
        pending->callback = callback;  // Keeps the reference CEF passed in until answered.
        YardletCEFMenuItem *items = calloc(count, sizeof(YardletCEFMenuItem));
        for (size_t index = 0; index < count; index++) {
            cef_menu_item_type_t type = model->get_type_at(model, index);
            items[index].commandID = model->get_command_id_at(model, index);
            items[index].kind = type == MENUITEMTYPE_SEPARATOR ? 1
                              : type == MENUITEMTYPE_CHECK ? 2
                              : type == MENUITEMTYPE_RADIO ? 3
                              : type == MENUITEMTYPE_SUBMENU ? 4 : 0;
            items[index].isEnabled = model->is_enabled_at(model, index);
            items[index].isChecked = model->is_checked_at(model, index);
            items[index].title = type == MENUITEMTYPE_SEPARATOR ? strdup("") : menu_title(model, index);
        }
        g_callbacks.contextMenu(tab, pending->id, x, y, items, (int)count);
        for (size_t index = 0; index < count; index++) free((void *)items[index].title);
        free(items);
    }
    YARDLET_RELEASE(model);
    YARDLET_RELEASE(params);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
    return 1;
}

static cef_context_menu_handler_t g_context_menu_handler;

void yardlet_cef_context_menu_result(int menu_id, int command_id) {
    for (int index = 0; index < kMaximumMenus; index++) {
        PendingMenu *pending = &g_menus[index];
        if (pending->callback == NULL || pending->id != menu_id) continue;
        if (command_id >= 0) {
            pending->callback->cont(pending->callback, command_id, EVENTFLAG_NONE);
        } else {
            pending->callback->cancel(pending->callback);
        }
        YARDLET_RELEASE(pending->callback);
        pending->callback = NULL;
        return;
    }
}

// MARK: - Life span handler

// CEF does not expose Chromium's PopupBlockerTabHelper or a continuation for
// OnBeforePopup. Keep the source frame and request metadata, cancel creation (so
// window.open returns null), and reissue window.open in that frame when selected.
// This preserves opener for script windows; CEF does not expose form POST bodies here.
typedef struct {
    int id, openerTab;
    cef_frame_t *frame;
    char *frameID, *url, *name;
    double replayUntil;
} BlockedPopup;
enum { kMaximumBlockedPopups = 1024, kMaximumPagePopups = 25 };
static BlockedPopup g_blocked_popups[kMaximumBlockedPopups];

static void free_blocked_popup(BlockedPopup *popup) {
    YARDLET_RELEASE(popup->frame);
    free(popup->frameID);
    free(popup->url);
    free(popup->name);
    memset(popup, 0, sizeof(*popup));
}
static void clear_blocked_popups(int tab) {
    for (int i = 0; i < kMaximumBlockedPopups; i++) {
        if (g_blocked_popups[i].id && g_blocked_popups[i].openerTab == tab)
            free_blocked_popup(&g_blocked_popups[i]);
    }
}
static void clear_frame_popups(int tab, cef_frame_t *frame) {
    cef_string_userfree_t identifier = frame->get_identifier(frame);
    char *frameID = identifier ? copy_string(identifier) : NULL;
    if (identifier) p_cef_string_userfree_utf16_free(identifier);
    for (int i = 0; frameID && i < kMaximumBlockedPopups; i++) {
        BlockedPopup *popup = &g_blocked_popups[i];
        if (popup->id && popup->openerTab == tab && !strcmp(popup->frameID, frameID)) {
            emit(tab, YardletCEFEventPopupRemoved, NULL, NULL, popup->id);
            free_blocked_popup(popup);
        }
    }
    free(frameID);
}
static int popups_allowed(BrowserSlot *slot) {
    if (!slot || !slot->browser) return 0;
    cef_frame_t *frame = slot->browser->get_main_frame(slot->browser);
    cef_string_userfree_t url = frame ? frame->get_url(frame) : NULL;
    cef_request_context_t *context = context_reference(slot->contextHandle);
    int allowed = url && context && context->get_content_setting(context, url, url,
        CEF_CONTENT_SETTING_TYPE_POPUPS) == CEF_CONTENT_SETTING_VALUE_ALLOW;
    if (url) p_cef_string_userfree_utf16_free(url);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE_CONTEXT(context);
    return allowed;
}
void yardlet_cef_popup_permission(int tab, int allowed, const char *expected_url) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (!slot || !slot->browser) return;
    if (allowed >= 0) {
        cef_frame_t *frame = slot->browser->get_main_frame(slot->browser);
        cef_string_userfree_t url = frame ? frame->get_url(frame) : NULL;
        char *address = url ? copy_string(url) : NULL;
        cef_request_context_t *context = context_reference(slot->contextHandle);
        // Site exceptions only: never turn a blank/file page into a profile-wide default.
        if (context && address && expected_url && !strcmp(address, expected_url) && (!strncmp(address, "https://", 8) || !strncmp(address, "http://", 7)))
            context->set_content_setting(context, url, url, CEF_CONTENT_SETTING_TYPE_POPUPS,
                allowed ? CEF_CONTENT_SETTING_VALUE_ALLOW : CEF_CONTENT_SETTING_VALUE_DEFAULT);
        free(address);
        if (url) p_cef_string_userfree_utf16_free(url);
        YARDLET_RELEASE(frame);
        YARDLET_RELEASE_CONTEXT(context);
    }
    for (int i = 0; i < kMaximumBrowsers; i++) {
        BrowserSlot *other = &g_browsers[i];
        if (other->inUse && other->contextHandle == slot->contextHandle)
            emit(other->tab, YardletCEFEventPopupPermission, NULL, NULL, popups_allowed(other));
    }
}
void yardlet_cef_cancel_blocked_popup(int openerTab, int popupTab) {
    for (int i = 0; i < kMaximumBlockedPopups; i++) {
        BlockedPopup *popup = &g_blocked_popups[i];
        if (popup->id != popupTab || popup->openerTab != openerTab) continue;
        emit(openerTab, YardletCEFEventPopupRemoved, NULL, NULL, popupTab);
        free_blocked_popup(popup);
        return;
    }
}
static char *popup_json_string(const char *text) {
    cef_value_t *value = p_cef_value_create();
    cef_string_t string = {0};
    set_string(&string, text);
    value->set_string(value, &string);
    p_cef_string_utf16_clear(&string);
    value->base.add_ref(&value->base);
    cef_string_userfree_t json = p_cef_write_json(value, JSON_WRITER_DEFAULT);
    char *result = json ? copy_string(json) : NULL;
    if (json) p_cef_string_userfree_utf16_free(json);
    YARDLET_RELEASE(value);
    return result;
}
void yardlet_cef_open_blocked_popup(int openerTab, int popupTab) {
    for (int i = 0; i < kMaximumBlockedPopups; i++) {
        BlockedPopup *popup = &g_blocked_popups[i];
        if (popup->id != popupTab || popup->openerTab != openerTab) continue;
        if (!popup->frame->is_valid(popup->frame)) {
            emit(openerTab, YardletCEFEventPopupRemoved, NULL, NULL, popupTab);
            free_blocked_popup(popup);
            return;
        }
        char *url = popup_json_string(popup->url), *name = popup_json_string(popup->name);
        if (!url || !name) { free(url); free(name); return; }
        char *script = NULL;
        if (asprintf(&script, "window.open(%s,%s)", url, name) >= 0) {
            cef_string_t code = {0}, source = {0};
            set_string(&code, script);
            // A one-shot grant for this frame, URL and target only. An overridden window.open
            // that does not make the request cannot leave a durable permission behind.
            popup->replayUntil = monotonic_seconds() + 2;
            popup->frame->execute_java_script(popup->frame, &code, &source, 0);
            p_cef_string_utf16_clear(&code);
            free(script);
        }
        free(url); free(name);
        return;
    }
}

static int CEF_CALLBACK life_span_on_before_popup(
    cef_life_span_handler_t *self, cef_browser_t *browser, cef_frame_t *frame, int popup_id,
    const cef_string_t *target_url, const cef_string_t *target_frame_name,
    cef_window_open_disposition_t target_disposition, int user_gesture,
    const cef_popup_features_t *popup_features, cef_window_info_t *window_info,
    cef_client_t **client, cef_browser_settings_t *settings,
    cef_dictionary_value_t **extra_info, int *no_javascript_access) {
    (void)self; (void)popup_features; (void)extra_info; (void)no_javascript_access;
    BrowserSlot *opener = slot_for_browser(browser);
    int tab = opener ? opener->tab : -1;
    int behind = target_disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    int made = 0;
    BlockedPopup *replay = NULL;
    char *requestedURL = target_url ? copy_string(target_url) : strdup("");
    char *requestedName = target_frame_name ? copy_string(target_frame_name) : strdup("");
    cef_string_userfree_t frameIdentifier = frame ? frame->get_identifier(frame) : NULL;
    char *frameID = frameIdentifier ? copy_string(frameIdentifier) : strdup("");
    if (frameIdentifier) p_cef_string_userfree_utf16_free(frameIdentifier);
    for (int i = 0; i < kMaximumBlockedPopups; i++) {
        BlockedPopup *candidate = &g_blocked_popups[i];
        if (candidate->id && candidate->openerTab == tab && candidate->replayUntil > monotonic_seconds()
            && !strcmp(candidate->frameID, frameID) && !strcmp(candidate->url, requestedURL)
            && !strcmp(candidate->name, requestedName)) { replay = candidate; break; }
    }
    int allowed = user_gesture || replay || popups_allowed(opener);
#ifndef NDEBUG
    fprintf(stderr, "popup request tab=%d userGesture=%d replay=%d allowed=%d\n", tab, user_gesture, replay != NULL, allowed);
#endif
    if (url_carries_filled_value(opener, target_url)) {
        emit(tab, YardletCEFEventFilledValueBlocked, NULL, NULL, 0);
    } else if (target_url && !string_is_allowed(target_url)) {
        // A new window for another app's address (a target=_blank mail link) opens no tab: Chrome closes the
        // tab such a window made once the app opens.
        if (is_external_scheme(target_url)) emit_external_protocol(tab, frame, target_url, user_gesture);
        else emit(tab, YardletCEFEventNavigationBlocked, target_url, NULL, 0);
    } else if (allowed && opener && opener->browser && free_slot()) {
        BrowserSlot *slot = free_slot();
        memset(slot, 0, sizeof(*slot));
        slot->inUse = 1;
        slot->tab = replay ? replay->id : g_next_popup_tab++;
        slot->identifier = kPopupPending;
        slot->waitingURL = target_url ? copy_string(target_url) : strdup("");
        slot->openerIdentifier = browser->get_identifier(browser);
        slot->popupID = popup_id;
        slot->openerTab = tab;
        slot->popupBehind = behind;
        slot->width = opener->width;
        slot->height = opener->height;
        slot->scale = opener->scale;
        slot->screenX = opener->screenX;
        slot->screenY = opener->screenY;
        slot->frameRate = opener->frameRate;
        slot->sharedTexture = opener->sharedTexture;
        // CEF makes the popup in the opener's request context: it holds that context as the opener does.
        slot->contextHandle = opener->contextHandle;
        if (slot->contextHandle > 0) g_contexts[slot->contextHandle - 1].users++;
        window_info->windowless_rendering_enabled = 1;
        window_info->shared_texture_enabled = slot->sharedTexture;
        window_info->runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        // The slot's own client names the slot to its render and accessibility handlers (static, like
        // the opener's client it replaces).
        *client = &g_slot_clients[slot - g_browsers].client;
        settings->windowless_frame_rate = slot->frameRate;
        settings->background_color = 0xFFFFFFFF;
        made = 1;
    } else if (!allowed && opener && frame) {
        int count = 0;
        BlockedPopup *pending = NULL;
        for (int i = 0; i < kMaximumBlockedPopups; i++) {
            if (g_blocked_popups[i].id && g_blocked_popups[i].openerTab == tab) count++;
            if (!g_blocked_popups[i].id && !pending) pending = &g_blocked_popups[i];
        }
        if (pending && count < kMaximumPagePopups) {
            pending->id = g_next_popup_tab++;
            pending->openerTab = tab;
            pending->frame = frame;
            frame->base.add_ref(&frame->base);
            pending->frameID = strdup(frameID);
            pending->url = strdup(requestedURL);
            pending->name = strdup(requestedName);
            emit(tab, YardletCEFEventPopupRetained, target_url, NULL, pending->id);
        }
    } else if (target_url && !replay) {
        // number: 1 background, 2 user gesture.
        emit(tab, YardletCEFEventPopupBlocked, target_url, NULL, (behind ? 1 : 0) | (user_gesture ? 2 : 0));
    }
    if (replay) {
        if (!made) emit(tab, YardletCEFEventPopupRemoved, NULL, NULL, replay->id);
        free_blocked_popup(replay);
    }
    free(requestedURL); free(requestedName); free(frameID);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
    return made ? 0 : 1;
}

static void free_popup_slot(BrowserSlot *slot) {
    int context = slot->contextHandle;
    free(slot->waitingURL);
    memset(slot, 0, sizeof(*slot));
    release_context(context);
}

static void CEF_CALLBACK life_span_on_before_popup_aborted(cef_life_span_handler_t *self,
                                                           cef_browser_t *browser, int popup_id) {
    (void)self;
    int opener = browser->get_identifier(browser);
    for (int index = 0; index < kMaximumBrowsers; index++) {
        BrowserSlot *slot = &g_browsers[index];
        if (slot->inUse && slot->identifier == kPopupPending && slot->openerIdentifier == opener
            && slot->popupID == popup_id) {
            emit(slot->openerTab, YardletCEFEventPopupRemoved, NULL, NULL, slot->tab);
            free_popup_slot(slot);
            break;
        }
    }
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK life_span_on_after_created(cef_life_span_handler_t *self,
                                                    cef_browser_t *browser) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot && slot->browser == NULL && slot->openerIdentifier != 0) {
        // A popup: keep it as make_browser keeps a browser it creates, then tell Yardlet. detail: the
        // opener's tab, number: 1 behind.
        slot->browser = browser;
        browser->base.add_ref(&browser->base);
        cef_browser_host_t *host = browser->get_host(browser);
        if (host) {
            slot->devtoolsRegistration = host->add_dev_tools_message_observer(host, &g_devtools_observer);
            YARDLET_RELEASE(host);
        }
        char opener[16];
        snprintf(opener, sizeof(opener), "%d", slot->openerTab);
        cef_string_t url = {0}, openerTab = {0};
        set_string(&url, slot->waitingURL);
        set_string(&openerTab, opener);
        free(slot->waitingURL);
        slot->waitingURL = NULL;
        emit(slot->tab, YardletCEFEventPopupOpened, &url, &openerTab, slot->popupBehind);
        p_cef_string_utf16_clear(&url);
        p_cef_string_utf16_clear(&openerTab);
    }
    emit(tab_of(browser), YardletCEFEventAfterCreated, NULL, NULL, 0);
    YARDLET_RELEASE(browser);
}

static int CEF_CALLBACK life_span_do_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    (void)self;
    YARDLET_RELEASE(browser);
    return 0;  // Windowless browsers have no window for CEF to close.
}

static void CEF_CALLBACK life_span_on_before_close(cef_life_span_handler_t *self,
                                                   cef_browser_t *browser) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    int tab = slot ? slot->tab : -1;
    if (tab >= 0) { release_media_prompts(tab); clear_blocked_popups(tab); }
    if (slot) {
        int context = slot->contextHandle;
        YARDLET_RELEASE(slot->devtoolsRegistration);
        YARDLET_RELEASE(slot->unresponsive);
        YARDLET_RELEASE(slot->browser);
        free(slot->passwordFrame);
        clear_filled_values(slot);
        memset(slot, 0, sizeof(*slot));
        release_context(context);
    }
    YARDLET_RELEASE(browser);
    emit(tab, YardletCEFEventBeforeClose, NULL, NULL, 0);
}

static cef_life_span_handler_t g_life_span_handler;

// MARK: - Display handler

static void CEF_CALLBACK display_on_address_change(cef_display_handler_t *self,
                                                   cef_browser_t *browser, cef_frame_t *frame,
                                                   const cef_string_t *url) {
    (void)self;
    if (frame && frame->is_main(frame)) emit(tab_of(browser), YardletCEFEventAddress, url, NULL, 0);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK display_on_title_change(cef_display_handler_t *self,
                                                 cef_browser_t *browser, const cef_string_t *title) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventTitle, title, NULL, 0);
    YARDLET_RELEASE(browser);
}

// MARK: - Page icons
// Chromium tells the display handler where a page's icons are; the browser downloads the first
// through its own network stack (as a favicon: no cookies sent or kept) and the PNG goes to Yardlet,
// which shows it on the page's side-panel tab. Each download has its own callback, which knows its
// tab and frees itself when CEF lets go of it. Releasing it after handing it over freed it under
// CEF's feet: the host then called through a freed callback (EXC_BAD_ACCESS at 0xcdcd…).

typedef struct {
    cef_download_image_callback_t callback;
    int tab;
    int references;
} FaviconDownload;

static void CEF_CALLBACK favicon_add_ref(cef_base_ref_counted_t *self) {
    __atomic_add_fetch(&((FaviconDownload *)self)->references, 1, __ATOMIC_RELAXED);
}

static int CEF_CALLBACK favicon_release(cef_base_ref_counted_t *self) {
    FaviconDownload *download = (FaviconDownload *)self;
    if (__atomic_sub_fetch(&download->references, 1, __ATOMIC_ACQ_REL) != 0) return 0;
    free(download);
    return 1;
}

static int CEF_CALLBACK favicon_has_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((FaviconDownload *)self)->references, __ATOMIC_ACQUIRE) == 1;
}

static int CEF_CALLBACK favicon_has_at_least_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((FaviconDownload *)self)->references, __ATOMIC_ACQUIRE) >= 1;
}

static void CEF_CALLBACK favicon_downloaded(cef_download_image_callback_t *self, const cef_string_t *image_url,
                                            int http_status_code, cef_image_t *image) {
    (void)http_status_code;
    FaviconDownload *download = (FaviconDownload *)self;
    if (g_callbacks.favicon != NULL) {
        char *url = copy_string(image_url);
        cef_binary_value_t *png = NULL;
        if (image && !image->is_empty(image)) {
            int width = 0, height = 0;
            png = image->get_as_png(image, 2.0f, 1, &width, &height);
        }
        size_t size = png ? png->get_size(png) : 0;
        void *bytes = size > 0 ? malloc(size) : NULL;
        if (bytes) size = png->get_data(png, bytes, size, 0);
        g_callbacks.favicon(download->tab, url, bytes, bytes ? size : 0);
        free(bytes);
        free(url);
        YARDLET_RELEASE(png);
    }
    YARDLET_RELEASE(image);
}

static void CEF_CALLBACK display_on_favicon_urlchange(cef_display_handler_t *self, cef_browser_t *browser,
                                                      cef_string_list_t icon_urls) {
    (void)self;
    int tab = tab_of(browser);
    cef_browser_host_t *host = browser->get_host(browser);
    cef_string_t url = {0};
    if (tab >= 0 && host && icon_urls && p_cef_string_list_size(icon_urls) > 0
        && p_cef_string_list_value(icon_urls, 0, &url) && url.length > 0) {
        FaviconDownload *download = calloc(1, sizeof(*download));
        if (download) {
            download->tab = tab;
            download->references = 1;
            cef_base_ref_counted_t *base = &download->callback.base;
            base->size = sizeof(download->callback);
            base->add_ref = favicon_add_ref;
            base->release = favicon_release;
            base->has_one_ref = favicon_has_one_ref;
            base->has_at_least_one_ref = favicon_has_at_least_one_ref;
            download->callback.on_download_image_finished = favicon_downloaded;
            // 16 points, as the tab shows it; the 2x version comes along where the site has one. A
            // structure passed to CEF hands it a reference (CEF's CToCpp wrapper releases the one the
            // caller added), so the download's one reference goes with it and CEF's last release frees it.
            host->download_image(host, &url, 1, 16, 0, &download->callback);
        }
    }
    p_cef_string_utf16_clear(&url);
    YARDLET_RELEASE(host);
    YARDLET_RELEASE(browser);
}

static int CEF_CALLBACK display_on_console_message(cef_display_handler_t *self,
                                                   cef_browser_t *browser, cef_log_severity_t level,
                                                   const cef_string_t *message,
                                                   const cef_string_t *source, int line) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventConsole, message, source,
         ((int)level << 16) | (line & 0xFFFF));
    YARDLET_RELEASE(browser);
    return 0;
}

static int CEF_CALLBACK display_on_cursor_change(cef_display_handler_t *self,
                                                 cef_browser_t *browser, cef_cursor_handle_t cursor,
                                                 cef_cursor_type_t type,
                                                 const cef_cursor_info_t *custom_cursor_info) {
    (void)self; (void)cursor; (void)custom_cursor_info;
    emit(tab_of(browser), YardletCEFEventCursor, NULL, NULL, (int)type);
    YARDLET_RELEASE(browser);
    return 1;  // Yardlet sets the cursor in its own process.
}

static int CEF_CALLBACK display_on_tooltip(cef_display_handler_t *self, cef_browser_t *browser,
                                           cef_string_t *text) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventTooltip, text && text->length > 0 ? text : NULL, NULL, 0);
    YARDLET_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK display_on_media_access_change(cef_display_handler_t *self, cef_browser_t *browser,
                                                        int has_video_access, int has_audio_access) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot) slot->capturing = has_video_access || has_audio_access;
    YARDLET_RELEASE(browser);
}

static cef_display_handler_t g_display_handler;

// MARK: - Request handler: URL policy, same-tab links, crashed renderers

static int CEF_CALLBACK request_on_before_browse(cef_request_handler_t *self, cef_browser_t *browser,
                                                 cef_frame_t *frame, cef_request_t *request,
                                                 int user_gesture, int is_redirect) {
    (void)self; (void)is_redirect;
    int cancel = 0;
    cef_string_userfree_t url = request ? request->get_url(request) : NULL;
    BrowserSlot *slot = slot_for_browser(browser);
    int inMainFrame = frame && frame->is_main(frame) ? 1 : 0;
    if (url_carries_filled_value(slot, url)) {
        // Before the scheme policy, whose events name the address.
        emit(tab_of(browser), YardletCEFEventFilledValueBlocked, NULL, NULL, inMainFrame);
        cancel = 1;
    } else if (url && !string_is_allowed(url) && !is_pdf_viewer_frame(frame, url)) {
        if (is_external_scheme(url)) emit_external_protocol(tab_of(browser), frame, url, user_gesture);
        else emit(tab_of(browser), YardletCEFEventNavigationBlocked, url, NULL, 0);
        cancel = 1;
    }
    if (url) p_cef_string_userfree_utf16_free(url);
    YARDLET_RELEASE(request);
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
    return cancel;
}

static int CEF_CALLBACK request_on_open_urlfrom_tab(cef_request_handler_t *self,
                                                   cef_browser_t *browser, cef_frame_t *frame,
                                                   const cef_string_t *target_url,
                                                   cef_window_open_disposition_t disposition,
                                                   int user_gesture) {
    (void)self; (void)disposition; (void)user_gesture;
    if (target_url && string_is_allowed(target_url)) {
        cef_frame_t *main_frame = browser->get_main_frame(browser);
        if (main_frame) {
            main_frame->load_url(main_frame, target_url);
            YARDLET_RELEASE(main_frame);
        }
    }
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK request_on_render_process_terminated(cef_request_handler_t *self,
                                                              cef_browser_t *browser,
                                                              cef_termination_status_t status,
                                                              int error_code,
                                                              const cef_string_t *error_string) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot) {
        YARDLET_RELEASE(slot->unresponsive);
        slot->unresponsive = NULL;
        // The ended renderer's field is gone; the page that loads next reports its own.
        set_password_focus(slot, 0, NULL);
        release_media_prompts(slot->tab);
        slot->capturing = 0;
    }
    if (slot && slot->discarding) {
        slot->discarding = 0;
        emit(slot->tab, YardletCEFEventDiscarded, NULL, NULL, (int)status);
        YARDLET_RELEASE(browser);
        return;
    }
    // The process's exit code (a signal number, or Chromium's result code) travels as the detail.
    char code[16];
    snprintf(code, sizeof code, "%d", error_code);
    cef_string_t code_string = {0};
    set_string(&code_string, code);
    emit(tab_of(browser), YardletCEFEventPageCrashed, error_string, &code_string, (int)status);
    p_cef_string_utf16_clear(&code_string);
    YARDLET_RELEASE(browser);
}

// Chromium's hang monitor: the renderer has not handled input for 15 seconds. The callback is kept
// (its reference is ours) and Yardlet decides: wait, or end the renderer. Returning 1 keeps Alloy's
// default of waiting, with no dialog of Chromium's own.
static int CEF_CALLBACK request_on_render_process_unresponsive(cef_request_handler_t *self,
                                                               cef_browser_t *browser,
                                                               cef_unresponsive_process_callback_t *callback) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot) {
        YARDLET_RELEASE(slot->unresponsive);
        slot->unresponsive = callback;
    } else {
        YARDLET_RELEASE(callback);
    }
    emit(tab_of(browser), YardletCEFEventResponsiveness, NULL, NULL, 0);
    YARDLET_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK request_on_render_process_responsive(cef_request_handler_t *self,
                                                              cef_browser_t *browser) {
    (void)self;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot) {
        YARDLET_RELEASE(slot->unresponsive);
        slot->unresponsive = NULL;
    }
    emit(tab_of(browser), YardletCEFEventResponsiveness, NULL, NULL, 1);
    YARDLET_RELEASE(browser);
}

static cef_request_handler_t g_request_handler;

// MARK: - JavaScript dialogs

enum { kMaximumPending = 32 };
typedef struct {
    int id;
    void *callback;
} PendingCallback;

static PendingCallback g_js_dialogs[kMaximumPending];
static PendingCallback g_file_dialogs[kMaximumPending];
static PendingCallback g_downloads[kMaximumPending];
static int g_next_dialog_id = 1;

static PendingCallback *pending_free(PendingCallback *table) {
    for (int index = 0; index < kMaximumPending; index++) {
        if (table[index].callback == NULL) return &table[index];
    }
    return NULL;
}

static PendingCallback *pending_find(PendingCallback *table, int id) {
    for (int index = 0; index < kMaximumPending; index++) {
        if (table[index].callback != NULL && table[index].id == id) return &table[index];
    }
    return NULL;
}

#if DEBUG
#include <sys/time.h>
// QA trace of dialog handling, in the same local time format as Chromium's log lines.
static void dialog_trace(const char *what, int value) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm local;
    localtime_r(&now.tv_sec, &local);
    fprintf(stderr, "[%02d%02d%02d.%06d] dialog trace: %s %d\n", local.tm_hour, local.tm_min, local.tm_sec,
            (int)now.tv_usec, what, value);
}
#else
#define dialog_trace(what, value) ((void)0)
#endif

static int CEF_CALLBACK jsdialog_on_jsdialog(cef_jsdialog_handler_t *self, cef_browser_t *browser,
                                             const cef_string_t *origin_url,
                                             cef_jsdialog_type_t dialog_type,
                                             const cef_string_t *message_text,
                                             const cef_string_t *default_prompt_text,
                                             cef_jsdialog_callback_t *callback,
                                             int *suppress_message) {
    (void)self;
    (void)suppress_message;
    dialog_trace("on_jsdialog type", (int)dialog_type);
    PendingCallback *pending = pending_free(g_js_dialogs);
    if (pending == NULL || g_callbacks.javaScriptDialog == NULL) {
        YARDLET_RELEASE(callback);
        YARDLET_RELEASE(browser);
        return 0;  // CEF's default: the dialog is suppressed.
    }
    pending->id = g_next_dialog_id++;
    pending->callback = callback;
    char *origin = copy_string(origin_url);
    char *message = copy_string(message_text);
    char *prompt = copy_string(default_prompt_text);
    g_callbacks.javaScriptDialog(tab_of(browser), pending->id, (int)dialog_type, message, prompt, origin, 0);
    free(origin);
    free(message);
    free(prompt);
    YARDLET_RELEASE(browser);
    return 1;
}

static int CEF_CALLBACK jsdialog_on_before_unload_dialog(cef_jsdialog_handler_t *self,
                                                         cef_browser_t *browser,
                                                         const cef_string_t *message_text,
                                                         int is_reload,
                                                         cef_jsdialog_callback_t *callback) {
    (void)self;
    dialog_trace("on_before_unload_dialog reload", is_reload);
    // Yardlet already took the tab away (close_browser with force, which still asks the page first): no
    // panel shows it any more and the close goes ahead whatever the answer, so the page is left at once.
    // Unanswered, the closed tab's page stayed alive, unseen, until the host ended.
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot && slot->closing) {
        cef_string_t empty = {0};
        callback->cont(callback, 1, &empty);
        YARDLET_RELEASE(callback);
        YARDLET_RELEASE(browser);
        return 1;
    }
    PendingCallback *pending = pending_free(g_js_dialogs);
    if (pending == NULL || g_callbacks.javaScriptDialog == NULL) {
        YARDLET_RELEASE(callback);
        YARDLET_RELEASE(browser);
        return 0;
    }
    pending->id = g_next_dialog_id++;
    pending->callback = callback;
    if (slot) slot->leaveDialog = pending->id;
    char *message = copy_string(message_text);
    g_callbacks.javaScriptDialog(tab_of(browser), pending->id, 3, message, "", "", is_reload);
    free(message);
    YARDLET_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK jsdialog_on_reset_dialog_state(cef_jsdialog_handler_t *self,
                                                        cef_browser_t *browser) {
    (void)self;
    dialog_trace("on_reset_dialog_state", 0);
    emit(tab_of(browser), YardletCEFEventDialogReset, NULL, NULL, 0);
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK jsdialog_on_dialog_closed(cef_jsdialog_handler_t *self, cef_browser_t *browser) {
    (void)self;
    dialog_trace("on_dialog_closed", 0);
    YARDLET_RELEASE(browser);
}

static cef_jsdialog_handler_t g_jsdialog_handler;

void yardlet_cef_jsdialog_result(int dialog_id, int accepted, const char *text) {
    dialog_trace("result accepted", accepted);
    PendingCallback *pending = pending_find(g_js_dialogs, dialog_id);
    if (pending == NULL) return;
    cef_jsdialog_callback_t *callback = pending->callback;
    pending->callback = NULL;
    cef_string_t input = {0};
    set_string(&input, text ? text : "");
    callback->cont(callback, accepted, &input);
    p_cef_string_utf16_clear(&input);
    YARDLET_RELEASE(callback);
}

// MARK: - File dialogs

static int CEF_CALLBACK dialog_on_file_dialog(cef_dialog_handler_t *self, cef_browser_t *browser,
                                              cef_file_dialog_mode_t mode, const cef_string_t *title,
                                              const cef_string_t *default_file_path,
                                              cef_string_list_t accept_filters,
                                              cef_string_list_t accept_extensions,
                                              cef_string_list_t accept_descriptions,
                                              cef_file_dialog_callback_t *callback) {
    (void)self; (void)accept_filters; (void)accept_descriptions;
    PendingCallback *pending = pending_free(g_file_dialogs);
    if (pending == NULL || g_callbacks.fileDialog == NULL) {
        callback->cancel(callback);
        YARDLET_RELEASE(callback);
        YARDLET_RELEASE(browser);
        return 1;
    }
    pending->id = g_next_dialog_id++;
    pending->callback = callback;
    // accept_extensions holds ";"-joined extension groups, one per accept filter.
    size_t groups = accept_extensions ? p_cef_string_list_size(accept_extensions) : 0;
    char **extensions = calloc(64, sizeof(char *));
    int extension_count = 0;
    for (size_t index = 0; index < groups && extension_count < 64; index++) {
        cef_string_t value = {0};
        if (!p_cef_string_list_value(accept_extensions, index, &value)) continue;
        char *joined = copy_string(&value);
        p_cef_string_utf16_clear(&value);
        char *cursor = joined, *item;
        while ((item = strsep(&cursor, ";")) != NULL && extension_count < 64) {
            while (*item == '.') item++;
            if (*item) extensions[extension_count++] = strdup(item);
        }
        free(joined);
    }
    char *title_utf8 = copy_string(title);
    char *default_path = copy_string(default_file_path);
    g_callbacks.fileDialog(tab_of(browser), pending->id, (int)mode, title_utf8, default_path,
                           (const char *const *)extensions, extension_count);
    for (int index = 0; index < extension_count; index++) free(extensions[index]);
    free(extensions);
    free(title_utf8);
    free(default_path);
    YARDLET_RELEASE(browser);
    return 1;
}

static cef_dialog_handler_t g_dialog_handler;

void yardlet_cef_file_dialog_result(int dialog_id, const char *const *paths, int count) {
    PendingCallback *pending = pending_find(g_file_dialogs, dialog_id);
    if (pending == NULL) return;
    cef_file_dialog_callback_t *callback = pending->callback;
    pending->callback = NULL;
    if (count < 0) {
        callback->cancel(callback);
    } else {
        cef_string_list_t list = p_cef_string_list_alloc();
        for (int index = 0; index < count; index++) {
            cef_string_t value = {0};
            set_string(&value, paths[index]);
            p_cef_string_list_append(list, &value);
            p_cef_string_utf16_clear(&value);
        }
        callback->cont(callback, list);
        p_cef_string_list_free(list);
    }
    YARDLET_RELEASE(callback);
}

// MARK: - Downloads

static int CEF_CALLBACK download_can_download(cef_download_handler_t *self, cef_browser_t *browser,
                                              const cef_string_t *url, const cef_string_t *method) {
    (void)self; (void)url; (void)method;
    YARDLET_RELEASE(browser);
    return 1;
}

// Downloads given no path (refused, or no downloads folder): CEF cancels them (Alloy style), and they keep no
// callback in g_downloads, which holds only kMaximumPending, also when a progress report comes before or after.
static int g_refused_downloads[kMaximumPending];
static int g_next_refused_download = 0;

static int download_refused(int id) {
    for (int index = 0; index < kMaximumPending; index++) {
        if (g_refused_downloads[index] == id) return 1;
    }
    return 0;
}

static void forget_download_callback(int id) {
    PendingCallback *pending = pending_find(g_downloads, id);
    if (pending == NULL) return;
    cef_download_item_callback_t *stored = pending->callback;
    pending->callback = NULL;
    YARDLET_RELEASE(stored);
}

static int CEF_CALLBACK download_on_before_download(cef_download_handler_t *self,
                                                    cef_browser_t *browser,
                                                    cef_download_item_t *item,
                                                    const cef_string_t *suggested_name,
                                                    cef_before_download_callback_t *callback) {
    (void)self;
    int handled = 0;
    if (g_callbacks.downloadPath) {
        char *name = copy_string(suggested_name);
        char *path = g_callbacks.downloadPath(tab_of(browser), (int)item->get_id(item), name);
        free(name);
        if (path) {
            cef_string_t value = {0};
            set_string(&value, path);
            callback->cont(callback, &value, 0);
            p_cef_string_utf16_clear(&value);
            free(path);
            handled = 1;
        }
    }
    if (!handled) {
        int id = (int)item->get_id(item);
        g_refused_downloads[g_next_refused_download] = id;
        g_next_refused_download = (g_next_refused_download + 1) % kMaximumPending;
        forget_download_callback(id);
    }
    YARDLET_RELEASE(callback);
    YARDLET_RELEASE(item);
    YARDLET_RELEASE(browser);
    return handled;
}

static void CEF_CALLBACK download_on_download_updated(cef_download_handler_t *self,
                                                      cef_browser_t *browser,
                                                      cef_download_item_t *item,
                                                      cef_download_item_callback_t *callback) {
    (void)self;
    int id = (int)item->get_id(item);
    int state = item->is_complete(item) ? 2
              : item->is_canceled(item) ? 3
              : item->is_interrupted(item) ? 4 : 1;
    PendingCallback *pending = pending_find(g_downloads, id);
    if (download_refused(id)) {
        forget_download_callback(id);
    } else if (state == 1 && pending == NULL) {
        pending = pending_free(g_downloads);
        if (pending) {
            pending->id = id;
            pending->callback = callback;
            callback->base.add_ref(&callback->base);
        }
    } else if (state != 1 && pending != NULL) {
        cef_download_item_callback_t *stored = pending->callback;
        pending->callback = NULL;
        YARDLET_RELEASE(stored);
    }
    if (g_callbacks.download) {
        cef_string_userfree_t full_path = item->get_full_path(item);
        char *path = full_path ? copy_string(full_path) : strdup("");
        if (full_path) p_cef_string_userfree_utf16_free(full_path);
        g_callbacks.download(tab_of(browser), id, state, path, item->get_received_bytes(item),
                             item->get_total_bytes(item));
        free(path);
    }
    YARDLET_RELEASE(callback);
    YARDLET_RELEASE(item);
    YARDLET_RELEASE(browser);
}

static cef_download_handler_t g_download_handler;

void yardlet_cef_cancel_download(int download_id) {
    PendingCallback *pending = pending_find(g_downloads, download_id);
    if (pending == NULL) return;
    cef_download_item_callback_t *callback = pending->callback;
    callback->cancel(callback);
}

// MARK: - Permission prompts
// A page asks for something Chrome asks the person about in its permission bubble: notifications, the
// location, a clipboard read, more than one download, another site's cookies … With Alloy style and no
// handler, CEF leaves the request unanswered (CEF_PERMISSION_RESULT_IGNORE): the page's promise never
// settled and a second download was dropped without a word. Yardlet asks in the tab's panel and answers
// with the person's choice; Chromium keeps an allow or a block for the site, as Chrome does. Camera and
// microphone come the same way below (media prompts), where the host keeps the answer itself.

typedef struct {
    uint64_t id;
    cef_permission_prompt_callback_t *callback;
} PendingPrompt;

static PendingPrompt g_permission_prompts[kMaximumPending];

static PendingPrompt *pending_prompt(uint64_t id) {
    for (int index = 0; index < kMaximumPending; index++) {
        if (g_permission_prompts[index].callback != NULL && g_permission_prompts[index].id == id) {
            return &g_permission_prompts[index];
        }
    }
    return NULL;
}

static int CEF_CALLBACK permission_on_show_permission_prompt(cef_permission_handler_t *self, cef_browser_t *browser,
                                                             uint64_t prompt_id, const cef_string_t *requesting_origin,
                                                             uint32_t requested_permissions,
                                                             cef_permission_prompt_callback_t *callback) {
    (void)self;
    int tab = tab_of(browser);
    PendingPrompt *pending = NULL;
    for (int index = 0; index < kMaximumPending && pending == NULL; index++) {
        if (g_permission_prompts[index].callback == NULL) pending = &g_permission_prompts[index];
    }
    YARDLET_RELEASE(browser);
    if (tab < 0 || pending == NULL || g_callbacks.permissionPrompt == NULL) {
        // Nobody to ask: the request ends as a dismissed prompt does, not unanswered.
        callback->cont(callback, CEF_PERMISSION_RESULT_DISMISS);
        YARDLET_RELEASE(callback);
        return 1;
    }
    pending->id = prompt_id;
    pending->callback = callback;
    char *origin = copy_string(requesting_origin);
    g_callbacks.permissionPrompt(tab, prompt_id, origin, requested_permissions);
    free(origin);
    return 1;
}

// After Yardlet's answer, or without one: the page moved on, the tab closed.
static void CEF_CALLBACK permission_on_dismiss_permission_prompt(cef_permission_handler_t *self, cef_browser_t *browser,
                                                                 uint64_t prompt_id, cef_permission_request_result_t result) {
    (void)self;
    (void)result;
    PendingPrompt *pending = pending_prompt(prompt_id);
    if (pending) {
        cef_permission_prompt_callback_t *callback = pending->callback;
        pending->callback = NULL;
        YARDLET_RELEASE(callback);
    }
    if (g_callbacks.permissionPromptDismissed) g_callbacks.permissionPromptDismissed(tab_of(browser), prompt_id);
    YARDLET_RELEASE(browser);
}

// Camera and microphone (getUserMedia): CEF asks on_request_media_access_permission, whose default with
// Alloy style refused both at once. The host asks Yardlet as for any permission, under its own prompt ids
// (kMediaPrompt set), and keeps the person's allow or block in Chrome's own site settings for the camera
// and microphone (the tab's profile), so a site is asked once, as in Chrome. An allow lets Chromium open
// the device, which is when macOS asks the person for Yardlet's access. Screen sharing (getDisplayMedia)
// needs Chrome's picker of screens and windows, which a windowless tab has none of: it is refused, as before.
// A request whose page moves on, closes or ends is let go: CEF refuses what a callback never answered.

static const uint64_t kMediaPrompt = 1ULL << 62;
static uint64_t g_next_media_prompt = 1;

typedef struct {
    uint64_t id;
    int tab;
    uint32_t devices;
    cef_string_t origin, topLevel;
    cef_media_access_callback_t *callback;
} PendingMedia;

static PendingMedia g_media_prompts[kMaximumPending];

static cef_request_context_t *request_context_of(cef_browser_t *browser) {
    cef_browser_host_t *host = browser ? browser->get_host(browser) : NULL;
    cef_request_context_t *context = host ? host->get_request_context(host) : NULL;
    YARDLET_RELEASE(host);
    return context;
}

static const uint32_t kMediaDevices[] = {CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE, CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE};

static cef_content_setting_types_t media_setting(uint32_t device) {
    return device == CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE ? CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA
                                                               : CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC;
}

static void free_media_prompt(PendingMedia *pending) {
    YARDLET_RELEASE(pending->callback);
    p_cef_string_utf16_clear(&pending->origin);
    p_cef_string_utf16_clear(&pending->topLevel);
    memset(pending, 0, sizeof(*pending));
}

/// Lets go of `tab`'s camera and microphone requests (the page moved on, closed or ended): each is refused.
static void release_media_prompts(int tab) {
    for (int index = 0; index < kMaximumPending; index++) {
        PendingMedia *pending = &g_media_prompts[index];
        if (pending->callback == NULL || pending->tab != tab) continue;
        uint64_t id = pending->id;
        pending->callback->cancel(pending->callback);
        free_media_prompt(pending);
        if (g_callbacks.permissionPromptDismissed) g_callbacks.permissionPromptDismissed(tab, id);
    }
}

static int CEF_CALLBACK permission_on_request_media_access_permission(cef_permission_handler_t *self, cef_browser_t *browser,
                                                                      cef_frame_t *frame, const cef_string_t *requesting_origin,
                                                                      uint32_t requested_permissions,
                                                                      cef_media_access_callback_t *callback) {
    (void)self;
    YARDLET_RELEASE(frame);
    int tab = tab_of(browser);
    uint32_t devices = requested_permissions & (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE);
    PendingMedia *pending = NULL;
    for (int index = 0; index < kMaximumPending && pending == NULL; index++) {
        if (g_media_prompts[index].callback == NULL) pending = &g_media_prompts[index];
    }
    cef_request_context_t *context = request_context_of(browser);
    if (tab < 0 || devices == 0 || devices != requested_permissions || pending == NULL || context == NULL
        || g_callbacks.permissionPrompt == NULL) {
        callback->cont(callback, CEF_MEDIA_PERMISSION_NONE);
        YARDLET_RELEASE(callback);
        YARDLET_RELEASE_CONTEXT(context);
        YARDLET_RELEASE(browser);
        return 1;
    }
    cef_frame_t *main_frame = browser->get_main_frame(browser);
    cef_string_userfree_t top_level = main_frame ? main_frame->get_url(main_frame) : NULL;
    YARDLET_RELEASE(main_frame);
    YARDLET_RELEASE(browser);
    // What the person answered for the site before: an allow for every device asked for goes on, a block of any
    // is refused.
    int allowed = 1, blocked = 0;
    for (size_t index = 0; index < sizeof(kMediaDevices) / sizeof(kMediaDevices[0]); index++) {
        if (!(devices & kMediaDevices[index])) continue;
        cef_content_setting_values_t value =
            context->get_content_setting(context, requesting_origin, top_level, media_setting(kMediaDevices[index]));
        if (value == CEF_CONTENT_SETTING_VALUE_BLOCK) blocked = 1;
        if (value != CEF_CONTENT_SETTING_VALUE_ALLOW) allowed = 0;
    }
    YARDLET_RELEASE_CONTEXT(context);
    if (blocked || allowed) {
        callback->cont(callback, blocked ? CEF_MEDIA_PERMISSION_NONE : devices);
        YARDLET_RELEASE(callback);
        if (top_level) p_cef_string_userfree_utf16_free(top_level);
        return 1;
    }
    pending->id = kMediaPrompt | g_next_media_prompt++;
    pending->tab = tab;
    pending->devices = devices;
    pending->callback = callback;
    if (requesting_origin && requesting_origin->str) {
        p_cef_string_utf16_set(requesting_origin->str, requesting_origin->length, &pending->origin, 1);
    }
    if (top_level && top_level->str) p_cef_string_utf16_set(top_level->str, top_level->length, &pending->topLevel, 1);
    if (top_level) p_cef_string_userfree_utf16_free(top_level);
    uint32_t asked = (devices & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE ? CEF_PERMISSION_TYPE_CAMERA_STREAM : 0)
        | (devices & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE ? CEF_PERMISSION_TYPE_MIC_STREAM : 0);
    char *origin = copy_string(requesting_origin);
    g_callbacks.permissionPrompt(tab, pending->id, origin, asked);
    free(origin);
    return 1;
}

/// The person's answer to a camera or microphone prompt: kept for the site, as Chrome keeps it.
static void answer_media_prompt(uint64_t prompt_id, int result) {
    for (int index = 0; index < kMaximumPending; index++) {
        PendingMedia *pending = &g_media_prompts[index];
        if (pending->callback == NULL || pending->id != prompt_id) continue;
        BrowserSlot *slot = slot_for_tab(pending->tab);
        cef_request_context_t *context = slot ? request_context_of(slot->browser) : NULL;
        if (context && result != CEF_PERMISSION_RESULT_DISMISS) {
            for (size_t device = 0; device < sizeof(kMediaDevices) / sizeof(kMediaDevices[0]); device++) {
                if (!(pending->devices & kMediaDevices[device])) continue;
                context->set_content_setting(context, &pending->origin, &pending->topLevel,
                                             media_setting(kMediaDevices[device]),
                                             result == CEF_PERMISSION_RESULT_ACCEPT ? CEF_CONTENT_SETTING_VALUE_ALLOW
                                                                                    : CEF_CONTENT_SETTING_VALUE_BLOCK);
            }
        }
        YARDLET_RELEASE_CONTEXT(context);
        int tab = pending->tab;
        pending->callback->cont(pending->callback, result == CEF_PERMISSION_RESULT_ACCEPT ? pending->devices
                                                                                          : CEF_MEDIA_PERMISSION_NONE);
        free_media_prompt(pending);
        // As CEF tells of its own prompts once answered.
        if (g_callbacks.permissionPromptDismissed) g_callbacks.permissionPromptDismissed(tab, prompt_id);
        return;
    }
}

static cef_permission_handler_t g_permission_handler;

void yardlet_cef_permission_result(uint64_t prompt_id, int result) {
    if (prompt_id & kMediaPrompt) {
        if (result >= CEF_PERMISSION_RESULT_ACCEPT && result <= CEF_PERMISSION_RESULT_DISMISS) answer_media_prompt(prompt_id, result);
        return;
    }
    PendingPrompt *pending = pending_prompt(prompt_id);
    if (pending == NULL || result < CEF_PERMISSION_RESULT_ACCEPT || result > CEF_PERMISSION_RESULT_DISMISS) return;
    cef_permission_prompt_callback_t *callback = pending->callback;
    pending->callback = NULL;
    callback->cont(callback, (cef_permission_request_result_t)result);
    YARDLET_RELEASE(callback);
}

// MARK: - Find

static void CEF_CALLBACK find_on_find_result(cef_find_handler_t *self, cef_browser_t *browser,
                                             int identifier, int count, const cef_rect_t *selection,
                                             int active_match, int final_update) {
    (void)self; (void)identifier; (void)selection;
    if (g_callbacks.findResult) g_callbacks.findResult(tab_of(browser), count, active_match, final_update);
    YARDLET_RELEASE(browser);
}

static cef_find_handler_t g_find_handler;

// MARK: - Load handler

static void CEF_CALLBACK load_on_loading_state_change(cef_load_handler_t *self,
                                                      cef_browser_t *browser, int is_loading,
                                                      int can_go_back, int can_go_forward) {
    (void)self;
    emit(tab_of(browser), YardletCEFEventLoadingState, NULL, NULL,
         (is_loading ? 1 : 0) | (can_go_back ? 2 : 0) | (can_go_forward ? 4 : 0));
    YARDLET_RELEASE(browser);
}

// A new document in a frame (a page's own move, a reload, a page from the back-forward cache, a frame
// from another site) comes with a new view or renderer, and Chromium gives it the page's focus only if
// the old view says it had it. CEF 154's windowless view never says so (`HasFocus` is false, `Focus`
// does nothing; CEF fixed both in 156, chromiumembedded/cef#4301), so the new page or frame lost the
// keyboard focus while Yardlet's panel kept it: keys still went in, but no caret was drawn and
// `document.hasFocus()` was false. Focusing again reaches every frame's renderer (Chromium replicates
// page focus to the page's other processes) and does nothing where the page is already focused.
//
// The new document's focused field is not the old one's. A fresh document reports its field when one
// takes focus; a page from the back-forward cache comes back with its field focused and reports nothing,
// so its renderer is asked.
static void CEF_CALLBACK load_on_load_start(cef_load_handler_t *self, cef_browser_t *browser,
                                            cef_frame_t *frame, cef_transition_type_t transition_type) {
    (void)self; (void)transition_type;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot && slot->focused) {
        cef_browser_host_t *host = browser->get_host(browser);
        if (host) host->set_focus(host, 1);
        YARDLET_RELEASE(host);
    }
    if (slot && frame && (frame->is_main(frame) || is_password_frame(slot, frame))) {
        if (slot->passwordFocused) set_password_focus(slot, 0, NULL);
        ask_focused_field(frame);
    }
    // A new document in the main frame (OnLoadStart comes after a commit, never for a same-document move):
    // what was asked or blocked for the page before goes, as Chrome closes its questions and clears its
    // blocked pop-ups then.
    if (slot && frame && !frame->is_main(frame)) clear_frame_popups(slot->tab, frame);
    if (slot && frame && frame->is_main(frame)) {
        clear_blocked_popups(slot->tab);
        release_media_prompts(slot->tab);
        slot->audibleAt = 0;
        slot->discarding = 0;
        // The filled document is gone; the next one was never given the value.
        clear_filled_values(slot);
        cef_string_userfree_t url = frame->get_url(frame);
        emit(slot->tab, YardletCEFEventDocumentStart, url, NULL, 0);
        emit(slot->tab, YardletCEFEventPopupPermission, NULL, NULL, popups_allowed(slot));
        if (url) p_cef_string_userfree_utf16_free(url);
    }
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK load_on_load_end(cef_load_handler_t *self, cef_browser_t *browser,
                                          cef_frame_t *frame, int http_status_code) {
    (void)self;
    if (frame && frame->is_main(frame)) {
        cef_string_userfree_t url = frame->get_url(frame);
        emit(tab_of(browser), YardletCEFEventLoadEnd, url, NULL, http_status_code);
        if (url) p_cef_string_userfree_utf16_free(url);
    }
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
}

static void CEF_CALLBACK load_on_load_error(cef_load_handler_t *self, cef_browser_t *browser,
                                            cef_frame_t *frame, cef_errorcode_t error_code,
                                            const cef_string_t *error_text,
                                            const cef_string_t *failed_url) {
    (void)self;
    if (frame && frame->is_main(frame)) {
        emit(tab_of(browser), YardletCEFEventLoadError, failed_url, error_text, (int)error_code);
    }
    YARDLET_RELEASE(frame);
    YARDLET_RELEASE(browser);
}

static cef_load_handler_t g_load_handler;

// MARK: - Client

static cef_life_span_handler_t *CEF_CALLBACK client_get_life_span_handler(cef_client_t *self) {
    (void)self;
    return &g_life_span_handler;
}
static cef_display_handler_t *CEF_CALLBACK client_get_display_handler(cef_client_t *self) {
    (void)self;
    return &g_display_handler;
}
static cef_load_handler_t *CEF_CALLBACK client_get_load_handler(cef_client_t *self) {
    (void)self;
    return &g_load_handler;
}
static cef_render_handler_t *CEF_CALLBACK client_get_render_handler(cef_client_t *self) {
    (void)self;
    return &g_render_handler;
}
static cef_context_menu_handler_t *CEF_CALLBACK client_get_context_menu_handler(cef_client_t *self) {
    (void)self;
    return &g_context_menu_handler;
}
static cef_request_handler_t *CEF_CALLBACK client_get_request_handler(cef_client_t *self) {
    (void)self;
    return &g_request_handler;
}
static cef_jsdialog_handler_t *CEF_CALLBACK client_get_jsdialog_handler(cef_client_t *self) {
    (void)self;
    return &g_jsdialog_handler;
}
static cef_dialog_handler_t *CEF_CALLBACK client_get_dialog_handler(cef_client_t *self) {
    (void)self;
    return &g_dialog_handler;
}
static cef_download_handler_t *CEF_CALLBACK client_get_download_handler(cef_client_t *self) {
    (void)self;
    return &g_download_handler;
}
static cef_find_handler_t *CEF_CALLBACK client_get_find_handler(cef_client_t *self) {
    (void)self;
    return &g_find_handler;
}
static cef_audio_handler_t *CEF_CALLBACK client_get_audio_handler(cef_client_t *self);

static cef_permission_handler_t *CEF_CALLBACK client_get_permission_handler(cef_client_t *self) {
    (void)self;
    return &g_permission_handler;
}

static cef_client_t g_client;

// MARK: - Per-slot client and accessibility

static int slot_index_of_client(const SlotClient *client) {
    long index = client - g_slot_clients;
    return index >= 0 && index < kMaximumBrowsers ? (int)index : -1;
}

static cef_render_handler_t *CEF_CALLBACK slot_client_get_render_handler(cef_client_t *self) {
    SlotClient *client = (SlotClient *)((char *)self - offsetof(SlotClient, client));
    return &client->renderHandler;
}

static cef_accessibility_handler_t *CEF_CALLBACK
slot_render_get_accessibility_handler(cef_render_handler_t *self) {
    SlotClient *client = (SlotClient *)((char *)self - offsetof(SlotClient, renderHandler));
    return &client->accessibilityHandler;
}

static void forward_accessibility(cef_accessibility_handler_t *self, cef_value_t *value, int kind) {
    SlotClient *client = (SlotClient *)((char *)self - offsetof(SlotClient, accessibilityHandler));
    int index = slot_index_of_client(client);
    int tab = index >= 0 && g_browsers[index].inUse ? g_browsers[index].tab : -1;
    if (value != NULL && tab >= 0 && g_callbacks.accessibility != NULL) {
        // A struct passed into the library gives up one reference; keep ours for the release below.
        value->base.add_ref(&value->base);
        clock_t started = clock();
        cef_string_userfree_t json = p_cef_write_json(value, JSON_WRITER_OMIT_DOUBLE_TYPE_PRESERVATION);
        double milliseconds = (double)(clock() - started) * 1000.0 / CLOCKS_PER_SEC;
        if (milliseconds > 50) fprintf(stderr, "accessibility JSON for tab %d written in %.0f ms\n", tab, milliseconds);
        if (json != NULL) {
            cef_string_utf8_t utf8 = {0};
            p_cef_string_utf16_to_utf8(json->str, json->length, &utf8);
            g_callbacks.accessibility(tab, kind, utf8.str ? utf8.str : "", utf8.length);
            p_cef_string_utf8_clear(&utf8);
            p_cef_string_userfree_utf16_free(json);
        }
    }
    YARDLET_RELEASE(value);
}

static void CEF_CALLBACK accessibility_on_tree_change(cef_accessibility_handler_t *self,
                                                      cef_value_t *value) {
    forward_accessibility(self, value, 0);
}

static void CEF_CALLBACK accessibility_on_location_change(cef_accessibility_handler_t *self,
                                                          cef_value_t *value) {
    forward_accessibility(self, value, 1);
}

/// Copies the shared handlers into every slot's own client (after prepare_handlers filled them).
static void prepare_slot_clients(void) {
    for (int index = 0; index < kMaximumBrowsers; index++) {
        SlotClient *client = &g_slot_clients[index];
        client->client = g_client;
        client->client.get_render_handler = slot_client_get_render_handler;
        client->renderHandler = g_render_handler;
        client->renderHandler.get_accessibility_handler = slot_render_get_accessibility_handler;
        memset(&client->accessibilityHandler, 0, sizeof(client->accessibilityHandler));
        init_base(&client->accessibilityHandler.base, sizeof(client->accessibilityHandler));
        client->accessibilityHandler.on_accessibility_tree_change = accessibility_on_tree_change;
        client->accessibilityHandler.on_accessibility_location_change = accessibility_on_location_change;
    }
}

// MARK: - Application and browser process handler

static void append_switch(cef_command_line_t *command_line, const char *name) {
    cef_string_t value = {0};
    set_string(&value, name);
    command_line->append_switch(command_line, &value);
    p_cef_string_utf16_clear(&value);
}

static char g_extra_switches[1024];

static void append_extra_switches(cef_command_line_t *command_line) {
    char buffer[sizeof(g_extra_switches)];
    strlcpy(buffer, g_extra_switches, sizeof(buffer));
    char *cursor = buffer;
    char *item;
    while ((item = strsep(&cursor, " ")) != NULL) {
        if (*item == '\0') continue;
        char *value = strchr(item, '=');
        if (value == NULL) {
            append_switch(command_line, item);
            continue;
        }
        *value++ = '\0';
        cef_string_t name_string = {0};
        cef_string_t value_string = {0};
        set_string(&name_string, item);
        set_string(&value_string, value);
        command_line->append_switch_with_value(command_line, &name_string, &value_string);
        p_cef_string_utf16_clear(&name_string);
        p_cef_string_utf16_clear(&value_string);
    }
}

// Chromium features a windowless tab has no Chrome window for, turned off as Chrome's own switch turns them
// off. Features the extra switches disable stay disabled.
//
// NativeNotifications: the browser shows no site notifications: it has no prompt for their permission
// (docs/BROWSER_HOST.md). Without it Chromium never connects to macOS notifications, so it neither asks for
// permission at launch nor starts its Alerts helper, and neither app lands in System Settings ›
// Notifications. Before 2026-10-25 every QA copy, a new identifier each time, put a permission request
// on the person's screen.
//
// WebPayments: the Payment Request API (Google Pay, Apple Pay and other wallet buttons, Secure Payment
// Confirmation). Its sheet opens only over the tab's active Chrome window (IsBrowserWindowActive), so show()
// always ended in AbortError here. Without the API (WebContentsImpl sets payment_request_enabled from it) a
// checkout shows no wallet button and the person pays by card, as in the Claude app.
static void disable_features(cef_command_line_t *command_line) {
    cef_string_t name = {0};
    set_string(&name, "disable-features");
    char *disabled = NULL;
    if (command_line->has_switch(command_line, &name)) {
        cef_string_userfree_t value = command_line->get_switch_value(command_line, &name);
        disabled = copy_string(value);
        if (value) p_cef_string_userfree_utf16_free(value);
    }
    char features[sizeof(g_extra_switches)];
    snprintf(features, sizeof(features), "%s%sNativeNotifications,WebPayments", disabled ? disabled : "",
             disabled && *disabled ? "," : "");
    free(disabled);
    cef_string_t value = {0};
    set_string(&value, features);
    command_line->append_switch_with_value(command_line, &name, &value);
    p_cef_string_utf16_clear(&name);
    p_cef_string_utf16_clear(&value);
}

static void CEF_CALLBACK app_on_before_command_line_processing(cef_app_t *self,
                                                               const cef_string_t *process_type,
                                                               cef_command_line_t *command_line) {
    (void)self;
    if (process_type == NULL || process_type->length == 0) {
        // The host adds use-mock-keychain here unless it is Developer ID signed (CookieKeychain).
        append_extra_switches(command_line);
        disable_features(command_line);
        // Chrome's pop-up blocker keeps what it blocks for its address bar's "Pop-ups blocked" (PopupBlockerTabHelper),
        // which a windowless tab has none of, and refuses before CEF asks OnBeforePopup, so the host never heard
        // of a blocked pop-up. With Chrome's own switch every new-window request reaches life_span_on_before_popup,
        // which blocks one without a user gesture by Chrome's rule (ShouldBlockPopup's kNoGesture) and tells Yardlet.
        append_switch(command_line, "disable-popup-blocking");
    }
    YARDLET_RELEASE(command_line);
}

static void CEF_CALLBACK browser_process_on_context_initialized(cef_browser_process_handler_t *self) {
    (void)self;
    cef_request_context_t *global = p_cef_request_context_get_global_context();
    set_windowless_preferences(global);
    YARDLET_RELEASE_CONTEXT(global);
    if (g_callbacks.event) g_callbacks.event(-1, YardletCEFEventContextInitialized, NULL, NULL, 0);
}

static cef_browser_process_handler_t g_browser_process_handler;

static cef_browser_process_handler_t *CEF_CALLBACK app_get_browser_process_handler(cef_app_t *self) {
    (void)self;
    return &g_browser_process_handler;
}

static cef_app_t g_app;

static void prepare_handlers(void) {
    memset(&g_app, 0, sizeof(g_app));
    init_base(&g_app.base, sizeof(g_app));
    g_app.on_before_command_line_processing = app_on_before_command_line_processing;
    g_app.get_browser_process_handler = app_get_browser_process_handler;

    memset(&g_browser_process_handler, 0, sizeof(g_browser_process_handler));
    init_base(&g_browser_process_handler.base, sizeof(g_browser_process_handler));
    g_browser_process_handler.on_context_initialized = browser_process_on_context_initialized;

    memset(&g_client, 0, sizeof(g_client));
    init_base(&g_client.base, sizeof(g_client));
    g_client.get_life_span_handler = client_get_life_span_handler;
    g_client.get_display_handler = client_get_display_handler;
    g_client.get_load_handler = client_get_load_handler;
    g_client.get_render_handler = client_get_render_handler;
    g_client.get_context_menu_handler = client_get_context_menu_handler;
    g_client.get_request_handler = client_get_request_handler;
    g_client.get_jsdialog_handler = client_get_jsdialog_handler;
    g_client.get_dialog_handler = client_get_dialog_handler;
    g_client.get_download_handler = client_get_download_handler;
    g_client.get_find_handler = client_get_find_handler;
    g_client.get_permission_handler = client_get_permission_handler;
    g_client.on_process_message_received = client_on_process_message_received;
    g_client.get_audio_handler = client_get_audio_handler;

    memset(&g_request_handler, 0, sizeof(g_request_handler));
    init_base(&g_request_handler.base, sizeof(g_request_handler));
    g_request_handler.on_before_browse = request_on_before_browse;
    g_request_handler.on_open_urlfrom_tab = request_on_open_urlfrom_tab;
    g_request_handler.on_render_process_terminated = request_on_render_process_terminated;
    g_request_handler.on_render_process_unresponsive = request_on_render_process_unresponsive;
    g_request_handler.on_render_process_responsive = request_on_render_process_responsive;

    memset(&g_jsdialog_handler, 0, sizeof(g_jsdialog_handler));
    init_base(&g_jsdialog_handler.base, sizeof(g_jsdialog_handler));
    g_jsdialog_handler.on_jsdialog = jsdialog_on_jsdialog;
    g_jsdialog_handler.on_before_unload_dialog = jsdialog_on_before_unload_dialog;
    g_jsdialog_handler.on_reset_dialog_state = jsdialog_on_reset_dialog_state;
    g_jsdialog_handler.on_dialog_closed = jsdialog_on_dialog_closed;

    memset(&g_dialog_handler, 0, sizeof(g_dialog_handler));
    init_base(&g_dialog_handler.base, sizeof(g_dialog_handler));
    g_dialog_handler.on_file_dialog = dialog_on_file_dialog;

    memset(&g_download_handler, 0, sizeof(g_download_handler));
    init_base(&g_download_handler.base, sizeof(g_download_handler));
    g_download_handler.can_download = download_can_download;
    g_download_handler.on_before_download = download_on_before_download;
    g_download_handler.on_download_updated = download_on_download_updated;

    memset(&g_find_handler, 0, sizeof(g_find_handler));
    init_base(&g_find_handler.base, sizeof(g_find_handler));
    g_find_handler.on_find_result = find_on_find_result;

    init_base(&g_permission_handler.base, sizeof(g_permission_handler));
    g_permission_handler.on_request_media_access_permission = permission_on_request_media_access_permission;
    g_permission_handler.on_show_permission_prompt = permission_on_show_permission_prompt;
    g_permission_handler.on_dismiss_permission_prompt = permission_on_dismiss_permission_prompt;

    memset(&g_render_handler, 0, sizeof(g_render_handler));
    init_base(&g_render_handler.base, sizeof(g_render_handler));
    g_render_handler.get_view_rect = render_get_view_rect;
    g_render_handler.get_screen_point = render_get_screen_point;
    g_render_handler.get_screen_info = render_get_screen_info;
    g_render_handler.on_popup_show = render_on_popup_show;
    g_render_handler.on_popup_size = render_on_popup_size;
    g_render_handler.on_paint = render_on_paint;
    g_render_handler.on_accelerated_paint = render_on_accelerated_paint;
    g_render_handler.start_dragging = render_start_dragging;
    g_render_handler.on_ime_composition_range_changed = render_on_ime_composition_range_changed;
    g_render_handler.update_drag_cursor = render_update_drag_cursor;
    g_render_handler.on_scroll_offset_changed = render_on_scroll_offset_changed;

    memset(&g_context_menu_handler, 0, sizeof(g_context_menu_handler));
    init_base(&g_context_menu_handler.base, sizeof(g_context_menu_handler));
    g_context_menu_handler.run_context_menu = menu_run_context_menu;

    memset(&g_life_span_handler, 0, sizeof(g_life_span_handler));
    init_base(&g_life_span_handler.base, sizeof(g_life_span_handler));
    g_life_span_handler.on_before_popup = life_span_on_before_popup;
    g_life_span_handler.on_before_popup_aborted = life_span_on_before_popup_aborted;
    g_life_span_handler.on_after_created = life_span_on_after_created;
    g_life_span_handler.do_close = life_span_do_close;
    g_life_span_handler.on_before_close = life_span_on_before_close;

    memset(&g_display_handler, 0, sizeof(g_display_handler));
    init_base(&g_display_handler.base, sizeof(g_display_handler));
    g_display_handler.on_address_change = display_on_address_change;
    g_display_handler.on_title_change = display_on_title_change;
    g_display_handler.on_favicon_urlchange = display_on_favicon_urlchange;
    g_display_handler.on_console_message = display_on_console_message;
    g_display_handler.on_cursor_change = display_on_cursor_change;
    g_display_handler.on_tooltip = display_on_tooltip;
    g_display_handler.on_media_access_change = display_on_media_access_change;

    memset(&g_load_handler, 0, sizeof(g_load_handler));
    init_base(&g_load_handler.base, sizeof(g_load_handler));
    g_load_handler.on_loading_state_change = load_on_loading_state_change;
    g_load_handler.on_load_start = load_on_load_start;
    g_load_handler.on_load_end = load_on_load_end;
    g_load_handler.on_load_error = load_on_load_error;

    memset(&g_devtools_observer, 0, sizeof(g_devtools_observer));
    init_base(&g_devtools_observer.base, sizeof(g_devtools_observer));
    g_devtools_observer.on_dev_tools_message = devtools_on_message;

    prepare_slot_clients();
}

// MARK: - Lifecycle

int yardlet_cef_load(const char *framework_binary_path, char *error, size_t error_capacity) {
    if (g_library) return 1;
    void *library = dlopen(framework_binary_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (library == NULL) {
        snprintf(error, error_capacity, "dlopen failed: %s", dlerror());
        return 0;
    }
#define YARDLET_RESOLVE(name)                                                   \
    p_##name = (__typeof__(&name))dlsym(library, #name);                        \
    if (p_##name == NULL) {                                                     \
        snprintf(error, error_capacity, "missing symbol %s", #name);            \
        dlclose(library);                                                       \
        return 0;                                                               \
    }
    YARDLET_CEF_FUNCTIONS(YARDLET_RESOLVE)
#undef YARDLET_RESOLVE
    // The first cef_api_hash call fixes the API version the library serves to this client.
    const char *hash = p_cef_api_hash(CEF_API_VERSION, 0);
    if (hash == NULL || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        snprintf(error, error_capacity, "API hash mismatch: library %s, headers %s",
                 hash ? hash : "(null)", CEF_API_HASH_PLATFORM);
        dlclose(library);
        return 0;
    }
    g_library = library;
    return 1;
}

int yardlet_cef_initialize(const YardletCEFConfiguration *configuration,
                           const YardletCEFCallbacks *callbacks) {
    if (g_library == NULL) return 0;
    g_callbacks = *callbacks;
    strlcpy(g_extra_switches, configuration->extraSwitches ? configuration->extraSwitches : "",
            sizeof(g_extra_switches));
    prepare_handlers();

    cef_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    settings.no_sandbox = configuration->noSandbox;
    settings.windowless_rendering_enabled = 1;
    settings.command_line_args_disabled = 1;
    // The profile persists, so a site stays signed in across host restarts.
    settings.persist_session_cookies = 1;
    settings.disable_signal_handlers = 1;
    settings.log_severity = LOGSEVERITY_WARNING;
    set_string(&settings.framework_dir_path, configuration->frameworkDirectory);
    set_string(&settings.main_bundle_path, configuration->mainBundlePath);
    set_string(&settings.browser_subprocess_path, configuration->helperExecutablePath);
    set_string(&settings.root_cache_path, configuration->rootCachePath);
    set_string(&settings.cache_path, configuration->profilePath);
    set_string(&settings.locale, configuration->locale);
    set_string(&settings.accept_language_list, configuration->acceptLanguages);
    free(g_accept_languages);
    g_accept_languages = strdup(configuration->acceptLanguages ? configuration->acceptLanguages : "");
    set_string(&settings.log_file, configuration->logFile);

    static char program[] = "Yardlet Browser Host";
    static char *argv[] = {program, NULL};
    cef_main_args_t arguments = {1, argv};
    int result = p_cef_initialize(&arguments, &settings, &g_app, NULL);

    p_cef_string_utf16_clear(&settings.framework_dir_path);
    p_cef_string_utf16_clear(&settings.main_bundle_path);
    p_cef_string_utf16_clear(&settings.browser_subprocess_path);
    p_cef_string_utf16_clear(&settings.root_cache_path);
    p_cef_string_utf16_clear(&settings.cache_path);
    p_cef_string_utf16_clear(&settings.locale);
    p_cef_string_utf16_clear(&settings.accept_language_list);
    p_cef_string_utf16_clear(&settings.log_file);
    return result;
}

void yardlet_cef_run_message_loop(void) { p_cef_run_message_loop(); }
void yardlet_cef_quit_message_loop(void) { p_cef_quit_message_loop(); }
void yardlet_cef_shutdown(void) { if (p_cef_shutdown) p_cef_shutdown(); }

// MARK: - Browsers

/// Makes the slot's browser in its request context; on failure the slot is freed and 0 returned.
static int make_browser(BrowserSlot *slot, const char *url) {
    SlotClient *client = &g_slot_clients[slot - g_browsers];
    slot->identifier = -1;

    cef_window_info_t window_info;
    memset(&window_info, 0, sizeof(window_info));
    window_info.size = sizeof(window_info);
    window_info.windowless_rendering_enabled = 1;
    window_info.shared_texture_enabled = slot->sharedTexture;
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    cef_browser_settings_t browser_settings;
    memset(&browser_settings, 0, sizeof(browser_settings));
    browser_settings.size = sizeof(browser_settings);
    browser_settings.windowless_frame_rate = slot->frameRate;
    browser_settings.background_color = 0xFFFFFFFF;  // Opaque: the panel has no page behind it.

    cef_string_t address = {0};
    set_string(&address, url);
    // A CEF object passed to a CEF function hands it a reference (its CppToC wrapper releases one), so the
    // context gets one of its own; NULL keeps the global context.
    int context_handle = slot->contextHandle;
    cef_request_context_t *context = context_handle > 0 ? context_reference(context_handle) : NULL;
    cef_browser_t *browser = p_cef_browser_host_create_browser_sync(
        &window_info, &client->client, &address, &browser_settings, NULL, context);
    p_cef_string_utf16_clear(&address);
    if (browser == NULL) {
        memset(slot, 0, sizeof(*slot));
        release_context(context_handle);
        return 0;
    }
    slot->identifier = browser->get_identifier(browser);
    slot->browser = browser;  // Keeps the reference returned by create_browser_sync.
    cef_browser_host_t *host = browser->get_host(browser);
    if (host) {
        slot->devtoolsRegistration = host->add_dev_tools_message_observer(host, &g_devtools_observer);
        YARDLET_RELEASE(host);
    }
    return 1;
}

static void make_waiting_browsers(int handle) {
    for (int index = 0; index < kMaximumBrowsers; index++) {
        BrowserSlot *slot = &g_browsers[index];
        if (!slot->inUse || slot->contextHandle != handle || slot->identifier != kWaitingForProfile) continue;
        int tab = slot->tab;
        char *url = slot->waitingURL;
        slot->waitingURL = NULL;
        int made = make_browser(slot, url);
        free(url);
        emit(tab, YardletCEFEventProfileReady, NULL, NULL, made);
    }
}

int yardlet_cef_create_browser(int tab, const char *url, double width, double height, double scale,
                               double screen_x, double screen_y, int frame_rate, int shared_texture,
                               const char *profile_path) {
    if (g_library == NULL || slot_for_tab(tab) != NULL) return 0;
    BrowserSlot *slot = free_slot();
    if (slot == NULL) return -1;
    int context_handle = acquire_context(profile_path);
    if (context_handle < 0) return 0;
    memset(slot, 0, sizeof(*slot));
    slot->inUse = 1;
    slot->contextHandle = context_handle;
    slot->tab = tab;
    slot->width = width;
    slot->height = height;
    slot->scale = scale;
    slot->screenX = screen_x;
    slot->screenY = screen_y;
    slot->frameRate = frame_rate;
    slot->sharedTexture = shared_texture;
    if (context_handle > 0 && !g_contexts[context_handle - 1].ready) {
        slot->identifier = kWaitingForProfile;
        slot->waitingURL = strdup(url ? url : "");
        return 2;
    }
    return make_browser(slot, url);
}

void yardlet_cef_set_viewport(int tab, double width, double height, double scale, double screen_x,
                              double screen_y, int frame_rate) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL) return;
    int scale_changed = slot->scale != scale;
    int size_changed = slot->width != width || slot->height != height;
    int rate_changed = frame_rate > 0 && slot->frameRate != frame_rate;
    if (size_changed || scale_changed) slot->resizedAt = monotonic_seconds();
    slot->width = width;
    slot->height = height;
    slot->scale = scale;
    slot->screenX = screen_x;
    slot->screenY = screen_y;
    if (rate_changed) slot->frameRate = frame_rate;
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    if (scale_changed) host->notify_screen_info_changed(host);
    // The panel moved to a display with another refresh rate: paint one frame per refresh there.
    if (rate_changed) host->set_windowless_frame_rate(host, frame_rate);
    // A move alone changes only where popups and IME windows go; the page needs no relayout.
    if (size_changed || scale_changed) host->was_resized(host);
    YARDLET_RELEASE(host);
}

int yardlet_cef_is_unresponsive(int tab) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return 0;
    int unresponsive = host->is_render_process_unresponsive(host);
    YARDLET_RELEASE(host);
    return unresponsive;
}

int yardlet_cef_unresponsive_action(int tab, int terminate) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->unresponsive == NULL) return 0;
    cef_unresponsive_process_callback_t *callback = slot->unresponsive;
    slot->unresponsive = NULL;
    if (terminate) callback->terminate(callback);
    else callback->wait(callback);
    YARDLET_RELEASE(callback);
    return 1;
}

int yardlet_cef_browser_limit(void) { return g_browser_limit; }

void yardlet_cef_set_browser_limit(int limit) {
    if (limit > 0 && limit <= kMaximumBrowsers) g_browser_limit = limit;
}

int yardlet_cef_cancel_waiting_browser(int tab) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->identifier != kWaitingForProfile) return 0;
    int context = slot->contextHandle;
    free(slot->waitingURL);
    clear_filled_values(slot);
    memset(slot, 0, sizeof(*slot));
    release_context(context);
    return 1;
}

void yardlet_cef_close_browser(int tab) {
    // Closed before its profile loaded: no browser was made, so the tab just goes.
    if (yardlet_cef_cancel_waiting_browser(tab)) {
        emit(tab, YardletCEFEventBeforeClose, NULL, NULL, 0);
        return;
    }
    BrowserSlot *slot = slot_for_tab(tab);
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    if (slot) slot->closing = 1;
    int leave = slot ? slot->leaveDialog : 0;
    host->close_browser(host, 1);
    YARDLET_RELEASE(host);
    // A leave-page question still open (a person's close, yardlet_cef_request_close, or a move) would hold the
    // close, which CEF only marks accepted while the page is asked: it is answered Leave. No-op once answered.
    if (leave) yardlet_cef_jsdialog_result(leave, 1, "");
}

void yardlet_cef_request_close(int tab) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot && slot->identifier == kWaitingForProfile) {
        yardlet_cef_close_browser(tab);
        return;
    }
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    // Without force, CEF asks the page first (beforeunload) where it has a handler, and closes now where it
    // has none; the person's Stay keeps the browser open (AlloyBrowserHostImpl::CloseBrowser).
    host->close_browser(host, 0);
    YARDLET_RELEASE(host);
}

// MARK: - Other apps' addresses
// Chrome's "Always allow ‹site› to open links of this type in the associated app" lives in the profile's
// protocol_handler.allowed_origin_protocol_pairs ({origin: {scheme: true}}, ExternalProtocolHandler). The
// host reads and writes the same setting in the tab's profile, so the answer stays where Chrome keeps it.

static const char kAllowedOriginProtocols[] = "protocol_handler.allowed_origin_protocol_pairs";

int yardlet_cef_external_scheme_allowed(int tab, const char *origin, const char *scheme) {
    BrowserSlot *slot = slot_for_tab(tab);
    cef_request_context_t *context = slot ? request_context_of(slot->browser) : NULL;
    if (context == NULL || origin == NULL || scheme == NULL) {
        YARDLET_RELEASE_CONTEXT(context);
        return 0;
    }
    cef_string_t name = {0}, origin_key = {0}, scheme_key = {0};
    set_string(&name, kAllowedOriginProtocols);
    set_string(&origin_key, origin);
    set_string(&scheme_key, scheme);
    int allowed = 0;
    cef_value_t *value = context->base.get_preference(&context->base, &name);
    cef_dictionary_value_t *pairs = value && value->get_type(value) == VTYPE_DICTIONARY ? value->get_dictionary(value) : NULL;
    if (pairs && pairs->get_type(pairs, &origin_key) == VTYPE_DICTIONARY) {
        cef_dictionary_value_t *schemes = pairs->get_dictionary(pairs, &origin_key);
        allowed = schemes && schemes->get_type(schemes, &scheme_key) == VTYPE_BOOL && schemes->get_bool(schemes, &scheme_key);
        YARDLET_RELEASE(schemes);
    }
    YARDLET_RELEASE(pairs);
    YARDLET_RELEASE(value);
    YARDLET_RELEASE_CONTEXT(context);
    p_cef_string_utf16_clear(&name);
    p_cef_string_utf16_clear(&origin_key);
    p_cef_string_utf16_clear(&scheme_key);
    return allowed;
}

int yardlet_cef_allow_external_scheme(int tab, const char *origin, const char *scheme) {
    BrowserSlot *slot = slot_for_tab(tab);
    cef_request_context_t *context = slot ? request_context_of(slot->browser) : NULL;
    if (context == NULL || origin == NULL || scheme == NULL) {
        YARDLET_RELEASE_CONTEXT(context);
        return 0;
    }
    cef_string_t name = {0}, origin_key = {0}, scheme_key = {0}, error = {0};
    set_string(&name, kAllowedOriginProtocols);
    set_string(&origin_key, origin);
    set_string(&scheme_key, scheme);
    cef_value_t *current = context->base.get_preference(&context->base, &name);
    cef_dictionary_value_t *pairs = NULL;
    if (current && current->get_type(current) == VTYPE_DICTIONARY) {
        cef_dictionary_value_t *stored = current->get_dictionary(current);
        if (stored) pairs = stored->copy(stored, 0);
        YARDLET_RELEASE(stored);
    }
    YARDLET_RELEASE(current);
    if (pairs == NULL) pairs = p_cef_dictionary_value_create();
    cef_dictionary_value_t *schemes = pairs->get_type(pairs, &origin_key) == VTYPE_DICTIONARY
        ? pairs->get_dictionary(pairs, &origin_key) : NULL;
    if (schemes) {
        schemes->set_bool(schemes, &scheme_key, 1);
        YARDLET_RELEASE(schemes);
    } else {
        schemes = p_cef_dictionary_value_create();
        schemes->set_bool(schemes, &scheme_key, 1);
        pairs->set_dictionary(pairs, &origin_key, schemes);  // takes the new dictionary's reference
    }
    cef_value_t *value = p_cef_value_create();
    value->set_dictionary(value, pairs);  // takes the pairs' reference
    // set_preference takes the value's reference.
    int kept = context->base.set_preference(&context->base, &name, value, &error);
    if (!kept) {
        char *message = copy_string(&error);
        fprintf(stderr, "Yardlet Browser Host: %s not set: %s\n", kAllowedOriginProtocols, message);
        free(message);
    }
    YARDLET_RELEASE_CONTEXT(context);
    p_cef_string_utf16_clear(&name);
    p_cef_string_utf16_clear(&origin_key);
    p_cef_string_utf16_clear(&scheme_key);
    p_cef_string_utf16_clear(&error);
    return kept;
}

int yardlet_cef_open_browser_count(void) {
    int count = 0;
    for (int index = 0; index < kMaximumBrowsers; index++) {
        // A popup not made yet has no browser to close.
        if (g_browsers[index].inUse && g_browsers[index].identifier != kPopupPending) count++;
    }
    return count;
}

// MARK: - Cookie copies
// A new task profile's context starts with the cookies of another (the default profile or its parent
// task's; docs/BROWSER_SESSION_ISOLATION.md 3). A copy must leave each cookie as
// Chromium stored it, or leave it out: Google's accounts site answers a __Host- cookie that is missing,
// or a sign-in cookie that comes twice, with /CookieMismatch (docs/BROWSER_SESSION_ISOLATION.md 8).
// A first visitor reads the source's cookies. CEF's cookie struct carries no partition key, and setting
// one makes an unpartitioned cookie, which every top-level site would get; so the copy then asks the
// source which of them each cookie's address gets, which CEF answers with unpartitioned cookies only,
// and sets just those. The target's store is flushed, and the flush's completion reports the copy.
// An import (another browser's sign-ins the person chose, docs/BROWSER_SESSION_ISOLATION.md 10) has no
// source context: its cookies come from Yardlet, unpartitioned, and a first visitor deletes the target's
// cookies of the chosen sites, so each site holds the other browser's cookies alone; they are then set
// as a copy's are.

typedef struct {
    cef_completion_callback_t callback;
    int references;
    int request, copied, sourceHandle, targetHandle;
} CookieFlush;

/// A source cookie kept until the copy knows whether it is partitioned: its strings in UTF-8, and the
/// address the copy asks about and sets it at.
typedef struct {
    cef_cookie_t cookie;
    char *name, *value, *domain, *path, *url;
    int unpartitioned;
} SourceCookie;

typedef struct {
    int references;
    int request, sourceHandle, targetHandle;
    /// The sites (each a domain with its subdomains) an import deletes first; none for a copy, which reads every
    /// site.
    char **sites;
    int siteCount;
    cef_cookie_manager_t *source, *target;
    SourceCookie *cookies;
    int count, capacity;
} CookieCopy;

/// What a visitor does: reads every source cookie, finds those an address gets, or deletes the target's cookies
/// of the import's sites.
enum { kVisitSource, kVisitAddress, kVisitDeleteSites };

typedef struct {
    cef_cookie_visitor_t visitor;
    int references;
    CookieCopy *copy;
    int mode;
} CookieCopyVisitor;

static void finish_cookie_copy(int request, int copied, int source, int target) {
    release_context(source);
    release_context(target);
    if (g_callbacks.event == NULL) return;
    char count[16];
    snprintf(count, sizeof(count), "%d", copied);
    g_callbacks.event(-1, (int)YardletCEFEventCookiesCopied, NULL, count, request);
}

static void CEF_CALLBACK cookie_flush_add_ref(cef_base_ref_counted_t *self) {
    __atomic_add_fetch(&((CookieFlush *)self)->references, 1, __ATOMIC_RELAXED);
}

static int CEF_CALLBACK cookie_flush_release(cef_base_ref_counted_t *self) {
    CookieFlush *flush = (CookieFlush *)self;
    if (__atomic_sub_fetch(&flush->references, 1, __ATOMIC_ACQ_REL) != 0) return 0;
    free(flush);
    return 1;
}

static int CEF_CALLBACK cookie_flush_has_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((CookieFlush *)self)->references, __ATOMIC_ACQUIRE) == 1;
}

static int CEF_CALLBACK cookie_flush_has_at_least_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((CookieFlush *)self)->references, __ATOMIC_ACQUIRE) >= 1;
}

static void CEF_CALLBACK cookie_flush_complete(cef_completion_callback_t *self) {
    CookieFlush *flush = (CookieFlush *)self;
    finish_cookie_copy(flush->request, flush->copied, flush->sourceHandle, flush->targetHandle);
}

static int cookie_domain_matches(const char *raw, const char *domain) {
    if (domain == NULL || domain[0] == '\0') return 1;
    const char *host = raw[0] == '.' ? raw + 1 : raw;
    size_t length = strlen(host), wanted = strlen(domain);
    return strcasecmp(host, domain) == 0
        || (length > wanted && host[length - wanted - 1] == '.' && strcasecmp(host + length - wanted, domain) == 0);
}

/// Whether the copy reads or deletes this cookie: one of its sites', or any when it names none.
static int copy_covers(const CookieCopy *copy, const char *domain) {
    if (domain[0] == '\0') return 0;
    if (copy->siteCount == 0) return 1;
    for (int index = 0; index < copy->siteCount; index++) {
        if (cookie_domain_matches(domain, copy->sites[index])) return 1;
    }
    return 0;
}

/// Whether the source also has the host-only cookie of this domain cookie's host, name and path: a copied domain
/// cookie the copy before 2026-10-25 made beside the site's own cookie, which the copy leaves out.
static int has_host_only_twin(const CookieCopy *copy, const SourceCookie *item) {
    if (item->domain[0] != '.') return 0;
    for (int index = 0; index < copy->count; index++) {
        const SourceCookie *other = &copy->cookies[index];
        if (other->unpartitioned && strcmp(other->domain, item->domain + 1) == 0 && strcmp(other->name, item->name) == 0
            && strcmp(other->path, item->path) == 0) {
            return 1;
        }
    }
    return 0;
}

/// Deletes the target's cookie of the other kind for this one's host, name and path (the domain cookie for a
/// host-only one, and the other way round) by setting it already expired, which Chromium takes as deleting that
/// one cookie. Chromium keeps both kinds side by side, and Google's sign-in refuses a profile with both
/// (/CookieMismatch).
static void expire_other_kind(CookieCopy *copy, const SourceCookie *item, const cef_string_t *url) {
    int hostOnly = item->domain[0] != '.';
    if (hostOnly && strncmp(item->name, "__Host-", 7) == 0) return;  // never a domain cookie
    cef_cookie_t other = item->cookie;
    memset(&other.name, 0, sizeof(other.name));
    memset(&other.value, 0, sizeof(other.value));
    memset(&other.domain, 0, sizeof(other.domain));
    memset(&other.path, 0, sizeof(other.path));
    set_string(&other.name, item->name);
    set_string(&other.path, item->path);
    if (hostOnly) set_string(&other.domain, item->domain);
    other.has_expires = 1;
    other.expires.val = 1;  // 1601
    copy->target->set_cookie(copy->target, url, &other, NULL);
    p_cef_string_utf16_clear(&other.name);
    p_cef_string_utf16_clear(&other.domain);
    p_cef_string_utf16_clear(&other.path);
}

/// Sets the source cookies no address left out, then flushes the target; the flush reports the copy.
static void set_copied_cookies(CookieCopy *copy) {
    int copied = 0;
    for (int index = 0; index < copy->count; index++) {
        SourceCookie *item = &copy->cookies[index];
        if (!item->unpartitioned || has_host_only_twin(copy, item)) continue;
        cef_cookie_t cookie = item->cookie;
        memset(&cookie.name, 0, sizeof(cookie.name));
        memset(&cookie.value, 0, sizeof(cookie.value));
        memset(&cookie.domain, 0, sizeof(cookie.domain));
        memset(&cookie.path, 0, sizeof(cookie.path));
        set_string(&cookie.name, item->name);
        set_string(&cookie.value, item->value);
        set_string(&cookie.path, item->path);
        // Chromium keeps a host-only cookie's domain without the leading dot. Given any domain, CEF
        // sets a domain cookie, sent to subdomains too and refused for a __Host- name; a host-only
        // cookie names its host in the address only.
        if (item->domain[0] == '.') set_string(&cookie.domain, item->domain);
        cef_string_t url = {0};
        set_string(&url, item->url);
        expire_other_kind(copy, item, &url);
        if (copy->target->set_cookie(copy->target, &url, &cookie, NULL)) copied++;
        p_cef_string_utf16_clear(&url);
        p_cef_string_utf16_clear(&cookie.name);
        p_cef_string_utf16_clear(&cookie.value);
        p_cef_string_utf16_clear(&cookie.domain);
        p_cef_string_utf16_clear(&cookie.path);
    }
    CookieFlush *flush = calloc(1, sizeof(*flush));
    int flushing = 0;
    if (flush) {
        *flush = (CookieFlush){.references = 1, .request = copy->request, .copied = copied,
                               .sourceHandle = copy->sourceHandle, .targetHandle = copy->targetHandle};
        cef_base_ref_counted_t *base = &flush->callback.base;
        base->size = sizeof(flush->callback);
        base->add_ref = cookie_flush_add_ref;
        base->release = cookie_flush_release;
        base->has_one_ref = cookie_flush_has_one_ref;
        base->has_at_least_one_ref = cookie_flush_has_at_least_one_ref;
        flush->callback.on_complete = cookie_flush_complete;
        flushing = copy->target->flush_store(copy->target, &flush->callback);
    }
    if (!flushing) finish_cookie_copy(copy->request, copied, copy->sourceHandle, copy->targetHandle);
}

/// Drops one of the copy's references; the last sets the cookies and frees the copy.
static void cookie_copy_release_reference(CookieCopy *copy) {
    if (__atomic_sub_fetch(&copy->references, 1, __ATOMIC_ACQ_REL) != 0) return;
    set_copied_cookies(copy);
    for (int index = 0; index < copy->count; index++) {
        SourceCookie *item = &copy->cookies[index];
        free(item->name);
        free(item->value);
        free(item->domain);
        free(item->path);
        free(item->url);
    }
    free(copy->cookies);
    for (int index = 0; index < copy->siteCount; index++) free(copy->sites[index]);
    free(copy->sites);
    YARDLET_RELEASE(copy->source);
    YARDLET_RELEASE(copy->target);
    free(copy);
}

static void start_cookie_visitor(CookieCopy *copy, int mode, const char *url);

/// The address a cookie is asked about and set at: its host, over https when it is Secure.
static char *cookie_address(const char *domain, const char *path, int secure) {
    const char *host = domain[0] == '.' ? domain + 1 : domain;
    size_t size = strlen(host) + strlen(path) + 16;
    char *url = malloc(size);
    if (url) snprintf(url, size, "%s://%s%s", secure ? "https" : "http", host, path[0] ? path : "/");
    return url;
}

static int CEF_CALLBACK cookie_copy_visit(cef_cookie_visitor_t *self, const cef_cookie_t *cookie, int count,
                                          int total, int *delete_cookie) {
    (void)count;
    (void)total;
    CookieCopyVisitor *visitor = (CookieCopyVisitor *)self;
    CookieCopy *copy = visitor->copy;
    if (cookie == NULL) return 1;
    char *name = copy_string(&cookie->name);
    char *domain = copy_string(&cookie->domain);
    char *path = copy_string(&cookie->path);
    if (visitor->mode == kVisitDeleteSites) {
        if (copy->siteCount > 0 && copy_covers(copy, domain)) *delete_cookie = 1;
    } else if (visitor->mode == kVisitAddress) {
        // This address gets the cookie, so it is not partitioned.
        for (int index = 0; index < copy->count; index++) {
            SourceCookie *item = &copy->cookies[index];
            if (strcmp(item->name, name) == 0 && strcmp(item->domain, domain) == 0 && strcmp(item->path, path) == 0) {
                item->unpartitioned = 1;
            }
        }
    } else if (copy_covers(copy, domain)) {
        if (copy->count == copy->capacity) {
            int capacity = copy->capacity ? copy->capacity * 2 : 64;
            SourceCookie *grown = realloc(copy->cookies, sizeof(*grown) * (size_t)capacity);
            if (grown == NULL) goto done;
            copy->cookies = grown;
            copy->capacity = capacity;
        }
        char *url = cookie_address(domain, path, cookie->secure);
        if (url == NULL) goto done;
        copy->cookies[copy->count++] = (SourceCookie){.cookie = *cookie, .name = name, .domain = domain, .path = path,
                                                      .value = copy_string(&cookie->value), .url = url};
        return 1;
    }
done:
    free(name);
    free(domain);
    free(path);
    return 1;
}

static void CEF_CALLBACK cookie_copy_add_ref(cef_base_ref_counted_t *self) {
    __atomic_add_fetch(&((CookieCopyVisitor *)self)->references, 1, __ATOMIC_RELAXED);
}

static int CEF_CALLBACK cookie_copy_release(cef_base_ref_counted_t *self) {
    CookieCopyVisitor *visitor = (CookieCopyVisitor *)self;
    if (__atomic_sub_fetch(&visitor->references, 1, __ATOMIC_ACQ_REL) != 0) return 0;
    CookieCopy *copy = visitor->copy;
    int mode = visitor->mode;
    free(visitor);
    if (mode == kVisitSource) {
        // Every source cookie was read: one question per address, while this visitor's reference keeps
        // the copy from ending under a question CEF answers at once.
        for (int index = 0; index < copy->count; index++) {
            int asked = 0;
            for (int earlier = 0; earlier < index && !asked; earlier++) {
                asked = strcmp(copy->cookies[earlier].url, copy->cookies[index].url) == 0;
            }
            if (!asked) start_cookie_visitor(copy, kVisitAddress, copy->cookies[index].url);
        }
    }
    cookie_copy_release_reference(copy);
    return 1;
}

static int CEF_CALLBACK cookie_copy_has_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((CookieCopyVisitor *)self)->references, __ATOMIC_ACQUIRE) == 1;
}

static int CEF_CALLBACK cookie_copy_has_at_least_one_ref(cef_base_ref_counted_t *self) {
    return __atomic_load_n(&((CookieCopyVisitor *)self)->references, __ATOMIC_ACQUIRE) >= 1;
}

/// Hands CEF a visitor with its one reference, which holds one of the copy's: every source cookie, the
/// unpartitioned ones `url` gets (`kVisitAddress`), or every cookie of the target, whose sites' it deletes
/// (`kVisitDeleteSites`). CEF's last release of the visitor ends its part.
static void start_cookie_visitor(CookieCopy *copy, int mode, const char *url) {
    CookieCopyVisitor *visitor = calloc(1, sizeof(*visitor));
    if (visitor == NULL) return;
    __atomic_add_fetch(&copy->references, 1, __ATOMIC_RELAXED);
    *visitor = (CookieCopyVisitor){.references = 1, .copy = copy, .mode = mode};
    cef_base_ref_counted_t *base = &visitor->visitor.base;
    base->size = sizeof(visitor->visitor);
    base->add_ref = cookie_copy_add_ref;
    base->release = cookie_copy_release;
    base->has_one_ref = cookie_copy_has_one_ref;
    base->has_at_least_one_ref = cookie_copy_has_at_least_one_ref;
    visitor->visitor.visit = cookie_copy_visit;
    if (mode == kVisitDeleteSites) {
        copy->target->visit_all_cookies(copy->target, &visitor->visitor);
        return;
    }
    if (mode != kVisitAddress) {
        copy->source->visit_all_cookies(copy->source, &visitor->visitor);
        return;
    }
    cef_string_t address = {0};
    set_string(&address, url);
    copy->source->visit_url_cookies(copy->source, &address, 1, &visitor->visitor);
    p_cef_string_utf16_clear(&address);
}

int yardlet_cef_copy_cookies(int request, const char *from_path, const char *to_path) {
    if (g_library == NULL) return 0;
    int source = acquire_context(from_path);
    if (source < 0) return 0;
    int target = acquire_context(to_path);
    if (target < 0) {
        release_context(source);
        return 0;
    }
    cef_request_context_t *source_context = context_reference(source);
    cef_request_context_t *target_context = context_reference(target);
    cef_cookie_manager_t *reader = source_context ? source_context->get_cookie_manager(source_context, NULL) : NULL;
    cef_cookie_manager_t *writer = target_context ? target_context->get_cookie_manager(target_context, NULL) : NULL;
    YARDLET_RELEASE_CONTEXT(source_context);
    YARDLET_RELEASE_CONTEXT(target_context);
    CookieCopy *copy = (reader && writer) ? calloc(1, sizeof(*copy)) : NULL;
    if (copy == NULL) {
        YARDLET_RELEASE(reader);
        YARDLET_RELEASE(writer);
        release_context(source);
        release_context(target);
        return 0;
    }
    // This function's own reference, dropped once the first visitor is with CEF.
    *copy = (CookieCopy){.references = 1, .request = request, .sourceHandle = source, .targetHandle = target,
                         .source = reader, .target = writer};
    start_cookie_visitor(copy, kVisitSource, NULL);
    cookie_copy_release_reference(copy);
    return 1;
}

int yardlet_cef_import_cookies(int request, const char *to_path, const char *const *sites, int site_count,
                               const YardletCEFCookie *cookies, int count) {
    if (g_library == NULL || sites == NULL || site_count <= 0 || count < 0) return 0;
    int target = acquire_context(to_path);
    if (target < 0) return 0;
    cef_request_context_t *context = context_reference(target);
    cef_cookie_manager_t *manager = context ? context->get_cookie_manager(context, NULL) : NULL;
    YARDLET_RELEASE_CONTEXT(context);
    CookieCopy *copy = manager ? calloc(1, sizeof(*copy)) : NULL;
    if (copy == NULL) {
        YARDLET_RELEASE(manager);
        release_context(target);
        return 0;
    }
    // The visitor that deletes the sites' cookies reads the target: its manager is the copy's source and target,
    // with a reference for each.
    manager->base.add_ref(&manager->base);
    *copy = (CookieCopy){.references = 1, .request = request, .targetHandle = target, .source = manager, .target = manager,
                         .sites = calloc((size_t)site_count, sizeof(char *)),
                         .cookies = count ? calloc((size_t)count, sizeof(SourceCookie)) : NULL};
    for (int index = 0; copy->sites && index < site_count; index++) {
        if (sites[index] && sites[index][0]) copy->sites[copy->siteCount++] = strdup(sites[index]);
    }
    for (int index = 0; copy->cookies && index < count; index++) {
        const YardletCEFCookie *given = &cookies[index];
        if (given->name == NULL || given->value == NULL || given->domain == NULL || given->domain[0] == '\0') continue;
        const char *path = given->path && given->path[0] ? given->path : "/";
        cef_cookie_t cookie;
        memset(&cookie, 0, sizeof(cookie));
        cookie.size = sizeof(cookie);
        cookie.secure = given->secure;
        cookie.httponly = given->httponly;
        cookie.same_site = (cef_cookie_same_site_t)given->same_site;
        cookie.priority = (cef_cookie_priority_t)given->priority;
        cookie.has_expires = given->has_expires;
        cookie.expires.val = given->expires;
        copy->cookies[copy->count++] = (SourceCookie){
            .cookie = cookie, .name = strdup(given->name), .value = strdup(given->value), .domain = strdup(given->domain),
            .path = strdup(path), .url = cookie_address(given->domain, path, given->secure), .unpartitioned = 1};
        copy->capacity = copy->count;
    }
    start_cookie_visitor(copy, kVisitDeleteSites, NULL);
    cookie_copy_release_reference(copy);
    return 1;
}

void yardlet_cef_load_url(int tab, const char *url) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL) return;
    cef_frame_t *frame = slot->browser->get_main_frame(slot->browser);
    if (frame == NULL) return;
    cef_string_t address = {0};
    set_string(&address, url);
    frame->load_url(frame, &address);
    p_cef_string_utf16_clear(&address);
    YARDLET_RELEASE(frame);
}

void yardlet_cef_navigation(int tab, int action) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL) return;
    cef_browser_t *browser = slot->browser;
    switch (action) {
    case 0: browser->go_back(browser); break;
    case 1: browser->go_forward(browser); break;
    case 2: browser->reload(browser); break;
    case 3: browser->stop_load(browser); break;
    default: break;
    }
}

void yardlet_cef_edit(int tab, int action) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL) return;
    cef_frame_t *frame = slot->browser->get_focused_frame(slot->browser);
    if (frame == NULL) frame = slot->browser->get_main_frame(slot->browser);
    if (frame == NULL) return;
    switch (action) {
    case 0: frame->undo(frame); break;
    case 1: frame->redo(frame); break;
    case 2: frame->cut(frame); break;
    case 3: frame->copy(frame); break;
    case 4: frame->paste(frame); break;
    case 5: frame->del(frame); break;
    case 6: frame->select_all(frame); break;
    default: break;
    }
    YARDLET_RELEASE(frame);
}

void yardlet_cef_set_focus(int tab, int focused) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot) slot->focused = focused ? 1 : 0;
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->set_focus(host, focused);
    YARDLET_RELEASE(host);
}

void yardlet_cef_set_accessibility(int tab, int enabled) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->set_accessibility_state(host, enabled ? STATE_ENABLED : STATE_DISABLED);
    YARDLET_RELEASE(host);
}

void yardlet_cef_set_hidden(int tab, int hidden) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->was_hidden(host, hidden);
    // A panel showing an existing tab needs a frame even if nothing on the page changed.
    if (!hidden) host->invalidate(host, PET_VIEW);
    YARDLET_RELEASE(host);
}

// MARK: - Input

void yardlet_cef_send_mouse(int tab, int kind, int x, int y, int button, int click_count,
                            uint32_t modifiers) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_mouse_event_t event = {x, y, modifiers};
    yardlet_host_input_began();
    switch (kind) {
    case 1:
    case 2:
        host->send_mouse_click_event(host, &event, (cef_mouse_button_type_t)button, kind == 2,
                                     click_count);
        break;
    case 3:
        host->send_mouse_move_event(host, &event, 1);
        break;
    default:
        host->send_mouse_move_event(host, &event, 0);
        break;
    }
    yardlet_host_input_ended();
    YARDLET_RELEASE(host);
}

void yardlet_cef_send_wheel(int tab, int x, int y, int delta_x, int delta_y, uint32_t modifiers) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_mouse_event_t event = {x, y, modifiers};
    yardlet_host_input_began();
    host->send_mouse_wheel_event(host, &event, delta_x, delta_y);
    yardlet_host_input_ended();
    YARDLET_RELEASE(host);
}

void yardlet_cef_send_key(int tab, int kind, uint32_t modifiers, int windows_key_code,
                          int native_key_code, int is_system_key, uint16_t character,
                          uint16_t unmodified_character) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_key_event_t event;
    memset(&event, 0, sizeof(event));
    event.size = sizeof(event);
    event.type = (cef_key_event_type_t)kind;
    event.modifiers = modifiers;
    event.windows_key_code = windows_key_code;
    event.native_key_code = native_key_code;
    event.is_system_key = is_system_key;
    event.character = character;
    event.unmodified_character = unmodified_character;
    yardlet_host_input_began();
    host->send_key_event(host, &event);
    yardlet_host_input_ended();
    YARDLET_RELEASE(host);
}

static cef_range_t make_range(int from, int to) {
    cef_range_t range;
    if (from < 0) {
        range.from = UINT32_MAX;
        range.to = UINT32_MAX;
    } else {
        range.from = (uint32_t)from;
        range.to = (uint32_t)to;
    }
    return range;
}

void yardlet_cef_ime_set_composition(int tab, const char *text, const int *underlines,
                                     int underline_count, int selection_from, int selection_to,
                                     int replacement_from, int replacement_to) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_composition_underline_t *values =
        underline_count > 0 ? calloc((size_t)underline_count, sizeof(cef_composition_underline_t)) : NULL;
    for (int index = 0; index < underline_count; index++) {
        values[index].size = sizeof(cef_composition_underline_t);
        values[index].range.from = (uint32_t)underlines[index * 3];
        values[index].range.to = (uint32_t)underlines[index * 3 + 1];
        values[index].color = 0xFF000000;
        values[index].background_color = 0x00000000;
        values[index].thick = underlines[index * 3 + 2];
        values[index].style = CEF_CUS_SOLID;
    }
    cef_string_t string = {0};
    set_string(&string, text);
    cef_range_t replacement = make_range(replacement_from, replacement_to);
    cef_range_t selection = make_range(selection_from, selection_to);
    host->ime_set_composition(host, &string, (size_t)underline_count, values, &replacement, &selection);
    p_cef_string_utf16_clear(&string);
    free(values);
    YARDLET_RELEASE(host);
}

void yardlet_cef_ime_commit_text(int tab, const char *text, int replacement_from, int replacement_to,
                                 int relative_cursor) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_string_t string = {0};
    set_string(&string, text);
    cef_range_t replacement = make_range(replacement_from, replacement_to);
    host->ime_commit_text(host, &string, &replacement, relative_cursor);
    p_cef_string_utf16_clear(&string);
    YARDLET_RELEASE(host);
}

void yardlet_cef_ime_finish_composing_text(int tab, int keep_selection) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->ime_finish_composing_text(host, keep_selection);
    YARDLET_RELEASE(host);
}

void yardlet_cef_ime_cancel_composition(int tab) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->ime_cancel_composition(host);
    YARDLET_RELEASE(host);
}

void yardlet_cef_zoom(int tab, int action) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_zoom_command_t command = action == 0 ? CEF_ZOOM_COMMAND_IN
                               : action == 1 ? CEF_ZOOM_COMMAND_OUT : CEF_ZOOM_COMMAND_RESET;
    host->zoom(host, command);
    YARDLET_RELEASE(host);
}

void yardlet_cef_find(int tab, const char *text, int forward, int match_case, int find_next) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_string_t value = {0};
    set_string(&value, text);
    host->find(host, &value, forward, match_case, find_next);
    p_cef_string_utf16_clear(&value);
    YARDLET_RELEASE(host);
}

void yardlet_cef_stop_finding(int tab, int clear_selection) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    host->stop_finding(host, clear_selection);
    YARDLET_RELEASE(host);
}

void yardlet_cef_drag(int tab, int phase, int x, int y, const char *const *files, int file_count,
                      uint32_t operations, uint32_t modifiers) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return;
    cef_mouse_event_t event = {x, y, modifiers};
    switch (phase) {
    case 0: {
        cef_drag_data_t *data = p_cef_drag_data_create();
        for (int index = 0; index < file_count; index++) {
            cef_string_t path = {0};
            set_string(&path, files[index]);
            const char *slash = strrchr(files[index], '/');
            cef_string_t name = {0};
            set_string(&name, slash ? slash + 1 : files[index]);
            data->add_file(data, &path, &name);
            p_cef_string_utf16_clear(&path);
            p_cef_string_utf16_clear(&name);
        }
        // A struct passed into the library carries a reference the library releases.
        data->base.add_ref(&data->base);
        host->drag_target_drag_enter(host, data, &event, (cef_drag_operations_mask_t)operations);
        YARDLET_RELEASE(data);
        break;
    }
    case 1:
        host->drag_target_drag_over(host, &event, (cef_drag_operations_mask_t)operations);
        break;
    case 2:
        host->drag_target_drag_leave(host);
        break;
    case 3:
        host->drag_target_drop(host, &event);
        break;
    default:
        break;
    }
    YARDLET_RELEASE(host);
}

int yardlet_cef_send_devtools_message(int tab, const char *message, size_t length) {
    cef_browser_host_t *host = host_for_tab(tab);
    if (host == NULL) return 0;
    int sent = host->send_dev_tools_message(host, message, length);
    YARDLET_RELEASE(host);
    return sent;
}

// MARK: - Memory saver
// Chrome's Memory Saver discards a tab nobody has looked at for a while: its page goes, while the tab keeps its
// address, title, icon and history, and the page loads again when the tab is shown (docs/BROWSER_HOST.md §3
// "Memory saver"). CEF 154 has no discard of its own, so the host ends the tab's main-frame renderer as Chrome's
// task manager ends a process; the browser and its navigation entries stay, and a reload starts another renderer.
// Before that the host reads what Chrome would not discard (yardlet_cef_page_signals) and asks the page's
// renderers (yardlet_cef_ask_page_state).
//
// Sound: CEF says nothing of a page playing sound, except that it asks an audio handler for capture parameters
// each time a page begins to (AlloyBrowserHostImpl::OnAudioStateChanged). The handler notes when and declines, so
// nothing is captured: capturing would mute the tab (CefAudioLoopbackStreamCreator passes mute_source).

static int CEF_CALLBACK audio_get_audio_parameters(cef_audio_handler_t *self, cef_browser_t *browser,
                                                   cef_audio_parameters_t *params) {
    (void)self; (void)params;
    BrowserSlot *slot = slot_for_browser(browser);
    if (slot) slot->audibleAt = monotonic_seconds();
    YARDLET_RELEASE(browser);
    return 0;
}

static cef_audio_handler_t g_audio_handler;

static cef_audio_handler_t *CEF_CALLBACK client_get_audio_handler(cef_client_t *self) {
    (void)self;
    if (g_audio_handler.base.size == 0) {
        init_base(&g_audio_handler.base, sizeof(g_audio_handler));
        g_audio_handler.get_audio_parameters = audio_get_audio_parameters;
    }
    return &g_audio_handler;
}

static int is_pdf_viewer_url(const cef_string_t *url) {
    static const char prefix[] = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/";
    char *utf8 = copy_string(url);
    int matches = strncmp(utf8, prefix, sizeof(prefix) - 1) == 0;
    free(utf8);
    return matches;
}

/// Calls `visit` with each of the browser's frames (borrowed); stops when it returns 0.
static void each_frame(cef_browser_t *browser, int (*visit)(cef_frame_t *frame, void *context), void *context) {
    cef_string_list_t identifiers = p_cef_string_list_alloc();
    if (identifiers == NULL) return;
    browser->get_frame_identifiers(browser, identifiers);
    size_t count = p_cef_string_list_size(identifiers);
    int going = 1;
    for (size_t index = 0; going && index < count; index++) {
        cef_string_t identifier = {0};
        if (!p_cef_string_list_value(identifiers, index, &identifier)) continue;
        cef_frame_t *frame = browser->get_frame_by_identifier(browser, &identifier);
        p_cef_string_utf16_clear(&identifier);
        if (frame == NULL) continue;
        if (frame->is_valid(frame)) going = visit(frame, context);
        YARDLET_RELEASE(frame);
    }
    p_cef_string_list_free(identifiers);
}

static int note_pdf_frame(cef_frame_t *frame, void *context) {
    cef_string_userfree_t url = frame->get_url(frame);
    int pdf = url != NULL && is_pdf_viewer_url(url);
    if (url) p_cef_string_userfree_utf16_free(url);
    if (pdf) *(int *)context = 1;
    return !pdf;
}

int yardlet_cef_page_signals(int tab, YardletCEFPageSignals *signals) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL || signals == NULL) return 0;
    cef_browser_t *browser = slot->browser;
    memset(signals, 0, sizeof(*signals));
    signals->audibleAgo = slot->audibleAt > 0 ? monotonic_seconds() - slot->audibleAt : -1;
    signals->capturing = slot->capturing;
    signals->loading = browser->is_loading(browser);
    cef_browser_host_t *host = browser->get_host(browser);
    cef_navigation_entry_t *entry = host ? host->get_visible_navigation_entry(host) : NULL;
    if (entry) signals->postData = entry->has_post_data(entry);
    YARDLET_RELEASE(entry);
    YARDLET_RELEASE(host);
    cef_frame_t *main = browser->get_main_frame(browser);
    cef_string_userfree_t url = main ? main->get_url(main) : NULL;
    cef_request_context_t *context = request_context_of(browser);
    if (url && context) {
        signals->notifications = context->get_content_setting(context, url, url, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS)
            == CEF_CONTENT_SETTING_VALUE_ALLOW;
    }
    YARDLET_RELEASE_CONTEXT(context);
    if (url) p_cef_string_userfree_utf16_free(url);
    YARDLET_RELEASE(main);
    each_frame(browser, note_pdf_frame, &signals->pdf);
    return 1;
}

typedef struct {
    int query;
    int asked;
} PageStateQuery;

static int ask_frame(cef_frame_t *frame, void *context) {
    PageStateQuery *query = context;
    cef_string_t name = {0};
    set_string(&name, kPageStateQuery);
    cef_process_message_t *message = p_cef_process_message_create(&name);
    p_cef_string_utf16_clear(&name);
    if (message == NULL) return 1;
    cef_list_value_t *arguments = message->get_argument_list(message);
    if (arguments) arguments->set_int(arguments, 0, query->query);
    YARDLET_RELEASE(arguments);
    // Passing the message gives the frame our reference.
    frame->send_process_message(frame, PID_RENDERER, message);
    query->asked++;
    return 1;
}

int yardlet_cef_ask_page_state(int tab, int query) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL) return -1;
    PageStateQuery state = {query, 0};
    each_frame(slot->browser, ask_frame, &state);
    return state.asked;
}

int yardlet_cef_ask_main_frame(int tab, int query) {
    BrowserSlot *slot = slot_for_tab(tab);
    cef_frame_t *main = slot && slot->browser ? slot->browser->get_main_frame(slot->browser) : NULL;
    if (main == NULL) return 0;
    PageStateQuery state = {query, 0};
    if (main->is_valid(main)) ask_frame(main, &state);
    YARDLET_RELEASE(main);
    return state.asked;
}

int yardlet_cef_discard(int tab) {
    BrowserSlot *slot = slot_for_tab(tab);
    if (slot == NULL || slot->browser == NULL || p_cef_task_manager_get == NULL) return 0;
    // Each task manager object samples every process every two seconds while it lives: one for this end only.
    cef_task_manager_t *manager = p_cef_task_manager_get();
    if (manager == NULL) return 0;
    int64_t task = manager->get_task_id_for_browser_id(manager, slot->browser->get_identifier(slot->browser));
    slot->discarding = 1;
    int ended = task >= 0 && manager->kill_task(manager, task);
    if (!ended) slot->discarding = 0;
    YARDLET_RELEASE(manager);
    return ended;
}
