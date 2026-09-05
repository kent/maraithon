import CoreSpotlight
import SwiftUI

@main
struct MaraithonApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Maraithon", id: "main") {
            RootWindow()
                .environment(environment)
                .frame(minWidth: 720, minHeight: 500)
                .onAppear {
                    environment.eventLog.info(
                        "app.launched",
                        source: .system,
                        payload: ["version": Bundle.main.shortVersion]
                    )
                }
                .onOpenURL { url in
                    environment.handleIncomingURL(url)
                }
                // Spotlight integration: when the user taps a result
                // surfaced by `SpotlightIndexer`, macOS hands us an
                // `NSUserActivity` whose `userInfo` contains the
                // tapped item's unique identifier. We parse that back
                // into a `maraithon://open/<source>/<guid>` deep link
                // and route it through the same `handleIncomingURL`
                // path the rest of the app uses for deep links.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard
                        let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier]
                            as? String,
                        let route = parseSpotlightActivityIdentifier(identifier)
                    else {
                        environment.eventLog.warning(
                            "spotlight.activity_ignored",
                            source: .system,
                            payload: [
                                "reason": "missing or unparsable identifier"
                            ]
                        )
                        return
                    }
                    environment.eventLog.info(
                        "spotlight.activity_received",
                        source: .system,
                        payload: [
                            "source": route.source,
                            "guid_prefix": String(route.guid.prefix(8))
                        ]
                    )
                    environment.handleIncomingURL(route.url)
                }
        }
        .defaultSize(width: 880, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(CompanionMenuBarCopy.checkNowButtonTitle) { environment.syncNowFromMenu() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!environment.canSyncNow)
            }
            TodoCommands()
            UpdateCommands(updates: environment.updates)
            DiagnosticExportCommands(env: environment)
        }

        MaraithonMenuBar()
            .environment(environment)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
