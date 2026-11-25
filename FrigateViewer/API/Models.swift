import Foundation

/// Subset of `GET /api/config` that the app needs.
struct FrigateConfig: Decodable {
    let cameras: [String: CameraConfig]

    struct CameraConfig: Decodable {
        let enabled: Bool?
        let detect: Detect?
        let record: Record?
        let live: Live?

        struct Live: Decodable {
            /// Display name → go2rtc stream name.
            let streams: [String: String]?
        }

        struct Detect: Decodable {
            let width: Int?
            let height: Int?
        }

        struct Record: Decodable {
            let enabled: Bool?
        }
    }

    func isRecording(_ camera: String) -> Bool {
        cameras[camera]?.record?.enabled ?? false
    }

    /// The go2rtc stream used for live video. Defaults to the camera's own name.
    func liveStreamName(for camera: String) -> String {
        let streams = cameras[camera]?.live?.streams ?? [:]
        return streams.sorted { $0.key < $1.key }.first?.value ?? camera
    }

    /// Camera names sorted alphabetically, skipping disabled cameras.
    var cameraNames: [String] {
        cameras
            .filter { $0.value.enabled ?? true }
            .map(\.key)
            .sorted()
    }

    func aspectRatio(for camera: String) -> CGFloat {
        guard let d = cameras[camera]?.detect, let w = d.width, let h = d.height, h > 0 else {
            return 16.0 / 9.0
        }
        return CGFloat(w) / CGFloat(h)
    }
}

/// An item from `GET /api/events`.
struct FrigateEvent: Decodable, Identifiable, Hashable {
    let id: String
    let camera: String
    let label: String
    let startTime: Double
    let endTime: Double?
    let hasClip: Bool
    let hasSnapshot: Bool
    let zones: [String]
    let topScore: Double?
    let data: EventData?

    struct EventData: Decodable, Hashable {
        let score: Double?
        let topScore: Double?

        enum CodingKeys: String, CodingKey {
            case score
            case topScore = "top_score"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, camera, label, zones, data
        case startTime = "start_time"
        case endTime = "end_time"
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
        case topScore = "top_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        camera = try c.decode(String.self, forKey: .camera)
        label = try c.decode(String.self, forKey: .label)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime)
        hasClip = try c.decodeIfPresent(Bool.self, forKey: .hasClip) ?? false
        hasSnapshot = try c.decodeIfPresent(Bool.self, forKey: .hasSnapshot) ?? false
        zones = try c.decodeIfPresent([String].self, forKey: .zones) ?? []
        topScore = try c.decodeIfPresent(Double.self, forKey: .topScore)
        data = try? c.decodeIfPresent(EventData.self, forKey: .data)
    }

    var startDate: Date { Date(timeIntervalSince1970: startTime) }
    var endDate: Date? { endTime.map { Date(timeIntervalSince1970: $0) } }
    var isInProgress: Bool { endTime == nil }

    /// Best available confidence score, 0...1.
    var score: Double? { data?.topScore ?? topScore ?? data?.score }

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime - startTime
    }
}

extension String {
    /// "front_door" -> "Front Door"
    var prettyName: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}
