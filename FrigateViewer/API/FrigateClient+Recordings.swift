import AVFoundation
import Foundation

/// A stretch of continuous recording, in Unix seconds.
struct RecordingRange: Hashable {
    var start: Double
    var end: Double

    func contains(_ t: Double) -> Bool { t >= start && t <= end }
}

private struct RecordingSegment: Decodable {
    let start_time: Double
    let end_time: Double
}

private struct RecordingDaySummary: Decodable {
    let day: String
}

extension FrigateClient {
    /// Recorded ranges for a camera between two times. Frigate stores ~10 s segments;
    /// segments closer than `gapTolerance` are merged into one range.
    func recordingRanges(camera: String, after: Double, before: Double, gapTolerance: Double = 3) async throws -> [RecordingRange] {
        let data = try await data(from: url("api/\(camera)/recordings", query: [
            URLQueryItem(name: "after", value: String(Int(after))),
            URLQueryItem(name: "before", value: String(Int(before))),
        ]))
        let segments = try JSONDecoder().decode([RecordingSegment].self, from: data)
            .sorted { $0.start_time < $1.start_time }
        return Self.merge(segments.map { RecordingRange(start: $0.start_time, end: $0.end_time) }, tolerance: gapTolerance)
    }

    static func merge(_ ranges: [RecordingRange], tolerance: Double = 3) -> [RecordingRange] {
        var merged: [RecordingRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, r.start <= last.end + tolerance {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Days (local to the server) that have recordings, newest first.
    func recordingDays(camera: String) async throws -> [Date] {
        let data = try await data(from: url("api/\(camera)/recordings/summary"))
        let days = try JSONDecoder().decode([RecordingDaySummary].self, from: data)
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return days.compactMap { fmt.date(from: $0.day) }.sorted(by: >)
    }

    /// A single frame from the recordings at time `t`.
    func recordingFrameURL(camera: String, time t: Double, height: Int) throws -> URL {
        try url("api/\(camera)/recordings/\(Int(t))/snapshot.jpg", query: [URLQueryItem(name: "height", value: String(height))])
    }

    /// HLS playlist for the recording between two times.
    func vodURL(camera: String, start: Double, end: Double) throws -> URL {
        try url("vod/\(camera)/start/\(Int(start))/end/\(Int(end.rounded(.up)))/index.m3u8")
    }

    /// An AVPlayerItem that sends the login cookie (needed on port 8971).
    func playerItem(for url: URL) async throws -> AVPlayerItem {
        if settings.usesAuthentication { try await ensureLoggedIn() }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        return AVPlayerItem(asset: asset)
    }
}
