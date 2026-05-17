import SwiftUI
import AppKit

struct ProjectsDashboardView: View {
    @Bindable var state: ProjectsDashboardState
    var onAddProject: (() -> Void)?

    var body: some View {
        NavigationStack(path: activeProjectPath) {
            dashboardBody
                .navigationDestination(for: Project.self) { project in
                    ProjectDetailView(project: project)
                }
        }
    }

    /// Drives navigation from the persisted active-project state. The stack
    /// has at most one entry (the active Project); popping back to the root
    /// clears the active Project so the next launch shows the dashboard.
    private var activeProjectPath: Binding<[Project]> {
        Binding(
            get: { state.activeProject.map { [$0] } ?? [] },
            set: { newPath in state.setActiveProject(newPath.last) }
        )
    }

    private var dashboardBody: some View {
        Group {
            if state.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: triggerAdd) {
                    Label("Add Project", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await state.refreshAllHealth() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.isEmpty)
                .help("Refresh local health for every Project")
            }
        }
        .task {
            // Initial refresh on dashboard appear. Each Project resolves
            // independently — one failing repo never blocks the others.
            await state.refreshAllHealth()
        }
        .alert(
            "Couldn't add Project",
            isPresented: Binding(
                get: { state.lastAddError != nil },
                set: { if !$0 { state.lastAddError = nil } }
            ),
            presenting: state.lastAddError
        ) { _ in
            Button("OK", role: .cancel) { state.lastAddError = nil }
        } message: { message in
            Text(message)
        }
        .overlay(alignment: .top) {
            attachedNoticeBanner
        }
        .animation(.easeInOut(duration: 0.2), value: state.attachedNotice)
    }

    /// Transient banner shown when `addProject` attached the selected path to
    /// an existing Project. Auto-dismisses so the user can keep working
    /// without clicking anything.
    @ViewBuilder
    private var attachedNoticeBanner: some View {
        if let notice = state.attachedNotice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if state.attachedNotice == notice {
                        state.attachedNotice = nil
                    }
                }
                .accessibilityLabel(Text(notice))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tree")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Projects yet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Add a Project to start tracking its branches, worktrees, and sync state.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: triggerAdd) {
                Label("Add Project", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectList: some View {
        List(state.projects) { project in
            NavigationLink(value: project) {
                ProjectRowView(project: project, health: state.health(for: project))
            }
            .contextMenu {
                Button("Refresh Health") {
                    Task { await state.refreshHealth(for: project) }
                }
            }
        }
    }

    private func triggerAdd() {
        if let onAddProject {
            onAddProject()
            return
        }
        presentFolderPicker()
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder inside a git checkout"
        panel.prompt = "Add Project"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    _ = try await state.addProject(at: url)
                } catch {
                    state.lastAddError = String(describing: error)
                }
            }
        }
    }
}

#Preview("Empty") {
    ProjectsDashboardView(state: ProjectsDashboardState())
}

#Preview("Populated") {
    ProjectsDashboardView(
        state: ProjectsDashboardState(projects: [
            Project(
                commonDirectoryPath: "/Users/maxkeable/kea-software/my-tools/treeline/.git",
                primaryCheckoutPath: "/Users/maxkeable/kea-software/my-tools/treeline",
                displayName: "treeline"
            ),
            Project(
                commonDirectoryPath: "/Users/maxkeable/kea-software/kea-website/.git",
                primaryCheckoutPath: "/Users/maxkeable/kea-software/kea-website",
                displayName: "kea-website"
            )
        ])
    )
}
