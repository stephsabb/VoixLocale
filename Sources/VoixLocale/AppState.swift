import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var text = ""
    @Published var voices: [VoiceProfile] = []
    @Published var selectedVoiceID = ""
    @Published var speed = 1.10
    @Published var hesitations = false
    @Published var isBackendReady = false
    @Published var isBusy = false
    @Published var status = "Démarrage du moteur local…"
    @Published var errorMessage: String?
    @Published var generatedURL: URL?
    @Published var generatedDuration: Double = 0
    @Published var isPlaying = false
    @Published var isPaused = false

    let backend = BackendService.shared
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?

    func start() async {
        backend.start()
        do {
            try await backend.waitUntilReady()
            isBackendReady = true
            status = "Prêt"
            try await refreshVoices()
        } catch { show(error) }
    }

    func refreshVoices() async throws {
        voices = try await backend.voices()
        if !voices.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = voices.first?.id ?? ""
        }
    }

    func importFile(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            text = try await backend.extract(url: url)
            status = "Document importé"
        } catch { show(error) }
    }

    func enroll(name: String, transcript: String, audioURL: URL) async -> Bool {
        isBusy = true
        status = "Préparation de la voix…"
        defer { isBusy = false }
        do {
            let voice = try await backend.enroll(name: name, transcript: transcript, audioURL: audioURL)
            try await refreshVoices()
            selectedVoiceID = voice.id
            status = "Voix « \(voice.name) » ajoutée"
            return true
        } catch {
            show(error)
            return false
        }
    }

    func deleteVoice(_ voice: VoiceProfile) async {
        do {
            try await backend.deleteVoice(id: voice.id)
            try await refreshVoices()
        } catch { show(error) }
    }

    func generate() async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Ajoutez d’abord un texte."
            return
        }
        guard !selectedVoiceID.isEmpty else {
            errorMessage = "Créez ou sélectionnez d’abord une voix."
            return
        }
        isBusy = true
        stopGenerated()
        generatedURL = nil
        status = "Génération locale en cours… Le premier lancement télécharge le modèle."
        defer { isBusy = false }
        do {
            let result = try await backend.generate(
                text: text, voiceID: selectedVoiceID, speed: speed,
                hesitations: hesitations
            )
            generatedURL = URL(fileURLWithPath: result.path)
            generatedDuration = result.duration
            status = "MP3 prêt — \(result.segments) segments"
        } catch { show(error) }
    }

    func playGenerated() {
        guard let url = generatedURL else { return }
        do {
            if player == nil || player?.url != url {
                player = try AVAudioPlayer(contentsOf: url)
            }
            player?.play()
            isPlaying = true
            isPaused = false
            startPlaybackTimer()
        } catch { show(error) }
    }

    func pauseGenerated() {
        guard player?.isPlaying == true else { return }
        player?.pause()
        isPlaying = false
        isPaused = true
    }

    func stopGenerated() {
        player?.stop()
        player?.currentTime = 0
        player = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        isPaused = false
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player?.isPlaying != true && !self.isPaused {
                    self.isPlaying = false
                    self.player?.currentTime = 0
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                }
            }
        }
    }

    func exportGenerated() {
        guard let source = generatedURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        panel.nameFieldStringValue = "lecture-voix-locale.mp3"
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                status = "MP3 enregistré"
            } catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "Erreur"
    }
}
