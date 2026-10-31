import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI
import WinUIApplication

/// Runs each check once XAML has started, writes what it found to the file SWIFT_WINRT_PROBE_OUTPUT
/// names, and exits.
@main
final class Probe: XamlApplication {
    private var lines: [String] = []

    required init() {
        super.init()
    }

    override func launched() {
        checkStringGetters()
        checkObjectIdentity()
        checkBoxedValues()
        if let path = ProcessInfo.processInfo.environment["SWIFT_WINRT_PROBE_OUTPUT"] {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        try? Application.current.exit()
    }

    private func report(_ line: String) {
        lines.append(line)
        print(line)
    }

    // MARK: Strings a getter receives

    /// Reads string properties many times and says how much the process heap, where HSTRINGs live,
    /// grew per read. A getter that kept every HSTRING it received grows by about the string's size each
    /// time; the control makes HSTRINGs and keeps them, to show the measurement sees that.
    private func checkStringGetters() {
        let uri = Uri("https://example.com/a/path/long/enough/to/notice?query=value")
        report(growth("Uri.absoluteUri read", count: 1_000_000) { _ = uri.absoluteUri })
        let block = TextBlock()
        block.text = "A line of text in a TextBlock, long enough to notice"
        report(growth("TextBlock.text read", count: 200_000) { _ = block.text })
        // The control: an HSTRING made and never deleted, detached from the HString that would delete it.
        report(growth("control: an HSTRING made and never deleted", count: 200_000) {
            _ = try? HString("A line of text in a TextBlock, long enough to notice").detach()
        })
    }

    private func growth(_ name: String, count: Int, _ body: () -> Void) -> String {
        for _ in 0..<1_000 { body() }
        let before = heapBytes()
        for _ in 0..<count { body() }
        let after = heapBytes()
        let perCall = Double(after - before) / Double(count)
        return "\(name): \(count) times, process heap \(before) -> \(after) bytes, \(String(format: "%.1f", perCall)) bytes a call"
    }

    private func heapBytes() -> Int {
        var summary = HEAP_SUMMARY()
        summary.cb = DWORD(MemoryLayout<HEAP_SUMMARY>.size)
        _ = HeapSummary(GetProcessHeap(), 0, &summary)
        return Int(summary.cbAllocated)
    }

    // MARK: A projected object passed as an Object

    private func checkObjectIdentity() {
        let navigation = NavigationView()
        let first = NavigationViewItem()
        let second = NavigationViewItem()
        navigation.menuItems.append(first)
        navigation.menuItems.append(second)
        var index: UInt32 = 0
        let foundAppended = navigation.menuItems.indexOf(second, &index)
        report("IVector<Object>.indexOf, the object appended: \(foundAppended ? "found at \(index)" : "not found")")
        let stored = navigation.menuItems.getAt(1)
        report("IVector<Object>.getAt returns the same Swift object: \((stored as AnyObject?) === second)")
        let foundStored = navigation.menuItems.indexOf(stored, &index)
        report("IVector<Object>.indexOf, what getAt returned: \(foundStored ? "found at \(index)" : "not found")")

        let panel = StackPanel()
        let block = TextBlock()
        panel.children.append(TextBlock())
        panel.children.append(block)
        let foundTyped = panel.children.indexOf(block, &index)
        report("IVector<UIElement>.indexOf (a typed parameter): \(foundTyped ? "found at \(index)" : "not found")")

        report("IVector<Object>.getAt is == to the object appended: \((stored as? NavigationViewItemBase).map { $0 == (second as NavigationViewItemBase) } ?? false)")

        navigation.selectedItem = second
        report("NavigationView.selectedItem is the item set: \((navigation.selectedItem as AnyObject?) === second)")

        // A Swift subclass of a composable class is aggregated: its COM identity is the Swift object.
        let derived = DerivedItem()
        navigation.menuItems.append(derived)
        let storedDerived = navigation.menuItems.getAt(2)
        report("Swift subclass: getAt returns the same Swift object: \((storedDerived as AnyObject?) === derived)")
        report("Swift subclass: IVector<Object>.indexOf: \(navigation.menuItems.indexOf(derived, &index) ? "found at \(index)" : "not found")")
    }

    // MARK: Boxed values

    private func checkBoxedValues() {
        let item = NavigationViewItem()
        item.tag = "a tag"
        report("tag set to a String comes back as \(describe(item.tag))")
        item.tag = 42
        report("tag set to an Int comes back as \(describe(item.tag))")
        item.content = "a title"
        report("content set to a String comes back as \(describe(item.content))")
    }

    private func describe(_ value: Any?) -> String {
        guard let value else { return "nil" }
        return "\(type(of: value)) (as String: \((value as? String).map { "\"\($0)\"" } ?? "no"))"
    }
}

/// A Swift subclass of a composable XAML class, which swift-winrt aggregates.
final class DerivedItem: NavigationViewItem {}
