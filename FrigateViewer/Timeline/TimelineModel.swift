import AVFoundation
import Foundation
import Observation
import UIKit

/// Drives the recordings timeline for one camera: where the playhead is, what is
/// recorded, and whether we're showing live, scrubbing, or playing back.
@MainActor
@Observable
final class TimelineModel {
    enum Mode: Equatable { case live, scrubbing, playback }

    let camera: String
    @ObservationIgnored let client: FrigateClient

    /// Wall-clock time (Unix seconds) under the playhead.
    private(set) var centerTime: Double = Date().timeIntervalSince1970
    /// Zoom: seconds of footage per point of timeline height.
    var secondsPerPoint: Double = 6
    private(set) var mode: Mode = .live
    private(set) var ranges: [RecordingRange] = []
    /// For each day that has been fetched: the start of the day and how far it was checked.
    /// Only time inside these spans can be shown as a gap; the rest isn't known yet.
    private(set) var checkedSpans: [Date: ClosedRange<Double>] = [:]
    private(set) var isPlaying = false
    /// Live view frozen on the current frame.
    private(set) var isLivePaused = false
    private(set) var isBuffering = false
    private(set) var previewImage: UIImage?
    private(set) var recordingDays: [Date] = []
    private(set) var message: String?
    /// Recordings start muted; audio tracks are disabled entirely while muted so
    /// playback never depends on the audio device.
    private(set) var isMuted = true

    let player = AVPlayer()

    /// Timeline viewport height, set by the view; used to decide which days to load.
    var viewportHeight: Double = 500

    static let minSecondsPerPoint = 0.5
    static let maxSecondsPerPoint = 120.0
    /// Anything this close to "now" is treated as live.
    static let liveThreshold = 30.0

    @ObservationIgnored private var loadedDays = Set<Date>()
    @ObservationIgnored private var loadingDays = [Date: Task<Void, Never>]()
    @ObservationIgnored private var vodStart: Double = 0
    @ObservationIgnored private var vodEnd: Double = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var momentumTask: Task<Void, Never>?

    init(camera: String, client: FrigateClient) {
        self.camera = camera
        self.client = client
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        liveTask?.cancel()
        previewTask?.cancel()
        momentumTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        statusObservation?.invalidate()
        itemStatusObservation?.invalidate()
    }

    func toggleMute() {
        isMuted.toggle()
        if let item = player.currentItem { applyAudio(to: item) }
    }

    private func applyAudio(to item: AVPlayerItem) {
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = !isMuted
        }
        player.isMuted = isMuted
    }

    var now: Double { Date().timeIntervalSince1970 }
    var earliestTime: Double { recordingDays.last?.timeIntervalSince1970 ?? (now - 86400) }

    // MARK: - Setup

    func start() async {
        goLive()
        if let days = try? await client.recordingDays(camera: camera) {
            recordingDays = days
        }
        await ensureRangesLoaded()
    }

    // MARK: - Live

    func goLive() {
        momentumTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mode = .live
        isLivePaused = false
        message = nil
        centerTime = now
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.mode == .live else { return }
                if !self.isLivePaused { self.centerTime = self.now }
                // Extend today's ranges as new footage is written.
                if let last = self.ranges.last, self.now - last.end < 120 {
                    self.ranges[self.ranges.count - 1].end = self.now - 5
                }
            }
        }
    }

    // MARK: - Scrubbing

    /// Moves the playhead by `points` of timeline (positive = later).
    func scrub(byPoints points: Double) {
        momentumTask?.cancel()
        beginScrubbing()
        setCenter(centerTime + points * secondsPerPoint)
    }

    /// Called when the finger lifts. `velocity` is in points/second (positive = later).
    func endScrub(velocity: Double) {
        momentumTask?.cancel()
        guard abs(velocity) > 200 else { finishScrub(); return }
        momentumTask = Task { [weak self] in
            var v = velocity
            while abs(v) > 30, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                self.setCenter(self.centerTime + v * 0.016 * self.secondsPerPoint)
                v *= 0.93
                if self.centerTime >= self.now { break }
            }
            guard !Task.isCancelled else { return }
            self?.finishScrub()
        }
    }

    func jump(to time: Double) {
        momentumTask?.cancel()
        beginScrubbing()
        setCenter(time)
        finishScrub()
    }

    /// How far behind "now" recordings can be played: the newest segment is still being written.
    static let liveRecordingDelay = 20.0

    func skip(by seconds: Double) {
        guard mode == .live else { jump(to: centerTime + seconds); return }
        guard seconds < 0 else { return }  // Can't skip ahead of live.
        // From live, play the most recent recording, `seconds` behind what's playable.
        liveTask?.cancel()
        isLivePaused = false
        let target = now - Self.liveRecordingDelay + seconds
        Task { await startPlayback(at: target) }
    }

    func zoom(to spp: Double) {
        secondsPerPoint = min(max(spp, Self.minSecondsPerPoint), Self.maxSecondsPerPoint)
        Task { await ensureRangesLoaded() }
    }

    private func beginScrubbing() {
        if mode != .scrubbing {
            liveTask?.cancel()
            player.pause()
            mode = .scrubbing
            message = nil
        }
    }

    private func setCenter(_ t: Double) {
        centerTime = min(max(t, earliestTime), now)
        schedulePreview()
        Task { await ensureRangesLoaded() }
    }

    private func finishScrub() {
        previewTask?.cancel()
        if now - centerTime < Self.liveThreshold {
            goLive()
        } else {
            Task { await startPlayback(at: centerTime) }
        }
    }

    /// Loads a still frame for the playhead position while dragging (debounced).
    private func schedulePreview() {
        previewTask?.cancel()
        let t = centerTime
        guard recordedRange(containing: t) != nil else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            guard let url = try? self.client.recordingFrameURL(camera: self.camera, time: t, height: 540),
                  let data = try? await self.client.data(from: url),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            self.previewImage = image
        }
    }

    // MARK: - Playback

    func togglePlay() {
        switch mode {
        case .live:
            isLivePaused.toggle()
            if !isLivePaused { centerTime = now }
        case .scrubbing: finishScrub()
        case .playback:
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }
    }

    private func startPlayback(at requested: Double) async {
        await ensureRangesLoaded()
        var t = requested
        guard let range = recordedRange(containing: t) ?? ranges.first(where: { $0.start > t }) else {
            message = "No recording here"
            mode = .playback
            player.replaceCurrentItem(with: nil)
            return
        }
        if !range.contains(t) { t = range.start }
        // Leave a margin before "now" so the segment being written isn't requested.
        let end = min(range.end, t + 3600, now - 15)
        guard end - t > 2 else { goLive(); return }

        mode = .playback
        message = nil
        centerTime = t
        vodStart = t
        vodEnd = end
        do {
            let item = try await client.playerItem(for: client.vodURL(camera: camera, start: t, end: end))
            guard mode == .playback, vodStart == t else { return }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.playedToEnd() }
            }
            failObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    self?.message = "Playback stopped: \(err?.localizedDescription ?? "unknown error")"
                }
            }
            // Apply mute as soon as the tracks are known, before audio starts.
            itemStatusObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in self?.applyAudio(to: item) }
            }
            player.isMuted = isMuted
            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            message = error.localizedDescription
        }
    }

    private func playedToEnd() {
        Task { await startPlayback(at: vodEnd + 1) }
    }

    private func playerTimeChanged(_ time: CMTime) {
        guard mode == .playback, player.currentItem != nil, time.isNumeric else { return }
        let t = vodStart + time.seconds
        if t >= vodStart { centerTime = min(t, now) }
    }

    // MARK: - Recorded ranges

    func recordedRange(containing t: Double) -> RecordingRange? {
        ranges.first { $0.contains(t) }
    }

    /// Fetches recordings for every local day the viewport touches.
    func ensureRangesLoaded() async {
        // The playhead is near the top of the timeline, so almost all visible time is below it.
        let below = viewportHeight * secondsPerPoint
        let lo = max(centerTime - below * 1.3, earliestTime)
        let hi = min(centerTime + below * 0.3, now)
        guard hi > lo else { return }
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date(timeIntervalSince1970: lo))
        let lastDay = cal.startOfDay(for: Date(timeIntervalSince1970: hi))
        var toLoad: [Date] = []
        var inFlight: [Task<Void, Never>] = []
        while day <= lastDay {
            if let task = loadingDays[day] {
                inFlight.append(task)
            } else if !loadedDays.contains(day) {
                toLoad.append(day)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        // Cap per pass so a zoomed-out fling doesn't fire dozens of requests.
        for day in toLoad.suffix(4) {
            let task = Task { [weak self] in
                guard let self else { return }
                let start = day.timeIntervalSince1970
                let end = cal.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince1970
                do {
                    let found = try await self.client.recordingRanges(camera: self.camera, after: start, before: min(end, self.now))
                    self.ranges = FrigateClient.merge(self.ranges + found)
                    self.checkedSpans[day] = start...max(start, min(end, self.now))
                    // Today keeps growing; don't mark it as fully loaded.
                    if end < self.now { self.loadedDays.insert(day) }
                } catch {
                    self.message = error.localizedDescription
                }
                self.loadingDays[day] = nil
            }
            loadingDays[day] = task
            inFlight.append(task)
        }
        // Wait for every day in view, including ones another call already started,
        // so callers like startPlayback see their ranges.
        for task in inFlight { await task.value }
    }
}
