import SwiftUI

struct CamerasView: View {
    @Environment(FrigateClient.self) private var client
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if !client.settings.isConfigured {
                    ContentUnavailableView("No Server", systemImage: "server.rack",
                                           description: Text("Add your Frigate server in Settings."))
                } else if let config = client.config {
                    if config.cameraNames.isEmpty {
                        ContentUnavailableView("No Cameras", systemImage: "video.slash")
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(client.cameraNames, id: \.self) { name in
                                    NavigationLink(value: name) {
                                        CameraTile(name: name, aspectRatio: config.aspectRatio(for: name))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding()
                        }
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("Can't Connect", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Connecting…")
                }
            }
            .navigationTitle("Cameras")
            .navigationDestination(for: String.self) { name in
                let ratio = client.config?.aspectRatio(for: name) ?? 16 / 9
                if client.config?.isRecording(name) == true {
                    TimelineCameraView(name: name, aspectRatio: ratio)
                } else {
                    LiveCameraView(name: name, aspectRatio: ratio)
                }
            }
            .navigationDestination(for: FrigateEvent.self) { EventDetailView(event: $0) }
            .refreshable { await load() }
            .task(id: client.settings.serverURL) {
                if client.config == nil { await load() }
            }
        }
    }

    private func load() async {
        guard client.settings.isConfigured else { return }
        do {
            try await client.loadConfig()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CameraTile: View {
    @Environment(FrigateClient.self) private var client
    let name: String
    let aspectRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The tile's size comes from the camera's shape alone, never from the picture,
            // so tiles don't change height while pictures load (which made the list jump).
            Color.black
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RemoteImage(makeURL: { try client.latestFrameURL(camera: name, height: 360) },
                                refreshInterval: .seconds(10), contentMode: .fill,
                                cacheKey: "tile:\(name)")
                }
                .overlay(alignment: .topLeading) {
                    if client.isOffline(name) {
                        LiveBadge(isOffline: true).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                Text(name.prettyName)
                    .font(.subheadline.weight(.semibold))
                if client.config?.isRecording(name) == true {
                    Circle()
                        .fill(.red)
                        .frame(width: 4, height: 4)
                        .accessibilityLabel("Recording")
                }
            }
        }
    }
}

/// "LIVE" in red, or "OFFLINE" in gray when the camera isn't sending video.
struct LiveBadge: View {
    let isOffline: Bool

    var body: some View {
        Label(isOffline ? "OFFLINE" : "LIVE",
              systemImage: isOffline ? "video.slash.fill" : "dot.radiowaves.left.and.right")
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOffline ? Color.black.opacity(0.55) : Color.red, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct LiveCameraView: View {
    @Environment(FrigateClient.self) private var client
    let name: String
    let aspectRatio: CGFloat
    @State private var hasEvents = false
    @State private var showFullScreen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    RemoteImage(makeURL: { try client.latestFrameURL(camera: name, height: 1080) },
                                refreshInterval: .seconds(1))
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                    LiveBadge(isOffline: client.isOffline(name))
                        .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    FullScreenButton { showFullScreen = true }.padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Only shown when this camera has events (detection may be turned off).
                if hasEvents {
                    Text("Recent Events").font(.headline)
                    EventList(camera: name, limit: 20, embedded: true)
                }
            }
            .padding()
        }
        .navigationTitle(name.prettyName)
        .navigationBarTitleDisplayMode(.inline)
        .task { hasEvents = (try? await client.anyEvents(camera: name)) ?? false }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenCamera {
                RemoteImage(makeURL: { try client.latestFrameURL(camera: name, height: 1080) },
                            refreshInterval: .seconds(1))
                    .aspectRatio(aspectRatio, contentMode: .fit)
            } controls: {
                EmptyView()
            }
        }
    }
}
