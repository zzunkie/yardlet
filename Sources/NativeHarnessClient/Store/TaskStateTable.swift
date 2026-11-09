import Foundation
import Observation

/// Per-task state that views read one task at a time. Each task's value is observed on its own,
/// so a task streaming in the background does not invalidate the view showing another task.
/// Reading the whole table (`dictionary`, `isEmpty`) observes every task and the set of tasks.
@MainActor
final class TaskStateTable<Value> {
    /// One task's value. Views that read it are invalidated only when it is set.
    @MainActor
    final class Cell: Observable {
        private let registrar = ObservationRegistrar()
        private var storage: Value?

        var value: Value? {
            get {
                registrar.access(self, keyPath: \.value)
                return storage
            }
            set {
                registrar.withMutation(of: self, keyPath: \.value) { storage = newValue }
            }
        }

        /// The value, read without observing it.
        var unobservedValue: Value? { storage }
    }

    /// Changes when a task gains or loses a value, for readers of the whole table.
    @MainActor
    private final class Membership: Observable {
        private let registrar = ObservationRegistrar()
        private var storage = 0

        var version: Int {
            get {
                registrar.access(self, keyPath: \.version)
                return storage
            }
            set {
                registrar.withMutation(of: self, keyPath: \.version) { storage = newValue }
            }
        }
    }

    private var cells: [UUID: Cell] = [:]
    private var presentIDs = Set<UUID>()
    private let membership = Membership()
    /// Told which task's value was just set, for state derived from it (the sidebar's
    /// `TaskAttentionDetail`), which is then published only when it changes.
    var didSet: ((UUID) -> Void)?

    init(_ values: [UUID: Value] = [:]) {
        for (id, value) in values { self[id] = value }
    }

    subscript(id: UUID) -> Value? {
        get { cell(for: id).value }
        set {
            let cell = cell(for: id)
            cell.value = newValue
            defer { didSet?(id) }
            let isPresent = newValue != nil
            guard isPresent != presentIDs.contains(id) else { return }
            if isPresent { presentIDs.insert(id) } else { presentIDs.remove(id) }
            membership.version &+= 1
        }
    }

    /// `id`'s value, read without observing it: for state kept outside the views that `didSet` tells
    /// of each change, such as the sidebar search's answers (`ConversationSearchMemo`).
    func unobservedValue(for id: UUID) -> Value? {
        cells[id]?.unobservedValue
    }

    var isEmpty: Bool {
        _ = membership.version
        return presentIDs.isEmpty
    }

    var dictionary: [UUID: Value] {
        _ = membership.version
        var values: [UUID: Value] = [:]
        values.reserveCapacity(presentIDs.count)
        for id in presentIDs {
            if let value = cells[id]?.value { values[id] = value }
        }
        return values
    }

    @discardableResult
    func removeValue(forKey id: UUID) -> Value? {
        guard presentIDs.contains(id) else { return nil }
        let previous = cells[id]?.value
        self[id] = nil
        return previous
    }

    func removeAll() {
        for id in presentIDs { self[id] = nil }
    }

    var reader: TaskStateReader<Value> { TaskStateReader(table: self) }

    private func cell(for id: UUID) -> Cell {
        if let cell = cells[id] { return cell }
        let cell = Cell()
        cells[id] = cell
        return cell
    }
}

/// Read-only access to a `TaskStateTable`, with the dictionary reads its callers already use.
@MainActor
struct TaskStateReader<Value> {
    fileprivate let table: TaskStateTable<Value>

    subscript(id: UUID) -> Value? { table[id] }
    var isEmpty: Bool { table.isEmpty }
    var dictionary: [UUID: Value] { table.dictionary }
}
