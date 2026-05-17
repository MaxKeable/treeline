import Foundation

/// Per-Project GitHub capability state for the dashboard. GitHub is treated as
/// an optional capability — local-only repos, missing `gh`, auth failures, and
/// network errors all resolve to `.unavailable(reason:)` rather than degrading
/// the Project itself. The dashboard surfaces the reason as a non-blocking
/// warning so the local git workflow keeps working.
enum GitHubCapability: Equatable, Sendable {
    /// The primary checkout is associated with a GitHub repository that `gh`
    /// can talk to. `openPullRequestCount` is `nil` when the identity probe
    /// succeeded but the PR-count probe failed — the row shows the GitHub
    /// badge without a count rather than collapsing back to "unavailable".
    case capable(identity: GitHubIdentity, openPullRequestCount: Int?)
    /// GitHub features are unavailable for this Project right now. The reason
    /// is user-readable and goes into the row's capability tooltip.
    case unavailable(reason: String)
}
