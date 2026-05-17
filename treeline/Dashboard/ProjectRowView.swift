import SwiftUI

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.headline)
                Text(project.primaryCheckoutPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    ProjectRowView(
        project: Project(
            commonDirectoryPath: "/Users/maxkeable/kea-software/my-tools/treeline/.git",
            primaryCheckoutPath: "/Users/maxkeable/kea-software/my-tools/treeline",
            displayName: "treeline"
        )
    )
    .padding()
}
