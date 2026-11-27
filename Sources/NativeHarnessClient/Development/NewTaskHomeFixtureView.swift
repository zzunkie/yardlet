#if DEBUG
import SwiftUI

/// Exercises the real composer and async navigation without creating a runtime.
struct NewTaskHomeFixtureView: View {
    @State private var runtimeSelections: RuntimeSelectionStore = {
        let suite = "NativeHarnessClient.HomeFixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let selections = RuntimeSelectionStore(
            defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false
        )
        for harness in [HarnessKind.codex, .openCode] {
            selections.select(URL(filePath: "/usr/bin/true"), for: harness)
        }
        return selections
    }()
    @State private var hasProject = true
    @State private var draft = NewTaskDraft()
    @State private var showsTask = false
    @State private var succeeds = false
    @State private var holdsStart = false
    @State private var openCodeAvailable = true
    @State private var pendingResult: SessionRecord?
    @State private var completion: CheckedContinuation<SessionRecord?, Never>?
    @State private var showsHarnesses = false
    @State private var submissions = 0
    private let workspace = URL(filePath: "/tmp/Yardlet-home-fixture-with-a-long-project-name")

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Home fixture").font(.headline)
                Text("No provider is contacted.").font(.caption)
                Toggle("Project selected", isOn: $hasProject)
                Toggle("Start succeeds", isOn: $succeeds)
                Toggle("Hold start", isOn: $holdsStart)
                Toggle("OpenCode available", isOn: $openCodeAvailable)
                Button(showsTask ? "Return home" : "Show task") { showsTask.toggle() }
                Button("Finish start") {
                    let pending = completion
                    completion = nil
                    if pendingResult != nil { showsTask = true }
                    pending?.resume(returning: pendingResult)
                    pendingResult = nil
                }
                .disabled(completion == nil)
                Text("Submissions: \(submissions)").font(.caption)
                Spacer()
            }
            .padding(16).frame(width: 208)
            .background(ParityTheme.subtleFill)
            if showsTask {
                Text("A different task").frame(width: 520, height: 400)
            } else {
                home
            }
        }
        .padding(.top, 40)
        .onChange(of: hasProject) { _, selected in draft.workspaceURL = selected ? workspace : nil }
        .onChange(of: openCodeAvailable) { _, available in
            runtimeSelections.select(
                URL(filePath: available ? "/usr/bin/true" : "/tmp/yardlet-home-fixture-missing-runtime"),
                for: .openCode
            )
        }
        .sheet(isPresented: $showsHarnesses) {
            HarnessCenterView(
                runtimeSelections: runtimeSelections,
                fixtureSnapshots: VisualFixtureScenario.harnessCenterSnapshots
            )
        }
    }

    private var home: some View {
        NewTaskHome(
            recentSessions: [],
            projects: hasProject
                ? [
                    Project(name: workspace.lastPathComponent, primaryRoot: workspace),
                    Project(name: "Another-project", primaryRoot: URL(filePath: "/tmp/Another-project"))
                ]
                : [],
            draft: draft,
            runtimeSelections: runtimeSelections,
            onSelectSession: { _ in },
            onShowHarnesses: { showsHarnesses = true },
            onCreate: { submission in
                submissions += 1
                let result = succeeds ? SessionRecord(
                    harness: submission.harness, workspaceURL: submission.workspaceURL ?? workspace,
                    runtimeExecutableURL: submission.runtimeURL, title: submission.title
                ) : nil
                if holdsStart {
                    pendingResult = result
                    return await withCheckedContinuation { completion = $0 }
                }
                if result != nil { showsTask = true }
                return result
            }
        )
        .frame(width: 520)
    }
}
#endif
