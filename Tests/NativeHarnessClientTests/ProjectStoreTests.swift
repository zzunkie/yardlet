import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ProjectStoreTests: XCTestCase {
    private func session(
        workspaceURL: URL,
        projectID: UUID? = nil,
        additionalRoots: [String] = [],
        originWorkspacePath: String? = nil,
        worktreeName: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> SessionRecord {
        SessionRecord(
            harness: .codex,
            workspaceURL: workspaceURL,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Task",
            createdAt: updatedAt,
            updatedAt: updatedAt,
            projectID: projectID,
            additionalRoots: additionalRoots,
            originWorkspacePath: originWorkspacePath,
            worktreeName: worktreeName
        )
    }

    func testFolderPreferencesAndTaskFoldersConvertToSingleRootProjectsExactlyOnce() {
        let registered = URL(filePath: "/tmp/registered-project")
        let renamed = URL(filePath: "/tmp/renamed-project")
        let hidden = URL(filePath: "/tmp/hidden-project")
        let taskFolder = URL(filePath: "/tmp/task-only-project")
        let preferences = LegacyProjectFolderPreferences(
            pinnedPaths: [renamed.path(percentEncoded: false)],
            aliasesByPath: [renamed.path(percentEncoded: false): "Client app"],
            hiddenPaths: [hidden.path(percentEncoded: false)],
            registeredPaths: [registered.path(percentEncoded: false)]
        )
        let repository = InMemoryProjectRepository()
        let store = ProjectStore(repository: repository)

        store.importFolderPreferences(preferences, sessionWorkspaceURLs: [taskFolder])
        let firstPass = store.projects
        XCTAssertEqual(firstPass.count, 4)
        XCTAssertEqual(store.project(containingRoot: renamed)?.name, "Client app")
        XCTAssertEqual(store.project(containingRoot: renamed)?.isPinned, true)
        XCTAssertEqual(store.project(containingRoot: hidden)?.isHidden, true)
        XCTAssertEqual(store.project(containingRoot: registered)?.name, "registered-project")
        XCTAssertEqual(store.project(containingRoot: taskFolder)?.roots, [taskFolder])
        XCTAssertTrue(firstPass.allSatisfy { $0.roots.count == 1 })

        // Running the conversion again neither adds nor rewrites a project.
        store.importFolderPreferences(preferences, sessionWorkspaceURLs: [taskFolder])
        XCTAssertEqual(store.projects, firstPass)
        XCTAssertTrue(store.didImportFolderPreferences)
    }

    func testConversionKeepsAFolderAlreadyCoveredByAMultiRootProject() {
        let primary = URL(filePath: "/tmp/repo-a")
        let secondary = URL(filePath: "/tmp/repo-b")
        let store = ProjectStore()
        let project = store.ensureProject(forRoot: primary, name: "Two repos")
        XCTAssertTrue(store.addRoot(secondary, to: project.id))

        store.importFolderPreferences(
            LegacyProjectFolderPreferences(
                pinnedPaths: [], aliasesByPath: [:], hiddenPaths: [],
                registeredPaths: [secondary.path(percentEncoded: false)]
            ),
            sessionWorkspaceURLs: [secondary]
        )

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.project(containingRoot: secondary)?.id, project.id)
    }

    func testProjectRoundTripsThroughTheFileStoreWithItsRootsAndPrimaryFolder() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileProjectRepository(fileURL: directory.appending(path: "projects.json"))
        let store = ProjectStore(repository: repository)
        let primary = URL(filePath: "/tmp/round-trip-a")
        let secondary = URL(filePath: "/tmp/round-trip-b")
        let project = store.ensureProject(forRoot: primary, name: "Round trip")
        store.addRoot(secondary, to: project.id)
        store.setPrimaryRoot(secondary, for: project.id)
        store.togglePinned(project.id)
        store.persistNow()

        let restored = ProjectStore(repository: FileProjectRepository(
            fileURL: directory.appending(path: "projects.json")
        ))
        let restoredProject = try? XCTUnwrap(restored.project(id: project.id))
        XCTAssertEqual(restoredProject?.name, "Round trip")
        XCTAssertEqual(restoredProject?.roots, [primary, secondary])
        XCTAssertEqual(restoredProject?.primaryRoot, secondary)
        XCTAssertEqual(restoredProject?.additionalRoots, [primary])
        XCTAssertEqual(restoredProject?.isPinned, true)
        XCTAssertTrue(restored.didImportFolderPreferences == false)
    }

    func testPrimaryFolderDefaultsToTheFirstRootAndNeverLeavesTheProject() {
        let primary = URL(filePath: "/tmp/primary-rules-a")
        let secondary = URL(filePath: "/tmp/primary-rules-b")
        var project = Project(name: "Primary rules", primaryRoot: primary, additionalRoots: [secondary])
        XCTAssertEqual(project.primaryRoot, primary)
        XCTAssertEqual(project.additionalRoots, [secondary])

        XCTAssertFalse(project.removeRoot(primary), "The primary folder is not removable")
        XCTAssertFalse(
            project.setPrimaryRoot(URL(filePath: "/tmp/not-a-root")),
            "Only a folder that belongs to the project can become primary"
        )
        XCTAssertTrue(project.setPrimaryRoot(secondary))
        XCTAssertEqual(project.additionalRoots, [primary])
        XCTAssertTrue(project.removeRoot(primary))
        XCTAssertEqual(project.roots, [secondary])
        XCTAssertFalse(project.removeRoot(secondary), "A project always keeps one folder")

        XCTAssertFalse(project.addRoot(secondary), "A root is never duplicated")
    }

    func testTaskWithoutAProjectIDStillGroupsUnderTheProjectThatOwnsItsFolder() {
        let primary = URL(filePath: "/tmp/legacy-grouping-a")
        let secondary = URL(filePath: "/tmp/legacy-grouping-b")
        let project = Project(name: "Legacy grouping", primaryRoot: primary, additionalRoots: [secondary])
        // Written before projects existed: no project ID, and a cwd that is now an extra root.
        let legacy = session(workspaceURL: secondary)
        let unrelated = session(workspaceURL: URL(filePath: "/tmp/no-project"))

        let groups = ProjectProjection.workspaceGroups(
            from: [legacy, unrelated],
            projects: [project]
        )

        XCTAssertEqual(
            groups.first { $0.project?.id == project.id }?.workspaceURL,
            primary,
            "A matched task groups under the project's primary folder"
        )
        XCTAssertEqual(groups.first { $0.project?.id == project.id }?.displayName, "Legacy grouping")
        XCTAssertNil(legacy.projectID, "Display-time matching must not rewrite the stored task")
        XCTAssertEqual(groups.count, 1, "A task in no project is a chat and makes no group")
        XCTAssertTrue(ProjectProjection.isChat(unrelated, in: [project]))
    }

    func testStoredProjectIDWinsOverFolderMatchingForTaskGrouping() {
        let shared = URL(filePath: "/tmp/shared-folder")
        let owning = Project(name: "Owner", primaryRoot: URL(filePath: "/tmp/owner"), additionalRoots: [shared])
        let chosen = Project(name: "Chosen", primaryRoot: shared)
        let task = session(workspaceURL: shared, projectID: chosen.id)

        let groups = ProjectProjection.workspaceGroups(from: [task], projects: [owning, chosen])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.project?.id, chosen.id)
    }

    func testHiddenProjectsLeaveTheSidebarAndPinnedProjectsLeadWithEmptyProjectsKept() {
        let store = ProjectStore()
        let first = store.ensureProject(forRoot: URL(filePath: "/tmp/visible-first"))
        let second = store.ensureProject(forRoot: URL(filePath: "/tmp/visible-second"))
        let empty = store.ensureProject(forRoot: URL(filePath: "/tmp/no-tasks-yet"))
        let tasks = [
            session(workspaceURL: first.primaryRoot, projectID: first.id,
                    updatedAt: Date(timeIntervalSince1970: 100)),
            session(workspaceURL: second.primaryRoot, projectID: second.id,
                    updatedAt: Date(timeIntervalSince1970: 200))
        ]

        XCTAssertEqual(
            store.visibleGroups(sessions: tasks).map(\.workspaceURL),
            [second.primaryRoot, first.primaryRoot, empty.primaryRoot]
        )

        store.togglePinned(first.id)
        XCTAssertEqual(
            store.visibleGroups(sessions: tasks).map(\.workspaceURL),
            [first.primaryRoot, second.primaryRoot, empty.primaryRoot]
        )

        store.hide(second.id)
        XCTAssertEqual(
            store.visibleGroups(sessions: tasks).map(\.workspaceURL),
            [first.primaryRoot, empty.primaryRoot]
        )

        store.reveal(second.id)
        XCTAssertEqual(store.visibleGroups(sessions: tasks).count, 3)
    }

    func testChoosingAFolderFindsItsProjectOrMakesAOneFolderOne() {
        let store = ProjectStore()
        let primary = URL(filePath: "/tmp/ensure-a")
        let secondary = URL(filePath: "/tmp/ensure-b")
        let created = store.ensureProject(forRoot: primary)
        XCTAssertEqual(created.name, "ensure-a")
        XCTAssertEqual(store.projects.count, 1)

        store.addRoot(secondary, to: created.id)
        XCTAssertEqual(store.ensureProject(forRoot: secondary).id, created.id)
        XCTAssertEqual(store.projects.count, 1, "An owned folder never starts a second project")

        store.hide(created.id)
        XCTAssertEqual(store.ensureProject(forRoot: primary).isHidden, false,
                       "Choosing a removed project's folder brings it back instead of duplicating it")
    }

    func testNewTaskDraftTakesTheProjectAndItsPrimaryFolder() {
        let project = Project(
            name: "Draft default",
            primaryRoot: URL(filePath: "/tmp/draft-primary"),
            additionalRoots: [URL(filePath: "/tmp/draft-extra")]
        )
        let draft = NewTaskDraft()

        draft.prepare(defaultProject: project, availableHarnesses: [.codex])

        XCTAssertEqual(draft.workspaceURL, project.primaryRoot)
        XCTAssertEqual(draft.projectID, project.id)
        let submission = try? XCTUnwrap(
            {
                draft.text = "Start work"
                return draft.beginSubmission(runtimeURL: URL(filePath: "/tmp/codex"))
            }()
        )
        XCTAssertEqual(submission?.workspaceURL, project.primaryRoot)
        XCTAssertEqual(submission?.projectID, project.id)
    }

    func testCreatedTaskRecordsItsProjectAndTheRemainingRootsWithoutTheCwd() async {
        let primary = URL(filePath: "/tmp/create-primary")
        let secondary = URL(filePath: "/tmp/create-secondary")
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: try! XCTUnwrap(
                UserDefaults(suiteName: testDefaultsSuite("ProjectStoreTests"))
            )),
            registry: HarnessRegistry(),
            restoresIndexOnLaunch: false
        )
        let project = model.projects.ensureProject(forRoot: primary, name: "Two roots")
        model.projects.addRoot(secondary, to: project.id)

        // The attach fails without a runtime; the stored task identity is what matters here.
        _ = await model.createSession(
            harness: .codex,
            workspaceURL: secondary,
            runtimeExecutableURL: URL(filePath: "/tmp/missing-codex"),
            title: "Multi root",
            projectID: project.id
        )

        let created = try? XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(created?.projectID, project.id)
        XCTAssertEqual(created?.workspaceURL, secondary)
        XCTAssertEqual(
            created?.additionalRoots,
            [primary.path(percentEncoded: false)],
            "The cwd is never repeated in the extra roots"
        )
    }

    func testATaskStartedInAWorktreeJoinsTheOriginRepositoryProjectInsteadOfMakingANewOne() async {
        let repositoryRoot = URL(filePath: "/tmp/worktree-origin-project")
        let worktree = URL(filePath: "/tmp/worktree-origin-tree")
        let store = SessionStore(repository: InMemorySessionRepository()) { url in
            url.standardizedFileURL == worktree.standardizedFileURL
                ? WorkspaceGitOrigin(
                    originWorkspacePath: repositoryRoot.path(percentEncoded: false),
                    worktreeName: "worktree-origin-tree",
                    branch: "feature-x"
                )
                : WorkspaceGitOrigin(branch: "main")
        }
        let model = AppModel(
            store: store,
            runtimeSelections: RuntimeSelectionStore(defaults: try! XCTUnwrap(
                UserDefaults(suiteName: testDefaultsSuite("ProjectStoreTests"))
            )),
            registry: HarnessRegistry(),
            restoresIndexOnLaunch: false
        )
        let project = model.projects.ensureProject(forRoot: repositoryRoot, name: "Origin repository")

        // The attach fails without a runtime; the stored task identity is what matters here.
        _ = await model.createSession(
            harness: .codex,
            workspaceURL: worktree,
            runtimeExecutableURL: URL(filePath: "/tmp/missing-codex"),
            title: "Worktree task"
        )

        let created = try? XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(model.projects.projects.count, 1, "A worktree does not start a second project")
        XCTAssertEqual(created?.projectID, project.id)
        XCTAssertEqual(created?.workspaceURL, worktree, "The worktree stays the task's cwd")
        XCTAssertEqual(created?.originWorkspacePath, repositoryRoot.path(percentEncoded: false))
        XCTAssertEqual(created?.worktreeName, "worktree-origin-tree")
        XCTAssertEqual(created?.branch, "feature-x")
        XCTAssertEqual(
            created.flatMap { model.project(for: $0)?.id },
            project.id,
            "The sidebar shows it under the original repository"
        )
    }

    func testAWorktreeTaskGroupsUnderTheProjectThatOwnsItsOriginRepository() {
        let repository = URL(filePath: "/tmp/origin-repository")
        let project = Project(name: "Origin repository", primaryRoot: repository)
        let worktreeTask = session(
            workspaceURL: URL(filePath: "/tmp/trees/blue"),
            originWorkspacePath: repository.path(percentEncoded: false),
            worktreeName: "blue"
        )
        let unrelated = session(
            workspaceURL: URL(filePath: "/tmp/trees/green"),
            originWorkspacePath: "/tmp/some-other-repository",
            worktreeName: "green"
        )

        XCTAssertEqual(ProjectProjection.project(for: worktreeTask, in: [project])?.id, project.id)
        XCTAssertNil(
            ProjectProjection.project(for: unrelated, in: [project]),
            "A worktree of an unknown repository still belongs to no project"
        )

        let groups = ProjectProjection.workspaceGroups(
            from: [worktreeTask, unrelated],
            projects: [project]
        )
        XCTAssertEqual(
            groups.first { $0.project?.id == project.id }?.workspaceURL,
            repository,
            "The worktree's task shows under the original repository's project"
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(ProjectProjection.isChat(unrelated, in: [project]), "An unmatched worktree's task is a chat")
        XCTAssertNil(worktreeTask.projectID, "Display-time matching never rewrites the stored task")
    }

    func testProjectMatchingPrefersTheStoredIDThenTheCwdThenTheOrigin() {
        let repository = URL(filePath: "/tmp/priority-origin")
        let worktree = URL(filePath: "/tmp/priority-tree")
        let chosen = URL(filePath: "/tmp/priority-chosen")
        let originProject = Project(name: "Origin", primaryRoot: repository)
        let cwdProject = Project(name: "Worktree folder", primaryRoot: worktree)
        let chosenProject = Project(name: "Chosen", primaryRoot: chosen)
        let all = [originProject, cwdProject, chosenProject]
        let origin = repository.path(percentEncoded: false)

        let stored = session(workspaceURL: worktree, projectID: chosenProject.id, originWorkspacePath: origin)
        XCTAssertEqual(ProjectProjection.project(for: stored, in: all)?.id, chosenProject.id)

        let byFolder = session(workspaceURL: worktree, originWorkspacePath: origin)
        XCTAssertEqual(
            ProjectProjection.project(for: byFolder, in: all)?.id,
            cwdProject.id,
            "A project that owns the worktree folder itself wins over the origin"
        )

        XCTAssertEqual(
            ProjectProjection.project(for: byFolder, in: [originProject, chosenProject])?.id,
            originProject.id,
            "With no project on the folder, the origin decides"
        )

        let unmatchedID = session(workspaceURL: worktree, projectID: UUID(), originWorkspacePath: origin)
        XCTAssertEqual(
            ProjectProjection.project(for: unmatchedID, in: [originProject])?.id,
            originProject.id,
            "A stored ID that names no project falls through to the remaining rules"
        )
    }

    func testProjectPathAbbreviatesHomeDirectoryWithTrailingSlash() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let workspace = home.appending(path: "Desktop/workspace/yardlet", directoryHint: .isDirectory)

        XCTAssertEqual(
            ProjectSidebarPresentation.abbreviatedPath(for: workspace, homeDirectory: home),
            "~/Desktop/workspace/yardlet"
        )
        XCTAssertEqual(
            ProjectSidebarPresentation.abbreviatedPath(
                for: URL(filePath: "/Volumes/Work/yardlet", directoryHint: .isDirectory),
                homeDirectory: home
            ),
            "/Volumes/Work/yardlet"
        )
        // Windows shows a folder as Windows writes it, never a file URL's `/C:/` path.
        let windowsHome = URL(filePath: "/C:/Users/example", directoryHint: .isDirectory)
        XCTAssertEqual(
            ProjectSidebarPresentation.abbreviatedPath(
                for: windowsHome.appending(path: "yardlet", directoryHint: .isDirectory),
                homeDirectory: windowsHome, rules: .windows
            ),
            #"C:\Users\example\yardlet"#
        )
    }
}
