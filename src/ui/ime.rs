//! macOS input-source (한/영) auto-switching.
//!
//! With a CJK IME active, the first keypress on a shortcut screen disappears
//! into the IME's preedit buffer and only commits on the NEXT keystroke — so
//! every shortcut feels like it needs two presses, and the app never sees the
//! held key at all (the terminal can't be asked to bypass composition either;
//! Ghostty drops composed keys entirely under kitty report-all-keys).
//!
//! The reliable fix is the im-select/vim pattern: while a shortcut screen is
//! focused, select an ASCII-capable system input source; when a text-input
//! screen opens (or Yard exits), restore the user's IME. macOS only — the
//! stubs below make it a no-op elsewhere.

#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(not(target_os = "macos"))]
pub use noop::*;

#[cfg(not(target_os = "macos"))]
mod noop {
    /// (input source id, is ASCII capable) of the current keyboard source.
    pub fn current_id_and_ascii() -> Option<(String, bool)> {
        None
    }
    pub fn select_ascii() -> bool {
        false
    }
    pub fn select_by_id(_id: &str) -> bool {
        false
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::c_void;

    type CFTypeRef = *const c_void;
    type CFStringRef = *const c_void;
    type CFArrayRef = *const c_void;
    type TISInputSourceRef = *const c_void;
    type CFIndex = isize;
    type Boolean = u8;

    const K_CFSTRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        static kTISPropertyInputSourceID: CFStringRef;
        static kTISPropertyInputSourceIsASCIICapable: CFStringRef;
        static kTISPropertyInputSourceIsSelectCapable: CFStringRef;
        static kTISPropertyInputSourceCategory: CFStringRef;
        static kTISCategoryKeyboardInputSource: CFStringRef;
        fn TISCopyCurrentKeyboardInputSource() -> TISInputSourceRef;
        fn TISGetInputSourceProperty(source: TISInputSourceRef, key: CFStringRef) -> CFTypeRef;
        fn TISSelectInputSource(source: TISInputSourceRef) -> i32;
        fn TISCreateInputSourceList(filter: CFTypeRef, include_all: Boolean) -> CFArrayRef;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFStringGetCString(
            s: CFStringRef,
            buf: *mut u8,
            size: CFIndex,
            encoding: u32,
        ) -> Boolean;
        fn CFArrayGetCount(a: CFArrayRef) -> CFIndex;
        fn CFArrayGetValueAtIndex(a: CFArrayRef, i: CFIndex) -> CFTypeRef;
        fn CFBooleanGetValue(b: CFTypeRef) -> Boolean;
        fn CFEqual(a: CFTypeRef, b: CFTypeRef) -> Boolean;
        fn CFRelease(t: CFTypeRef);
    }

    fn to_string(s: CFStringRef) -> Option<String> {
        if s.is_null() {
            return None;
        }
        let mut buf = [0u8; 256];
        unsafe {
            if CFStringGetCString(
                s,
                buf.as_mut_ptr(),
                buf.len() as CFIndex,
                K_CFSTRING_ENCODING_UTF8,
            ) == 0
            {
                return None;
            }
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        Some(String::from_utf8_lossy(&buf[..end]).into_owned())
    }

    fn bool_prop(src: TISInputSourceRef, key: CFStringRef) -> bool {
        unsafe {
            let v = TISGetInputSourceProperty(src, key);
            !v.is_null() && CFBooleanGetValue(v) != 0
        }
    }

    /// (input source id, is ASCII capable) of the current keyboard source.
    pub fn current_id_and_ascii() -> Option<(String, bool)> {
        unsafe {
            let src = TISCopyCurrentKeyboardInputSource();
            if src.is_null() {
                return None;
            }
            let id = to_string(TISGetInputSourceProperty(src, kTISPropertyInputSourceID));
            let ascii = bool_prop(src, kTISPropertyInputSourceIsASCIICapable);
            CFRelease(src);
            id.map(|i| (i, ascii))
        }
    }

    /// Select an enabled ASCII-capable keyboard source (prefers plain ABC).
    pub fn select_ascii() -> bool {
        select_matching(|_, ascii| ascii, Some("com.apple.keylayout.ABC"))
    }

    /// Re-select a previously remembered source by its id.
    pub fn select_by_id(id: &str) -> bool {
        select_matching(|sid, _| sid == id, None)
    }

    fn select_matching(pred: impl Fn(&str, bool) -> bool, prefer: Option<&str>) -> bool {
        unsafe {
            // Enabled (user-visible) sources only: include_all = false.
            let list = TISCreateInputSourceList(std::ptr::null(), 0);
            if list.is_null() {
                return false;
            }
            let mut fallback: TISInputSourceRef = std::ptr::null();
            let mut chosen: TISInputSourceRef = std::ptr::null();
            for i in 0..CFArrayGetCount(list) {
                let src = CFArrayGetValueAtIndex(list, i);
                let cat = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory);
                if cat.is_null() || CFEqual(cat, kTISCategoryKeyboardInputSource) == 0 {
                    continue;
                }
                if !bool_prop(src, kTISPropertyInputSourceIsSelectCapable) {
                    continue;
                }
                let id = to_string(TISGetInputSourceProperty(src, kTISPropertyInputSourceID))
                    .unwrap_or_default();
                let ascii = bool_prop(src, kTISPropertyInputSourceIsASCIICapable);
                if !pred(&id, ascii) {
                    continue;
                }
                if prefer == Some(id.as_str()) {
                    chosen = src;
                    break;
                }
                if fallback.is_null() {
                    fallback = src;
                }
            }
            let target = if !chosen.is_null() { chosen } else { fallback };
            let ok = !target.is_null() && TISSelectInputSource(target) == 0;
            CFRelease(list);
            ok
        }
    }
}
