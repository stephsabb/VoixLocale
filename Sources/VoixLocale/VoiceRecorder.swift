import AVFoundation
import Foundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var level: Double = 0
    @Published var recordingURL: URL?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var highestPower: Float = -160

    func toggle() {
        isRecording ? stop() : requestAndStart()
    }

    private func requestAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard granted else {
                    self?.errorMessage = "L’accès au microphone est nécessaire pour créer une voix."
                    return
                }
                self?.start()
            }
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voixlocale-sample.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            guard recorder?.prepareToRecord() == true, recorder?.record() == true else {
                throw NSError(
                    domain: "VoixLocale", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Le microphone n’a pas pu démarrer. Vérifiez l’entrée audio sélectionnée dans Réglages Système."]
                )
            }
            recordingURL = nil
            duration = 0
            level = 0
            highestPower = -160
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let power = recorder.averagePower(forChannel: 0)
                    self.highestPower = max(self.highestPower, power)
                    self.level = max(0, min(1, Double(power + 60) / 60))
                    self.duration = recorder.currentTime
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        if highestPower < -45 {
            recordingURL = nil
            errorMessage = "Aucun son exploitable n’a été détecté. Vérifiez que le microphone n’est pas coupé et que le vumètre bouge pendant la lecture."
        } else {
            recordingURL = recorder?.url
        }
        level = 0
        isRecording = false
    }
}
