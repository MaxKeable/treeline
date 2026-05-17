import SwiftUI

@main
struct treelineApp: App {
    @State private var dashboardState: ProjectsDashboardState = {
        let gitClient = GitClient(runner: CLIRunner())
        if let url = try? ProjectStore.defaultURL() {
            return ProjectsDashboardState(store: ProjectStore(fileURL: url), gitClient: gitClient)
        }
        return ProjectsDashboardState(gitClient: gitClient)
    }()

    var body: some Scene {
        WindowGroup {
            ProjectsDashboardView(state: dashboardState)
        }
    }
}
