import AVFoundation
import Speech
import SwiftUI

/// Speech to text with the phone's own recognizer: the words appear while the user talks.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    /// How loud it is now, 0...1, for the button to breathe with.
    @Published private(set) var level: CGFloat = 0
    @Published var problem: String?

    /// Gets everything heard so far, whole each time.
    var onText: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    private var sessionID: UUID?
    private var tapInstalled = false
    private var recordingSessionActive = false
    private var finishing: Task<Void, Never>?

    var busy: Bool { sessionID != nil }

    func start() async {
        guard !busy else { return }
        let id = UUID()
        sessionID = id
        problem = nil
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

    /// Stops recording, allowing a final transcription before releasing the recognizer.
    func stop() {
        guard let request, let id = sessionID, finishing == nil else { return }
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
        withAnimation(.smooth) {
            listening = false
            level = 0
        }
        if recordingSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            recordingSessionActive = false
        }
    }

    private func finish(cancelTask: Bool) {
        sessionID = nil
        finishing?.cancel()
        finishing = nil
        stopRecording()
        if cancelTask { task?.cancel() }
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
