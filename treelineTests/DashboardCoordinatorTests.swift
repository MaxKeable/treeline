import Foundation
import Testing
@testable import treeline

@MainActor
struct DashboardCoordinatorTests {
    @Test func addProjectFromPickerUsesAddConfigurationAndStoresError() async {
        let picker = FakeDashboardFolderPicker(
            selectedURL: URL(fileURLWithPath: "/tmp/not-configured")
        )
        let state = ProjectsDashboardState()
        let coordinator = DashboardCoordinator(state: state, folderPicker: picker)

        await coordinator.addProjectFromPicker()

        #expect(picker.requests == [.addProject])
        #expect(state.lastAddError == "notConfigured")
    }

    @Test func cancelledAddPickerDoesNotMutateState() async {
        let picker = FakeDashboardFolderPicker(selectedURL: nil)
        let state = ProjectsDashboardState()
        let coordinator = DashboardCoordinator(state: state, folderPicker: picker)

        await coordinator.addProjectFromPicker()

        #expect(picker.requests == [.addProject])
        #expect(state.lastAddError == nil)
        #expect(state.projects.isEmpty)
    }

    @Test func relocateFromPickerUsesProjectConfigurationAndStoresMappedError() async {
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let picker = FakeDashboardFolderPicker(
            selectedURL: URL(fileURLWithPath: "/Users/dev/acme-fixed")
        )
        let state = ProjectsDashboardState(projects: [project])
        let coordinator = DashboardCoordinator(state: state, folderPicker: picker)

        await coordinator.relocateProjectFromPicker(project)

        #expect(picker.requests == [.relocateProject(project)])
        #expect(state.lastRelocateError == "Treeline isn't configured to access git, so the Project can't be relocated.")
    }

    @Test func changePrimaryCheckoutReturnsMappedErrors() async {
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme",
            checkoutPaths: ["/Users/dev/acme", "/Users/dev/acme-wt"]
        )
        let state = ProjectsDashboardState(projects: [project])
        let coordinator = DashboardCoordinator(state: state)

        let message = await coordinator.changePrimaryCheckout(
            project,
            to: "/Users/dev/acme-wt"
        )

        #expect(message == "Treeline isn't configured to access git, so the primary checkout can't be changed.")
    }

    @Test func messageMappingPreservesExistingDashboardCopy() {
        #expect(
            DashboardCoordinator.message(
                for: ProjectsDashboardState.ChangePrimaryCheckoutError.unknownCheckout(
                    path: "/tmp/other"
                )
            ) == "“/tmp/other” isn't one of this Project's known checkouts."
        )
        #expect(
            DashboardCoordinator.message(
                for: ProjectsDashboardState.ChangePrimaryCheckoutError.missingFolder(
                    path: "/tmp/gone"
                )
            ) == "“/tmp/gone” no longer exists on disk."
        )
        #expect(
            DashboardCoordinator.message(
                for: ProjectsDashboardState.RelocateProjectError.invalidPath(
                    reason: "fatal: not a git repository"
                )
            ) == "That folder isn't inside a git repository.\n\nfatal: not a git repository"
        )
    }
}

private final class FakeDashboardFolderPicker: DashboardFolderPicking {
    private let selectedURL: URL?
    private(set) var requests: [DashboardFolderPickerRequest] = []

    init(selectedURL: URL?) {
        self.selectedURL = selectedURL
    }

    func chooseFolder(for request: DashboardFolderPickerRequest) async -> URL? {
        requests.append(request)
        return selectedURL
    }
}
