import Foundation

/// Computes a `ProjectHealth` snapshot for one Project by probing the primary
/// checkout with cheap git calls. Every failure mode resolves to a degraded
/// status with a human-readable reason instead of throwing, so a single bad
/// repo (missing path, missing git, repo corruption) can never block the rest
/// of the dashboard.
struct ProjectHealthRefresher: Sendable {
    let gitClient: GitClient
    let fileManager: FileManager
    let now: @Sendable () -> Date

    init(
        gitClient: GitClient,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gitClient = gitClient
        self.fileManager = fileManager
        self.now = now
    }

    func refresh(_ project: Project) async -> ProjectHealth {
        let primaryURL = URL(fileURLWithPath: project.primaryCheckoutPath)
        let timestamp = now()

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: primaryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return degraded(
                "Primary checkout is missing or no longer a directory",
                at: timestamp
            )
        }

        do {
            // Run the three cheap probes in parallel. Worktree discovery is
            // best-effort: older git versions or non-standard repos can fail
            // `git worktree list --porcelain` without invalidating branch or
            // status, so we don't let it degrade the whole snapshot.
            async let branchTask = gitClient.currentBranch(at: primaryURL)
            async let dirtyTask = gitClient.isWorkingTreeDirty(at: primaryURL)
            async let worktreeCountTask = bestEffortWorktreeCount(at: primaryURL)

            let branch = try await branchTask
            let isDirty = try await dirtyTask
            let worktreeCount = await worktreeCountTask

            return ProjectHealth(
                status: .ready,
                currentBranch: branch,
                workingTree: isDirty ? .dirty : .clean,
                worktreeCount: worktreeCount,
                lastRefreshedAt: timestamp
            )
        } catch let CLIError.launchFailed(reason) {
            return degraded("git is unavailable: \(reason)", at: timestamp)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return degraded(
                message.isEmpty ? "git command failed" : message,
                at: timestamp
            )
        } catch let GitClientError.notInsideRepository(_, underlying) {
            return degraded(
                underlying.isEmpty ? "Not inside a git repository" : underlying,
                at: timestamp
            )
        } catch GitClientError.emptyOutput {
            return degraded("git produced no output", at: timestamp)
        } catch {
            return degraded("git command failed: \(error)", at: timestamp)
        }
    }

    private func bestEffortWorktreeCount(at url: URL) async -> Int {
        let paths = (try? await gitClient.listWorktreePaths(at: url)) ?? []
        // Even when worktree list fails or returns nothing, the primary
        // checkout itself is one tracked checkout, so we never display "0".
        return max(paths.count, 1)
    }

    private func degraded(_ reason: String, at timestamp: Date) -> ProjectHealth {
        ProjectHealth(
            status: .degraded(reason: reason),
            currentBranch: nil,
            workingTree: nil,
            worktreeCount: nil,
            lastRefreshedAt: timestamp
        )
    }
}
