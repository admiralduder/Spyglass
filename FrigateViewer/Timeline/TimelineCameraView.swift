import AVFoundation
import SwiftUI

/// Camera screen for cameras that record: video on top, a vertical timeline below.
/// Drag the timeline to scrub (newest at the top), pinch to zoom, tap Live to return.
struct TimelineCameraView: View {
    @Environment(FrigateClient.self) private var client
    let name: String
    let aspectRatio: CGFloat

    @State private var model: TimelineModel?
    @State private var showDatePicker = false
    @State private var showFullScreen = false
    @State private var showFullScreenDatePicker = false

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                VideoArea(model: model, aspectRatio: aspectRatio) { showFullScreen = true }
                ControlBar(model: model, showDatePicker: $showDatePicker)
                    // A darker frosted panel between the video and the timeline.
                    .glassCard(cornerRadius: 22, tint: Color(.systemGray3).opacity(0.35))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                TimelineStrip(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(name.prettyName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showDatePicker) {
            if let model { JumpToDateSheet(model: model) }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let model {
                FullScreenCamera {
                    VideoArea(model: model, aspectRatio: aspectRatio, onFullScreen: nil)
                } controls: {
                    ControlBar(model: model, showDatePicker: $showFullScreenDatePicker)
                        .glassCard(cornerRadius: 22)
                        .frame(maxWidth: 560)
                }
                .sheet(isPresented: $showFullScreenDatePicker) { JumpToDateSheet(model: model) }
            }
        }
        .task {
            guard model == nil else { return }
            let m = TimelineModel(camera: name, client: client)
            model = m
            await m.start()
        }
        // Full screen covers this view; only stop when actually leaving the camera.
        .onDisappear { if !showFullScreen { model?.stop() } }
    }
}

// MARK: - Video

private struct VideoArea: View {
    @Environment(FrigateClient.self) private var client
    let model: TimelineModel
    let aspectRatio: CGFloat
    /// Shows the full-screen button when set.
    var onFullScreen: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            switch model.mode {
            case .live:
                // When paused, the view reloads once and then stops refreshing (a frozen frame).
                RemoteImage(makeURL: { [camera = model.camera] in try client.latestFrameURL(camera: camera, height: 720) },
                            refreshInterval: model.isLivePaused ? nil : .seconds(1))
                    .id(model.isLivePaused)
            case .scrubbing:
                if model.recordedRange(containing: model.centerTime) == nil {
                    noRecording
                } else if let image = model.previewImage {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            case .playback:
                PlayerLayerView(player: model.player)
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.white.opacity(0.8))
                } else if model.isBuffering {
                    ProgressView().tint(.white)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) { badge.padding(10) }
        .overlay(alignment: .bottomTrailing) {
            if let onFullScreen { FullScreenButton(action: onFullScreen).padding(10) }
        }
    }

    private var noRecording: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.slash")
            Text("No recording")
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.7))
    }

    @ViewBuilder private var badge: some View {
        if model.mode == .live && client.isOffline(model.camera) {
            LiveBadge(isOffline: true)
        } else if model.mode == .live {
            Label(model.isLivePaused ? "PAUSED" : "LIVE",
                  systemImage: model.isLivePaused ? "pause.fill" : "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(model.isLivePaused ? Color.black.opacity(0.55) : Color.red, in: Capsule())
                .foregroundStyle(.white)
        } else {
            Text(Date(timeIntervalSince1970: model.centerTime), format: .dateTime.hour().minute().second())
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

// MARK: - Controls

private struct ControlBar: View {
    let model: TimelineModel
    @Binding var showDatePicker: Bool

    private var isLiveNow: Bool { model.mode == .live && !model.isLivePaused }

    private var showsPause: Bool {
        switch model.mode {
        case .live: !model.isLivePaused
        case .playback: model.isPlaying
        case .scrubbing: false
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(TimelineFormat.dayLabel(model.centerTime))
                    .font(.caption).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: model.centerTime), format: .dateTime.hour().minute().second())
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)

            Button { model.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
            Button { model.togglePlay() } label: {
                Image(systemName: showsPause ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            Button { model.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                .disabled(model.mode == .live)  // Nothing ahead of live.
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 24)
            }
            Button { showDatePicker = true } label: { Image(systemName: "calendar") }

            Button { model.goLive() } label: {
                Text("LIVE").font(.caption.bold())
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(isLiveNow ? Color.red : Color.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(isLiveNow ? .white : .primary)
            }
            .disabled(isLiveNow)
        }
        .font(.title3)
        // Black in light mode, white in dark mode.
        .tint(.primary)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

private struct JumpToDateSheet: View {
    let model: TimelineModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Go to", selection: $date,
                       in: Date(timeIntervalSince1970: model.earliestTime)...Date(),
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Go to Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            model.jump(to: date.timeIntervalSince1970)
                            dismiss()
                        }
                    }
                }
        }
        // Black in light mode, white in dark mode, like the player controls.
        .tint(.primary)
        .presentationDetents([.medium, .large])
        .onAppear { date = Date(timeIntervalSince1970: model.centerTime) }
    }
}

// MARK: - Timeline

private struct TimelineStrip: View {
    let model: TimelineModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var lastDrag: CGFloat = 0
    @State private var zoomBase: Double?

    private let labelWidth: CGFloat = 70
    private let trackInset: CGFloat = 80
    /// The playhead sits near the top: at live it marks "now" and everything below is the past,
    /// so the timeline never shows time that hasn't happened yet.
    static let playheadY: CGFloat = 40

    var body: some View {
        // Read observed values here so SwiftUI redraws the Canvas when they change.
        let center = model.centerTime
        let spp = model.secondsPerPoint
        let ranges = model.ranges
        let now = model.now
        let isLight = colorScheme == .light

        GeometryReader { geo in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, center: center, spp: spp, ranges: ranges, now: now, isLight: isLight)
            }
            .overlay { playhead(width: geo.size.width) }
            .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(magnify)
            .onAppear { model.viewportHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, h in model.viewportHeight = h }
        }
        .background(Color(.systemBackground))
        .clipped()
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dy = value.translation.height - lastDrag
                lastDrag = value.translation.height
                model.scrub(byPoints: dy)
            }
            .onEnded { value in
                lastDrag = 0
                model.endScrub(velocity: value.velocity.height)
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomBase == nil { zoomBase = model.secondsPerPoint }
                model.zoom(to: (zoomBase ?? 6) / value.magnification)
            }
            .onEnded { _ in zoomBase = nil }
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { model.zoom(to: model.secondsPerPoint / 2) } label: {
                Image(systemName: "plus").frame(width: 36, height: 34)
            }
            Divider().frame(width: 36)
            Button { model.zoom(to: model.secondsPerPoint * 2) } label: {
                Image(systemName: "minus").frame(width: 36, height: 34)
            }
        }
        .font(.subheadline.weight(.semibold))
        .tint(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func playhead(width: CGFloat) -> some View {
        GeometryReader { geo in
            let y = Self.playheadY
            ZStack(alignment: .leading) {
                Rectangle().fill(.blue).frame(height: 2)
                    .padding(.leading, labelWidth)
                Circle().fill(.blue).frame(width: 10, height: 10)
                    .offset(x: labelWidth - 5)
            }
            .frame(width: width)
            .position(x: width / 2, y: y)
        }
        .allowsHitTesting(false)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, center: Double, spp: Double,
                      ranges: [RecordingRange], now: Double, isLight: Bool) {
        let top = Self.playheadY
        func y(_ t: Double) -> CGFloat { top - CGFloat((t - center) / spp) }
        // Never draw past "now".
        let tTop = min(center + Double(top) * spp, now)
        let tBottom = center - Double(size.height - top) * spp
        let trackWidth = size.width - trackInset - 16

        // Track background (only up to "now"): anything not covered by footage is a gap, shown light gray.
        let trackTop = max(0, y(now))
        let track = CGRect(x: trackInset, y: trackTop, width: trackWidth, height: size.height - trackTop)
        ctx.fill(Path(roundedRect: track, cornerRadius: 6), with: .color(Color(.systemGray3)))

        // Recorded footage: white in light mode, black in dark mode; gaps show the gray track.
        for r in ranges where r.end > tBottom && r.start < tTop {
            let y1 = y(min(r.end, tTop)), y2 = y(max(r.start, tBottom))
            let rect = CGRect(x: trackInset, y: y1, width: trackWidth, height: max(2, y2 - y1))
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(isLight ? .white : .black))
        }

        // Time ticks, aligned to local time.
        let step = TimelineFormat.tickStep(secondsPerPoint: spp)
        let tz = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: center)))
        var t = (floor((tBottom + tz) / step) * step) - tz
        while t <= tTop {
            let ty = y(t)
            let isMidnight = Int((t + tz).rounded()) % 86400 == 0
            var line = Path()
            line.move(to: CGPoint(x: labelWidth + 2, y: ty))
            line.addLine(to: CGPoint(x: isMidnight ? size.width : trackInset - 4, y: ty))
            ctx.stroke(line, with: .color(.secondary.opacity(isMidnight ? 0.6 : 0.35)), lineWidth: isMidnight ? 1 : 0.5)
            // Faint line across the track at every labeled time.
            if !isMidnight && ty >= trackTop {
                var across = Path()
                across.move(to: CGPoint(x: trackInset, y: ty))
                across.addLine(to: CGPoint(x: trackInset + trackWidth, y: ty))
                ctx.stroke(across, with: .color(isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.15)), lineWidth: 0.5)
            }

            let label = isMidnight ? TimelineFormat.shortDay(t) : TimelineFormat.tickLabel(t, step: step)
            ctx.draw(Text(label)
                        .font(isMidnight ? .caption2.bold() : .caption2)
                        .foregroundStyle(isMidnight ? Color.primary : Color.secondary),
                     at: CGPoint(x: labelWidth - 2, y: ty), anchor: .trailing)
            t += step
        }

        // "Now" marker.
        if now <= tTop {
            let ny = y(now)
            var line = Path()
            line.move(to: CGPoint(x: trackInset, y: ny))
            line.addLine(to: CGPoint(x: size.width - 16, y: ny))
            ctx.stroke(line, with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.draw(Text("Now").font(.caption2.bold()).foregroundStyle(.red),
                     at: CGPoint(x: size.width - 20, y: ny - 2), anchor: .bottomTrailing)
        }
    }
}

enum TimelineFormat {
    /// Smallest tick spacing that keeps labels at least ~56 pt apart.
    static func tickStep(secondsPerPoint spp: Double) -> Double {
        let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400]
        return steps.first { $0 / spp >= 56 } ?? 86400
    }

    static func tickLabel(_ t: Double, step: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        return step < 60
            ? date.formatted(.dateTime.hour().minute().second())
            : date.formatted(.dateTime.hour().minute())
    }

    static func shortDay(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.month(.abbreviated).day())
    }

    static func dayLabel(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
