import AVFoundation
import WebRTC

/// A WebRTC audio device that only plays sound and never opens the microphone.
///
/// WebRTC's built-in audio device always sets up recording too, which would ask for
/// microphone access just to listen to a camera. This one plays the received audio
/// through AVAudioEngine, and only while the camera is unmuted.
final class PlayoutAudioDevice: NSObject, RTCAudioDevice {
    static let shared = PlayoutAudioDevice()

    private let sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private weak var delegate: RTCAudioDeviceDelegate?
    private let lock = NSLock()
    private var wantsSound = false
    private var playoutRequested = false

    // MARK: Called by the app

    /// Turns sound on or off. Sound only plays while WebRTC is also playing.
    func setSoundOn(_ on: Bool) {
        lock.lock(); wantsSound = on; lock.unlock()
        updateEngine()
    }

    private func updateEngine() {
        lock.lock()
        let shouldRun = wantsSound && playoutRequested && delegate != nil
        lock.unlock()
        DispatchQueue.main.async { [self] in
            if shouldRun {
                guard !engine.isRunning else { return }
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
                attachSourceIfNeeded()
                try? engine.start()
            } else if engine.isRunning {
                engine.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func attachSourceIfNeeded() {
        guard sourceNode == nil else { return }
        // WebRTC hands over 16-bit mono samples.
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, data in
            guard let self, let delegate = self.delegate else {
                Self.silence(data)
                return noErr
            }
            var flags = AudioUnitRenderActionFlags()
            let status = delegate.getPlayoutData(&flags, timestamp, 0, frameCount, data)
            if status != noErr { Self.silence(data) }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    private static func silence(_ data: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let mData = buffer.mData { memset(mData, 0, Int(buffer.mDataByteSize)) }
        }
    }

    // MARK: RTCAudioDevice

    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { delegate != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        return true
    }

    func terminateDevice() -> Bool {
        lock.lock(); playoutRequested = false; lock.unlock()
        updateEngine()
        delegate = nil
        return true
    }

    var isPlayoutInitialized: Bool { true }
    func initializePlayout() -> Bool { true }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playoutRequested
    }

    func startPlayout() -> Bool {
        lock.lock(); playoutRequested = true; lock.unlock()
        updateEngine()
        return true
    }

    func stopPlayout() -> Bool {
        lock.lock(); playoutRequested = false; lock.unlock()
        updateEngine()
        return true
    }

    // Never records.
    var isRecordingInitialized: Bool { false }
    func initializeRecording() -> Bool { false }
    var isRecording: Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }
}
