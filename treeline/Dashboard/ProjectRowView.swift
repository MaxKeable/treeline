import SwiftUI

struct ProjectRowView: View {
    let project: Project
    let health: ProjectHealth
    var isRefreshing: Bool = false
    var isStale: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.displayName)
                        .font(.headline)
                    if isRefreshing && health.lastRefreshedAt != nil {
                        // Re-refresh while a previous snapshot is on screen —
                        // a small spinner reassures the user that data is
                        // being updated without flashing the row back to
                        // "loading".
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(Text("Refreshing"))
                    }
                    if isStale {
                        Label("Stale", systemImage: "clock.badge.exclamationmark")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .help("Dashboard data hasn't been refreshed recently")
                            .accessibilityLabel(Text("Stale data"))
                    }
                    if case .degraded(let reason) = health.status {
                        Label("Degraded", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help(reason)
                            .accessibilityLabel(Text("Degraded: \(reason)"))
                    }
                }
                Text(project.primaryCheckoutPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                healthRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var healthRow: some View {
        switch health.status {
        case .loading where health.lastRefreshedAt == nil:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading health…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .degraded(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
        default:
            HStack(spacing: 12) {
                branchLabel
                workingTreeLabel
                syncLabel
                worktreeCountLabel
                refreshedAtLabel
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var syncLabel: some View {
        // Detached HEAD is already communicated by `branchLabel`, so skip the
        // duplicate badge when sync state is just confirming that.
        if case .detached = health.branchSync {
            EmptyView()
        } else if let sync = health.branchSync {
            Label(sync.displayLabel, systemImage: sync.systemImageName)
                .foregroundStyle(syncTint(sync))
        } else if health.status == .ready {
            Label("unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func syncTint(_ sync: BranchSync) -> Color {
        switch sync {
        case .upToDate: return .green
        case .ahead, .behind: return .blue
        case .diverged: return .orange
        case .noUpstream, .detached: return .secondary
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        if let branch = health.currentBranch {
            Label(branch, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
        } else if health.status == .ready {
            // Ready but no branch name → detached HEAD.
            Label("detached", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var workingTreeLabel: some View {
        switch health.workingTree {
        case .clean:
            Label("clean", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .dirty:
            Label("dirty", systemImage: "pencil.circle.fill")
                .foregroundStyle(.orange)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var worktreeCountLabel: some View {
        if let count = health.worktreeCount {
            Label("\(count)", systemImage: "rectangle.stack")
                .accessibilityLabel(Text("\(count) worktrees"))
        }
    }

    @ViewBuilder
    private var refreshedAtLabel: some View {
        if let date = health.lastRefreshedAt {
            Text(date, format: .relative(presentation: .named))
                .accessibilityLabel(Text("Last refreshed \(date.formatted(.relative(presentation: .named)))"))
        }
    }
}

#Preview("Ready") {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/Users/maxkeable/kea-software/my-tools/treeline/.git",
            primaryCheckoutPath: "/Users/maxkeable/kea-software/my-tools/treeline",
            displayName: "treeline"
        ),
        health: ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: .ahead(2),
            worktreeCount: 2,
            lastRefreshedAt: Date()
        )
    )
    .padding()
}

#Preview("Degraded") {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/Users/maxkeable/gone/.git",
            primaryCheckoutPath: "/Users/maxkeable/gone",
            displayName: "gone"
        ),
        health: ProjectHealth(
            status: .degraded(reason: "Primary checkout is missing or no longer a directory"),
            currentBranch: nil,
            workingTree: nil,
            branchSync: nil,
            worktreeCount: nil,
            lastRefreshedAt: Date()
        )
    )
    .padding()
}

#Preview("Loading") {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "x"
        ),
        health: .loading
    )
    .padding()
}

#Preview("Stale") {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "treeline"
        ),
        health: ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: .upToDate,
            worktreeCount: 1,
            lastRefreshedAt: Date(timeIntervalSinceNow: -600)
        ),
        isRefreshing: false,
        isStale: true
    )
    .padding()
}

#Preview("Refreshing") {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "treeline"
        ),
        health: ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: .upToDate,
            worktreeCount: 1,
            lastRefreshedAt: Date()
        ),
        isRefreshing: true,
        isStale: false
    )
    .padding()
}
