use ratatui::crossterm::event::{KeyCode, KeyModifiers};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TextInputAction {
    Noop,
    Cancel,
    Submit,
    InsertNewline,
    Insert(char),
    Backspace,
    Delete,
    CaretLeft,
    CaretRight,
    CaretHome,
    CaretEnd,
    CaretUp,
    CaretDown,
}

pub(super) fn action_for_key(
    code: KeyCode,
    modifiers: KeyModifiers,
    keyboard_enhancement: bool,
) -> TextInputAction {
    match code {
        KeyCode::Esc => TextInputAction::Cancel,
        KeyCode::Char('s' | 'S') if modifiers.contains(KeyModifiers::CONTROL) => {
            TextInputAction::Submit
        }
        KeyCode::Enter if keyboard_enhancement && modifiers.contains(KeyModifiers::CONTROL) => {
            TextInputAction::Submit
        }
        KeyCode::Enter => TextInputAction::InsertNewline,
        KeyCode::Backspace => TextInputAction::Backspace,
        KeyCode::Delete => TextInputAction::Delete,
        KeyCode::Left => TextInputAction::CaretLeft,
        KeyCode::Right => TextInputAction::CaretRight,
        KeyCode::Home => TextInputAction::CaretHome,
        KeyCode::End => TextInputAction::CaretEnd,
        KeyCode::Up => TextInputAction::CaretUp,
        KeyCode::Down => TextInputAction::CaretDown,
        KeyCode::Char(c) if !modifiers.contains(KeyModifiers::CONTROL) => {
            TextInputAction::Insert(c)
        }
        _ => TextInputAction::Noop,
    }
}

#[cfg(test)]
mod tests {
    use ratatui::crossterm::event::{KeyCode, KeyModifiers};

    use super::{action_for_key, TextInputAction};

    #[test]
    fn enter_is_newline_without_keyboard_enhancement_for_every_modifier() {
        for modifiers in [
            KeyModifiers::NONE,
            KeyModifiers::SHIFT,
            KeyModifiers::ALT,
            KeyModifiers::CONTROL,
        ] {
            assert_eq!(
                action_for_key(KeyCode::Enter, modifiers, false),
                TextInputAction::InsertNewline,
                "{modifiers:?}"
            );
        }
    }

    #[test]
    fn submit_keys_follow_keyboard_enhancement_capability() {
        for enhanced in [false, true] {
            assert_eq!(
                action_for_key(KeyCode::Char('s'), KeyModifiers::CONTROL, enhanced),
                TextInputAction::Submit
            );
        }
        assert_eq!(
            action_for_key(KeyCode::Enter, KeyModifiers::CONTROL, true),
            TextInputAction::Submit
        );
        assert_eq!(
            action_for_key(KeyCode::Enter, KeyModifiers::CONTROL, false),
            TextInputAction::InsertNewline
        );
    }

    #[test]
    fn editing_and_navigation_keys_map_without_terminal_state() {
        for (code, expected) in [
            (KeyCode::Esc, TextInputAction::Cancel),
            (KeyCode::Backspace, TextInputAction::Backspace),
            (KeyCode::Delete, TextInputAction::Delete),
            (KeyCode::Left, TextInputAction::CaretLeft),
            (KeyCode::Right, TextInputAction::CaretRight),
            (KeyCode::Home, TextInputAction::CaretHome),
            (KeyCode::End, TextInputAction::CaretEnd),
            (KeyCode::Up, TextInputAction::CaretUp),
            (KeyCode::Down, TextInputAction::CaretDown),
            (KeyCode::Char('한'), TextInputAction::Insert('한')),
        ] {
            assert_eq!(
                action_for_key(code, KeyModifiers::NONE, false),
                expected,
                "{code:?}"
            );
        }
        assert_eq!(
            action_for_key(KeyCode::Char('x'), KeyModifiers::CONTROL, false),
            TextInputAction::Noop
        );
    }
}
