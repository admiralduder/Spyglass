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
            RemoteImage(makeURL: { try client.latestFrameURL(camera: name, height: 360) },
                        refreshInterval: .seconds(10), contentMode: .fill)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
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

struct LiveCameraView: View {
    @Environment(FrigateClient.self) private var client
    let name: String
    let aspectRatio: CGFloat
    @State private var hasEvents = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    RemoteImage(makeURL: { try client.latestFrameURL(camera: name, height: 1080) },
                                refreshInterval: .seconds(1))
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
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
    }
}
