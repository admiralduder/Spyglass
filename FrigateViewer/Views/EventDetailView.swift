import AVKit
import SwiftUI

struct EventDetailView: View {
    @Environment(FrigateClient.self) private var client
    let event: FrigateEvent

    @State private var playback: ClipPlayback?
    @State private var showFullScreen = false
    @State private var clipFile: URL?
    @State private var loadingClip = false
    @State private var clipError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                media
                    .aspectRatio(client.config?.aspectRatio(for: event.camera) ?? 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if let playback {
                    ClipControls(playback: playback)
                        .glassCard(cornerRadius: 22)
                } else if event.hasClip {
                    Button {
                        Task { await loadClip() }
                    } label: {
                        Label(loadingClip ? "Loading clip…" : "Play Clip", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .tint(.primary)
                    .glassButton()
                    .disabled(loadingClip)
                }
                if let clipError {
                    Text(clipError).font(.footnote).foregroundStyle(.red)
                }

                details
            }
            .padding()
        }
        .navigationTitle(event.label.prettyName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let clipFile {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: clipFile)
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let playback {
                FullScreenCamera {
                    PlayerLayerView(player: playback.player).pinchToZoom()
                } controls: {
                    ClipControls(playback: playback)
                        .glassCard(cornerRadius: 22)
                        .frame(maxWidth: 560)
                }
            }
        }
        .onDisappear {
            // Full screen covers this view; only stop when actually leaving.
            guard !showFullScreen else { return }
            playback?.pause()
            if let clipFile { try? FileManager.default.removeItem(at: clipFile) }
        }
    }

    @ViewBuilder private var media: some View {
        if let playback {
            // Pinch to zoom; drag to move around while zoomed.
            PlayerLayerView(player: playback.player).pinchToZoom()
                .overlay(alignment: .bottomTrailing) {
                    FullScreenButton { showFullScreen = true }.padding(8)
                }
        } else if event.hasSnapshot {
            RemoteImage(makeURL: { try client.snapshotURL(event: event) })
        } else {
            RemoteImage(makeURL: { try client.thumbnailURL(event: event) })
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Camera", event.camera.prettyName)
            row("Object", event.label.prettyName)
            if let score = event.score {
                row("Confidence", score.formatted(.percent.precision(.fractionLength(0))))
            }
            row("Started", event.startDate.formatted(date: .abbreviated, time: .standard))
            if let duration = event.duration {
                row("Duration", Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
            } else {
                row("Status", "In progress")
            }
            if !event.zones.isEmpty {
                row("Zones", event.zones.map(\.prettyName).joined(separator: ", "))
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    /// Downloads the clip first so auth cookies and self-signed certs work the same as for images.
    private func loadClip() async {
        loadingClip = true
        defer { loadingClip = false }
        do {
            let file = try await client.download(from: client.clipURL(event: event), fileExtension: "mp4")
            clipFile = file
            let p = ClipPlayback(url: file)
            playback = p
            p.player.play()
            clipError = nil
        } catch {
            clipError = error.localizedDescription
        }
    }
}
