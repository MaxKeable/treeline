import Foundation

/// One branch entry surfaced in the Project detail branches list.
///
/// Local and remote-tracking refs share the same row shape because the user
/// interacts with them the same way (click to switch / check out). The two are
/// distinguished by `kind` so the row can label remote entries with their
/// remote name and so switching to a remote creates a local tracking branch
/// rather than detaching HEAD.
struct BranchListing: Identifiable, Equatable, Sendable, Hashable {
    enum Kind: Equatable, Sendable, Hashable {
        case local
        case remote(remote: String)
    }

    /// Full ref (e.g. `refs/heads/main`, `refs/remotes/origin/main`). Stable
    /// across renames so SwiftUI can keep row identity through a refresh.
    let id: String
    /// Display name users see in the list. For locals this is the branch
    /// name; for remotes this is `<remote>/<branch>`.
    let displayName: String
    /// Just the branch portion, no remote prefix. Used when creating a local
    /// tracking branch from a remote entry.
    let shortName: String
    let kind: Kind
    /// Configured upstream short name for locals (e.g. `origin/main`). `nil`
    /// for remotes and for locals with no upstream.
    let upstream: String?
    /// `true` when this is the branch HEAD currently points at. Only one
    /// listing can be current at a time, and only for local entries.
    let isCurrent: Bool
}
