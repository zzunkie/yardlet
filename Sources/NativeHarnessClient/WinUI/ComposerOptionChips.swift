import Foundation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI

/// The session controls in a composer's bottom row, as the Mac's (`ComposerSessionControls`):
///
///     [+][mode | Plan][permissions] … [context ring][model][queue/steer][Send | Stop]
///
/// Which controls show, their choices, names and values come from `ComposerSessionOptions`, the same reading for a
/// task and for New task; a choice goes back through `choose` with the path its provider applies it by. A control that
/// cannot choose yet reads its choices first (`prepare`), as opening the Mac's does, and opens once they are read. A
/// choice the provider asks about first, such as skipping permission prompts, is asked about in the Mac's words. Each
/// menu is Windows' own menu.
@MainActor
final class ComposerOptionChips {
    /// Applies a choice by the path its control names.
    var choose: (_ id: String, _ value: String, _ apply: ComposerApplyPath) -> Void = { _, _, _ in }
    /// Reads the choices a control does not have yet: a detached task's settings, or a model list. Nothing starts.
    var prepare: () async -> Void = {}
    /// Turns Codex's Plan mode off; without it the Plan indicator is not drawn.
    var turnOffPlanMode: (() -> Void)?
    /// Called when the controls must be drawn again: while their choices are read, and once they are.
    var redraw: () -> Void = {}

    private var isPreparing = false
    /// The control to open once its choices are read.
    private var opensAfterPreparing: String?
    /// Opens the model menu last drawn.
    private var openModel: (() -> Void)?

    /// The current model label, for the task footer to fit between the fixed-size actions.
    private(set) var modelLabel: ComposerParts.ControlLabel?

    /// The controls after + : the mode or Plan indicator, the permissions, and while choices are read, a spinner.
    func leading(_ options: ComposerSessionOptions) -> [UIElement] {
        var controls: [UIElement] = []
        switch options.mode {
        case .planIndicator?:
            if let turnOffPlanMode {
                let indicator = ComposerParts.control(title: L10n.string("Plan mode indicator"),
                                                      glyph: ComposerParts.Glyph.plan)
                try? ToolTipService.setToolTip(indicator, L10n.string("Turn plan mode off"))
                indicator.click.addHandler { _, _ in turnOffPlanMode() }
                controls.append(indicator)
            }
        case let .selector(selector, canChoose, apply)?:
            let title = ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
            let control = ComposerParts.control(title: title, chevron: true, name: selector.name)
            try? ToolTipService.setToolTip(control, selector.name)
            attach(key: "mode", to: control, canChoose: canChoose) { [weak self] in
                self?.menu(selector, apply: apply, confirmations: [:], anchor: control)
            }
            controls.append(control)
        case nil:
            break
        }
        if let permission = options.permission {
            let tint = permission.isElevated ? ComposerParts.orange : WindowsTheme.secondaryText
            let control = ComposerParts.control(title: permission.title,
                                                glyph: ComposerParts.Glyph.shield,
                                                chevron: true, tint: tint, name: L10n.string("Permissions"))
            try? ToolTipService.setToolTip(control, permission.help ?? permission.accessibilityHint)
            let canChoose = permission.canChoose && !permission.preparesBeforeOpening
            attach(key: "permission", to: control, canChoose: canChoose || permission.explanation != nil) { [weak self] in
                guard let self else { return nil }
                if let selector = permission.selector, permission.showsChoices, permission.canChoose {
                    return self.menu(selector, apply: permission.apply, confirmations: permission.confirmations,
                                     anchor: control)
                }
                // Nothing to choose here: the menu says the policy and how it changes, as the Mac's does.
                let menu = MenuFlyout()
                let current = MenuFlyoutItem()
                current.text = permission.title
                current.isEnabled = false
                menu.items.append(current)
                if let explanation = permission.explanation {
                    let line = MenuFlyoutItem()
                    line.text = explanation.text
                    line.isEnabled = false
                    menu.items.append(line)
                }
                return menu
            }
            controls.append(control)
        }
        if options.isLoadingSettings || isPreparing {
            let ring = ProgressRing()
            ring.isActive = true
            ring.minWidth = 0
            ring.minHeight = 0
            ring.width = 14
            ring.height = 14
            ring.margin = Thickness(left: 7, top: 0, right: 7, bottom: 0)
            ring.verticalAlignment = .center
            try? AutomationProperties.setName(ring, L10n.string("Loading"))
            controls.append(ring)
        }
        if let error = options.settingsError {
            let mark = ComposerParts.glyph(ComposerParts.Glyph.warning, size: 12, color: ComposerParts.orange)
            try? ToolTipService.setToolTip(mark, error)
            try? AutomationProperties.setName(mark, error)
            controls.append(mark)
        }
        return controls
    }

    /// The controls before the queue and Send: the model menu, beside Send as both reference apps place it.
    func trailing(_ options: ComposerSessionOptions) -> [UIElement] {
        openModel = nil
        modelLabel = nil
        guard let slot = options.model else { return [] }
        let menu = slot.menu
        let control = ComposerParts.control(title: menu.triggerTitle, detail: menu.triggerDetail, chevron: true,
                                            name: L10n.string("Model")) { self.modelLabel = $0 }
        try? ToolTipService.setToolTip(control, L10n.string("Select model"))
        let canChoose = menu.canChoose && !menu.isEmpty
        attach(key: "model", to: control, canChoose: canChoose) { [weak self] in
            self?.modelMenu(menu, apply: slot.apply, anchor: control)
        }
        openModel = { [weak self] in
            guard control.isEnabled else { return }
            if let flyout = control.flyout {
                try? flyout.showAt(control)
            } else if !canChoose {
                self?.prepareThenOpen("model")
            }
        }
        return [control]
    }

    /// Opens the model menu as a click on it does, for the Mac's Open Model Menu key
    /// (`TaskCommandShortcut.openModelMenu`); nothing when the composer has no model menu.
    func openModelMenu() {
        openModel?()
    }

    // MARK: Menus

    /// Gives `control` its menu, made when it opens, or where the choices are not read yet, reads them first and then
    /// opens it.
    private func attach(key: String, to control: Button, canChoose: Bool, menu: @escaping () -> MenuFlyout?) {
        guard canChoose else {
            control.click.addHandler { [weak self] _, _ in self?.prepareThenOpen(key) }
            return
        }
        guard let made = menu() else { return }
        made.placement = .top
        control.flyout = made
        if opensAfterPreparing == key {
            opensAfterPreparing = nil
            // The control as the event passes it: the Swift wrapper here is gone once its row holds it.
            control.loaded.addHandler { sender, _ in
                guard let control = sender as? Button else { return }
                try? control.flyout?.showAt(control)
            }
        }
    }

    private func prepareThenOpen(_ key: String) {
        guard !isPreparing else { return }
        isPreparing = true
        redraw()
        Task {
            await prepare()
            isPreparing = false
            opensAfterPreparing = key
            redraw()
        }
    }

    /// A selector's choices, the current one checked; a choice's description is its tooltip.
    private func menu(_ selector: ProviderCapabilitySelector, apply: ComposerApplyPath,
                      confirmations: [String: ComposerPermissionSlot.Confirmation], anchor: Button) -> MenuFlyout {
        let menu = MenuFlyout()
        append(selector, to: menu, apply: apply, confirmations: confirmations, anchor: anchor)
        return menu
    }

    private func append(_ selector: ProviderCapabilitySelector, to menu: MenuFlyout, apply: ComposerApplyPath,
                        confirmations: [String: ComposerPermissionSlot.Confirmation], anchor: Button) {
        for choice in selector.choices {
            let item = RadioMenuFlyoutItem()
            item.text = choice.name
            item.groupName = selector.id
            item.isChecked = choice.value == selector.currentValue
            if let description = choice.description, !description.isEmpty {
                try? ToolTipService.setToolTip(item, description)
            }
            let value = choice.value
            item.click.addHandler { [weak self, weak anchor] _, _ in
                guard let self, value != selector.currentValue else { return }
                self.pick(value, id: selector.id, apply: apply, confirmation: confirmations[value], anchor: anchor)
            }
            menu.items.append(item)
        }
    }

    /// The model menu (`HarnessIntelligencePicker`): the models, then the effort under its name, then the speed, which
    /// turns on and off.
    private func modelMenu(_ menu: ComposerModelMenu, apply: ComposerApplyPath, anchor: Button) -> MenuFlyout {
        let flyout = MenuFlyout()
        if let model = menu.model { append(model, to: flyout, apply: apply, confirmations: [:], anchor: anchor) }
        if let effort = menu.effort {
            if menu.model != nil { flyout.items.append(MenuFlyoutSeparator()) }
            let heading = MenuFlyoutItem()
            heading.text = effort.name
            heading.isEnabled = false
            flyout.items.append(heading)
            append(effort, to: flyout, apply: apply, confirmations: [:], anchor: anchor)
        }
        if let speed = menu.speed {
            if menu.model != nil || menu.effort != nil { flyout.items.append(MenuFlyoutSeparator()) }
            if speed.isBinarySpeedSwitch {
                let toggle = ToggleMenuFlyoutItem()
                toggle.text = speed.name
                toggle.isChecked = speed.currentValue == "on"
                if let description = speed.description { try? ToolTipService.setToolTip(toggle, description) }
                toggle.click.addHandler { [weak self, weak anchor] _, _ in
                    self?.pick(speed.currentValue == "on" ? "off" : "on", id: speed.id, apply: apply, confirmation: nil,
                               anchor: anchor)
                }
                flyout.items.append(toggle)
            } else {
                let heading = MenuFlyoutItem()
                heading.text = speed.name
                heading.isEnabled = false
                flyout.items.append(heading)
                append(speed, to: flyout, apply: apply, confirmations: [:], anchor: anchor)
            }
        }
        return flyout
    }

    private func pick(_ value: String, id: String, apply: ComposerApplyPath,
                      confirmation: ComposerPermissionSlot.Confirmation?, anchor: Button?) {
        guard let confirmation else {
            choose(id, value, apply)
            return
        }
        let dialog = ContentDialog()
        dialog.title = confirmation.title
        dialog.content = confirmation.message
        dialog.primaryButtonText = confirmation.confirm
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.defaultButton = .close
        dialog.xamlRoot = anchor?.xamlRoot
        Task {
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else {
                // The menu showed the choice as made; drawn again, it shows what still holds.
                redraw()
                return
            }
            choose(id, value, apply)
        }
    }
}
