import Foundation

/// How the primary checkout sits relative to its upstream branch. Derived from
/// a single cheap `git status --porcelain=v2 --branch` call so the dashboard
/// can render sync risk without rev-walking history.
enum BranchSync: Equatable, Sendable {
    case upToDate
    case ahead(Int)
    case behind(Int)
    case diverged(ahead: Int, behind: Int)
    /// Branch exists but has no configured upstream — typical for local-only
    /// repositories and freshly-created branches.
    case noUpstream
    /// HEAD is detached, so there is no branch to compare against an upstream.
    case detached
}

extension BranchSync {
    /// Short label for the dashboard row. Sync state values are bounded, so
    /// the row uses these directly instead of formatting at the call site.
    var displayLabel: String {
        switch self {
        case .upToDate: return "up to date"
        case .ahead(let n): return "↑\(n)"
        case .behind(let n): return "↓\(n)"
        case .diverged(let a, let b): return "↑\(a) ↓\(b)"
        case .noUpstream: return "local only"
        case .detached: return "detached"
        }
    }

    /// SF Symbol name paired with `displayLabel`. Names are intentionally
    /// neutral so the row owns colour.
    var systemImageName: String {
        switch self {
        case .upToDate: return "equal.circle"
        case .ahead: return "arrow.up.circle"
        case .behind: return "arrow.down.circle"
        case .diverged: return "arrow.triangle.swap"
        case .noUpstream: return "personalhotspot.slash"
        case .detached: return "link.circle"
        }
    }
}

extension Optional where Wrapped == BranchSync {
    /// Display label when sync state is not known (probe failed or never ran).
    /// Keeps "unknown" rendering in one place so the row and tests agree.
    var dashboardDisplayLabel: String {
        self?.displayLabel ?? "unknown"
    }
}
