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
    /// One ongoing or completed git action.
    ///
    /// Lives until completion regardless of whether the UI ever surfaces it:
    /// `BranchesState.runningAction` references it while in flight (drives
    /// the per-button spinner + disable), and `activeAction` is only set on
    /// failure so the modal sheet appears exclusively for errors.
    @MainActor
    @Observable
    final class Action: Identifiable {
        /// Classifies what's running so buttons can decide which one of them
        /// shows the spinner. Carrying identifiers (branch name, listing id)
        /// on the cases that need them keeps the spinner targeted — switching
        /// to `main` doesn't make every Switch button on every row spin.
        enum Kind: Equatable, Hashable, Sendable {
            case fetch
            case pull
            case push
            case commit
            case createBranch
            case rename(branch: String)
            case switchBranch(listingID: String)
        }

        enum Phase: Equatable {
            case running
            case succeeded
            case failed(message: String)
        }

        /// One-click follow-up offered in the error sheet when we recognise
        /// the failure as something Treeline can fix automatically. Surfaced
        /// as a button so the user opts in instead of us silently re-running
        /// git with different flags.
        enum Recovery: Equatable, Sendable {
            /// Re-push with `-u origin <branch>` to rewrite the stale upstream
            /// configuration. The classic post-rename push failure.
            case relinkUpstreamAndPush(branch: String)

            var buttonLabel: String {
                switch self {
                case .relinkUpstreamAndPush(let branch):
                    return "Push and re-link upstream to origin/\(branch)"
                }
            }

            var explanation: String {
                switch self {
                case .relinkUpstreamAndPush:
                    return "This branch was likely renamed locally — its upstream still points at the old name. Treeline can re-push and re-link the upstream to the matching remote branch."
                }
            }
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let commandPreview: String
        var output: [String] = []
        var phase: Phase = .running
        /// Suggested follow-up the user can invoke from the error sheet.
        /// `nil` for failures we don't know how to recover from.
        var recovery: Recovery?

        init(kind: Kind, title: String, commandPreview: String) {
            self.kind = kind
            self.title = title
            self.commandPreview = commandPreview
        }

        var isFinished: Bool {
            switch phase {
            case .running: return false
            case .succeeded, .failed: return true
            }
        }

        /// Joined transcript ready for clipboard. Computed here so the sheet
        /// and any future copy-anywhere caller agree on the format.
        var combinedLog: String {
            output.joined(separator: "\n")
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

    /// The action sheet binding. Set **only** when an action fails — the
    /// modal is reserved for surfacing errors with a copyable log. Successes
    /// never present anything; the user gets their feedback through the
    /// branch list refresh and the changed-file badge.
    var activeAction: Action?

    /// The action currently in flight. Drives the per-button spinner and
    /// the global "another action is running" disable. Set immediately when
    /// the user clicks a button and cleared when the action completes — the
    /// UI shows progress on the originating button, not in a modal.
    private(set) var runningAction: Action?

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
            kind: .fetch,
            title: "Fetch",
            commandPreview: "git fetch --all --prune",
            invocation: gitClient.fetchAction()
        )
    }

    /// Kick off a pull (`git pull`). Blocks on dirty working tree.
    func runPull() {
        guard let gitClient else { return }
        runAction(
            kind: .pull,
            title: "Pull",
            commandPreview: "git pull",
            invocation: gitClient.pullAction()
        )
    }

    /// Kick off a push. The caller supplies the current branch name and
    /// whether it has an upstream so the action can pick between `git push`
    /// and `git push -u origin <branch>` automatically.
    ///
    /// If the push fails because the configured upstream's branch name no
    /// longer matches the local branch (classic post-rename situation), the
    /// error sheet offers a "Push and re-link upstream" recovery button that
    /// retries with `-u origin <branch>`.
    func runPush(currentBranch: String?, hasUpstream: Bool) {
        guard let gitClient else { return }
        let invocation = gitClient.pushAction(
            currentBranch: currentBranch,
            hasUpstream: hasUpstream
        )
        let preview = "git " + invocation.arguments.joined(separator: " ")
        runAction(
            kind: .push,
            title: "Push",
            commandPreview: preview,
            invocation: invocation,
            recoveryDetector: { failureOutput in
                Self.detectPushRecovery(in: failureOutput, currentBranch: currentBranch)
            }
        )
    }

    /// Look at a failed push's combined output and decide if we recognise it
    /// as something Treeline can fix. Matched against git's exact phrasing
    /// for the rename/upstream-mismatch error.
    ///
    /// `nonisolated` so the @Sendable detector closure can call it freely —
    /// the function is a pure string parse with no state to protect.
    private nonisolated static func detectPushRecovery(
        in output: String,
        currentBranch: String?
    ) -> Action.Recovery? {
        guard let branch = currentBranch, !branch.isEmpty else { return nil }
        // git's wording is stable across versions: "The upstream branch of
        // your current branch does not match the name of your current
        // branch". Match the distinctive fragment so we're not fooled by
        // unrelated "upstream" mentions in stderr.
        if output.localizedCaseInsensitiveContains("upstream branch of your current branch does not match") {
            return .relinkUpstreamAndPush(branch: branch)
        }
        return nil
    }

    /// Invoke the suggested recovery on a failed action. Closes the sheet
    /// and kicks off the recovery as a fresh action so it gets its own
    /// spinner + log just like any other run.
    func performRecovery(for action: Action) {
        guard let recovery = action.recovery else { return }
        guard let gitClient else { return }
        // Clear the error sheet first so the button press doesn't visually
        // race the new action's spinner.
        activeAction = nil
        switch recovery {
        case .relinkUpstreamAndPush(let branch):
            // Force the `-u origin <branch>` path; that's exactly what
            // `pushAction` produces when `hasUpstream` is false.
            let invocation = gitClient.pushAction(currentBranch: branch, hasUpstream: false)
            runAction(
                kind: .push,
                title: "Push (re-link upstream)",
                commandPreview: "git " + invocation.arguments.joined(separator: " "),
                invocation: invocation
                // No recoveryDetector on the recovery itself — if THIS fails
                // it's a real error, not another rename-shaped recoverable.
            )
        }
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
            kind: .rename(branch: oldName),
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
        runAction(
            kind: .switchBranch(listingID: listing.id),
            title: "Switch to \(listing.displayName)",
            commandPreview: preview,
            invocation: invocation
        )
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
        guard runningAction == nil else { return }
        guard let gitClient else { return }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else { return }
        let preview = body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "git add -A && git commit -m … -m …"
            : "git add -A && git commit -m …"
        let action = Action(kind: .commit, title: "Commit", commandPreview: preview)
        runningAction = action

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
                self.completeSuccessfully(action)
            } catch let GitClientError.actionFailed(_, output) {
                self.complete(
                    action,
                    failure: output.isEmpty ? "git exited with a non-zero status." : output
                )
            } catch {
                self.complete(action, failure: String(describing: error))
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
            kind: .createBranch,
            title: checkout ? "Create + switch to \(trimmed)" : "Create branch \(trimmed)",
            commandPreview: preview,
            invocation: invocation
        )
    }

    /// Convenience used by the views to ask "is *this* particular action the
    /// one in flight?" so each button can render its own spinner without
    /// looking at the global `runningAction` and squinting at fields.
    func isRunning(_ kind: Action.Kind) -> Bool {
        runningAction?.kind == kind
    }

    /// True when any git action is in flight. Drives the global disable so
    /// users can't queue a second action against the same working tree while
    /// the first is mid-flight.
    var isAnyActionRunning: Bool {
        runningAction != nil
    }

    private func runAction(
        kind: Action.Kind,
        title: String,
        commandPreview: String,
        invocation: GitClient.ActionInvocation,
        recoveryDetector: (@Sendable (String) -> Action.Recovery?)? = nil
    ) {
        guard runningAction == nil else {
            // Only one action runs at a time — we never want two concurrent
            // git invocations against the same working tree.
            return
        }
        guard let gitClient else { return }
        let action = Action(kind: kind, title: title, commandPreview: commandPreview)
        runningAction = action

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
                self.completeSuccessfully(action)
            } catch let GitClientError.dirtyWorkingTree(path) {
                self.complete(
                    action,
                    failure: "Working tree at \(path) has uncommitted changes. Commit or stash them, then try again.",
                    recoveryDetector: recoveryDetector
                )
            } catch let GitClientError.actionFailed(_, output) {
                self.complete(
                    action,
                    failure: output.isEmpty ? "git exited with a non-zero status." : output,
                    recoveryDetector: recoveryDetector
                )
            } catch {
                self.complete(action, failure: String(describing: error), recoveryDetector: recoveryDetector)
            }
        }
    }

    /// Success path — clears the in-flight tracking. No modal is shown for
    /// successes; the branch list and changed-file badge already updated.
    private func completeSuccessfully(_ action: Action) {
        if runningAction?.id == action.id { runningAction = nil }
    }

    /// Failure path — clears the in-flight tracking, attaches any recovery
    /// the detector recognised in the captured output, and presents the
    /// modal so the user can read the error and choose the next move.
    private func complete(
        _ action: Action,
        failure: String,
        recoveryDetector: (@Sendable (String) -> Action.Recovery?)? = nil
    ) {
        action.phase = .failed(message: failure)
        if let recoveryDetector {
            // Probe against the combined stream + the explicit failure
            // message so detectors don't have to guess where git put the
            // signal text.
            let haystack = action.combinedLog + "\n" + failure
            action.recovery = recoveryDetector(haystack)
        }
        if runningAction?.id == action.id { runningAction = nil }
        activeAction = action
    }
}
