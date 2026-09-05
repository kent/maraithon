import Foundation
import Observation

/// Shared service container injected through the SwiftUI environment.
/// Owns the long-lived services that views, sources, and the sync engine
/// all need access to.
///
/// Construction order matters here:
///   1. `EventLog` first — every other service emits to it.
///   2. `Blocklist` — used by sources to filter before push.
///   3. `DeviceAuth` — owns the bearer token; everyone reads from it.
///   4. `TodosStore` — reads account-backed work through that device token.
///   5. `SyncEngine` — needs both `EventLog` and `DeviceAuth`.
///   6. `SourceRegistry` — installs sources whose outboxes call into
///      `SyncEngine`.
@Observable
@MainActor
final class AppEnvironment {
    let eventLog: EventLog
    let deviceAuth: DeviceAuth
    let todos: TodosStore
    let onboarding: OnboardingFlow
    let syncEngine: SyncEngine
    let sources: SourceRegistry
    let blocklist: Blocklist
    /// Sparkle wrapper. Built here so views can read it through the
    /// `AppEnvironment` rather than threading a separate `@State` through
    /// the scene graph — keeps `MaraithonApp` a single owner of services.
    let updates: UpdateController
    /// Realtime WebSocket channel for instant sync. Each ingest helper
    /// receives a reference and prefers it over HTTP when connected.
    let realtime: RealtimeChannel

    private(set) var isPaused: Bool = false

    init() {
        let log = EventLog()
        self.eventLog = log
        self.blocklist = Blocklist()
        let auth = DeviceAuth(eventLog: log)
        self.deviceAuth = auth
        self.todos = TodosStore(
            client: MaraithonClient(
                tokenProvider: { [weak auth] in
                    await MainActor.run { [auth] in auth?.currentToken }
                }
            ),
            eventLog: log,
            unauthorizedHandler: { [weak auth] in
                auth?.tokenRejected()
            }
        )
        self.onboarding = OnboardingFlow(eventLog: log)
        let engine = SyncEngine(eventLog: log, deviceAuth: deviceAuth)
        self.syncEngine = engine
        let registry = SourceRegistry(eventLog: log)
        self.sources = registry
        self.updates = UpdateController(eventLog: log)

        let realtimeChannel = RealtimeChannel(
            deviceId: deviceAuth.deviceId,
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            log: { @Sendable [weak log] msg, payload in
                Task { @MainActor in log?.info(msg, source: .realtime, payload: payload) }
            }
        )
        self.realtime = realtimeChannel

        let imessageIngest = IMessageIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let imessage = IMessageSource(
            blocklist: blocklist,
            eventLog: log,
            ingest: imessageIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(imessage)

        let contactsIngest = ContactsIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let contacts = ContactsSource(
            eventLog: log,
            ingest: contactsIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(contacts)

        let notesIngest = NotesIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let notes = NotesSource(
            eventLog: log,
            ingest: notesIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(notes)

        let voiceMemosIngest = VoiceMemosIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let voiceMemos = VoiceMemosSource(
            eventLog: log,
            ingest: voiceMemosIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(voiceMemos)

        let remindersIngest = RemindersIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let reminders = RemindersSource(
            eventLog: log,
            ingest: remindersIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(reminders)

        let calendarIngest = CalendarIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let calendar = CalendarEventsSource(
            eventLog: log,
            ingest: calendarIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(calendar)

        let filesIngest = FilesIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let files = FilesSource(
            eventLog: log,
            ingest: filesIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(files)

        let browserHistoryIngest = BrowserHistoryIngest(
            tokenProvider: { [weak deviceAuth] in
                await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
            },
            realtime: realtimeChannel
        )
        let browserHistory = BrowserHistorySource(
            eventLog: log,
            ingest: browserHistoryIngest,
            deviceIdProvider: { [weak deviceAuth] in deviceAuth?.deviceId ?? UUID() }
        )
        registry.register(browserHistory)

        // The onboarding skip flag is persisted so the banner survives
        // relaunches, but it must clear once the current app copy proves
        // macOS Full Disk Access is already granted. Source-level red
        // states still clear only after the protected read succeeds.
        if FullDiskAccessProbe.isGranted() {
            onboarding.recordFullDiskAccessGranted()
            registry.verifyFullDiskAccessBlocksIfGranted(isGranted: { true })
        }

        if Self.shouldAutoStartLiveServices {
            // Kick off the realtime channel. start() loops with backoff until a
            // valid token is available, so calling it pre-sign-in is safe.
            Task { [realtime = realtimeChannel] in
                await realtime.start()
            }

            // Auto-start every registered source so polling begins immediately
            // on launch. Sources that need permissions they don't yet have
            // surface as `.needsAttention(...)` rather than crashing.
            registry.startAll()
        }
    }

    private static var shouldAutoStartLiveServices: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// Routes inbound deep-link URLs (e.g. `maraithon://device-token/<t>`).
    func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == "maraithon", url.host?.lowercased() == "show" {
            eventLog.debug("app.show_window_requested", source: .ui)
            return
        }

        deviceAuth.handleIncomingURL(url)
    }

    /// Triggered by the global `⌘R` shortcut and the toolbar.
    func syncNowFromMenu() {
        sources.syncNow()
        if case .signedIn = deviceAuth.state {
            Task { [todos] in
                await todos.load()
            }
        }
    }

    /// Toggle every registered source between paused and running. Surfaces
    /// via the menubar so the user can mute syncing without quitting.
    func togglePaused() {
        if isPaused {
            sources.startAll()
            isPaused = false
            eventLog.info("app.resume", source: .system)
        } else {
            sources.pauseAll()
            isPaused = true
            eventLog.info("app.pause", source: .system)
        }
    }

    /// Sync Now is only meaningful once the user is paired and sync isn't
    /// already in flight or paused.
    var canSyncNow: Bool {
        switch deviceAuth.state {
        case .signedIn: return !isPaused
        default: return false
        }
    }

    /// SF Symbol for the menubar item. Reflects the highest-priority
    /// signal across registered sources so the user can read it at a
    /// glance.
    var menuBarSymbol: String {
        CompanionMenuBarCopy.symbol(
            isPaused: isPaused,
            deviceAuthState: deviceAuth.state,
            sourceStates: displayedSourceStates
        )
    }

    /// True when any installed source is mid-sync. Used by the menubar
    /// label to drive the rotating glyph.
    var isAnySourceSyncing: Bool {
        sources.sources.contains {
            (sources.statusPublisher(for: $0.id)?.displayedState() ?? $0.state) == .syncing
        }
    }

    /// Accessibility label paired with the menubar SF Symbol.
    var menuBarAccessibilityLabel: String {
        CompanionMenuBarCopy.accessibilityLabel(
            isPaused: isPaused,
            deviceAuthState: deviceAuth.state,
            sourceStates: displayedSourceStates
        )
    }

    private var displayedSourceStates: [SourceState] {
        sources.sources.filter { !$0.comingSoon }.map {
            sources.statusPublisher(for: $0.id)?.displayedState() ?? $0.state
        }
    }
}

/// Product-facing menubar copy. Keeps the tiny menu-bar surface honest:
/// "checking" only appears while work is actually in flight.
enum CompanionMenuBarCopy {
    static let checkNowButtonTitle = "Check now"
    static let pauseUpdatesButtonTitle = "Pause updates"
    static let resumeUpdatesButtonTitle = "Resume updates"
    static let showWindowButtonTitle = "Show Maraithon"

    static func symbol(
        isPaused: Bool,
        deviceAuthState: DeviceAuth.State,
        sourceStates: [SourceState]
    ) -> String {
        if isPaused { return "pause.circle" }

        switch deviceAuthState {
        case .signedOut, .error:
            return "exclamationmark.triangle"
        case .connecting, .awaitingApproval:
            return "arrow.triangle.2.circlepath"
        case .signedIn:
            break
        }

        if sourceStates.contains(where: { if case .error = $0 { return true } else { return false } }) {
            return "exclamationmark.octagon.fill"
        }
        if sourceStates.contains(where: { if case .needsAttention = $0 { return true } else { return false } }) {
            return "exclamationmark.triangle.fill"
        }
        if sourceStates.contains(.syncing) { return "arrow.triangle.2.circlepath" }
        if sourceStates.contains(.paused) { return "pause.circle" }
        if sourceStates.contains(.connected) { return "checkmark.circle" }
        return "arrow.triangle.2.circlepath.circle"
    }

    static func accessibilityLabel(
        isPaused: Bool,
        deviceAuthState: DeviceAuth.State,
        sourceStates: [SourceState]
    ) -> String {
        if isPaused { return "Maraithon — updates paused" }

        switch deviceAuthState {
        case .signedOut:
            return "Maraithon — sign in required"
        case .error:
            return "Maraithon — sign-in needs review"
        case .connecting, .awaitingApproval:
            return "Maraithon — connecting"
        case .signedIn:
            return signedInAccessibilityLabel(sourceStates: sourceStates)
        }
    }

    private static func signedInAccessibilityLabel(sourceStates: [SourceState]) -> String {
        if sourceStates.contains(where: { if case .error = $0 { return true } else { return false } }) {
            return "Maraithon — checks need review"
        }
        if sourceStates.contains(where: { if case .needsAttention = $0 { return true } else { return false } }) {
            return "Maraithon — checks need review"
        }
        if sourceStates.contains(.syncing) {
            return "Maraithon — checking"
        }
        if sourceStates.contains(.paused) {
            return "Maraithon — updates paused"
        }
        if sourceStates.contains(.connected) {
            return "Maraithon — assistant ready"
        }
        return "Maraithon — waiting for first check"
    }
}
