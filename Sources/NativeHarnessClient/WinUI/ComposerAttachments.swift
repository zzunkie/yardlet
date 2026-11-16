import Foundation
import UWP
import WinUI

/// What a message carries besides its words, as the Mac's composer adds and shows it: "+" at the start of the bottom
/// row with "Add files or photos" ("Add files" where the harness takes no images) and "Add folder"
/// (`ComposerPlusMenu`), each through Windows' own dialog; files or a picture pasted into the text
/// (`WindowsClipboard`); and above the text a chip for each, an image as its thumbnail, with its remove button
/// (`ComposerInputChip`). What joins goes into the draft exactly as on the Mac (`ComposerAttachmentIntake`,
/// `ComposerDraftEditing.attachPastedImage`). The Mac's slash commands and connectors in "+" stay on the Mac.
@MainActor
final class ComposerAttachments {
    /// "+", which the composer puts first in its bottom row.
    let plusButton: Button
    /// The chips, which the composer puts in its card's row for them; collapsed while nothing is attached.
    let chipRow = ScrollViewer()
    /// The window the dialogs belong to, as an `HWND`'s value.
    var windowHandle: () -> UInt64 = { 0 }
    /// The draft "+" and a paste add to, and what its harness takes; nil while there is none.
    var target: () -> (draft: any ComposerDraftEditing, policy: HarnessComposerInputPolicy)? = { nil }

    private let chips = StackPanel()
    private let log: QAEventLog
    private var shown: [CodexUserInput]?
    private var menuCarriesImages: Bool?

    /// The Mac's image chip is this many points on a side (`ComposerImageChip.side`).
    private static let thumbnailSide: Double = 48

    init(log: QAEventLog) {
        self.log = log
        plusButton = ComposerParts.iconButton(ComposerParts.Glyph.plus, name: L10n.string("Add files and more"),
                                              foreground: WindowsTheme.secondaryText, fill: nil, radius: 6)
        try? ToolTipService.setToolTip(plusButton, L10n.string("Add files and more"))
        plusButton.visibility = .collapsed

        chips.orientation = .horizontal
        chips.spacing = 6
        chipRow.horizontalScrollBarVisibility = .hidden
        chipRow.horizontalScrollMode = .enabled
        chipRow.verticalScrollBarVisibility = .disabled
        chipRow.verticalScrollMode = .disabled
        chipRow.content = chips
        chipRow.visibility = .collapsed
    }

    /// "+" shows where the harness takes files, as the Mac's does (`showsMentionControl`); its first item names photos
    /// where the harness takes images too.
    func show(policy: HarnessComposerInputPolicy?) {
        plusButton.visibility = policy?.showsMentionControl == true ? .visible : .collapsed
        guard let policy, policy.carriesImages != menuCarriesImages else { return }
        menuCarriesImages = policy.carriesImages
        let menu = MenuFlyout()
        menu.placement = .topEdgeAlignedLeft
        menu.items.append(ComposerParts.menuItem(
            policy.carriesImages ? L10n.string("Add files or photos") : L10n.string("Add files"),
            glyph: ComposerParts.Glyph.attach) { [weak self] in self?.choose(folders: false) })
        menu.items.append(ComposerParts.menuItem(L10n.string("Add folder"), glyph: ComposerParts.Glyph.folder) {
            [weak self] in self?.choose(folders: true)
        })
        plusButton.flyout = menu
    }

    /// The chips for what the draft carries, made again only when that changed.
    func redraw(_ attachments: [CodexUserInput]) {
        guard attachments != shown else { return }
        shown = attachments
        chips.children.clear()
        for (index, input) in attachments.enumerated() { chips.children.append(chip(input, at: index)) }
        chipRow.visibility = attachments.isEmpty ? .collapsed : .visible
    }

    /// A paste into the text: files or a picture on the clipboard join the draft instead, as on the Mac, while copied
    /// text is left to the field. A picture the harness cannot take is refused with why.
    func paste(_ args: TextControlPasteEventArgs?) {
        guard let target = target(), target.policy.showsMentionControl,
              let clipboard = WindowsClipboard.attachment(window: windowHandle()) else { return }
        args?.handled = true
        if case let .files(urls) = clipboard {
            target.draft.attachFiles(urls, policy: target.policy)
            log.write("pasted files: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        } else if let png = clipboard.png {
            let attaching = target.draft.attachPastedImage(policy: target.policy, png: png)
            Task { [log] in
                await attaching?.value
                log.write("pasted image: \(target.draft.attachments.count) attached")
            }
        }
    }

    // MARK: Adding

    /// "Add files or photos" or "Add folder": Windows' dialog, opened once the menu has closed, and what it chose
    /// joins the draft as the Mac's pickers add it.
    private func choose(folders: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let title = folders ? L10n.string("Add folder") : L10n.string("Add files")
            guard let urls = WindowsFolderPicker.chooseItems(window: self.windowHandle(), title: title,
                                                             folders: folders),
                  let target = self.target() else { return }
            target.draft.add(chosen: folders ? ComposerAttachmentIntake.chosenFolders(urls)
                : ComposerAttachmentIntake.chosenInputs(urls, policy: target.policy))
            self.log.write("added \(folders ? "folders" : "files"): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        }
    }

    private func remove(at index: Int) {
        guard let target = target() else { return }
        target.draft.removeAttachment(at: index)
    }

    // MARK: Chips

    /// An image the app can read as a thumbnail with its remove button in the corner, anything else as a chip of its
    /// symbol and name (`ComposerChipContent`).
    private func chip(_ input: CodexUserInput, at index: Int) -> FrameworkElement {
        let name = input.chipLabel
        if case let .localImage(url, _) = input, url.isFileURL {
            return thumbnail(url, name: name, at: index)
        }
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.children.append(ComposerParts.glyph(Self.glyph(for: input), size: 10))
        let words = ComposerParts.label(name, size: 11, weight: 400)
        words.maxWidth = 220
        row.children.append(words)
        row.children.append(removeButton(at: index, size: 16))
        let chip = Border()
        chip.height = 24
        chip.padding = Thickness(left: 7, top: 0, right: 3, bottom: 0)
        chip.cornerRadius = ComposerParts.corners(12)
        chip.background = WindowsTheme.subtleFill.brush
        chip.child = row
        try? AutomationProperties.setName(chip, "\(L10n.string("Attached input")): \(name)")
        try? ToolTipService.setToolTip(chip, name)
        return chip
    }

    private func thumbnail(_ url: URL, name: String, at index: Int) -> FrameworkElement {
        let side = Self.thumbnailSide
        let image = Image()
        image.source = PackagedImage.thumbnail(of: url, height: Int32(side * 2))
        image.stretch = .uniformToFill
        let frame = Border()
        frame.width = side
        frame.height = side
        frame.cornerRadius = ComposerParts.corners(8)
        frame.background = WindowsTheme.subtleFill.brush
        frame.borderBrush = WindowsTheme.separator.brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.child = image
        let tile = Grid()
        tile.width = side
        tile.height = side
        tile.children.append(frame)
        let remove = removeButton(at: index, size: 18)
        remove.horizontalAlignment = .right
        remove.verticalAlignment = .top
        remove.margin = Thickness(left: 0, top: 2, right: 2, bottom: 0)
        remove.background = WindowsTheme.input.brush
        _ = remove.resources?.insert("ButtonBackground", WindowsTheme.input.brush)
        tile.children.append(remove)
        try? AutomationProperties.setName(tile, "\(L10n.string("Attached input")): \(name)")
        try? ToolTipService.setToolTip(frame, name)
        return tile
    }

    private func removeButton(at index: Int, size: Double) -> Button {
        let button = ComposerParts.iconButton(ComposerParts.Glyph.remove, name: L10n.string("Remove attachment"),
                                              size: 8, foreground: WindowsTheme.secondaryText, fill: nil,
                                              radius: size / 2)
        button.width = size
        button.height = size
        button.click.addHandler { [weak self] _, _ in self?.remove(at: index) }
        return button
    }

    /// The Mac chip's symbol (`ComposerChipContent.symbol`) in Windows' icon font.
    private static func glyph(for input: CodexUserInput) -> String {
        switch input {
        case .text: "\u{E8E4}"
        case .image, .localImage: ComposerParts.Glyph.image
        case .audio, .localAudio: "\u{E8D6}"
        case .skill: "\u{E945}"
        case let .mention(_, path): path.hasDirectoryPath ? ComposerParts.Glyph.folder : ComposerParts.Glyph.file
        case .unknown: "\u{E897}"
        }
    }
}
