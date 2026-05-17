import SwiftUI
import AppKit

struct ProjectsDashboardView: View {
    @Bindable var state: ProjectsDashboardState
    var onAddProject: (() -> Void)?
    /// Project queued for a destructive Remove confirmation. Bound to the
    /// confirmation dialog so the action only fires after the user agrees.
    @State private var projectPendingRemoval: Project?
    /// User-facing message for the most recent failed "change primary
    /// checkout" attempt. Surfaced in its own alert so the wording stays
    /// specific to this action instead of being lumped in with relocate.
    @State private var changePrimaryError: String?

    var body: some View {
        NavigationStack(path: activeProjectPath) {
            dashboardBody
                .navigationDestination(for: Project.self) { project in
                    ProjectDetailView(project: project, state: state)
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
            // Initial refresh on dashboard appear, after Projects have been
            // loaded from the store. Each Project resolves independently —
            // one failing repo never blocks the others.
            await state.refreshAllHealth()
        }
        .onChange(of: state.activeProjectID) { _, newValue in
            // Navigating into a Project detail counts as switching screens
            // for the purposes of the PRD: the dashboard isn't on screen so
            // any in-flight refreshes should be dropped.
            if newValue != nil { state.cancelAllRefreshes() }
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
        .alert(
            "Couldn't relocate Project",
            isPresented: Binding(
                get: { state.lastRelocateError != nil },
                set: { if !$0 { state.lastRelocateError = nil } }
            ),
            presenting: state.lastRelocateError
        ) { _ in
            Button("OK", role: .cancel) { state.lastRelocateError = nil }
        } message: { message in
            Text(message)
        }
        .overlay(alignment: .top) {
            attachedNoticeBanner
        }
        .animation(.easeInOut(duration: 0.2), value: state.attachedNotice)
        .confirmationDialog(
            "Remove Project?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            presenting: projectPendingRemoval
        ) { project in
            Button("Remove “\(project.displayName)”", role: .destructive) {
                state.removeProject(project)
                projectPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
        } message: { project in
            Text("This only removes the Project from Treeline. Files at \(project.primaryCheckoutPath) are not touched.")
        }
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
            let health = state.health(for: project)
            let isMissing = health.status == .missing
            Group {
                if isMissing {
                    // Missing rows don't navigate — there's no detail to show
                    // until the user repairs or removes the Project. Surface
                    // Relocate / Remove inline so the fix path is one click.
                    HStack(alignment: .top, spacing: 12) {
                        ProjectRowView(
                            project: project,
                            health: health,
                            isRefreshing: state.isRefreshing(project),
                            isStale: state.isStale(for: project)
                        )
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Relocate…") { presentRelocatePicker(for: project) }
                            Button("Remove…", role: .destructive) {
                                projectPendingRemoval = project
                            }
                        }
                        .controlSize(.small)
                    }
                } else {
                    NavigationLink(value: project) {
                        ProjectRowView(
                            project: project,
                            health: health,
                            isRefreshing: state.isRefreshing(project),
                            isStale: state.isStale(for: project)
                        )
                    }
                }
            }
            .contextMenu {
                Button("Refresh Health") {
                    Task { await state.refreshHealth(for: project) }
                }
                primaryCheckoutMenu(for: project)
                Button("Relocate…") { presentRelocatePicker(for: project) }
                Button("Remove…", role: .destructive) {
                    projectPendingRemoval = project
                }
            }
        }
    }

    /// Submenu of every known checkout/worktree the user can promote to
    /// primary. The current primary is shown with a checkmark and isn't
    /// re-selectable. Hidden entirely when there's only one candidate so
    /// the menu doesn't show an empty / dead submenu.
    @ViewBuilder
    private func primaryCheckoutMenu(for project: Project) -> some View {
        if project.checkoutPaths.count > 1 {
            Menu("Primary Checkout") {
                ForEach(project.checkoutPaths, id: \.self) { path in
                    Button {
                        Task { await changePrimaryCheckout(project, to: path) }
                    } label: {
                        if path == project.primaryCheckoutPath {
                            Label(path, systemImage: "checkmark")
                        } else {
                            Text(path)
                        }
                    }
                    .disabled(path == project.primaryCheckoutPath)
                }
            }
        }
    }

    private func changePrimaryCheckout(_ project: Project, to path: String) async {
        do {
            _ = try await state.changePrimaryCheckout(
                project,
                to: URL(fileURLWithPath: path)
            )
            // Re-probe immediately so the row reflects the new primary's
            // branch / sync / GitHub state without waiting for the next
            // dashboard-wide refresh.
            if let updated = state.projects.first(where: { $0.id == project.id }) {
                await state.refreshHealth(for: updated)
            }
        } catch let error as ProjectsDashboardState.ChangePrimaryCheckoutError {
            changePrimaryError = changePrimaryMessage(for: error)
        } catch {
            changePrimaryError = String(describing: error)
        }
    }

    private func changePrimaryMessage(
        for error: ProjectsDashboardState.ChangePrimaryCheckoutError
    ) -> String {
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

    private func triggerAdd() {
        if let onAddProject {
            onAddProject()
            return
        }
        presentFolderPicker()
    }

    private func presentRelocatePicker(for project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose the new folder for “\(project.displayName)”"
        panel.prompt = "Relocate"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    _ = try await state.relocateProject(project, to: url)
                } catch let error as ProjectsDashboardState.RelocateProjectError {
                    state.lastRelocateError = relocateMessage(for: error)
                } catch {
                    state.lastRelocateError = String(describing: error)
                }
            }
        }
    }

    private func relocateMessage(for error: ProjectsDashboardState.RelocateProjectError) -> String {
        switch error {
        case .notConfigured:
            return "Treeline isn't configured to access git, so the Project can't be relocated."
        case .invalidPath(let reason):
            return "That folder isn't inside a git repository.\n\n\(reason)"
        case .repositoryMismatch(let message):
            return message
        }
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
