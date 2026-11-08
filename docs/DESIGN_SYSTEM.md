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
scaled twice. SF system text provides Korean fallback; code uses the system monospaced face.

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

Keep `ParityTheme`'s adaptive palette. The RGB figures below are its nominal calibrated components,
rounded to 8-bit notation for reading, not measured display pixels. They are neutral, not beige.

| Role / existing name | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas / `canvas` | #FEFEFE | #131313 | Conversation and home |
| Sidebar / `sidebar` | #F6F6F6 | #1B1B1B | Project navigation |
| Elevated / `elevated` | #FFFFFF | #222222 | Popover/panel surface |
| Input / `input` | #FFFFFF | #282828 | Composer and editable field |
| Accent / `accent`, AppKit `accentColor` | #143B6B | #8CB8FA | Links and selected emphasis; current palette, identity choice still open |
| Signal / `signal` | #6B8505 | #D1ED2B | Existing signal only; never a default text or background color |
| Primary action / `primaryActionFill` | #333333 | #E0E0E0 | Send/action fill |
| On action / `primaryActionForeground` | #FFFFFF | #1F1F1F | Action glyph |
| Text / proposed `text.primary`, `text.secondary` | Native primary/secondary label | Native primary/secondary label | Alias current `.primary`/`.secondary`; preserve accessibility appearance |
| Border / `separator`, `strongSeparator` | Primary × 10% / 12% | Primary × 10% / 12% | Noninteractive dividers; not a focus indicator |
| Fill / `subtleFill`, `hoverFill`, `selectedFill` | Primary × 3.5% / 6.5% / 9.5% | Primary × 3.5% / 6.5% / 9.5% | Rest, hover, selection |
| Status / proposed `status.success`, `warning`, `danger` | Native system green/orange/red | Native system green/orange/red | Alias scattered status colors; always pair with text or an icon |
| Focus / proposed `focus` | Native focus indicator | Native focus indicator | Keep native focus rings; never substitute a faint border |

Secondary is not disabled. Essential instructions use primary or secondary text, never tertiary text
or a status color alone. Check normal text against 4.5:1 and essential control indicators against 3:1
on their actual composite background; the table alone does not establish contrast compliance.

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
| Chip | 13 pt control text, 24 pt minimum control height, 8 pt horizontal inset, 6 pt radius. Use `ParityComposerControl`; a chip is a control/reference, not decoration on every row. |
| Popover | 12 pt surface radius, 8 pt outer content inset, shared rows. Width follows content within its existing bounds. Preserve dismissal, focus return and keyboard traversal. Render its content without opening it during QA. |
| Menu | Native menu when native behavior is needed; custom composer menus reuse `ComposerMenuList`/`ComposerMenuRow` and `IntelligencePickerRow` with `ComposerOptionChoiceLabel`. 13 pt labels, 12 pt descriptions, 8 pt row inset. Do not recreate menu semantics in a stack of unrelated buttons. |
| Composer | `PromptComposer`, 14 pt editor, 13 pt controls, 12 pt corner, 28 pt send target, 24 pt auxiliary controls. Controls wrap before the send action clips. Shared 32 pt outer conversation gutter; preserve provider-specific options. |
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
