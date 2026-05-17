import Foundation

/// Locally observable health for a Project's primary checkout. V1 sticks to
/// the cheap git calls the PRD allows on the dashboard — branch, working tree
/// cleanliness, worktree count, and the timestamp of the last successful (or
/// degraded) refresh. Ahead/behind, PR counts, and deep graph state are
/// deliberately deferred to Project detail.
///
/// All fields are optional because a Project can be partially observable: the
/// path may be missing, git may be unavailable, or a single command may fail
/// while others succeed conceptually. The view surfaces what is known and the
/// degraded reason explains the rest.
struct ProjectHealth: Equatable, Sendable {
    enum WorkingTree: Equatable, Sendable {
        case clean
        case dirty
    }

    enum Status: Equatable, Sendable {
        case loading
        case ready
        case degraded(reason: String)
        /// The Project's primary checkout path no longer points at a directory
        /// (folder moved, drive disconnected, etc.). Distinct from `.degraded`
        /// so the dashboard can offer Relocate / Remove instead of suggesting
        /// the repo itself is sick.
        case missing
    }

    var status: Status
    /// Branch on the primary checkout. `nil` means HEAD is detached or the
    /// branch couldn't be measured (e.g. degraded). The view should fall back
    /// to "(detached)" or hide the row.
    var currentBranch: String?
    var workingTree: WorkingTree?
    /// Sync state vs. the configured upstream. `nil` means sync state couldn't
    /// be determined (probe failed, ancient git, etc.); the row should render
    /// it as "unknown".
    var branchSync: BranchSync?
    var worktreeCount: Int?
    /// Optional GitHub capability for the primary checkout. `nil` means the
    /// capability hasn't been probed yet (e.g. the loading sentinel); a
    /// concrete `.unavailable(reason:)` means we asked and the answer is no.
    /// Defaulted so older call sites (tests and the loading sentinel) keep
    /// compiling without naming a GitHub field they don't care about.
    var gitHub: GitHubCapability? = nil
    var lastRefreshedAt: Date?

    static let loading = ProjectHealth(
        status: .loading,
        currentBranch: nil,
        workingTree: nil,
        branchSync: nil,
        worktreeCount: nil,
        gitHub: nil,
        lastRefreshedAt: nil
    )
}
