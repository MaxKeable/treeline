import Foundation

/// Optional GitHub metadata for a Project. Treeline stores this as a
/// secondary attribute — Project identity comes from the canonical git common
/// directory (see `Project`), not from GitHub. A repository with no GitHub
/// remote, no `gh` install, or no auth simply has no identity to record and
/// remains a fully usable local-only Project.
struct GitHubIdentity: Equatable, Hashable, NonSecretPersistable, Sendable {
    let owner: String
    let name: String

    var nameWithOwner: String { "\(owner)/\(name)" }
}
