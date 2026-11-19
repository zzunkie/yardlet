# Media in the conversation

What an answer shows in place besides its words: the pictures its Markdown names, the videos and sounds it names,
and the visualizations the Codex app's `visualize` skill writes. Everything here is drawn on the Mac for the person
only; nothing of it reaches a harness or a model, and none of it has a setting.

## Pictures

An image in an answer's Markdown (the `![alt]` syntax, or one image alone inside a link) becomes a block of its own where
it stands, in a paragraph, a list or a quote; the words around it stay their paragraphs (`TranscriptMarkdownPicture`,
the `.pictures` block of `TranscriptMarkdownDocument`). Images separated only by spaces share one block.

- **Sources.** A path relative to the task's folder, an absolute path, `~/`, `file:` and `data:image/`, resolved as a
  link in the message is. A file outside the task's folder is drawn too: only the person sees it. A web address is
  never fetched: it is a chip with the alt text and the host that opens the address as a link in the conversation
  does. A file that is not an image, larger than 64 MB or not there is a chip with its name.
- **Size.** One image is as wide as the message at most, never larger than its own size (its DPI counted, so a
  Retina screenshot is half its pixels) and at most 480 points tall. Several share rows: each row's images take one
  height that fills the width together, at most 240 points, and a row wraps where they would be under 140 points.
- **Actions.** A click opens the message's images in the image preview over the window. The context menu offers
  View the image, Copy Image, Show in Finder and, for a linked image, Open Link.
- **Cost.** The size comes from the file's header (a small cache), so the row has its height before the image is
  read. The bitmap is decoded off the main thread at up to 1,600 pixels on its long side only while it is on
  screen, and let go when it leaves; decoded images share the 48 MB image cache. A long conversation holds only the
  pictures in view.
- The Windows app shows the alt text.

## Videos and sounds

The same Markdown naming a video or a sound file (by its extension's type, such as `mp4`, `mov`, `m4a` or `mp3`) plays
it in place (`TranscriptPictureMovie`, `TranscriptPictureSound`).

- A video shows its first frame at its own size, with its length and a play button, read off the main thread; a
  sound is a row with its name and length. No player exists until the person presses play; nothing plays by itself.
- One plays at a time across the app (`TranscriptMediaPlayback`): starting another pauses it. The controls are the
  Files panel's (`AVPlayerView`), with full screen and picture in picture.
- Any other file is a chip that opens it in the Files panel.

## Codex visualizations

A Codex model that follows the `visualize` skill writes an HTML fragment to a file and names it in its answer, on a
line of its own, as `visualize{"path": …, "title": …, "mode": "wide"}` between the private-use marks the skill
teaches; the Codex app reads that into `::codex-inline-vis{path=…}`, and Yardlet reads both
(`CodexVisualization`). "Copy response" leaves the line out, as the app does.

- **Where Codex writes them** (`CodexVisualizationFolders`). As the Codex app does, a turn that may write (Ask for
  approval, Approve for me, Full access) gets its thread's folder, `<Codex home>/visualizations/YYYY/MM/DD/<thread>`,
  after the task's folder in `turn/start`'s `runtimeWorkspaceRoots`, made as the turn starts; the skill tells the
  model to write there. The date is the UTC day of the time in the thread's UUIDv7 ID, the Codex home the one the
  task's account runs with. A Read-only turn gets none, as in the app, and neither does Custom, whose sandbox is
  whatever `config.toml` says. Unlike the app, which keeps every turn's folder, a folder the turn made and left empty
  goes at its end. Yardlet lists the folders it made in `~/.yardlet/harnesses/codex/visualization-folders.txt`, and
  deleting the thread (`thread/delete`) takes away only those; archiving a thread or removing it from Yardlet's list
  leaves its folder, and a folder the Codex app or another client made is never removed.
- **Which files.** An `.html` file in the task's folder, or under a thread's folder in a Codex home,
  `<home>/visualizations/YYYY/MM/DD/<thread>/` and anything below it, where the home holds `config.toml` or
  `sessions` (`CodexVisualizationPage.allowedFile`). A link, a folder or a file over 5 MB is not read. It is read off
  the main thread.
- **The page.** The fragment is wrapped as the skill's own `scripts/render.py` wraps it: the skill's stylesheet, its
  widgets around the fragment and its host bridge, read from the newest `visualize` the Codex CLI installed in
  `~/.codex` or in a Codex home Yardlet keeps for another account
  (`plugins/cache/<marketplace>/visualize/<version>/skills/visualize/assets`). Yardlet does not ship the kit.
  Without it the fragment is drawn in the system's plain styles with a bridge of Yardlet's own, so its words and
  charts show but the kit's cards, tabs and icons do not. A whole document keeps its own head. A page `render.py`
  exported for a browser holds the visualization in a frame of its own, which the policy below does not open, so it
  shows empty; answers name the fragment, not the export.
- **Hosting.** As an MCP App view is hosted ([CONNECTORS](CONNECTORS.md), "19. MCP Apps"): its own web view and
  non-persistent data store, two documents from Yardlet's scheme at two random hosts, the page in a sandboxed frame,
  the bridge in an isolated content world, no navigation, window, download, camera or microphone, and the same pool
  of four live views. The page's policy is the Codex app's: scripts, styles, images, fonts and media inline or from
  cdnjs, jsDelivr, unpkg, esm.sh, Google Fonts and Bunny Fonts (and the skill's components on
  `persistent.oaistatic.com`); `connect-src` only `blob:` and `data:`, `frame-src 'none'`. The outer page and its frame
  declare `color-scheme: light dark`, so the page's `prefers-color-scheme` is the app's appearance, which the kit's
  theme follows as it changes, without loading the page again.
- **The bridge** (`CodexVisualizationBridge`). Each time the frame loads, the outer page hands it a new
  `MessageChannel` port with `codex-visualization-initialize`, as the Codex app does. The page may say its height;
  open an `http` or `https` link the person clicked, as a link in the conversation opens, one a second at most; ask a
  follow-up, which goes into the composer after what is typed there and is not sent; and save its widget state (a
  JSON object up to 16 KiB), which is kept in memory for the app's run, by the row, and given back when the page is
  drawn again. The state never reaches the model.
- **Size.** A placeholder 240 points tall keeps the place until the page reports its height. The row is as tall as
  the page, up to 1,200 points, past which the page scrolls inside; scrolling over a page that fits scrolls the
  conversation. The height is kept while the view is parked, so the conversation does not jump.
- **Expanding.** On hover, "Expand visualization" in the top right corner (which the skill keeps clear for the host)
  moves the same web view into a sheet as wide as the skill's wide layout (1,064 points ideally), so what the person
  chose in the page stays; "Done" or Esc puts it back in its row. The pool does not park a view while it is expanded.
  The message column is already about as wide as the skill's regular layout, so `"mode": "wide"` draws the same.
- **When it cannot be drawn.** A file that is not allowed or not readable, or a page that does not report its height
  within ten seconds, leaves a card with the title, "Show view again" and "Open file". The Windows app leaves the
  visualization out.
- **Leaving nothing behind.** There is no setting. The page, its state and its height are in memory only; the
  folders Yardlet made keep what the model wrote until the thread is deleted.
