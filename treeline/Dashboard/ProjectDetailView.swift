import SwiftUI

/// Placeholder Project detail view. Later slices will replace the body with
/// branch state, worktrees, sync status, and actions; for now it confirms
/// the selection so launch can restore the last active Project, and exposes
/// the action to switch which known checkout drives dashboard probes.
struct ProjectDetailView: View {
    let project: Project
    /// Optional dashboard state so the detail view can mutate primary
    /// checkout selection. `nil` in #Preview blocks where the project is
    /// rendered standalone.
    var state: ProjectsDashboardState?

    @State private var changePrimaryError: String?

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

            if project.checkoutPaths.count > 1 {
                primaryCheckoutPicker
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(project.displayName)
        .alert(
            "Couldn't change primary checkout",
            isPresented: Binding(
                get: { changePrimaryError != nil },
                set: { if !$0 { changePrimaryError = nil } }
            ),
            presenting: changePrimaryError
        ) { _ in
            Button("OK", role: .cancel) { changePrimaryError = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Lists every known checkout/worktree as a row the user can promote to
    /// primary. The current primary is selected and disabled so an accidental
    /// tap doesn't fire a redundant refresh.
    @ViewBuilder
    private var primaryCheckoutPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Primary checkout")
                .font(.headline)
            ForEach(project.checkoutPaths, id: \.self) { path in
                let isCurrent = path == project.primaryCheckoutPath
                Button {
                    Task { await select(path) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCurrent || state == nil)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func select(_ path: String) async {
        guard let state else { return }
        do {
            _ = try await state.changePrimaryCheckout(
                project,
                to: URL(fileURLWithPath: path)
            )
            if let updated = state.projects.first(where: { $0.id == project.id }) {
                await state.refreshHealth(for: updated)
            }
        } catch let error as ProjectsDashboardState.ChangePrimaryCheckoutError {
            changePrimaryError = message(for: error)
        } catch {
            changePrimaryError = String(describing: error)
        }
    }

    private func message(for error: ProjectsDashboardState.ChangePrimaryCheckoutError) -> String {
        switch error {
        case .notConfigured:
            return "Treeline isn't configured to access git, so the primary checkout can't be changed."
        case .projectNotFound:
            return "That Project is no longer tracked."
        case .unknownCheckout(let path):
            return "“\(path)” isn't one of this Project's known checkouts."
        case .missingFolder(let path):
            return "“\(path)” no longer exists on disk."
        case .repositoryMismatch(let message):
            return message
        }
    }
}

#Preview {
    NavigationStack {
        ProjectDetailView(
            project: Project(
                commonDirectoryPath: "/Users/maxkeable/kea-software/my-tools/treeline/.git",
                primaryCheckoutPath: "/Users/maxkeable/kea-software/my-tools/treeline",
                displayName: "treeline",
                checkoutPaths: [
                    "/Users/maxkeable/kea-software/my-tools/treeline",
                    "/Users/maxkeable/kea-software/my-tools/treeline-feat"
                ]
            )
        )
    }
}
