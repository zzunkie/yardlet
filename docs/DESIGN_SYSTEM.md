# Design system

Yardlet uses familiar agent controls inside a quiet native workbench. This document defines the
consolidation target and maps it to today's implementation. The type, spacing and radius tokens are
implemented in [`ParityDesignSystem.swift`](../Sources/NativeHarnessClient/Views/ParityDesignSystem.swift),
the source of shared values: `ParityType` with `Font.parity(_:weight:scale:)`, `ParitySpace` and
`ParityRadius`. The Settings window (its shell, rows and groups, General, Browser, Appearance,
Notifications, Keyboard shortcuts, Accounts/Harnesses and Usage), the conversation's request cards,
task headers and the session rail use them; remaining surfaces move onto the tokens surface by
surface. The color
presets' values and a person's own colors are in
[`MacColorTheme.swift`](../Sources/NativeHarnessClient/Views/MacColorTheme.swift), which the same tokens read.

## Surface ownership

| Surface | Direction |
| --- | --- |
| Conversation, composer, task rows, popovers, menus, settings controls, terminal, review | **A: familiar agent UI.** Follow the Claude and Codex apps' hierarchy, density, disclosure, focus and keyboard behavior. Preserve each provider's names and capabilities. Use native controls where appropriate. |
| App icon/accent, home/new task, sidebar project grouping, empty states | **B: Yardlet identity.** Settled on the quiet A+B direction: neutral default surfaces, typography, spacing and subtle selection details carry Yardlet's identity. Projects stay neutral without random colored dots in the sidebar, Home or Desk. No beige canvas, decorative numbered labels or badge-covered cards. |
| Split view, accounts/limits, built-in browser, Cloud, remote, mailbox, schedules | **B in structure, A in controls.** Make Yardlet's purpose clear while reusing the same rows, menus, headers and composer. |

The sidebar's task row belongs to A; its project grouping belongs to B. Settings controls belong to
A even when their setting is Yardlet-specific. A remote conversation retains the local components.

## Tokens

Values are macOS points at the standard interface size. Use the existing `yardletInterfaceScale`
(compact 0.94, standard 1, large 1.08) where the component already supports it; text must not be
scaled twice. View › Zoom In and Zoom Out multiply it by the app's zoom (80% to 175%,
`InterfaceZoom`). The window applies the zoom once, when it sets the scale
(`YardletWindowPreferences`), and no view reads `InterfaceZoom` itself, so a view that reads the
scale follows both, code and the terminal included: a size in points as `size * yardletInterfaceScale`, a text style as `Font.yardlet(_:scale:)`, which draws exactly as the
style at 1. SwiftUI's `dynamicTypeSize` does not change the size of macOS fonts, text styles such as
`.body` included, so it is not a way to scale text. Native controls (buttons, pickers, switches) keep
their system size. SF system text provides Korean fallback. Code (code blocks, diffs, command output, open
files and the terminal) uses the code font Settings › Appearance chooses, `yardletCodeFont`: a view
keeps its size for the standard code font, the system monospaced face at 12 points, and takes its
font and size from it (`YardletCodeFont.size(_:scale:)`), so the default draws as before. That function
multiplies the code font's chosen size by the same scale, so code follows the zoom once too. The Connect to
Mac and Task Resource Usage windows do not apply the interface size, so their scale stays 1.

| Type token | Size / weight | Current mapping and consolidation |
| --- | --- | --- |
| `type.caption`, `ParityType.caption` | 12 / regular | A secondary line, metadata, a hint: `SettingsMetrics.detailFont`, the request cards' secondary lines and key caps. Metadata literals 9, 9.5, 10, 10.5, 11, 11.5 and 12 elsewhere become 12. |
| `type.control`, `ParityType.control` | 13 / regular or medium | A control's label, a row's title, a card's own words: `ParityComposerControl`'s label, `SettingsMetrics.titleFont` (medium) and `groupTitleFont` (semibold), the request card's band title (semibold). Control labels 12.5, 13 and 13.5 elsewhere become 13. |
| `type.body`, `ParityType.body` | 14 / regular | `ParityTheme.conversationFont(scale:)` and a question's headline (semibold). Use 13 monospaced for code, with a 12 minimum for dense line numbers. |
| `type.section`, `ParityType.section` | 18 / semibold | A Settings page's heading. Section-heading literals 15–19 elsewhere become 18; body text does not become a heading merely because of its size. |
| `type.title`, `ParityType.title` | 24 / semibold | Not used yet. Home/title literals 20, 22, 26, 30, 34 and 38 are candidates for 24 after checking hierarchy. |

`Font.parity(_:weight:scale:)` draws a token at a scale: a view that follows the interface size and
zoom passes `yardletInterfaceScale`, which already holds the zoom, so it scales once; Settings, which
keeps its size, passes 1. This is a role migration, not a numeric search-and-replace. An 8 pt disclosure glyph is an icon,
not caption text. Keep platform menu fonts and the existing interface-size preference. The terminal
draws the code font at its chosen size (12 pt by default) multiplied by that scale; leave it out of a
chrome-only font migration. Do not impose
a fixed line-height on Korean text: validate its actual line boxes and wrapping.

| Token | Values | Current mapping and consolidation |
| --- | --- | --- |
| `space`, `ParitySpace` | 0, **4**, 8, 12, 16, 20, 24, 32, 48 (`s4` … `s48`) | `conversationInset` = `s32`; `SettingsMetrics` and the request card's insets and gaps. Spacing does not follow the interface size. Elsewhere chrome padding/gaps 5–7 → 8, 9–11 → 12, 14–15 → 16, 18 → 20, 22 → 24, 28 → 32, by role. Keep 1 pt rules and 2 pt optical adjustments separate, and the gap around a middle dot in a run of words is typography, not spacing. |
| `radius.control`, `ParityRadius.control` | 6 | `ParityComposerControl`, the Settings search field; small-control 6/7 → 6. A 16 pt key cap keeps a 4 pt corner. |
| `radius.row`, `ParityRadius.row` | 8 | Settings' section and result rows and a highlighted row, request options, the plan box and an option's preview; row/attachment/code-container 8/9/10/11 elsewhere → 8. |
| `radius.surface`, `ParityRadius.surface` | 12 | `panelCornerRadius` and the request panel; popover/sheet surfaces use 12. |
| `radius.composer`, `ParityRadius.composer` | 14 | `composerCornerRadius`: 14 pt outer with 8 pt inner padding nests 6 pt inner controls (`14 - 8 = 6`). |

Circles and capsules are shapes, not additional radius tokens. Native menu corners remain the OS's.
Do not round typography or window geometry onto the spacing grid. `proseLineSpacing` = 5 and
`proseBlockSpacing` = 15 remain current compatibility values. `ConversationLayout` also owns the
current turn/item gaps of 15/10. A conversation density change needs its own render comparison;
do not change these incidentally while replacing padding literals. The references below distinguish
independent messages from grouped work.

### Semantic colors

Keep `ParityTheme`'s adaptive surface palette. Accent follows the preference below.
A color preset or a person's own colors do not form a second palette: they are inputs to these
tokens (`MacColorTheme`, in the environment as `yardletColorTheme`). Their background shifts the
surface rows together, their text color becomes the window's foreground color in place of the native
label, and their accent is the Accent row; see Custom appearance. The table gives the defaults.
The RGB figures below are the current default sRGB surface values from `ParityDesignSystem.swift`
(neutral cool grays, not beige). The contrast figures use the colors resolved to sRGB.

| Role / existing name | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas / `canvas` | #FCFCFC | #191A1B | Conversation and home |
| Sidebar / `sidebar` | #F4F5F7 | #202124 | Project navigation |
| Elevated / `elevated` | #FFFFFF | #27282C | Popover/panel surface |
| Input / `input` | #FFFFFF | #2C2D31 | Composer and editable field |
| Inner rail / `innerRail` | #F8F8F9 | #141518 | Stepped inner section rail (Mail, Calendar, Personal agents) |
| User bubble / `userBubbleFill` | #F2F3F5 | #23252A | Sent user message bubble |
| Accent / `accent`, AppKit `accentColor` | System by default; preset light value | System by default; preset dark value | One semantic accent for every accent use; see below |
| Signal / `signal` | #6B8505 | #D1ED2B | Existing signal only; never a default text or background color |
| Primary action / `primaryActionFill` | #333333 | #E0E0E0 | Send/action fill |
| On action / `primaryActionForeground` | #FFFFFF | #1F1F1F | Action glyph |
| Text / proposed `text.primary`, `text.secondary` | Native primary/secondary label | Native primary/secondary label | Alias current `.primary`/`.secondary`; preserve accessibility appearance |
| Border / `separator`, `strongSeparator` | Black × 9.5% / 16% | White × 10.5% / 18% | Noninteractive dividers; not a focus indicator |
| Fill / `subtleFill`, `hoverFill`, `selectedFill` | Primary × 3.5% / 6.2% / 9.5% | Primary × 3.5% / 6.2% / 9.5% | Rest, hover, selection |
| Request panel / `requestPanelFill` | Elevated + primary × 4.5% (drawn ≈ #F4F4F4) | Elevated + primary × 4.5% (drawn ≈ #323337) | A waiting request's panel, a shade off the canvas and the composer |
| Status / proposed `status.success`, `warning`, `danger` | Native system green/orange/red | Native system green/orange/red | Alias scattered status colors; always pair with text or an icon |
| Focus / proposed `focus` | Native focus indicator | Native focus indicator | Keep native focus rings; never substitute a faint border. A waiting request's panel draws none: its question shows the focused choice by the selection fill, a field its caret, an answer button the key that gives it. Nor does the turn rail beside a conversation, which a click on a mark gives the arrow keys: the turn it marks shows where it is |

Secondary is not disabled. Essential instructions use primary or secondary text, never tertiary text
or a status color alone. Check normal text against 4.5:1 and essential control indicators against 3:1
on their actual composite background; the table alone does not establish contrast compliance.

### Accent

Accent is one semantic token, independent of the home/sidebar composition. Route all accent-colored
links, selection details and custom controls through `ParityTheme.accent`; AppKit reads `accentColor`
as the same token's bridge, not a second palette. Status colors retain their semantic meaning.

**Settings > Appearance > Color preset** defaults to **System**, resolved dynamically from
[`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor),
which follows the person's macOS accent preference. Do not cache it as a fixed RGB value or assume
its color space. **Ink**, **Grove** and **Iris** set only the accent, each an sRGB light/dark pair; the
complete presets in Custom appearance set an accent pair with their background and text. `ParityTheme`
builds every preset's adaptive accent from these pairs (`YardletAccentPreference.colors(in:)`). The Mac
settings tools expose the same choice as `accent`.
Links use primary text when the accent lacks text contrast. Prose links keep an accent underline.

| Preset | Light | Dark | Minimum text contrast, light / dark |
| --- | --- | --- | --- |
| Ink | #143B6B | #8CB8FA | 10.31:1 / 6.79:1 |
| Grove | #14664A | #7AD1AD | 6.36:1 / 7.57:1 |
| Iris | #5C45AB | #B8A6FA | 6.65:1 / 6.47:1 |

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
Code keeps its own font and size. **Color preset** offers four complete palettes alongside
System and the accent-only Ink, Grove and Iris. Each complete palette sets these sRGB colors:

| Preset | Light background / text / accent | Dark background / text / accent |
| --- | --- | --- |
| Nord | `#FEFEFE` / `#2E3440` / `#5E81AC` | `#20242D` / `#ECEFF4` / `#88C0D0` |
| Catppuccin | `#FEFEFE` / `#4C4F69` / `#8839EF` | `#1E1E2E` / `#CDD6F4` / `#CBA6F7` |
| Ember | `#FFFFFE` / `#3B2823` / `#943F20` | `#211714` / `#F7E7DA` / `#F3AB82` |
| Tidepool | `#FEFFFF` / `#193537` / `#006C68` | `#102326` / `#D5F3EE` / `#75D7CB` |

Nord uses Polar Night text and a Frost accent on a Snow Storm background in light mode.
To preserve contrast for the fixed status and diff colors, Yardlet lightens Snow Storm
(`#ECEFF4`) and darkens the dark Polar Night background (`#2E3440`). Catppuccin pairs
Latte and Mocha with their Mauve accents and lightens Latte's Base (`#EFF1F5`).
Ember and Tidepool are Yardlet palettes. The third-party palette licenses are in
[Third-party notices](../THIRD_PARTY_NOTICES.md).

Changing a color in either column shows **Custom** in the picker. Selecting a preset again
replaces all six colors and keeps the interface font. System restores native colors in both
columns. Save applies the choice. Searching Settings or the command palette for a preset name
opens its row. The agent's `accent` setting accepts the same preset names as lowercase IDs and reads
`custom` once a column overrides a color.

Reset to defaults restores the system accent, the native surface and label colors, and the system
interface font in a single action. It also clears a preset saved by an earlier version. The theme
is stored in app preferences. The agent can set `light_accent_color`, `light_background_color`,
`light_text_color` and their `dark_` counterparts to an opaque sRGB `#RRGGBB` or `default`.
A color set to `default` inherits from the selected preset. The interface font setting is `ui_font`.

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

Keep `sidebarWidth` 240, `titleBarHeight` 50, `windowTabBarHeight` 36, `areaHeaderHeight` 36, `toolbarHeight` 46, `paneToolbarHeight` 40,
`contentWidth` 768 and `conversationInset` 32 as named component geometry. They make one conversation
column (`ParityTheme.conversationColumnWidth(in:)`, `View.conversationColumn`): at most 768 wide and
centered, with the 32 pt gutter inside each side, so content is at most 704 pt and keeps 32 pt from a
narrower area's edges. The turns and everything over and under them (the composer and its trays, the
request dock, the error card, banners and notice lines) use that column, so their edges line up at every
width. The turn rail floats in the leading gutter and takes no width from the column; a conversation of
one turn draws none. Text scrolled up under the task area's header fades out over the top 16 pt of the
conversation rather than being cut at the header's edge. Under a floating
side panel the conversation keeps its minimum width beneath the panel while the composer stops at the
panel's edge (`clearOfFloatingPanel`), so the leading edges stay aligned. Resizable surfaces retain
their existing minimums and stored sizes. `ParityAccessibility`'s traversal priorities are behavior,
not visual tokens, and remain unchanged.

## Component contracts

These are consolidation targets; provider differences in meaning remain intact.

| Component | Contract / existing implementation to reuse |
| --- | --- |
| Row | 13 pt label, 12 pt secondary text, 8 pt content gap and horizontal inset, 28 pt minimum for a compact single line; grow for a second line. Keep task title width before optional metadata. Reuse the sidebar row and `IntelligencePickerRow` patterns; retain the sidebar's current 30/42 pt geometry during token-only work. |
| Settings row | `SettingsRow` in `SettingsGroup` (`SettingsCenter.swift`): 13 pt medium title, 12 pt secondary line under it, the control at the trailing edge, 12 pt above and below, 16 pt inside the group's sides, dividers edge to edge within that inset; a group's 13 pt semibold heading 8 pt over it and 24 pt between a page's groups, so a heading reads with its rows; the page's 18 pt heading 16 pt over its content inside a 20 pt margin, and the window's 13 pt semibold title in the top bar (`SettingsMetrics`). The section list has a 12 pt margin, 12 pt semibold headings and 30 pt rows with an 8 pt inset and the row radius. Settings keeps these sizes under View › Zoom. A row says what changes and where it takes effect in its line, not only in a tooltip. No symbol on the row and no tile behind one: the section list carries the symbols, as in both apps. A list of things (devices, harnesses, connectors, sign-ins) may show the thing's own mark or symbol, without a tile. Every settings page and the task's harness settings sheet use the same row and group. |
| Settings search and links | A search field heads the Settings sidebar, as in macOS System Settings, with the keyboard in it when Settings opens. Words find sections, every setting in the settings catalog, parts of pages the catalog does not list (`SettingsSearch.pageItems`) and the commands Keyboard shortcuts changes, by their names and synonyms in English and Korean whatever language the app shows (`SettingsSearch`). Results take the section list's place: the section's symbol, the name in up to two lines, the section under it, a command after the settings. With no words the arrow keys move between sections and Escape closes Settings; with words they move between results and open each, and Escape clears them. While ⌘K has words, the same search lists up to eight settings after the tasks and commands, under a Settings heading with where each is. A result, one of ⌘K's, a link from a panel (the browser panel's menu) or a conversation's changed-setting row opens a `SettingsDestination`: its section, and its row scrolled into view with a 14% accent fill that fades after 1.6 s. A row marks itself with `settingsAnchor`; a row built from a setting has its id. Every entry point opens the one row, never a copy of its control. |
| Request card | `ConversationRequestCard` on `ConversationRequestSurface`: a waiting approval, question, plan or form sits on its panel (`ConversationRequestPanel`), the elevated surface a shade darker (`requestPanelFill`) so it stands apart from the canvas and the composer, with a hairline border and the panel radius, never tinted by its state or kind and with no symbol tile. A header band (`subtleFill`, a hairline under it) holds an accent symbol for what the request waits for (an answer, a plan's review, a form, an approval) and the request's title in 13 pt semibold, or the tool's name when the provider described the call, whose description then heads the body in 13 pt semibold. A question form's band also carries the question's label and, among several, its place between the previous and next question (`ConversationQuestionBand`); every band is as tall as one with the pager. The question's own text is the body's headline, 14 pt semibold. 16 pt inside the band's sides and the body, 12 pt between blocks. Options and a form's choices are rows with a 12 pt inset, 8 pt above and below and 4 pt apart, a 13 pt label and a 12 pt secondary line, no fill at rest, the hover fill under the pointer and the selection fill when chosen; while the form takes input each row ends with the number key that picks it (1–9) in 12 pt secondary. A text field on the panel (a question's answer, what to change in a plan) is plain text on the input surface with a hairline edge and the row radius (`conversationRequestField`), as the composer draws its own, not a bezeled field. A form field's name, 13 pt medium, carries "Required" or "Optional" and its line in 12 pt secondary, with its control and hint 8 pt under them and 16 pt between fields. No control on the panel draws a focus ring (Focus, above). Codex's own questions (`CodexQuestionOptions`) wait on the same panel under a "Questions" band and, once answered, read as an answered question does; the reply that answered them draws no message of its own while that card reads it, and stays the person's message when no card does. What the request would do (a command, a change's diff box, a plan) sits in a well of the elevated surface with a hairline edge and the row radius, its command in primary monospaced text, so it stands off the panel's shade. Answers end the row with "Allow once" in the action fill Send is drawn in (`parityPrimaryActionButton()`, `primaryActionFill`), the others bordered beside it; the keys the composer answers it with show inside the buttons, on the oldest waiting request only. The wider allows between them are one split button, as the Claude app draws "Always allow": the narrowest by a short name (`ConversationAllowScope`), and every one in its menu with its scope on a second line; words Yardlet cannot name keep their own button. In a task's own conversation the waiting requests dock right above the composer (`ConversationRequestDock`), as the Claude app docks them: the oldest whole, up to two after it as edges showing 8 pt behind it, and its band ending with how many more wait ("2 more waiting") in 12 pt secondary, at most 60% of the conversation's height, a taller card opening at its answers and scrolling under the panel's edge, raised off the conversation by the composer's soft shadow; the composer stays free, and the turn keeps its line saying what the front request waits for: "Awaiting approval" for an approval, "Waiting for your answer" for a question, plan or form. A conversation inside another surface keeps them under their turn. An answered request leaves one 13 pt secondary line (symbol, outcome, title), never red. An answered question or form keeps that line at the top of one quiet block (`ConversationAnsweredBlock`: the subtle fill, the surface radius, 16 pt inside its sides and 12 pt above, below and between) with each question in 12 pt secondary and its answer under it in 13 pt medium after an accent check, or "Not answered" after a dash, or the form's sent values. `PersonalAgentRequestCard` uses the same surface. |
| Chip | 13 pt control text, 24 pt minimum control height, 8 pt horizontal inset, 6 pt radius. Use `ParityComposerControl`; a chip is a control/reference, not decoration on every row. |
| Popover | 12 pt surface radius, 8 pt outer content inset, shared rows. Width follows content within its existing bounds. Preserve dismissal, focus return and keyboard traversal. Render its content without opening it during QA. |
| Floating surface | `floatingSurface()` (`TaskWorkspaceLayout.swift`): the side panel floating over the conversation's edge or as a sheet in a narrow area, and the session rail raised where the area has no room for it. A card 8 pt in from the area's top, trailing and bottom edges, with the surface radius, the elevated fill, a hairline edge (`strongSeparator` in dark) and a soft two-layer shadow drawn from a plain shape behind it. Below the area's header, the panel's own header leaves out the side panel toggle the area's header already shows right above it. Below the conversation's share and the panel's minimum (`SidePanelWidth.conversationInView`) the panel is a sheet: 48 pt of the conversation shows behind it, dimmed and not worked from, and a click there or Escape closes the panel. Only the panel's expand button puts it in the conversation's place, edge to edge. |
| Menu | Native menu when native behavior is needed; custom composer menus reuse `ComposerMenuList`/`ComposerMenuRow` and `IntelligencePickerRow` with `ComposerOptionChoiceLabel`. 13 pt labels, 12 pt descriptions, 8 pt row inset. Do not recreate menu semantics in a stack of unrelated buttons. |
| Composer | `PromptComposer`, 14 pt editor, 13 pt controls, 12 pt corner, 28 pt send target, 24 pt auxiliary controls. Controls wrap before the send action clips; when the context ring, the model control, the queue and send are all that is left on the last row and still do not fit, the model control drops its effort and then shortens its name from the end, as the Codex app drops the effort and both apps shorten the name, so send stays in view. A text field that wraps (`wrapsBetweenWords()`) and the conversation's prose break lines between words, as `Text` does: Korean at its spaces. Shared 32 pt outer conversation gutter; preserve provider-specific options. |
| Panel header | `paneToolbarHeight` 40, 13 pt label, shared toolbar buttons and 8 pt content gaps. One header per panel; focus belongs to the pane whose control was used. |
| Title bar row and tabs | The title bar, a split pane's header and a side panel's tab strip in the header's row stand on the canvas, with no band of their own. Their icon buttons and icon menus draw as the task's panel buttons do (`ParityHeaderButton`, `ParityHeaderMenu`, `ParityHeaderSymbol`): a 12 pt secondary symbol in a 28 pt square with a 7 pt corner, the hover fill under the pointer; a panel header sets `parityHeaderControls` so its `ParityIconButton`s draw the same. With one tab the window's top row is the 50 pt title bar holding the shown item's header. With two tabs or more the window's tab bar (`WindowTabBar`) takes the window's top: a 36 pt row (`windowTabBarHeight`) in the sidebar's tone with a hairline along its bottom, the sidebar's top part and the window's buttons centred on the same row, and with the sidebar hidden the title bar's sidebar part leading the tabs. Its tabs are 30 pt high on the bar's bottom edge with 13 pt titles; the shown tab stands on the canvas with 8 pt top corners and a hairline edge that curves out into the bar's bottom line (`WindowTabShape`), so it runs into the header below without a line, and its title is in medium weight; the others take the hover fill under the pointer and a hairline (`strongSeparator`) parts two of them side by side. Under the bar the shown task's header, or the panes' headers of a split view, and a side panel's tabs stand a step down in one 36 pt row (`areaHeaderHeight`), which no longer moves the window. A split view's tab holds its name, which opens its actions, as a split view has no header of its own. Side panel tabs are 28 pt high: the shown one stands on the elevated surface with a hairline edge (`ParityTabBackground`). Every tab and pane closes by the same button (`ParityTabCloseButton`): a 9 pt cross, an 18 pt hover circle and a 22 pt square to click, named with the tab's title. A side panel tab shows its title while the whole of it or a few letters fit, else its icon alone, and never takes more than the room the strip gives it. |
| Split view focus | Panes are parted by a 1 pt hairline (`separator`) in the 6 pt resize handle, with no band or outline. The focused pane reads as the window's front: its title clear and its composer raised (`ParitySurfaceEmphasis.raised`: the focused shadow and `strongSeparator` edge even before the composer has the keyboard). The other panes lie under a wash (`paneWash`: black 1.8% in light, white 1.5% in dark, over whatever canvas the color preset gives), their task's title faded at an opacity that keeps 4.5:1 on that washed canvas (`ThemeContrast.fadedTextOpacity`), and their composers flat, without a shadow, on the canvas with the subtle fill (`ParitySurfaceEmphasis.flat`), so where typing goes shows from the composers alone. A press anywhere in a pane, on its composer's, conversation's or terminal's text and a browser page included, or its composer taking the keyboard, gives the pane the focus (`PanePressMonitor`). The harness and the rest of a header keep their colours. A narrow pane's header shows the harness by its mark alone, leaving the title its room. Each pane's header has Maximize pane beside Close pane: the focused pane shows alone over its split view for now (`SplitStore.maximizedPane`, not saved), the split view's tree unchanged, until Restore split view, a move of the focus to another pane, another tab or the split view's end; coming back does not maximize it again. The Split View menu, ⌘K and ⌃⌘Return do the same. |
| Empty state | 18 pt title, 14 pt explanation, one primary next action, 16 pt vertical gap and 24/32 pt outer inset. Keep the real task composer available when useful. No large decorative badge or enclosure. |
| Terminal/review | The code font (`yardletCodeFont`) at the interface scale, shared header/selection colors. Preserve ANSI/diff meaning and horizontal scrolling; never clip code to achieve a tidy silhouette. |

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
   `ParityDesignSystem.swift` and a color preset's values in `MacColorTheme.swift`; keep provider
   protocol data out of visual tokens.
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
| App and window menus | ⌘, opens Settings, ⌘K searches tasks and commands, and ⌘N opens New task. The Task, View, Edit, File, Window and Split View menus show the available keys for the current window. View › Zoom In (⌘+ or ⌘=), Zoom Out (⌘−) and Actual Size (⌘0) change the size of the text and code in every task window, another Mac's included, as in the Claude and Codex apps: the sidebar, home, conversation, composer, session rail, panels, mailbox, calendar and schedules, and a sheet that sizes its text from the interface scale, such as the schedule editor. Settings' rows, menus and native controls keep their sizes. Yardlet keeps the zoom across launches, and Actual Size returns to Settings' interface size. A focused browser page or an image preview takes these keys for its own zoom first. |
| Task window | ⌘1–4 select task surfaces. ⌃1–9 open pinned rows in sidebar order. ⌃Tab and ⌃⇧Tab move between window tabs, or between tasks when only one tab is open. ⌘⌥ and an arrow focus an adjacent pane, and ⌃⌘Return shows the focused pane alone or the split view again. |
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
