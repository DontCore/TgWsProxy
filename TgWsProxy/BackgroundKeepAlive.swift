import AVFoundation
import Foundation

/// Держит приложение живым в фоне: тихий звуковой поток.
/// iOS не замораживает процесс с активным аудиосессией — это позволяет
/// прокси работать 24/7 без VPN-профиля и без энтайтментов.
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)

        if player == nil {
            guard let url = Self.silentFileURL() else { return }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1 // бесконечный повтор
            player?.volume = 0.01
            player?.prepareToPlay()
        }
        player?.play()
    }

    func stop() {
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Генерирует WAV с тишиной (10 секунд, 8 кГц, моно) во временной папке.
    private static func silentFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procam_silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000
        let samples = sampleRate * 10
        var data = Data()

        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + samples * 2))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))                     // размер fmt-чанка
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // моно
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))         // байт/сек
        append(UInt16(2))                      // блок
        append(UInt16(16))                     // бит/сэмпл
        data.append("data".data(using: .ascii)!)
        append(UInt32(samples * 2))
        data.append(contentsOf: [UInt8](repeating: 0, count: samples * 2))

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
