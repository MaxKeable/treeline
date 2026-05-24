import SwiftUI

/// Branches panel on the Project detail screen.
///
/// Surfaces the action bar (Fetch / Pull / Push / New Branch), a filterable
/// list of local + remote-tracking refs, and the modal sheet that hosts the
/// running action. The section is intentionally self-contained — `state` is
/// scoped to one Project so unmounting the detail view discards everything in
/// flight via SwiftUI's normal lifecycle.
struct BranchesSection: View {
    @Bindable var state: BranchesState
    /// Current health snapshot from the dashboard. Used to derive the push
    /// upstream hint and to disable actions that would obviously fail (e.g.
    /// pulling while the working tree is dirty).
    var health: ProjectHealth

    @State private var filterText: String = ""
    @State private var isPresentingNewBranchSheet = false
    @State private var isPresentingCommitSheet = false
    /// When non-nil, the rename sheet is presented for this branch. Holding
    /// the listing itself (not just a name) lets us show the original name in
    /// the sheet header without re-looking it up.
    @State private var branchPendingRename: BranchListing?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            actionBar
            if let error = state.lastBranchError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            branchList
        }
        .padding(.vertical, 8)
        .task { await state.refreshBranches() }
        .sheet(item: $state.activeAction) { action in
            // `activeAction` is only set on failure, so this sheet is now
            // purely an error surface. Recovery button (when present) hands
            // back to the state to kick off the suggested follow-up.
            GitActionSheet(
                action: action,
                onClose: { state.activeAction = nil },
                onRecover: action.recovery == nil ? nil : { state.performRecovery(for: action) }
            )
        }
        .sheet(isPresented: $isPresentingNewBranchSheet) {
            NewBranchSheet(
                baseSuggestions: branchNames,
                defaultBase: health.currentBranch ?? "",
                onCancel: { isPresentingNewBranchSheet = false },
                onCreate: { name, base, checkout in
                    isPresentingNewBranchSheet = false
                    state.runCreateBranch(name: name, base: base, checkout: checkout)
                }
            )
        }
        .sheet(item: $branchPendingRename) { listing in
            RenameBranchSheet(
                originalName: listing.shortName,
                existingLocalNames: localBranchNames,
                onCancel: { branchPendingRename = nil },
                onRename: { newName in
                    branchPendingRename = nil
                    state.runRename(from: listing.shortName, to: newName)
                }
            )
        }
        .sheet(isPresented: $isPresentingCommitSheet) {
            CommitSheet(
                branch: health.currentBranch,
                changedFileCount: state.changedFileCount ?? 0,
                onCancel: { isPresentingCommitSheet = false },
                onCommit: { subject, body in
                    isPresentingCommitSheet = false
                    state.runCommit(subject: subject, body: body)
                }
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton(
                kind: .fetch,
                label: "Fetch",
                systemImage: "arrow.down.to.line",
                disabledReason: nil,
                fallbackHelp: "git fetch --all --prune"
            ) {
                state.runFetch()
            }

            actionButton(
                kind: .pull,
                label: "Pull",
                systemImage: "arrow.down.circle",
                disabledReason: health.workingTree == .dirty
                    ? "Working tree has uncommitted changes — commit or stash first."
                    : nil,
                fallbackHelp: "git pull on the current branch"
            ) {
                state.runPull()
            }

            actionButton(
                kind: .commit,
                label: "Commit",
                systemImage: "tray.and.arrow.down",
                disabledReason: commitDisabledReason,
                fallbackHelp: "Stage all tracked + new files and commit"
            ) {
                isPresentingCommitSheet = true
            }

            actionButton(
                kind: .push,
                label: "Push",
                systemImage: "arrow.up.circle",
                disabledReason: health.currentBranch == nil
                    ? "Detached HEAD — switch to a branch first."
                    : nil,
                fallbackHelp: "git push (sets upstream automatically on first push)"
            ) {
                state.runPush(
                    currentBranch: health.currentBranch,
                    hasUpstream: hasUpstreamForCurrent
                )
            }

            actionButton(
                kind: .createBranch,
                label: "New Branch",
                systemImage: "plus.rectangle.on.folder",
                // Default flow in the sheet is "create + check out", which
                // moves HEAD and therefore needs a clean tree.
                disabledReason: health.workingTree == .dirty
                    ? "Working tree has uncommitted changes — commit or stash first."
                    : nil,
                fallbackHelp: "Create a new branch off the current HEAD"
            ) {
                isPresentingNewBranchSheet = true
            }

            Spacer()

            Button {
                Task { await state.refreshBranches() }
            } label: { Label("Refresh List", systemImage: "arrow.clockwise") }
                .disabled(state.isAnyActionRunning)
                .help("Re-read the branch list with git for-each-ref")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// Shared layout for the action-bar buttons. Swaps the icon for a
    /// `ProgressView` while *this* action is in flight, disables itself
    /// whenever any action is running (or has its own reason to be disabled),
    /// and forwards a sensible tooltip in every state.
    @ViewBuilder
    private func actionButton(
        kind: BranchesState.Action.Kind,
        label: String,
        systemImage: String,
        disabledReason: String?,
        fallbackHelp: String,
        action: @escaping () -> Void
    ) -> some View {
        let isThisRunning = state.isRunning(kind)
        let isAnyRunning = state.isAnyActionRunning
        Button(action: action) {
            HStack(spacing: 6) {
                if isThisRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(label)
            }
        }
        .disabled(isAnyRunning || disabledReason != nil)
        .help(isThisRunning ? "Running…" : (disabledReason ?? fallbackHelp))
    }

    private var branchList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Branches")
                    .font(.headline)
                if state.isLoadingBranches {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                TextField("Filter", text: $filterText, prompt: Text("Filter branches"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            if filteredBranches.isEmpty {
                Text(state.isLoadingBranches ? "Loading branches…" : "No branches match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredBranches) { listing in
                        BranchRow(
                            listing: listing,
                            isCurrent: listing.isCurrent,
                            // Only the current row gets a changed-file badge —
                            // the count is computed against the working tree
                            // which only meaningfully describes HEAD's branch.
                            changedFileCount: listing.isCurrent ? state.changedFileCount : nil,
                            isSwitchDisabled: switchDisabled(for: listing),
                            switchDisabledReason: switchDisabledReason(for: listing),
                            isSwitching: state.isRunning(.switchBranch(listingID: listing.id)),
                            isAnyActionRunning: state.isAnyActionRunning,
                            onSwitch: { state.runSwitch(to: listing) },
                            onRename: listing.kind == .local
                                ? { branchPendingRename = listing }
                                : nil
                        )
                        Divider()
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var filteredBranches: [BranchListing] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return state.branches }
        return state.branches.filter {
            $0.displayName.lowercased().contains(trimmed)
        }
    }

    private var branchNames: [String] {
        state.branches.map(\.displayName)
    }

    /// Just the local branch names, used by the rename sheet for client-side
    /// collision detection. Remote-tracking refs don't matter here because
    /// `git branch -m` only conflicts with other local branches.
    private var localBranchNames: [String] {
        state.branches.compactMap { $0.kind == .local ? $0.shortName : nil }
    }

    private var hasUpstreamForCurrent: Bool {
        // The dashboard's branchSync probe already tells us whether the
        // current branch has an upstream — reuse it instead of reaching back
        // into git from the section.
        switch health.branchSync {
        case .upToDate, .ahead, .behind, .diverged: return true
        case .noUpstream, .detached, .none: return false
        }
    }

    private var commitDisabled: Bool {
        // Detached HEAD commits are technically valid but produce dangling
        // history that surprises users — block the action and explain why.
        if health.currentBranch == nil { return true }
        // Nothing to commit: the count probe ran and reported a clean tree.
        if let n = state.changedFileCount, n == 0 { return true }
        return false
    }

    private var commitDisabledReason: String? {
        if health.currentBranch == nil {
            return "HEAD is detached — switch to a branch before committing."
        }
        if let n = state.changedFileCount, n == 0 {
            return "Working tree is clean — nothing to commit."
        }
        return nil
    }

    private func switchDisabled(for listing: BranchListing) -> Bool {
        if listing.isCurrent { return true }
        if health.workingTree == .dirty { return true }
        return false
    }

    private func switchDisabledReason(for listing: BranchListing) -> String? {
        if listing.isCurrent { return "Already on this branch." }
        if health.workingTree == .dirty {
            return "Working tree has uncommitted changes — commit or stash first."
        }
        return nil
    }
}

/// One row in the branches list. Pulled out so we can attach hover state and
/// keep the section code readable.
private struct BranchRow: View {
    let listing: BranchListing
    let isCurrent: Bool
    /// Files-changed indicator. Non-nil only on the current branch row. `0`
    /// renders nothing (clean tree), positive values render the badge.
    let changedFileCount: Int?
    let isSwitchDisabled: Bool
    let switchDisabledReason: String?
    /// `true` when *this* row's switch is currently running. Drives the
    /// per-row spinner so the user can see which branch is being switched to
    /// even when multiple rows look similar.
    let isSwitching: Bool
    /// `true` when any action anywhere in the section is running. Used to
    /// blanket-disable other rows' Switch buttons so the user can't queue a
    /// second working-tree mutation against the same checkout.
    let isAnyActionRunning: Bool
    let onSwitch: () -> Void
    /// `nil` when rename isn't supported for this row (i.e. remote-tracking
    /// refs). When present, surfaced both in the context menu and as an
    /// overflow menu next to the Switch button so the action is discoverable
    /// even for users who don't reach for right-click.
    let onRename: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(iconStyle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(listing.displayName)
                        .font(.body.monospaced())
                    if isCurrent {
                        Text("current")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(.tint)
                    }
                    if let n = changedFileCount, n > 0 {
                        // Orange badge to draw the eye: an uncommitted-changes
                        // count is the "you have work to commit" signal and
                        // shouldn't blend in with the neutral "current" pill.
                        Text("\(n) changed")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                            .help("\(n) file\(n == 1 ? "" : "s") with uncommitted changes")
                    }
                }
                if let upstream = listing.upstream {
                    Text("→ \(upstream)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onSwitch) {
                if isSwitching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Switching…")
                    }
                } else {
                    Text(isCurrent ? "Current" : (listing.kind == .local ? "Switch" : "Check out"))
                }
            }
            .controlSize(.small)
            // Disable while any action runs so a second switch can't be
            // queued. The currently-switching row keeps showing the spinner
            // because `isSwitching` short-circuits the visual treatment.
            .disabled(isSwitchDisabled || (isAnyActionRunning && !isSwitching))
            .help(isSwitching ? "Switching…" : (switchDisabledReason ?? ""))
            if let onRename {
                // Overflow menu next to the Switch button so the action is
                // discoverable without forcing users to know about right-click.
                Menu {
                    Button("Rename…", action: onRename)
                        .disabled(isAnyActionRunning)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isAnyActionRunning)
                .help("More actions for \(listing.displayName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.05) : Color.clear)
        .contextMenu {
            if let onRename {
                Button("Rename “\(listing.displayName)”…", action: onRename)
            }
        }
    }

    private var icon: String {
        switch listing.kind {
        case .local: return isCurrent ? "checkmark.circle.fill" : "point.3.connected.trianglepath.dotted"
        case .remote: return "cloud"
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch listing.kind {
        case .local: return isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
        case .remote: return AnyShapeStyle(.secondary)
        }
    }
}

/// Sheet for creating a new branch. Lives next to `BranchesSection` because
/// it's the only thing that presents it; promoting it to its own file isn't
/// worth the cost until a second caller appears.
private struct NewBranchSheet: View {
    var baseSuggestions: [String]
    var defaultBase: String
    var onCancel: () -> Void
    var onCreate: (_ name: String, _ base: String?, _ checkout: Bool) -> Void

    @State private var name: String = ""
    @State private var base: String = ""
    @State private var checkoutAfterCreate: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                TextField("feature/awesome", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Base (leave empty for current HEAD)")
                    .font(.subheadline)
                TextField(defaultBase.isEmpty ? "HEAD" : defaultBase, text: $base)
                    .textFieldStyle(.roundedBorder)
                if !baseSuggestions.isEmpty {
                    Menu("Pick from existing branch…") {
                        ForEach(baseSuggestions, id: \.self) { suggestion in
                            Button(suggestion) { base = suggestion }
                        }
                    }
                    .controlSize(.small)
                }
            }

            Toggle("Check out new branch immediately", isOn: $checkoutAfterCreate)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create") {
                    onCreate(name, base.isEmpty ? nil : base, checkoutAfterCreate)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

/// Sheet for renaming a local branch. Surfaces a textfield seeded with the
/// original name so common edits (typo, capitalization) are one or two key
/// presses. Does client-side collision detection against the current list of
/// local branches; git's own check is still authoritative — this just gives
/// the user a faster signal before they click Rename.
private struct RenameBranchSheet: View {
    var originalName: String
    var existingLocalNames: [String]
    var onCancel: () -> Void
    var onRename: (_ newName: String) -> Void

    @State private var newName: String

    init(
        originalName: String,
        existingLocalNames: [String],
        onCancel: @escaping () -> Void,
        onRename: @escaping (_ newName: String) -> Void
    ) {
        self.originalName = originalName
        self.existingLocalNames = existingLocalNames
        self.onCancel = onCancel
        self.onRename = onRename
        _newName = State(initialValue: originalName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Branch")
                .font(.headline)
            Text("Renaming “\(originalName)”")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("New name")
                    .font(.subheadline)
                TextField(originalName, text: $newName)
                    .textFieldStyle(.roundedBorder)
                if let problem = validationProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rename") {
                    onRename(newName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationProblem != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    /// Lightweight pre-validation. Doesn't try to mirror every git refname
    /// rule (that's git's job and it errors clearly in the sheet) — just
    /// catches the most common mistakes before they reach the shell.
    private var validationProblem: String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name can't be empty." }
        if trimmed == originalName { return "New name is the same as the current name." }
        if trimmed.contains(" ") { return "Branch names can't contain spaces." }
        if existingLocalNames.contains(trimmed) {
            return "A local branch named “\(trimmed)” already exists."
        }
        return nil
    }
}

/// Sheet for composing a commit message. v1 keeps it intentionally minimal:
/// a single-line subject (required) and an optional multi-line description.
/// All changed files are staged automatically by `git add -A`; there's no
/// per-file picker in this slice.
private struct CommitSheet: View {
    var branch: String?
    var changedFileCount: Int
    var onCancel: () -> Void
    var onCommit: (_ subject: String, _ body: String?) -> Void

    @State private var subject: String = ""
    @State private var messageBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 4) {
                Text("Subject")
                    .font(.subheadline)
                TextField("Short description (required)", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)")
                    .font(.subheadline)
                TextEditor(text: $messageBody)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Commit") {
                    let trimmedBody = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCommit(subject, trimmedBody.isEmpty ? nil : trimmedBody)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Commit")
                .font(.headline)
            // Surface what we're about to stage so the user knows there's no
            // surprise selection happening behind the scenes.
            HStack(spacing: 6) {
                if let branch {
                    Text("on \(branch)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("• \(changedFileCount) file\(changedFileCount == 1 ? "" : "s") to stage")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    BranchesSection(
        state: {
            let state = BranchesState(
                project: Project(
                    commonDirectoryPath: "/tmp/.git",
                    primaryCheckoutPath: "/tmp",
                    displayName: "demo"
                ),
                gitClient: nil,
                dashboard: nil
            )
            return state
        }(),
        health: ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: .upToDate,
            worktreeCount: 1,
            gitHub: nil,
            lastRefreshedAt: Date()
        )
    )
    .padding()
}
