import Foundation

/// One git repository identity plus the checkouts and worktrees that belong
/// to it. `primaryCheckoutPath` is whichever checkout the user originally
/// added — it never changes when later worktrees or sibling checkouts get
/// attached to the same Project. Branch state and GitHub metadata will arrive
/// in later slices.
///
/// Project identity is the canonical git common directory path
/// (`git rev-parse --git-common-dir`), not the selected folder, the checkout
/// root, or GitHub metadata. Two checkouts that share the same common
/// directory are the same Project.
struct Project: Identifiable, Equatable, Hashable, Codable {
    var commonDirectoryPath: String
    var primaryCheckoutPath: String
    var displayName: String
    /// Every checkout or worktree path known to belong to this Project,
    /// canonicalized and de-duplicated. Always contains `primaryCheckoutPath`.
    /// Sorted so persisted JSON has a stable diff.
    var checkoutPaths: [String]

    var id: String { commonDirectoryPath }

    init(
        commonDirectoryPath: String,
        primaryCheckoutPath: String,
        displayName: String,
        checkoutPaths: [String] = []
    ) {
        self.commonDirectoryPath = commonDirectoryPath
        self.primaryCheckoutPath = primaryCheckoutPath
        self.displayName = displayName
        self.checkoutPaths = Self.normalize(checkoutPaths, primary: primaryCheckoutPath)
    }

    init(identity: GitIdentity, displayName: String? = nil, discoveredCheckouts: [URL] = []) {
        let primary = identity.checkoutRoot.path
        self.commonDirectoryPath = identity.commonDirectory.path
        self.primaryCheckoutPath = primary
        self.displayName = displayName ?? identity.checkoutRoot.lastPathComponent
        self.checkoutPaths = Self.normalize(
            discoveredCheckouts.map { $0.path },
            primary: primary
        )
    }

    enum CodingKeys: String, CodingKey {
        case commonDirectoryPath
        case primaryCheckoutPath
        case displayName
        case checkoutPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let commonDirectoryPath = try container.decode(String.self, forKey: .commonDirectoryPath)
        let primaryCheckoutPath = try container.decode(String.self, forKey: .primaryCheckoutPath)
        let displayName = try container.decode(String.self, forKey: .displayName)
        // Legacy (schema v1) payloads have no `checkoutPaths`; backfill from
        // the primary checkout so the invariant "primary is in the list"
        // holds even before the user adds a second worktree.
        let stored = try container.decodeIfPresent([String].self, forKey: .checkoutPaths) ?? []
        self.commonDirectoryPath = commonDirectoryPath
        self.primaryCheckoutPath = primaryCheckoutPath
        self.displayName = displayName
        self.checkoutPaths = Self.normalize(stored, primary: primaryCheckoutPath)
    }

    private static func normalize(_ paths: [String], primary: String) -> [String] {
        var unique = Set(paths)
        unique.insert(primary)
        return unique.sorted()
    }
}
