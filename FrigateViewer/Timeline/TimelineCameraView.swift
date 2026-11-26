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
    @State private var stream: LiveStream?
    /// Whether this screen (or its full-screen view) is showing.
    @State private var isOnScreen = false
    @State private var isStreaming = false
    /// Whether this camera has any events (detection may be off).
    @State private var hasEvents = false
    @AppStorage("showsEventList") private var showsEventList = false

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                VideoArea(model: model, stream: stream, aspectRatio: aspectRatio) { showFullScreen = true }
                ControlBar(model: model, stream: stream, showDatePicker: $showDatePicker)
                    // A darker frosted panel between the video and the timeline.
                    .glassCard(cornerRadius: 22, tint: Color(.systemGray3).opacity(0.35))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if hasEvents {
                    DayHeader(model: model, showsList: $showsEventList)
                    Divider()
                }
                if hasEvents && showsEventList {
                    DayEventList(model: model)
                } else {
                    TimelineStrip(model: model)
                }
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
                    VideoArea(model: model, stream: stream, aspectRatio: aspectRatio, onFullScreen: nil)
                } controls: {
                    ControlBar(model: model, stream: stream, showDatePicker: $showFullScreenDatePicker)
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
            stream = LiveStream(camera: name, client: client)
            syncLive()
            async let checkEvents = client.anyEvents(camera: name)
            await m.start()
            hasEvents = (try? await checkEvents) ?? false
        }
        .onAppear { isOnScreen = true; syncLive() }
        // Full screen covers this view; only stop when actually leaving the camera.
        .onDisappear {
            guard !showFullScreen else { return }
            isOnScreen = false
            syncLive()
            model?.stop()
        }
        // Live video streams only while watching live, not recordings.
        .onChange(of: model?.mode) { syncLive() }
        .onChange(of: model?.isLivePaused) { syncLive() }
        .onChange(of: model?.isMuted) { stream?.setMuted(model?.isMuted ?? true) }
        .onChange(of: client.isOffline(name)) { _, offline in
            if !offline, stream?.state == .failed { stream?.retry() }
        }
    }
}

extension TimelineCameraView {
    private func syncLive() {
        guard let model, let stream else { return }
        let want = isOnScreen && model.mode == .live && !model.isLivePaused
        stream.setMuted(model.isMuted)
        guard want != isStreaming else { return }
        isStreaming = want
        if want { stream.start() } else { stream.stop() }
    }
}

// MARK: - Video

private struct VideoArea: View {
    @Environment(FrigateClient.self) private var client
    let model: TimelineModel
    let stream: LiveStream?
    let aspectRatio: CGFloat
    /// Shows the full-screen button when set.
    var onFullScreen: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            Group { media }.pinchToZoom()
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        // Badges sit on the video itself, even when it's narrower than the screen.
        .overlay(alignment: .topLeading) { badge.padding(10) }
        .overlay(alignment: .bottomTrailing) {
            if let onFullScreen { FullScreenButton(action: onFullScreen).padding(10) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var media: some View {
        ZStack {
            switch model.mode {
            case .live:
                if let stream {
                    // When paused, shows a single frozen picture instead of video.
                    LiveVideoView(stream: stream, isPaused: model.isLivePaused)
                }
            case .scrubbing:
                if model.isKnownGap(model.centerTime) {
                    noRecording
                } else if let image = model.previewImage {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if model.scrubOrigin == .playback {
                    // The paused recording, until the first scrub frame arrives.
                    PlayerLayerView(player: model.player)
                } else if let stream {
                    // The last live picture, until the first scrub frame arrives.
                    LiveVideoView(stream: stream, isPaused: true)
                }
            case .playback:
                // The last scrub frame stays underneath while the recording loads,
                // so letting go doesn't flash black.
                if let image = model.previewImage {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                }
                PlayerLayerView(player: model.player)
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.white.opacity(0.8))
                } else if model.isBuffering {
                    ProgressView().tint(.white)
                }
            }
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
            // Red only while video is actually streaming; gray while connecting or stalled.
            let isRed = !model.isLivePaused && stream?.isStreaming == true
            Label(model.isLivePaused ? "PAUSED" : "LIVE",
                  systemImage: model.isLivePaused ? "pause.fill" : "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isRed ? Color.red : Color.black.opacity(0.55), in: Capsule())
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
        // Clear, so a picture underneath shows until the video's first frame.
        view.backgroundColor = .clear
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
    let stream: LiveStream?
    @Binding var showDatePicker: Bool

    private var isLiveNow: Bool { model.mode == .live && !model.isLivePaused }
    /// The LIVE pill is red only while live video is actually streaming.
    private var isLiveRed: Bool { isLiveNow && stream?.isStreaming == true }

    private var showsPause: Bool {
        switch model.mode {
        case .live: !model.isLivePaused
        case .playback: model.isPlaying
        case .scrubbing: false
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(Date(timeIntervalSince1970: model.centerTime), format: .dateTime.hour().minute().second())
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
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
                    .background(isLiveRed ? Color.red : Color.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(isLiveRed ? .white : .primary)
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
    @State private var time: Date
    @State private var eventDays: Set<Int> = []
    private let day: Date

    init(model: TimelineModel) {
        self.model = model
        let now = Date(timeIntervalSince1970: model.centerTime)
        day = Calendar.current.startOfDay(for: now)
        _time = State(initialValue: now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // Tapping a day goes there right away, at the time below.
                    EventCalendar(day: day,
                                  range: Date(timeIntervalSince1970: model.earliestTime)...Date(),
                                  eventDays: eventDays) { picked in
                        model.jump(to: combine(picked, time).timeIntervalSince1970)
                        dismiss()
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Go to Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        // Black in light mode, white in dark mode, like the player controls.
        .tint(.primary)
        .presentationDetents([.large])
        .task {
            let days = (try? await model.client.eventDays(camera: model.camera)) ?? []
            eventDays = Set(days.map(EventCalendar.key))
        }
    }

    /// A day at a time of day.
    private func combine(_ day: Date, _ time: Date) -> Date {
        let cal = Calendar.current
        var parts = cal.dateComponents([.year, .month, .day], from: day)
        let clock = cal.dateComponents([.hour, .minute], from: time)
        parts.hour = clock.hour
        parts.minute = clock.minute
        return cal.date(from: parts) ?? day
    }
}

/// A month calendar with a small dot under each day that has events.
/// Tapping a day reports it right away.
private struct EventCalendar: UIViewRepresentable {
    /// The day being watched; the calendar opens on its month.
    let day: Date
    let range: ClosedRange<Date>
    /// Days with events, as `key`s.
    let eventDays: Set<Int>
    let onSelect: (Date) -> Void

    /// A day as one number (20261125). DateComponents carry extra fields (calendar,
    /// leap month) that make otherwise equal days compare as different.
    static func key(_ date: Date) -> Int {
        key(Calendar.current.dateComponents([.year, .month, .day], from: date))
    }

    static func key(_ parts: DateComponents) -> Int {
        (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private static func components(_ key: Int) -> DateComponents {
        DateComponents(calendar: .current, year: key / 10_000, month: key / 100 % 100, day: key % 100)
    }

    private static func date(_ parts: DateComponents) -> Date? {
        Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = .current
        view.availableDateRange = DateInterval(start: range.lowerBound, end: range.upperBound)
        view.tintColor = .label
        view.delegate = context.coordinator
        // Nothing starts selected, so tapping any day (even the one being watched) picks it.
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.visibleDateComponents = Calendar.current.dateComponents([.year, .month, .calendar], from: day)
        context.coordinator.shownDays = eventDays
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
        // Event days arrive after the sheet opens.
        if context.coordinator.shownDays != eventDays {
            let changed = context.coordinator.shownDays.symmetricDifference(eventDays)
            context.coordinator.shownDays = eventDays
            view.reloadDecorations(forDateComponents: changed.map(Self.components), animated: true)
        }
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: EventCalendar
        var shownDays: Set<Int> = []

        init(parent: EventCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard parent.eventDays.contains(EventCalendar.key(dateComponents)) else { return nil }
            return .default(color: .secondaryLabel, size: .small)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let parts = dateComponents, let date = EventCalendar.date(parts) else { return }
            parent.onSelect(date)
        }
    }
}

// MARK: - Day header and events

/// The day under the playhead, how many events it has, and the timeline / events switch.
private struct DayHeader: View {
    let model: TimelineModel
    @Binding var showsList: Bool

    var body: some View {
        let day = model.currentDay
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(TimelineFormat.dayLabel(model.centerTime)).font(.headline)
                Group {
                    if model.eventsDay == day {
                        Text(model.dayEvents.count == 1 ? "1 event" : "\(model.dayEvents.count) events")
                    } else {
                        Text(" ")  // Keeps the height steady while loading.
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsList.toggle() }
            } label: {
                Image(systemName: showsList ? "clock.arrow.circlepath" : "list.bullet")
                    .font(.title3)
                    .frame(width: 44, height: 36)
            }
            .tint(.primary)
            .accessibilityLabel(showsList ? "Show Timeline" : "Show Events")
        }
        .padding(.leading)
        .padding(.trailing, 6)
        .padding(.bottom, 4)
        .task(id: day) {
            // Today keeps getting new events, so check again now and then.
            while !Task.isCancelled {
                await model.loadEvents(day: day)
                guard Calendar.current.isDateInToday(day) else { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// The day's events, newest first. Tapping one plays it in the video above.
private struct DayEventList: View {
    let model: TimelineModel
    /// The event last tapped, so it's the one marked when events overlap.
    @State private var tappedID: String?

    var body: some View {
        Group {
            if model.eventsDay != model.currentDay {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.dayEvents.isEmpty {
                ContentUnavailableView("No Events", systemImage: "list.bullet",
                                       description: Text("Nothing was detected on this day."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let playingID = playingEventID
                        ForEach(model.dayEvents) { event in
                            Button {
                                tappedID = event.id
                                model.play(event)
                            } label: {
                                DayEventRow(event: event, isPlaying: event.id == playingID)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 156)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// The one event the playhead is in, while watching recordings: the tapped one if
    /// it's still playing, otherwise the latest one to start.
    private var playingEventID: String? {
        guard model.mode != .live else { return nil }
        let t = model.centerTime
        let containing = model.dayEvents.filter { t >= $0.startTime - 3 && t <= ($0.endTime ?? model.now) }
        if let tappedID, containing.contains(where: { $0.id == tappedID }) { return tappedID }
        return containing.max { $0.startTime < $1.startTime }?.id
    }
}

private struct DayEventRow: View {
    @Environment(FrigateClient.self) private var client
    let event: FrigateEvent
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(makeURL: { try client.thumbnailURL(event: event) }, contentMode: .fill)
                .frame(width: 128, height: 72)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Label(event.label.prettyName, systemImage: LabelIcon.symbol(for: event.label))
                    .font(.headline)
                Text(event.startDate, format: .dateTime.hour().minute().second())
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(durationText)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isPlaying ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    private var durationText: String {
        guard let duration = event.duration else { return "In progress" }
        let seconds = max(1, Int(duration.rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
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
        let checked = Array(model.checkedSpans.values)
        let now = model.now
        let isLight = colorScheme == .light
        let events = model.loadedEvents
        let motion = model.shownMotion

        GeometryReader { geo in
            let marks = eventMarks(events, size: geo.size, center: center, spp: spp, now: now)
            Canvas { ctx, size in
                draw(in: &ctx, size: size, center: center, spp: spp, ranges: ranges,
                     checked: checked, motion: motion, now: now, isLight: isLight, marks: marks)
            }
            .overlay { thumbnails(marks) }
            .overlay { playhead(width: geo.size.width) }
            .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
            .contentShape(Rectangle())
            // Tapping an event (its bar or picture) jumps to it.
            .onTapGesture { point in
                if let event = event(at: point, in: marks) {
                    model.play(event)
                } else if let start = motionStart(at: point, motion: motion, center: center, spp: spp) {
                    model.jump(to: start - 2)
                }
            }
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

    // MARK: Events on the timeline

    /// Where one event is drawn: a colored bar in the track, and maybe a picture beside it.
    struct EventMark {
        let event: FrigateEvent
        let bar: CGRect
        var thumbnail: CGRect?
    }

    private static let barWidth: CGFloat = 6
    private static let laneSpacing: CGFloat = 12
    private static let maxLanes = 4
    private static let thumbnailSize = CGSize(width: 96, height: 54)

    /// Lays out the events in view. Overlapping events go side by side in lanes;
    /// pictures are shown where they don't overlap each other.
    private func eventMarks(_ events: [FrigateEvent], size: CGSize, center: Double, spp: Double,
                            now: Double) -> [EventMark] {
        let top = Double(Self.playheadY)
        func y(_ t: Double) -> CGFloat { CGFloat(top - (t - center) / spp) }
        let tTop = center + top * spp
        let tBottom = center - (Double(size.height) - top) * spp
        let minHeight: CGFloat = 8

        // Oldest first, so each event takes the first lane that's free by then.
        var laneEnds: [Double] = []
        var marks: [EventMark] = []
        for event in events.sorted(by: { $0.startTime < $1.startTime }) {
            let end = max(event.endTime ?? now, event.startTime + Double(minHeight + 4) * spp)
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 < event.startTime }) {
                lane = free
                laneEnds[free] = end
            } else {
                lane = min(laneEnds.count, Self.maxLanes - 1)
                if laneEnds.count < Self.maxLanes { laneEnds.append(end) } else { laneEnds[lane] = max(laneEnds[lane], end) }
            }
            guard end > tBottom, event.startTime < tTop else { continue }
            let y1 = y(min(event.endTime ?? now, now)), y2 = y(event.startTime)
            let height = max(minHeight, y2 - y1)
            let x = Self.gapX(trackInset: trackInset) + Self.laneSpacing + 4 + CGFloat(lane) * Self.laneSpacing
            marks.append(EventMark(event: event,
                                   bar: CGRect(x: x, y: y2 - height, width: Self.barWidth, height: height)))
        }

        // Pictures on the right of the track, newest (top) first, skipping any that would overlap.
        let thumbX = size.width - 16 - 8 - Self.thumbnailSize.width
        var lastBottom = -CGFloat.infinity
        for i in marks.indices.sorted(by: { marks[$0].bar.midY < marks[$1].bar.midY }) {
            let h = Self.thumbnailSize.height
            // Never above the "Now" line, so the "Now" label stays visible.
            let top = max(marks[i].bar.midY - h / 2, y(now) + 4)
            let rect = CGRect(x: thumbX, y: top, width: Self.thumbnailSize.width, height: h)
            guard rect.minY >= lastBottom + 6 else { continue }
            marks[i].thumbnail = rect
            lastBottom = rect.maxY
        }
        return marks
    }

    private func thumbnails(_ marks: [EventMark]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(marks.filter { $0.thumbnail != nil }, id: \.event.id) { mark in
                let rect = mark.thumbnail!
                EventThumbnail(event: mark.event, size: rect.size)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The event under a tap, with some slack so thin bars are easy to hit.
    private func event(at point: CGPoint, in marks: [EventMark]) -> FrigateEvent? {
        if let hit = marks.first(where: { $0.thumbnail?.contains(point) == true }) { return hit.event }
        return marks
            .filter { $0.bar.insetBy(dx: -8, dy: -8).contains(point) }
            .min { abs($0.bar.midX - point.x) < abs($1.bar.midX - point.x) }?
            .event
    }

    /// The start of the motion bar under a tap, if any.
    private func motionStart(at point: CGPoint, motion: [RecordingRange], center: Double, spp: Double) -> Double? {
        let x = Self.gapX(trackInset: trackInset) + Self.barWidth / 2
        guard abs(point.x - x) <= 12 else { return nil }
        let t = center + Double(Self.playheadY - point.y) * spp
        let slack = 8 * spp
        return motion.first { t >= $0.start - slack && t <= $0.end + slack }?.start
    }

    static let motionColor = Color(.systemYellow)

    /// The column that shows gaps in the recordings and motion, left of the event columns.
    static func gapX(trackInset: CGFloat) -> CGFloat { trackInset + 10 }

    /// Time that has been checked with the server but has no recording.
    static func gaps(checked: [ClosedRange<Double>], ranges: [RecordingRange]) -> [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        let sorted = ranges.sorted { $0.start < $1.start }
        for span in checked {
            var cursor = span.lowerBound
            for r in sorted where r.end > cursor && r.start < span.upperBound {
                if r.start > cursor { gaps.append(cursor...r.start) }
                cursor = max(cursor, r.end)
            }
            if cursor < span.upperBound { gaps.append(cursor...span.upperBound) }
        }
        return gaps
    }

    static func color(for label: String) -> Color {
        switch label {
        case "person", "face": .red
        case "car", "truck", "motorcycle", "bus", "bicycle", "license_plate": .green
        case "dog", "cat", "bird", "horse", "bear", "deer": .orange
        case "package": .brown
        default: .blue
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, center: Double, spp: Double,
                      ranges: [RecordingRange], checked: [ClosedRange<Double>], motion: [RecordingRange],
                      now: Double, isLight: Bool,
                      marks: [EventMark]) {
        let top = Self.playheadY
        func y(_ t: Double) -> CGFloat { top - CGFloat((t - center) / spp) }
        // Never draw past "now".
        let tTop = min(center + Double(top) * spp, now)
        let tBottom = center - Double(size.height - top) * spp
        let trackWidth = size.width - trackInset - 16

        let footage: Color = isLight ? .white : .black

        // Track background (only up to "now") in the footage color, so time that hasn't
        // loaded yet doesn't flash as a gap.
        let trackTop = max(0, y(now))
        let track = CGRect(x: trackInset, y: trackTop, width: trackWidth, height: size.height - trackTop)
        ctx.fill(Path(roundedRect: track, cornerRadius: 6), with: .color(footage))

        // Gaps in the recordings: a gray bar in their own column, like the event bars.
        // Only time that has been checked with the server can be a gap.
        let gapX = Self.gapX(trackInset: trackInset)
        for gap in Self.gaps(checked: checked, ranges: ranges) where gap.upperBound > tBottom && gap.lowerBound < tTop {
            let y1 = y(min(gap.upperBound, tTop)), y2 = y(max(gap.lowerBound, tBottom))
            guard y2 - y1 >= 1 else { continue }
            let rect = CGRect(x: gapX, y: y1, width: Self.barWidth, height: max(Self.barWidth, y2 - y1))
            ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(Color(.systemGray3)))
        }

        // Motion: a yellow bar in the same column (motion only happens where there's footage).
        for m in motion where m.end > tBottom && m.start < tTop {
            let y1 = y(min(m.end, tTop)), y2 = y(max(m.start, tBottom))
            let height = max(Self.barWidth, y2 - y1)
            let rect = CGRect(x: gapX, y: y2 - height, width: Self.barWidth, height: height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(Self.motionColor))
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

        // Events: a colored bar for each, from its start to its end.
        for mark in marks {
            ctx.fill(Path(roundedRect: mark.bar, cornerRadius: Self.barWidth / 2),
                     with: .color(Self.color(for: mark.event.label)))
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

/// An event's picture on the timeline.
private struct EventThumbnail: View {
    @Environment(FrigateClient.self) private var client
    let event: FrigateEvent
    let size: CGSize

    var body: some View {
        RemoteImage(makeURL: { try client.thumbnailURL(event: event) }, contentMode: .fill,
                    cacheKey: "event:\(event.id)")
            .frame(width: size.width, height: size.height)
            .background(Color.secondary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
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
