import AVFoundation
import SwiftUI

/// Playback state for an event clip, shared by the inline player and full screen.
@MainActor @Observable
final class ClipPlayback {
    let player: AVPlayer
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// While dragging the slider, the slider owns the time.
    var isSeeking = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func update(_ t: CMTime) {
        if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0 { duration = d.seconds }
        if !isSeeking, t.isNumeric { time = t.seconds }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            // At the end, start over.
            if duration > 0, time >= duration - 0.25 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() { player.pause() }
}

/// Play/pause, elapsed time, a slider to scrub, and the length of the clip.
struct ClipControls: View {
    let playback: ClipPlayback

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Text(Self.format(playback.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.1)) { editing in
                playback.isSeeking = editing
            }

            Text(Self.format(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tint(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
