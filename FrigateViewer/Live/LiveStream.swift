import Foundation
import Observation
import WebRTC

/// Live video and sound for one camera over WebRTC, using go2rtc inside Frigate.
///
/// Signaling goes through Frigate's own port (`/live/webrtc/api/ws`), so it uses the
/// same login as the rest of the app. Media then flows directly from go2rtc on port 8555.
/// If anything fails, `state` becomes `.failed` and the view falls back to pictures.
@MainActor @Observable
final class LiveStream: NSObject {
    enum State: Equatable { case idle, connecting, playing, failed }

    let camera: String
    private(set) var state: State = .idle
    /// True once the first video frame has arrived, so the view can swap out the picture.
    private(set) var hasVideo = false
    private(set) var videoTrack: RTCVideoTrack?
    /// False when the camera's audio can't be sent over WebRTC (for example AAC,
    /// unless go2rtc is set up to convert it to Opus).
    private(set) var hasAudio = false
    /// Streams start muted.
    private(set) var isMuted = true

    @ObservationIgnored private let client: FrigateClient
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
    @ObservationIgnored private var frameWatcher: FirstFrameWatcher?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var users = 0

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory(),
                                        audioDevice: PlayoutAudioDevice.shared)
    }()

    init(camera: String, client: FrigateClient) {
        self.camera = camera
        self.client = client
    }

    // MARK: - Public

    /// Starts the stream (if needed). Each `start` should be balanced by a `stop`,
    /// so a full-screen view can share the stream with the screen underneath it.
    func start() {
        users += 1
        guard users == 1 else { return }
        connect()
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        disconnect()
        state = .idle
    }

    /// Tries again after a failure.
    func retry() {
        guard users > 0 else { return }
        disconnect()
        connect()
    }

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioTrack?.isEnabled = !muted
        PlayoutAudioDevice.shared.setSoundOn(!muted && state != .idle)
    }

    // MARK: - Connection

    private func connect() {
        state = .connecting
        hasVideo = false

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed
            return
        }
        self.peer = peer

        let recvOnly = RTCRtpTransceiverInit()
        recvOnly.direction = .recvOnly
        peer.addTransceiver(of: .video, init: recvOnly)
        peer.addTransceiver(of: .audio, init: recvOnly)

        // Give up and show pictures if video hasn't started in time.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, !self.hasVideo else { return }
            self.fail()
        }

        Task {
            do {
                let streamName = client.config?.liveStreamName(for: camera) ?? camera
                let socket = try await client.webSocket(path: "live/webrtc/api/ws",
                                                        query: [URLQueryItem(name: "src", value: streamName)])
                guard self.peer === peer else { socket.cancel(); return }
                self.socket = socket
                socket.resume()
                receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }

                let offer = try await peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
                try await peer.setLocalDescription(offer)
                try await send(["type": "webrtc/offer", "value": offer.sdp])
            } catch {
                fail()
            }
        }
    }

    private func disconnect() {
        timeoutTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if let frameWatcher { videoTrack?.remove(frameWatcher) }
        frameWatcher = nil
        peer?.close()
        peer = nil
        videoTrack = nil
        audioTrack = nil
        hasAudio = false
        hasVideo = false
        PlayoutAudioDevice.shared.setSoundOn(false)
    }

    private func fail() {
        disconnect()
        state = .failed
    }

    private func send(_ message: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket?.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else {
                // The socket can close once the call is set up; only a failure before video counts.
                if !hasVideo && self.socket === socket { fail() }
                return
            }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            let value = json["value"] as? String ?? ""
            switch type {
            case "webrtc/answer":
                guard let peer else { return }
                do {
                    try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: value))
                    await addServerCandidates(to: peer)
                } catch {
                    fail()
                    return
                }
            case "webrtc/candidate":
                guard let peer, !value.isEmpty else { continue }
                let mid = peer.transceivers.first?.mid ?? "0"
                try? await peer.add(RTCIceCandidate(sdp: value, sdpMLineIndex: 0, sdpMid: mid))
            case "error":
                fail()
                return
            default:
                continue
            }
        }
    }

    /// go2rtc running in Docker often only reports its internal address, which the phone
    /// can't reach. Also offer the server's own address on go2rtc's WebRTC port (8555).
    private func addServerCandidates(to peer: RTCPeerConnection) async {
        guard let host = client.settings.baseURL?.host(), let ip = await Self.resolveIPv4(host) else { return }
        let mid = peer.transceivers.first?.mid ?? "0"
        let candidates = [
            "candidate:3735928559 1 udp 2130706431 \(ip) 8555 typ host",
            "candidate:3735928560 1 tcp 2130706430 \(ip) 8555 typ host tcptype passive",
        ]
        for c in candidates {
            try? await peer.add(RTCIceCandidate(sdp: c, sdpMLineIndex: 0, sdpMid: mid))
        }
    }

    private nonisolated static func resolveIPv4(_ host: String) async -> String? {
        if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result, let addr = info.pointee.ai_addr else {
                return nil
            }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            return String(cString: buffer)
        }.value
    }

    // MARK: - Tracks

    fileprivate func didReceive(track: RTCMediaStreamTrack) {
        if let video = track as? RTCVideoTrack, videoTrack == nil {
            videoTrack = video
            let watcher = FirstFrameWatcher { [weak self] in
                Task { @MainActor in
                    guard let self, !self.hasVideo else { return }
                    self.hasVideo = true
                    self.state = .playing
                    self.timeoutTask?.cancel()
                }
            }
            frameWatcher = watcher
            video.add(watcher)
        } else if let audio = track as? RTCAudioTrack {
            audioTrack = audio
            hasAudio = true
            audio.isEnabled = !isMuted
            PlayoutAudioDevice.shared.setSoundOn(!isMuted)
        }
    }

    fileprivate func didChange(_ connection: RTCPeerConnectionState) {
        if connection == .failed { fail() }
    }

    fileprivate func didGather(_ candidate: RTCIceCandidate) {
        Task { try? await send(["type": "webrtc/candidate", "value": candidate.sdp]) }
    }
}

// WebRTC calls these on its own thread.
extension LiveStream: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                    streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        Task { @MainActor in self.didReceive(track: track) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.didChange(newState) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in self.didGather(candidate) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Reports the first decoded video frame.
private final class FirstFrameWatcher: NSObject, RTCVideoRenderer {
    private var fired = false
    private let onFirstFrame: () -> Void

    init(onFirstFrame: @escaping () -> Void) { self.onFirstFrame = onFirstFrame }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil, !fired else { return }
        fired = true
        onFirstFrame()
    }
}
