# Design system

Yardlet uses familiar agent controls inside a quiet native workbench. This document defines the
consolidation target and maps it to today's implementation. It does **not** mean the new tokens
have been implemented. The current source of shared values is
[`ParityDesignSystem.swift`](../Sources/NativeHarnessClient/Views/ParityDesignSystem.swift).

## Surface ownership

| Surface | Direction |
| --- | --- |
| Conversation, composer, task rows, popovers, menus, settings controls, terminal, review | **A: familiar agent UI.** Follow the Claude and Codex apps' hierarchy, density, disclosure, focus and keyboard behavior. Preserve each provider's names and capabilities. Use native controls where appropriate. |
| App icon/accent, home/new task, sidebar project grouping, empty states | **B: Yardlet identity.** Use typography, spacing and a small selection detail. No beige canvas, decorative numbered labels or badge-covered cards. The identity direction remains open. |
| Split view, accounts/limits, built-in browser, Cloud, remote, mailbox, schedules | **B in structure, A in controls.** Make Yardlet's purpose clear while reusing the same rows, menus, headers and composer. |

The sidebar's task row belongs to A; its project grouping belongs to B. Settings controls belong to
A even when their setting is Yardlet-specific. A remote conversation retains the local components.

## Tokens

Values are macOS points at the standard interface size. Use the existing `yardletInterfaceScale`
(compact 0.94, standard 1, large 1.08) where the component already supports it; text must not be
scaled twice. SF system text provides Korean fallback. Code (code blocks, diffs, command output, open
files and the terminal) uses the code font Settings › Appearance chooses, `yardletCodeFont`: a view
keeps its size for the standard code font, the system monospaced face at 12 points, and takes its
font and size from it (`YardletCodeFont.size(_:scale:)`), so the default draws as before.

| Proposed type token | Size / weight | Current mapping and consolidation |
| --- | --- | --- |
| `type.caption` | 12 / regular | No shared font token. Metadata literals 9, 9.5, 10, 10.5, 11, 11.5 and 12 become 12. |
| `type.control` | 13 / regular or medium | `ParityComposerControl`'s label is already 13. Control labels 12.5, 13 and 13.5 become 13. |
| `type.body` | 14 / regular | `ParityTheme.conversationFont(scale:)`; keep the current 14. Use 13 monospaced for code, with a 12 minimum for dense line numbers. |
| `type.section` | 18 / semibold | No shared token. Section-heading literals 15–19 become 18; body text does not become a heading merely because of its size. |
| `type.title` | 24 / semibold | No shared token. Home/title literals 20, 22, 26, 30, 34 and 38 are candidates for 24 after checking hierarchy. |

This is a role migration, not a numeric search-and-replace. An 8 pt disclosure glyph is an icon,
not caption text. Keep platform menu fonts and the existing interface-size preference. The terminal
currently uses 12 pt multiplied by that scale; leave it out of a chrome-only font migration. Do not impose
a fixed line-height on Korean text: validate its actual line boxes and wrapping.

| Proposed token | Values | Current mapping and consolidation |
| --- | --- | --- |
| `space` | 0, **4**, 8, 12, 16, 20, 24, 32, 48 | No shared scale. `conversationInset` = 32. Chrome padding/gaps 5–7 → 8, 9–11 → 12, 14–15 → 16, 18 → 20, 22 → 24, 28 → 32, by role. Keep 1 pt rules and 2 pt optical adjustments separate. |
| `radius.control` | 6 | `ParityComposerControl` uses literal 6; small-control 6/7 → 6. |
| `radius.row` | 8 | No shared token; row/attachment/code-container 8/9/10/11 → 8. |
| `radius.surface` | 12 | `composerCornerRadius` and `panelCornerRadius` are already 12; popover/sheet surfaces use 12. |

Circles and capsules are shapes, not additional radius tokens. Native menu corners remain the OS's.
Do not round typography or window geometry onto the spacing grid. `proseLineSpacing` = 5 and
`proseBlockSpacing` = 15 remain current compatibility values. `ConversationLayout` also owns the
current turn/item gaps of 15/10. A conversation density change needs its own render comparison;
do not change these incidentally while replacing padding literals. The references below distinguish
independent messages from grouped work.

### Semantic colors

Keep `ParityTheme`'s adaptive surface palette. Accent follows the preference below.
The RGB figures below are the current palette's nominal calibrated components,
rounded to 8-bit notation for reading. The contrast figures use the colors resolved to sRGB. They are neutral, not beige.

| Role / existing name | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas / `canvas` | #FEFEFE | #131313 | Conversation and home |
| Sidebar / `sidebar` | #F6F6F6 | #1B1B1B | Project navigation |
| Elevated / `elevated` | #FFFFFF | #222222 | Popover/panel surface |
| Input / `input` | #FFFFFF | #282828 | Composer and editable field |
| Accent / `accent`, AppKit `accentColor` | System by default; preset light value | System by default; preset dark value | One semantic accent for every accent use; see below |
| Signal / `signal` | #6B8505 | #D1ED2B | Existing signal only; never a default text or background color |
| Primary action / `primaryActionFill` | #333333 | #E0E0E0 | Send/action fill |
| On action / `primaryActionForeground` | #FFFFFF | #1F1F1F | Action glyph |
| Text / proposed `text.primary`, `text.secondary` | Native primary/secondary label | Native primary/secondary label | Alias current `.primary`/`.secondary`; preserve accessibility appearance |
| Border / `separator`, `strongSeparator` | Primary × 10% / 12% | Primary × 10% / 12% | Noninteractive dividers; not a focus indicator |
| Fill / `subtleFill`, `hoverFill`, `selectedFill` | Primary × 3.5% / 6.5% / 9.5% | Primary × 3.5% / 6.5% / 9.5% | Rest, hover, selection |
| Request panel / `requestPanelFill` | Elevated + primary × 4.5% (drawn ≈ #F5F5F5) | Elevated + primary × 4.5% (drawn ≈ #363636) | A waiting request's panel, a shade off the canvas and the composer |
| Status / proposed `status.success`, `warning`, `danger` | Native system green/orange/red | Native system green/orange/red | Alias scattered status colors; always pair with text or an icon |
| Focus / proposed `focus` | Native focus indicator | Native focus indicator | Keep native focus rings; never substitute a faint border. A waiting request's panel draws none: its question shows the focused choice by the selection fill, a field its caret, an answer button the key that gives it |

Secondary is not disabled. Essential instructions use primary or secondary text, never tertiary text
or a status color alone. Check normal text against 4.5:1 and essential control indicators against 3:1
on their actual composite background; the table alone does not establish contrast compliance.

### Accent

Accent is one semantic token, independent of the home/sidebar composition. Route all accent-colored
links, selection details and custom controls through `ParityTheme.accent`; AppKit reads `accentColor`
as the same token's bridge, not a second palette. Status colors retain their semantic meaning.

**Settings > Appearance > Accent** defaults to **System**, resolved dynamically from
[`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor),
which follows the person's macOS accent preference. Do not cache it as a fixed RGB value or assume
its color space. **Ink**, **Grove** and **Iris** each provide an sRGB light/dark pair. The Mac settings tools expose the same choice as `accent`.
Links use primary text when the accent lacks text contrast. Prose links keep an accent underline.

| Preset | Light | Dark | Minimum text contrast, light / dark |
| --- | --- | --- | --- |
| Ink | #143B6B | #8CB8FA | 10.58:1 / 6.10:1 |
| Grove | #14664A | #7AD1AD | 6.52:1 / 6.80:1 |
| Iris | #5C45AB | #B8A6FA | 6.83:1 / 5.82:1 |

These are the lowest ratios measured across the four resolved canvas/sidebar/elevated/input colors;
all three pairs exceed 4.5:1 in both themes. White text on each light accent and black text on each
dark accent also exceed 4.5:1. Recheck hover, selection, disabled and increased-contrast appearances
on implementation. System is dynamic, so no fixed ratio is claimed for it: retain native control
rendering, and do not use an accent alone to communicate essential state. If accent text does not
meet contrast, retain primary text and put the accent in a supporting detail rather than inventing
a second accent color. Composition options must work with any preset; color is not an identity vote.

### Custom appearance

In Settings > Appearance on the Mac, the Light and Dark columns each set an accent, a background
and a text color. Save applies the draft to open windows. The chosen background moves the canvas,
sidebar, elevated panels, input and review surfaces together, preserving the brightness differences
between them. The interface font offers the system, serif and rounded faces with native fallback.
Code keeps its own font and size. The accent preset supplies both accents until a column overrides
one. Selecting another preset replaces both accent overrides.

Reset to defaults restores the system accent, the native surface and label colors, and the system
interface font in a single action. It also clears a preset saved by an earlier version. The theme
is stored in app preferences. The agent can set `light_accent_color`, `light_background_color`,
`light_text_color` and their `dark_` counterparts to an opaque sRGB `#RRGGBB` or `default`.
The interface font setting is `ui_font`.

The settings page and `update_setting` validate the same candidate palette before writing it.
Primary text requires 4.5:1 against its background. Accent requires 3:1. These checks include the
sidebar selection and conversation bubble. The error red, waiting line's orange and diff
addition/removal colors keep their native values. Each fixed color requires the lower of 3:1
and its contrast on the corresponding default background in that appearance, using the same
accent preset. Diff checks composite the change tint over its surface, including a selected line
and an inline preview. A failed save identifies the appearance and pair, its measured contrast
and its required contrast. The last saved palette stays active.

### Motion and geometry

`ParityMotion.easeOut` is 150 ms; `easeInOut` is 160 ms. Existing hover overrides use 100 ms.
Reuse these, return no animation with Reduce Motion, and do not animate new transcript text or
scroll position as decoration. No new spring or looping motion is proposed.

Keep `sidebarWidth` 240, `titleBarHeight` 50, `toolbarHeight` 46, `paneToolbarHeight` 40,
`contentWidth` 768 and `conversationInset` 32 as named component geometry. Resizable surfaces retain
their existing minimums and stored sizes. `ParityAccessibility`'s traversal priorities are behavior,
not visual tokens, and remain unchanged.

## Component contracts

These are consolidation targets; provider differences in meaning remain intact.

| Component | Contract / existing implementation to reuse |
| --- | --- |
| Row | 13 pt label, 12 pt secondary text, 8 pt content gap and horizontal inset, 28 pt minimum for a compact single line; grow for a second line. Keep task title width before optional metadata. Reuse the sidebar row and `IntelligencePickerRow` patterns; retain the sidebar's current 30/42 pt geometry during token-only work. |
| Settings row | `SettingsRow` in `SettingsGroup` (`SettingsCenter.swift`): 13 pt medium title, 12 pt secondary line under it, the control at the trailing edge, 12 pt above and below, 16 pt inside the group's sides, dividers edge to edge within that inset. No symbol on the row and no tile behind one: the section list carries the symbols, as in both apps. A list of things (devices, harnesses, connectors, sign-ins) may show the thing's own mark or symbol, without a tile. Every settings page and the task's harness settings sheet use the same row and group. |
| Request card | `ConversationRequestCard` on `ConversationRequestSurface`: a waiting approval, question, plan or form sits on its panel (`ConversationRequestPanel`), the elevated surface a shade darker (`requestPanelFill`) so it stands apart from the canvas and the composer, with a hairline border and the panel radius, never tinted by its state or kind and with no symbol tile. A header band (`subtleFill`, a hairline under it) holds an accent symbol for what the request waits for (an answer, a plan's review, a form, an approval) and the request's title in 13 pt semibold, or the tool's name when the provider described the call, whose description then heads the body in 13 pt semibold. A question form's band also carries the question's label and, among several, its place between the previous and next question (`ConversationQuestionBand`); the question's own text is the body's headline, 14 pt semibold. 12 pt inside and between blocks. No control on the panel draws a focus ring (Focus, above). Codex's own questions (`CodexQuestionOptions`) wait on the same panel under a "Questions" band and, once answered, read as their answers on the answered request's 2 pt rule. A command shows in the bounded monospaced block. Answers end the row with the prominent "Allow once"; the keys the composer answers it with show inside the buttons, on the oldest waiting request only. The wider allows between them are one split button, as the Claude app draws "Always allow": the narrowest by a short name (`ConversationAllowScope`), and every one in its menu with its scope on a second line; words Yardlet cannot name keep their own button. In a task's own conversation the waiting requests dock right above the composer (`ConversationRequestDock`), as the Claude app docks them: the oldest whole, up to two after it as edges showing behind it, at most 60% of the conversation's height, a taller card opening at its answers and scrolling under the panel's edge; the composer stays free, and the turn keeps its "Awaiting approval" line. A conversation inside another surface keeps them under their turn. An answered request leaves one 13 pt secondary line (symbol, outcome, title), never red, with a question's answers or a form's sent values under it on a 2 pt rule. `PersonalAgentRequestCard` uses the same surface. |
| Chip | 13 pt control text, 24 pt minimum control height, 8 pt horizontal inset, 6 pt radius. Use `ParityComposerControl`; a chip is a control/reference, not decoration on every row. |
| Popover | 12 pt surface radius, 8 pt outer content inset, shared rows. Width follows content within its existing bounds. Preserve dismissal, focus return and keyboard traversal. Render its content without opening it during QA. |
| Menu | Native menu when native behavior is needed; custom composer menus reuse `ComposerMenuList`/`ComposerMenuRow` and `IntelligencePickerRow` with `ComposerOptionChoiceLabel`. 13 pt labels, 12 pt descriptions, 8 pt row inset. Do not recreate menu semantics in a stack of unrelated buttons. |
| Composer | `PromptComposer`, 14 pt editor, 13 pt controls, 12 pt corner, 28 pt send target, 24 pt auxiliary controls. Controls wrap before the send action clips; when the context ring, the model control, the queue and send are all that is left on the last row and still do not fit, the model control drops its effort and then shortens its name from the end, as the Codex app drops the effort and both apps shorten the name, so send stays in view. A text field that wraps (`wrapsBetweenWords()`) and the conversation's prose break lines between words, as `Text` does: Korean at its spaces. Shared 32 pt outer conversation gutter; preserve provider-specific options. |
| Panel header | `paneToolbarHeight` 40, 13 pt label, shared toolbar buttons and 8 pt content gaps. One header per panel; focus belongs to the pane whose control was used. |
| Empty state | 18 pt title, 14 pt explanation, one primary next action, 16 pt vertical gap and 24/32 pt outer inset. Keep the real task composer available when useful. No large decorative badge or enclosure. |
| Terminal/review | Native monospaced text, existing interface-size scaling, shared header/selection colors. Preserve ANSI/diff meaning and horizontal scrolling; never clip code to achieve a tidy silhouette. |

## Reference measurements

Read from installed bundle bytes on 2026-11-08, without launching either app. CSS px are logical
pixels at the bundle's baseline; rem conversions below assume a 16 px root and scale 1. They are
not physical screenshot pixels or proof of a particular user's active theme/density.

**Claude 4.4212.0**: `ion-dist.asar`, `assets/v1/c25d7186f-CHE_J2eY.js` (token definitions), and
`assets/v1/c6a992d55-DOxJvg9D.css` (component utility rules).
Code conversation geometry is in `assets/v1/c96d752d0-BKceltwO.js`, `Q3`.
Terminal defaults are in `assets/v1/c6bf19e8f-BzuTs6yG.js`, `Dr`/`Er` and the terminal constructor.

| Reference token or rule | Compact / comfortable, unless stated |
| --- | --- |
| `--cds-font-size-caption/footnote/body/prose/title` | 11/12/13/14/20 px; comfortable 12/13/14/16/22 px |
| `--cds-leading-body/prose` | 19/20 px; comfortable 20/24 px |
| `--cds-h-control`, `--cds-radius`, `--cds-radius-composer` | 24/6/12 px; comfortable 32/8/14 px |
| `--cds-pad-xs/sm/md/lg/xl` | 4/6/8/12/20 px; comfortable 6/8/12/16/24 px |
| `--cds-gap-xs/sm/md/lg/xl` | 6/8/12/20/32 px; comfortable 8/12/16/28/40 px |
| `--chat-column-gutter-start/end` fallback | 32 px; route overrides exist |
| Code conversation `Q3` turn/item/reply gaps | 20/16/6 px; comfortable 24/20/8 px. These are not Yardlet's current 15/10 gaps. |
| `--cds-surface-0/1/2/3` light → dark | #F9F9F7/#FCFCFB/#FFFFFF/#FFFFFF → #0B0B0B/#151515/#1A1A19/#20201F |
| `--cds-text-primary/secondary/accent` light → dark | #0B0B0B/#52514E/#184F95 → #F0EFEC/#C3C2B7/#6DA7EC |
| `--cds-surface-panel/popover`, `--cds-border` | Surface 2/3; black 10% light, white 10% dark |
| `--cds-font-sans/mono` | Anthropic sans/mono with system/SF Mono fallback; Yardlet uses system faces |
| Terminal `fontSize` / `fontFamily` fallback | 13 px / Menlo, Monaco, Courier New, monospace; an explicit font choice overrides them |
| `--cds-dur-fast/snap/base/sheet` | 60/120/200/300 ms; reference only |

**Codex 26.1103.41825**, bundle ID `com.openai.codex`: `app.asar`,
`webview/assets/async/e77f816560c6.css`. This stylesheet also contains browser/extension rules;
do not confuse those with the desktop defaults.

| Reference token or selector | Value |
| --- | --- |
| Desktop `--text-sm/base/lg`, `--text-heading-sm/md/app` | 13/14/16 px; headings 18/20/28 px. The theme starts at small = 12 px, then `[data-codex-window-type=electron]` overrides it to 13 px. |
| `--font-sans-default`, `--font-mono-default` | System sans; system mono/SF Mono/Menlo fallback |
| `--spacing`, `--conversation-item-gap/grouped-item-gap` | 4 px; 16/4 px |
| `--height-toolbar`, `--height-toolbar-pane` | 46/40 px |
| `--spacing-token-sidebar` | `clamp(240px, 275px, min(520px, calc(100vw - 320px)))` |
| `--spacing-token-button-composer`, desktop `--composer-radius` | 28 px target; 22 px round corner |
| `--radius-sm/md/xl/2xl-base` | 6/8/12/16 px; supported superellipse corners scale some radii by 1.25. Not directly equivalent to SwiftUI round corners. |
| Desktop menu override `--menu-item-padding`, `--menu-gutter` | 5 px vertical, row-x fallback 8 px; gutter 4 px. The separate browser selector uses 8 px gutter. |
| `--app-color-background-surface/under/application-menu` light → dark | #FFFFFF/#F9F9F9/#F9F9F9 → #181818/#000000/#212121 |
| `--app-color-text-foreground`, `--color-token-text-secondary` | #1A1C1F → #DFDFDF; secondary is foreground at 65% over the surface |
| `--diffs-font-size`, `--diffs-line-height` | User code size, fallback 12 px; line-height × 1.8 |

The references do not agree on every corner, density or typeface. Yardlet's shared compact composer
currently follows Claude's 12 pt corner and 24 pt controls; its panel bars follow Codex's 46/40 pt
metrics. Retain that explicit choice while consolidating. Reference colors inform roles, not a
requirement to copy Claude's warm light palette or Codex's every theme override.

## Adding or changing a value

1. Choose a semantic role and reuse its token/component first. Put shared values in
   `ParityDesignSystem.swift`; keep provider protocol data out of visual tokens.
2. If no role fits, show the smallest new value with its purpose and reference selector, or explain
   the Yardlet-specific need. A one-off literal needs the same justification as a token.
3. Render the affected real view in light/dark, Korean/English, standard and narrow widths. Include
   long labels, long content, focus, selection and relevant disabled/error states. Use
   `WindowlessRender` and synthetic data; never show a native menu during an offscreen test.
4. Compare the previous image at logical size. Check legibility, clipping, focus and scroll behavior.
   A static image cannot prove interaction or performance; use the relevant contract test as well.
5. Update this mapping with the implementation. Do not create a second palette or another component
   for one provider. Identity options require a separate choice before applying them to product UI.

## Mac keyboard shortcuts

The Mac command registry (`MacShortcut`) gives each application shortcut a stable identifier,
title, scope and default key. The existing menu, focused view or window monitor dispatches it.
Menu commands continue to participate in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts.

| Where the keyboard is | Default behavior |
| --- | --- |
| App and window menus | ⌘, opens Settings, ⌘K searches tasks and commands, and ⌘N opens New task. The Task, View, Edit, File, Window and Split View menus show the available keys for the current window. |
| Task window | ⌘1–4 select task surfaces. ⌃1–9 open pinned rows in sidebar order. ⌃Tab and ⌃⇧Tab move between window tabs, or between tasks when only one tab is open. ⌘⌥ and an arrow focus an adjacent pane. |
| Composer | The existing send preference decides whether Return sends or inserts a line. The alternate follow-up uses ⌘Return or ⇧⌘Return. Typed commands and mentions take precedence over submission. Marked text stays with the input method. In the empty composer the send keys can allow one pending request, and Escape can deny one before stopping a turn. |
| Terminal | ⌘J and Control-backtick toggle the terminal. The latter is handled by the window while its panel commands are enabled. ⇧⌘L attaches a shared terminal selection; the terminal and shell handle their own input. |
| Browser page | The focused page handles editing, navigation, zoom, find, address and browser-tab commands. The window's task-surface bindings take precedence where registered. The address field has its own suggestion keys. See [Browser host](BROWSER_HOST.md). |
| Other focused controls | The palette and lists navigate a selection; the model picker and question form have numbered choices. Image previews handle navigation and zoom. Mail composition and the Simulator screen have their own commands. Standard text editing, dialog acceptance, cancellation and focus traversal follow the native control. |

Settings > Keyboard shortcuts searches by command, scope or current key. Click a key to record a
replacement, clear it or restore the default. If another command uses the requested key, the editor
names it before offering to clear its binding and assign the new one. Cancel preserves both bindings.
Restoring all shortcuts removes the Mac shortcut preference. Commands that share a factory key keep
their original focus and priority when restored.

A shortcut assigned in macOS App Shortcuts takes precedence. The editor shows the assigned key
and its owner, and directs changes to System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts.
It reads those assignments when Settings opens or the app becomes active. If macOS assigns a command,
Yardlet drops its own override for that command. The recorder also identifies standard shortcuts for
Spotlight, input sources and app switching. macOS can consume those keys before a recorder receives them.

The list configures this Mac. Agent settings tools continue to expose the composer's existing send
preference. Recording a key and confirming the displacement of another command take place in the editor.
