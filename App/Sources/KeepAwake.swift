import AVFoundation
import Foundation

/// 后台保持运行: while a companion is working and Clio is in the background, play silence so iOS does not freeze it.
/// Off unless the person turns it on (it costs a little battery); stops the moment no turn is running.
@MainActor
enum KeepAwake {
    static let key = "bg.keepAwake"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var player: AVAudioPlayer?
    private static var watching: NSObjectProtocol?

    static var playing: Bool { player?.isPlaying == true }

    static func start() {
        guard on, player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixed with others: music the person is playing goes on undisturbed.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let silence = try AVAudioPlayer(data: silentWave())
            silence.numberOfLoops = -1
            silence.volume = 0
            silence.play()
            player = silence
        } catch {
            Diag.note("后台保持运行没开起来：\(error.localizedDescription)")
            return
        }
        // A phone call stops the silence; after it, start it again.
        watching = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated {
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.play()
            }
        }
    }

    static func stop() {
        guard let silence = player else { return }
        silence.stop()
        player = nil
        if let watching { NotificationCenter.default.removeObserver(watching) }
        watching = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One second of silence, 8 kHz mono 16-bit, as a WAV file.
    private static func silentWave() -> Data {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let bytes = samples * 2
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(16); put16(1); put16(1); put(rate); put(rate * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }
}
