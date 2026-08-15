import AppKit
import AVFoundation
import Foundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var level: Double = 0
    @Published var recordingURL: URL?
    @Published var errorMessage: String?
    /// Vrai lorsque l’autorisation micro a été refusée : l’interface propose alors d’ouvrir les Réglages Système.
    @Published var needsMicrophoneSettings = false
    /// Vrai pendant que la boîte de dialogue d’autorisation macOS est affichée, pour empêcher
    /// un second appui sur « Enregistrer » de relancer une demande en parallèle.
    @Published var isRequestingAccess = false

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var highestPower: Float = -160

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func toggle() {
        isRecording ? stop() : requestAndStart()
    }

    func openSystemSettings() {
        guard let url = Self.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestAndStart() {
        guard !isRequestingAccess else { return }
        errorMessage = nil
        needsMicrophoneSettings = false

        switch authorizationStatus {
        case .authorized:
            start()
        case .notDetermined:
            isRequestingAccess = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRequestingAccess = false
                    guard granted else {
                        self.denyAccess()
                        return
                    }
                    self.start()
                }
            }
        case .denied, .restricted:
            denyAccess()
        @unknown default:
            denyAccess()
        }
    }

    private func denyAccess() {
        needsMicrophoneSettings = true
        errorMessage = "L’accès au microphone est nécessaire pour créer une voix. "
            + "Autorisez VoixLocale dans Réglages Système › Confidentialité et sécurité › Microphone, "
            + "puis relancez l’enregistrement."
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
