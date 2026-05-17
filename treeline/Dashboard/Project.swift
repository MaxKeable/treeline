import Foundation

/// One git repository identity plus the checkouts and worktrees that belong
/// to it. For this slice the model holds the originally added checkout as the
/// primary checkout; additional checkouts, worktrees, branch state, and
/// GitHub metadata will arrive in later slices.
///
/// Project identity is the canonical git common directory path
/// (`git rev-parse --git-common-dir`), not the selected folder, the checkout
/// root, or GitHub metadata. Two checkouts that share the same common
/// directory are the same Project.
struct Project: Identifiable, Equatable, Hashable, Codable {
    var commonDirectoryPath: String
    var primaryCheckoutPath: String
    var displayName: String

    var id: String { commonDirectoryPath }

    init(commonDirectoryPath: String, primaryCheckoutPath: String, displayName: String) {
        self.commonDirectoryPath = commonDirectoryPath
        self.primaryCheckoutPath = primaryCheckoutPath
        self.displayName = displayName
    }

    init(identity: GitIdentity, displayName: String? = nil) {
        self.commonDirectoryPath = identity.commonDirectory.path
        self.primaryCheckoutPath = identity.checkoutRoot.path
        self.displayName = displayName ?? identity.checkoutRoot.lastPathComponent
    }
}
