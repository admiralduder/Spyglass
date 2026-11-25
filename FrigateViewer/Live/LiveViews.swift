import SwiftUI
import WebRTC

/// Live video for a camera: shows refreshed pictures until WebRTC video starts,
/// and keeps showing pictures if WebRTC can't connect.
struct LiveVideoView: View {
    @Environment(FrigateClient.self) private var client
    let stream: LiveStream
    /// Freezes on the current picture (used when live is paused).
    var isPaused = false

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(makeURL: { [camera = stream.camera] in try client.latestFrameURL(camera: camera, height: 720) },
                        // Stop refreshing pictures once real video is showing, or when paused.
                        refreshInterval: (isPaused || stream.hasVideo) ? nil : .seconds(1),
                        cacheKey: "live:\(stream.camera)")
                .id(isPaused)
            if !isPaused, let track = stream.videoTrack {
                WebRTCVideoView(track: track)
                    .opacity(stream.hasVideo ? 1 : 0)
                    .animation(.easeIn(duration: 0.2), value: stream.hasVideo)
            }
        }
    }
}

/// Shows a WebRTC video track.
private struct WebRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    final class Coordinator { var track: RTCVideoTrack? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .clear
        track.add(view)
        context.coordinator.track = track
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        track.add(view)
        context.coordinator.track = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }
}

/// The controls bar for cameras without recordings: the current time, mute, and LIVE.
struct LiveControlBar: View {
    let stream: LiveStream
    var isOffline = false

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text(TimelineFormat.dayLabel(context.date.timeIntervalSince1970))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(context.date, format: .dateTime.hour().minute().second())
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)

            Button { stream.toggleMute() } label: {
                Image(systemName: stream.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 24)
            }
            .accessibilityLabel(stream.isMuted ? "Unmute" : "Mute")
            // Grayed out when live video is playing but the camera has no sound to send.
            .disabled(stream.hasVideo && !stream.hasAudio)

            Text(isOffline ? "OFFLINE" : "LIVE").font(.caption.bold())
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isOffline ? Color.secondary.opacity(0.2) : Color.red, in: Capsule())
                .foregroundStyle(isOffline ? Color.primary : Color.white)
        }
        .font(.title3)
        .tint(.primary)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
