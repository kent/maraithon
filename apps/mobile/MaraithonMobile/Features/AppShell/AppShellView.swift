import Combine
import SwiftUI

enum AppTab: Hashable {
    case today
    case todos
    case stream
    case crm
    case chat
}

struct AppShellView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = AppNavigation()
    @State private var identityPrefill: MobileAPIClient.IdentityResponse.Identity?
    @State private var didCheckIdentity = false
    @AppStorage(AuthSessionStorageKeys.aiConsentAccepted) private var aiConsentAccepted = false

    var body: some View {
        if aiConsentAccepted {
            shell
        } else {
            AIDataDisclosureView {
                aiConsentAccepted = true
            }
        }
    }

    private var shell: some View {
        TabView(selection: Binding(
            get: { navigation.selectedTab },
            set: { navigation.selectedTab = $0 }
        )) {
            Tab("Today", systemImage: "sparkles.rectangle.stack", value: .today) {
                TodayView()
            }

            Tab("Work", systemImage: "checklist", value: .todos) {
                TodosView()
            }

            Tab("Stream", systemImage: "wave.3.right", value: .stream) {
                StreamView()
            }

            Tab("People", systemImage: "person.2.crop.square.stack", value: .crm) {
                CRMView()
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: .chat) {
                ChatThreadsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(navigation)
        .task {
            PushCoordinator.shared.clearBadge()

            // A push tap or deep link may have arrived before this shell
            // mounted (cold launch); route it now that navigation exists.
            drainPendingDeepLink()

            // Push permission must not wait on the identity network call.
            async let pushSetup: Void = PushCoordinator.shared.enablePush()
            await checkIdentity()
            await pushSetup
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PushCoordinator.shared.clearBadge()
                Task { await PushCoordinator.shared.enablePush() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maraithonDeepLink)) { _ in
            drainPendingDeepLink()
        }
        .sheet(item: $identityPrefill) { prefill in
            IdentityOnboardingView(prefill: prefill) {
                identityPrefill = nil
            }
        }
    }

    private func drainPendingDeepLink() {
        guard let url = PushCoordinator.shared.pendingDeepLink else { return }
        PushCoordinator.shared.pendingDeepLink = nil
        navigation.route(url)
    }

    private func checkIdentity() async {
        guard !didCheckIdentity, let sessionToken = sessionStore.user?.sessionToken else { return }
        didCheckIdentity = true

        do {
            let identity = try await MobileAPIClient().getIdentity(sessionToken: sessionToken)
            if !identity.confirmed {
                identityPrefill = identity
            }
        } catch {
            // Identity onboarding is best-effort; the next launch retries.
        }
    }
}
