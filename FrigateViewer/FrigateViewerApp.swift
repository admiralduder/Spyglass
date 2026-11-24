import SwiftUI

@main
struct FrigateViewerApp: App {
    @State private var client = FrigateClient(settings: ServerSettings())

    private var colorScheme: ColorScheme? {
        switch client.settings.appearance {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .preferredColorScheme(colorScheme)
        }
    }
}

struct RootView: View {
    @Environment(FrigateClient.self) private var client
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            CamerasView()
                .tabItem { Label("Cameras", systemImage: "video") }
                .tag(0)
            // Only offered when the server actually has events (detection may be turned off).
            if client.hasEvents == true {
                EventsView()
                    .tabItem { Label("Events", systemImage: "bell.badge") }
                    .tag(1)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(2)
        }
        // Accent is black in light mode, white in dark mode, everywhere in the app.
        .tint(.primary)
        .onAppear {
            // Tapping outside a text field closes the keyboard, everywhere in the app.
            DispatchQueue.main.async { KeyboardDismisser.shared.install() }
            if !client.settings.isConfigured { tab = 2 }
        }
        .task(id: client.settings.serverURL) {
            guard client.settings.isConfigured else { return }
            _ = try? await client.anyEvents()
        }
        // Keep camera online/offline status current while the app is open.
        .task(id: client.settings.serverURL) {
            guard client.settings.isConfigured else { return }
            while !Task.isCancelled {
                try? await client.refreshCameraStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: client.hasEvents) { _, has in
            if has != true && tab == 1 { tab = 0 }
        }
    }
}
