import Foundation

/// Observable state for the branches section on Project detail.
///
/// Owns the branch list for the currently displayed Project plus the action
/// sheet that runs the user's chosen git command. Lives on the main actor so
/// SwiftUI can observe mutations directly and the streaming `onLine` callback
/// can append output without a hop.
///
/// Kept separate from `ProjectsDashboardState` because branch operations are
/// per-Project and should not couple into the dashboard-wide refresh
/// bookkeeping. The dashboard state is still passed in so successful actions
/// can drive a `refreshHealth` for the affected Project.
@MainActor
@Observable
final class BranchesState {
    /// One ongoing or completed git action surfaced through the modal sheet.
    /// The sheet observes this directly so live output and the final result
    /// stay in sync without an intermediate state machine.
    @MainActor
    @Observable
    final class Action: Identifiable {
        enum Phase: Equatable {
            case running
            case succeeded
            case failed(message: String)
        }

        let id = UUID()
        let title: String
        let commandPreview: String
        var output: [String] = []
        var phase: Phase = .running

        init(title: String, commandPreview: String) {
            self.title = title
            self.commandPreview = commandPreview
        }

        var isFinished: Bool {
            switch phase {
            case .running: return false
            case .succeeded, .failed: return true
            }
        }
    }

    let project: Project
    private let gitClient: GitClient?
    private weak var dashboard: ProjectsDashboardState?

    /// Last successfully-loaded branch list. Kept as the empty array until the
    /// first refresh resolves so the section renders an explicit "Loading…"
    /// state rather than guessing.
    private(set) var branches: [BranchListing] = []
    private(set) var isLoadingBranches = false
    /// Count of files with uncommitted changes on the primary checkout's
    /// current branch (tracked changes + untracked, gitignored excluded).
    /// `nil` while we've never probed; `0` when clean. The view uses this to
    /// render the "N changed" badge next to the current-branch row and to
    /// gate the Commit button.
    private(set) var changedFileCount: Int?
    /// Last error from `refreshBranches`, surfaced inline above the list.
    var lastBranchError: String?

    /// The action sheet's binding. When non-nil the modal is presented; the
    /// user dismisses it via the Close button once the action finishes.
    var activeAction: Action?

    init(
        project: Project,
        gitClient: GitClient?,
        dashboard: ProjectsDashboardState?
    ) {
        self.project = project
        self.gitClient = gitClient
        self.dashboard = dashboard
    }

    /// Refresh the local branch list and the changed-file count. Idempotent —
    /// replaces the previous snapshot wholesale so renamed/deleted branches
    /// drop out cleanly. The changed-file count probe is best-effort: a
    /// failure there doesn't blow away an otherwise good branch list.
    func refreshBranches() async {
        guard let gitClient else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        let primaryURL = URL(fileURLWithPath: project.primaryCheckoutPath)
        do {
            let result = try await gitClient.listBranches(at: primaryURL)
            branches = result
            lastBranchError = nil
        } catch let GitClientError.notInsideRepository(_, underlying) {
            lastBranchError = underlying.isEmpty ? "Not inside a git repository." : underlying
        } catch {
            lastBranchError = String(describing: error)
        }
        // Probe count independently of the branch list — a transient failure
        // here just leaves the badge hidden, it doesn't degrade the branch UI.
        changedFileCount = try? await gitClient.changedFileCount(at: primaryURL)
    }

    /// Kick off a fetch (`git fetch --all --prune`).
    func runFetch() {
        guard let gitClient else { return }
        runAction(
            title: "Fetch",
            commandPreview: "git fetch --all --prune",
            invocation: gitClient.fetchAction()
        )
    }

    /// Kick off a pull (`git pull`). Blocks on dirty working tree.
    func runPull() {
        guard let gitClient else { return }
        runAction(
            title: "Pull",
            commandPreview: "git pull",
            invocation: gitClient.pullAction()
        )
    }

    /// Kick off a push. The caller supplies the current branch name and
    /// whether it has an upstream so the action can pick between `git push`
    /// and `git push -u origin <branch>` automatically.
    func runPush(currentBranch: String?, hasUpstream: Bool) {
        guard let gitClient else { return }
        let invocation = gitClient.pushAction(
            currentBranch: currentBranch,
            hasUpstream: hasUpstream
        )
        let preview = "git " + invocation.arguments.joined(separator: " ")
        runAction(title: "Push", commandPreview: preview, invocation: invocation)
    }

    /// Rename a local branch. Surfaced through the per-row context menu;
    /// only valid for local listings (remotes aren't renameable through git
    /// without separate remote-side coordination, which is out of scope).
    func runRename(from oldName: String, to newName: String) {
        guard let gitClient else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        let invocation = gitClient.renameAction(from: oldName, to: trimmed)
        runAction(
            title: "Rename \(oldName) → \(trimmed)",
            commandPreview: "git branch -m \(oldName) \(trimmed)",
            invocation: invocation
        )
    }

    /// Switch to an existing branch, either local or by creating a tracking
    /// branch from a remote ref. Blocks on dirty working tree.
    func runSwitch(to listing: BranchListing) {
        guard let gitClient else { return }
        let invocation: GitClient.ActionInvocation
        let preview: String
        switch listing.kind {
        case .local:
            invocation = gitClient.switchAction(toLocal: listing.shortName)
            preview = "git switch \(listing.shortName)"
        case .remote:
            invocation = gitClient.switchAction(
                toRemote: listing.displayName,
                localName: listing.shortName
            )
            preview = "git switch -c \(listing.shortName) --track \(listing.displayName)"
        }
        runAction(title: "Switch to \(listing.displayName)", commandPreview: preview, invocation: invocation)
    }

    /// Stage everything (tracked changes + new files, gitignored excluded)
    /// and create a commit. `body` is optional — when present it becomes the
    /// commit message body separated from the subject by a blank line per
    /// conventional formatting.
    ///
    /// Uses its own task path rather than `runAction` because the commit is a
    /// composite (`git add -A` then `git commit`) that needs to share one
    /// sheet across two streamed invocations.
    func runCommit(subject: String, body: String?) {
        guard activeAction == nil else { return }
        guard let gitClient else { return }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else { return }
        let preview = body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "git add -A && git commit -m … -m …"
            : "git add -A && git commit -m …"
        let action = Action(title: "Commit", commandPreview: preview)
        activeAction = action

        Task { @MainActor [weak self, weak action] in
            guard let self, let action else { return }
            do {
                try await gitClient.runCommit(
                    subject: trimmedSubject,
                    body: body,
                    at: URL(fileURLWithPath: self.project.primaryCheckoutPath),
                    onLine: { line in
                        action.output.append(line)
                    }
                )
                action.phase = .succeeded
                await self.refreshBranches()
                if let dashboard = self.dashboard,
                   let updated = dashboard.projects.first(where: { $0.id == self.project.id }) {
                    await dashboard.refreshHealth(for: updated)
                }
            } catch let GitClientError.actionFailed(_, output) {
                action.phase = .failed(message: output.isEmpty ? "git exited with a non-zero status." : output)
            } catch {
                action.phase = .failed(message: String(describing: error))
            }
        }
    }

    /// Create a new branch, optionally checking it out immediately. `base` is
    /// passed through to git; an empty string means "off current HEAD".
    func runCreateBranch(name: String, base: String?, checkout: Bool) {
        guard let gitClient else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let invocation = gitClient.createBranchAction(
            name: trimmed,
            base: base,
            checkout: checkout
        )
        let preview = "git " + invocation.arguments.joined(separator: " ")
        runAction(
            title: checkout ? "Create + switch to \(trimmed)" : "Create branch \(trimmed)",
            commandPreview: preview,
            invocation: invocation
        )
    }

    private func runAction(
        title: String,
        commandPreview: String,
        invocation: GitClient.ActionInvocation
    ) {
        guard activeAction == nil else {
            // Only one action runs at a time — the sheet is modal and a
            // second concurrent action would race on the same working tree.
            return
        }
        guard let gitClient else { return }
        let action = Action(title: title, commandPreview: commandPreview)
        activeAction = action

        Task { @MainActor [weak self, weak action] in
            guard let self, let action else { return }
            do {
                try await gitClient.runAction(
                    invocation,
                    at: URL(fileURLWithPath: self.project.primaryCheckoutPath),
                    onLine: { line in
                        action.output.append(line)
                    }
                )
                action.phase = .succeeded
                // Refresh branch list + dashboard health so the section and
                // row reflect the post-action state without the user clicking
                // anything.
                await self.refreshBranches()
                if let dashboard = self.dashboard,
                   let updated = dashboard.projects.first(where: { $0.id == self.project.id }) {
                    await dashboard.refreshHealth(for: updated)
                }
            } catch let GitClientError.dirtyWorkingTree(path) {
                action.phase = .failed(message: "Working tree at \(path) has uncommitted changes. Commit or stash them, then try again.")
            } catch let GitClientError.actionFailed(_, output) {
                action.phase = .failed(message: output.isEmpty ? "git exited with a non-zero status." : output)
            } catch {
                action.phase = .failed(message: String(describing: error))
            }
        }
    }
}
