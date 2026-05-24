import AppKit
import Foundation

struct DashboardFolderPickerRequest: Equatable {
    let title: String
    let prompt: String
}

protocol DashboardFolderPicking {
    @MainActor
    func chooseFolder(for request: DashboardFolderPickerRequest) async -> URL?
}

struct AppKitDashboardFolderPicker: DashboardFolderPicking {
    func chooseFolder(for request: DashboardFolderPickerRequest) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = request.title
            panel.prompt = request.prompt

            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

@MainActor
struct DashboardCoordinator {
    let state: ProjectsDashboardState
    let folderPicker: any DashboardFolderPicking

    init(
        state: ProjectsDashboardState,
        folderPicker: any DashboardFolderPicking = AppKitDashboardFolderPicker()
    ) {
        self.state = state
        self.folderPicker = folderPicker
    }

    func addProjectFromPicker() async {
        guard let url = await folderPicker.chooseFolder(for: .addProject) else { return }
        await addProject(at: url)
    }

    func addProject(at url: URL) async {
        do {
            _ = try await state.addProject(at: url)
        } catch {
            state.lastAddError = String(describing: error)
        }
    }

    func relocateProjectFromPicker(_ project: Project) async {
        let request = DashboardFolderPickerRequest.relocateProject(project)
        guard let url = await folderPicker.chooseFolder(for: request) else { return }
        await relocateProject(project, to: url)
    }

    func relocateProject(_ project: Project, to url: URL) async {
        do {
            _ = try await state.relocateProject(project, to: url)
        } catch let error as ProjectsDashboardState.RelocateProjectError {
            state.lastRelocateError = Self.message(for: error)
        } catch {
            state.lastRelocateError = String(describing: error)
        }
    }

    func changePrimaryCheckout(_ project: Project, to path: String) async -> String? {
        do {
            _ = try await state.changePrimaryCheckout(
                project,
                to: URL(fileURLWithPath: path)
            )
            if let updated = state.projects.first(where: { $0.id == project.id }) {
                await state.refreshHealth(for: updated)
            }
            return nil
        } catch let error as ProjectsDashboardState.ChangePrimaryCheckoutError {
            return Self.message(for: error)
        } catch {
            return String(describing: error)
        }
    }

    static func message(
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

    static func message(for error: ProjectsDashboardState.RelocateProjectError) -> String {
        switch error {
        case .notConfigured:
            return "Treeline isn't configured to access git, so the Project can't be relocated."
        case .invalidPath(let reason):
            return "That folder isn't inside a git repository.\n\n\(reason)"
        case .repositoryMismatch(let message):
            return message
        }
    }
}

extension DashboardFolderPickerRequest {
    static let addProject = DashboardFolderPickerRequest(
        title: "Choose a folder inside a git checkout",
        prompt: "Add Project"
    )

    static func relocateProject(_ project: Project) -> DashboardFolderPickerRequest {
        DashboardFolderPickerRequest(
            title: "Choose the new folder for “\(project.displayName)”",
            prompt: "Relocate"
        )
    }
}
