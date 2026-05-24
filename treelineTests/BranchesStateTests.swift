import Foundation
import Testing
@testable import treeline

@MainActor
struct BranchesStateTests {

    @Test func runDeleteUsesSafeDeleteAndRefreshesBranchList() async throws {
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory
            .appendingPathComponent("treeline-branch-delete-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["branch", "-d", "feature/remove"],
            stdout: "Deleted branch feature/remove (was abc123).\n"
        )
        runner.stub(
            arguments: [
                "for-each-ref",
                "--format=%(HEAD)|%(refname)|%(upstream:short)",
                "refs/heads",
                "refs/remotes",
            ],
            stdout: "*|refs/heads/main|origin/main\n"
        )
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")

        let state = BranchesState(
            project: Project(
                commonDirectoryPath: checkout.appendingPathComponent(".git").path,
                primaryCheckoutPath: checkout.path,
                displayName: "demo"
            ),
            gitClient: GitClient(runner: runner),
            dashboard: nil
        )

        state.runDelete(name: " feature/remove ")
        try await waitForActionToFinish(state)

        #expect(state.activeAction == nil)
        #expect(state.branches.map(\.displayName) == ["main"])
        #expect(runner.invocations.contains { $0.arguments == ["branch", "-d", "feature/remove"] })
    }

    private func waitForActionToFinish(
        _ state: BranchesState,
        timeout: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while state.runningAction != nil || state.isLoadingBranches {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for branch action to finish")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
