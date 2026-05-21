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
            GitActionSheet(action: action) {
                // Allow dismissing even while running ("Hide") so the user
                // can keep working; the underlying Task continues and the
                // sheet will re-appear if they trigger another action only
                // after this one finishes (runAction guards on activeAction).
                if action.isFinished {
                    state.activeAction = nil
                } else {
                    state.activeAction = nil
                }
            }
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
            Button {
                state.runFetch()
            } label: { Label("Fetch", systemImage: "arrow.down.to.line") }

            Button {
                state.runPull()
            } label: { Label("Pull", systemImage: "arrow.down.circle") }
                .disabled(health.workingTree == .dirty)
                .help(health.workingTree == .dirty
                      ? "Working tree has uncommitted changes — commit or stash first."
                      : "git pull on the current branch")

            Button {
                isPresentingCommitSheet = true
            } label: { Label("Commit", systemImage: "tray.and.arrow.down") }
                .disabled(commitDisabled)
                .help(commitDisabledReason ?? "Stage all tracked + new files and commit")

            Button {
                state.runPush(
                    currentBranch: health.currentBranch,
                    hasUpstream: hasUpstreamForCurrent
                )
            } label: { Label("Push", systemImage: "arrow.up.circle") }
                .disabled(health.currentBranch == nil)
                .help(health.currentBranch == nil
                      ? "Detached HEAD — switch to a branch first."
                      : "git push (sets upstream automatically on first push)")

            Button {
                isPresentingNewBranchSheet = true
            } label: { Label("New Branch", systemImage: "plus.rectangle.on.folder") }
                // Default flow in the sheet is "create + check out", which
                // moves HEAD and therefore needs a clean tree. Block at the
                // button rather than letting the user fill out the sheet and
                // hit a dirty-tree error after the fact.
                .disabled(health.workingTree == .dirty)
                .help(health.workingTree == .dirty
                      ? "Working tree has uncommitted changes — commit or stash first."
                      : "Create a new branch off the current HEAD")

            Spacer()

            Button {
                Task { await state.refreshBranches() }
            } label: { Label("Refresh List", systemImage: "arrow.clockwise") }
                .help("Re-read the branch list with git for-each-ref")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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
                            onSwitch: { state.runSwitch(to: listing) }
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
    let onSwitch: () -> Void

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
                Text(isCurrent ? "Current" : (listing.kind == .local ? "Switch" : "Check out"))
            }
            .controlSize(.small)
            .disabled(isSwitchDisabled)
            .help(switchDisabledReason ?? "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.05) : Color.clear)
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
