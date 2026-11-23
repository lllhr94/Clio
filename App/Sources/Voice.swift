import AVFoundation
import Speech
import SwiftUI

/// Speech to text: either the phone's own live recognizer (default) or a standalone OpenAI-compatible cloud endpoint.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    /// True after stopping a cloud recording while waiting for the transcription response.
    @Published private(set) var transcribing = false
    /// How loud it is now, 0...1, for the button to breathe with.
    @Published private(set) var level: CGFloat = 0
    @Published var problem: String?

    /// Gets everything heard so far, whole each time.
    var onText: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    private var recorder: AVAudioRecorder?
    private var cloudFile: URL?
    private var meterTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var cloudEndpoint: URL?
    private var cloudKey = ""
    private var cloudModel = ""
    private var cloudLanguage = ""

    private var sessionID: UUID?
    private var tapInstalled = false
    private var recordingSessionActive = false
    private var finishing: Task<Void, Never>?

    init() {
        Task.detached(priority: .utility) {
            Self.cleanupStaleRecordings()
        }
    }

    nonisolated private static func cleanupStaleRecordings() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let urls = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-300)
        for url in urls where url.lastPathComponent.hasPrefix("clio-voice-") && url.pathExtension.lowercased() == "m4a" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    var busy: Bool { sessionID != nil }

    func start() async {
        guard !busy else { return }
        let id = UUID()
        sessionID = id
        problem = nil

        if VoiceTranscription.mode == .cloud {
            await startCloud(id: id)
        } else {
            await startSystem(id: id)
        }
    }

    private func startSystem(id: UUID) async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard speech == .authorized else {
            problem = "没有语音识别权限，去 设置 → 隐私与安全性 → 语音识别 里打开。"
            cancel()
            return
        }
        let recorded = await AVAudioApplication.requestRecordPermission()
        guard sessionID == id else { return }
        guard recorded else {
            problem = "没有麦克风权限，去 设置 → 隐私与安全性 → 麦克风 里打开。"
            cancel()
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "语音识别现在用不了，稍后再试。"
            cancel()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            recordingSessionActive = true
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            let format = input.outputFormat(forBus: 0)
            guard Self.usable(hardware), Self.usable(format) else {
                problem = "现在没有可用的麦克风，接上麦克风后再试。"
                cancel()
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.sessionID == id, self.listening else { return }
                    self.level = level
                }
            })
            tapInstalled = true
            engine.prepare()
            try engine.start()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { listening = true }
            task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, done in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let text { self.onText?(text) }
                    if done { self.finish(cancelTask: false) }
                }
            })
        } catch {
            problem = "开不了麦克风：\(error.localizedDescription)"
            cancel()
        }
    }

    private func startCloud(id: UUID) async {
        let endpoint: URL
        switch VoiceTranscription.validateEndpoint(VoiceTranscription.baseURL) {
        case .success(let url):
            endpoint = url
        case .failure(let err):
            problem = err.localizedDescription
            cancel()
            return
        }
        let modelName = VoiceTranscription.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            problem = "还没填语音转写模型名，请去 设置 › 对话显示与反馈 › 语音输入与转写 配置。"
            cancel()
            return
        }
        let key = await VoiceTranscription.readKey(for: endpoint)
        guard sessionID == id else { return }
        let recorded = await AVAudioApplication.requestRecordPermission()
        guard sessionID == id else { return }
        guard recorded else {
            problem = "没有麦克风权限，去 设置 → 隐私与安全性 → 麦克风 里打开。"
            cancel()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true)
            recordingSessionActive = true

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("clio-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let rec = try AVAudioRecorder(url: fileURL, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                try? FileManager.default.removeItem(at: fileURL)
                problem = "麦克风启动失败，请重试。"
                cancel()
                return
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            recorder = rec
            cloudFile = fileURL
            cloudEndpoint = endpoint
            cloudKey = key
            cloudModel = modelName
            cloudLanguage = VoiceTranscription.language
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { listening = true }

            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard let self, self.sessionID == id, self.listening, let rec = self.recorder else { return }
                    rec.updateMeters()
                    let db = rec.averagePower(forChannel: 0)
                    self.level = CGFloat(min(1, max(0, (db + 50) / 40)))
                }
            }
        } catch {
            problem = "开不了麦克风：\(error.localizedDescription)"
            cancel()
        }
    }

    /// Stops recording, allowing a final transcription before releasing the recognizer or uploading to cloud STT.
    func stop() {
        guard let id = sessionID else { return }
        if let rec = recorder, let fileURL = cloudFile, let endpoint = cloudEndpoint {
            meterTask?.cancel()
            meterTask = nil
            rec.stop()
            recorder = nil
            stopRecording()
            withAnimation(.smooth) { transcribing = true }
            let key = cloudKey
            let modelName = cloudModel
            let lang = cloudLanguage
            uploadTask = Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: fileURL) }
                do {
                    let heard = try await VoiceTranscription.transcribe(
                        fileURL: fileURL,
                        endpoint: endpoint,
                        apiKey: key,
                        model: modelName,
                        language: lang
                    )
                    guard let self, self.sessionID == id, !Task.isCancelled else { return }
                    if !heard.isEmpty {
                        self.onText?(heard)
                        Haptics.tick(0.5)
                    } else {
                        self.problem = "没有识别出文字，请再试一次。"
                    }
                    self.finish(cancelTask: false)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.sessionID == id else { return }
                    self.problem = error.localizedDescription
                    Haptics.lock()
                    self.finish(cancelTask: false)
                }
            }
            return
        }

        guard let request, finishing == nil else { return }
        stopRecording()
        request.endAudio()
        finishing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.sessionID == id else { return }
            self.cancel()
        }
    }

    /// Leaving the chat must also cancel an outstanding permission prompt or final callback.
    func cancel() {
        guard busy else { return }
        finish(cancelTask: true)
    }

    private func stopRecording() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let rec = recorder {
            rec.stop()
            recorder = nil
        }
        meterTask?.cancel()
        meterTask = nil
        withAnimation(.smooth) {
            listening = false
            level = 0
        }
        if recordingSessionActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, mode: .default)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            recordingSessionActive = false
        }
    }

    private func finish(cancelTask: Bool) {
        sessionID = nil
        finishing?.cancel()
        finishing = nil
        if cancelTask {
            uploadTask?.cancel()
            task?.cancel()
            if let file = cloudFile {
                try? FileManager.default.removeItem(at: file)
            }
        }
        uploadTask = nil
        cloudFile = nil
        cloudEndpoint = nil
        cloudKey = ""
        stopRecording()
        withAnimation(.smooth) { transcribing = false }
        task = nil
        request = nil
        onText = nil
    }

    private static func usable(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate.isFinite && format.sampleRate > 0
    }

    /// Runs on the audio thread: feeds the recognizer and measures loudness.
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest, level: @escaping @Sendable (CGFloat) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            level(CGFloat(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 40))))
        }
    }

    nonisolated private static func results(_ report: @escaping @Sendable (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            report(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true)
        }
    }
}
