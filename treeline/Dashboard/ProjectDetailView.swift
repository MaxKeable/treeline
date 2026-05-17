import SwiftUI

/// Placeholder Project detail view. Later slices will replace the body with
/// branch state, worktrees, sync status, and actions; for now it confirms
/// the selection so launch can restore the last active Project.
struct ProjectDetailView: View {
    let project: Project

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text(project.displayName)
                .font(.title)
                .fontWeight(.semibold)
            Text(project.primaryCheckoutPath)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(project.displayName)
    }
}

#Preview {
    NavigationStack {
        ProjectDetailView(
            project: Project(
                commonDirectoryPath: "/Users/maxkeable/kea-software/my-tools/treeline/.git",
                primaryCheckoutPath: "/Users/maxkeable/kea-software/my-tools/treeline",
                displayName: "treeline"
            )
        )
    }
}
