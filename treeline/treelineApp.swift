import SwiftUI

@main
struct treelineApp: App {
    @State private var dashboardState: ProjectsDashboardState = {
        let runner = CLIRunner()
        let gitClient = GitClient(runner: runner)
        let ghClient = GHClient(runner: runner)
        if let url = try? ProjectStore.defaultURL() {
            return ProjectsDashboardState(
                store: ProjectStore(fileURL: url),
                gitClient: gitClient,
                gitHubProbe: ghClient
            )
        }
        return ProjectsDashboardState(
            gitClient: gitClient,
            healthRefresher: ProjectHealthRefresher(gitClient: gitClient, gitHubProbe: ghClient)
        )
    }()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ProjectsDashboardView(state: dashboardState)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Regaining focus (or coming back from miniaturized
                        // / background) should produce fresh dashboard data
                        // without the user clicking refresh.
                        Task { await dashboardState.refreshAllHealth() }
                    case .inactive, .background:
                        // The user can no longer see the dashboard, so
                        // drop any work that would only matter on screen.
                        dashboardState.cancelAllRefreshes()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
