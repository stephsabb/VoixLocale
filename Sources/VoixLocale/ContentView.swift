import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("VoixLocale").font(.headline)
                        Text("Synthèse vocale privée sur votre Mac").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    AppTabButton(
                        title: "Lecture", icon: "text.bubble", tag: 0,
                        selection: $selection
                    )
                    AppTabButton(
                        title: "Mes voix", icon: "person.wave.2", tag: 1,
                        selection: $selection
                    )
                    AppTabButton(
                        title: "Réglages", icon: "slider.horizontal.3", tag: 2,
                        selection: $selection
                    )
                }
                .padding(5)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))

                HStack(spacing: 7) {
                    Circle().fill(state.isBackendReady ? .green : .orange).frame(width: 8, height: 8)
                    Text(state.status).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(.bar)

            Group {
                switch selection {
                case 1:
                    VoicesView()
                case 2:
                    SettingsView()
                default:
                GeneratorView(openVoices: { selection = 1 })
                }
            }
        }
    }
}

private struct AppTabButton: View {
    let title: String
    let icon: String
    let tag: Int
    @Binding var selection: Int

    private var isSelected: Bool { selection == tag }

    var body: some View {
        Button { selection = tag } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
            .frame(width: 82, height: 45)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: isSelected ? .black.opacity(0.10) : .clear, radius: 3, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GeneratorView: View {
    @EnvironmentObject private var state: AppState
    @State private var importing = false
    let openVoices: () -> Void

    private var supportedTypes: [UTType] {
        [.plainText, .pdf, UTType(filenameExtension: "docx") ?? .data]
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Votre texte").font(.title2.bold())
                    Spacer()
                    Button { importing = true } label: { Label("Importer", systemImage: "doc.badge.plus") }
                }
                TextEditor(text: $state.text)
                    .font(.system(.body, design: .serif))
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                HStack {
                    Text("\(state.text.count) caractères").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Effacer") { state.text = "" }.disabled(state.text.isEmpty)
                }
            }
            .padding(24).frame(minWidth: 510)

            VStack(alignment: .leading, spacing: 18) {
                Text("Production").font(.title2.bold())
                if state.voices.isEmpty {
                    ContentUnavailableView {
                        Label("Aucune voix", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Enregistrez un court échantillon avant de générer votre MP3.")
                    } actions: {
                        Button("Créer une voix", action: openVoices).buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voix").font(.caption).foregroundStyle(.secondary)
                        Picker("Voix", selection: $state.selectedVoiceID) {
                            ForEach(state.voices) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Vitesse"); Spacer(); Text(String(format: "%.2f×", state.speed)).monospacedDigit() }
                        Slider(value: $state.speed, in: 0.75...1.25, step: 0.05)
                        HStack {
                            Text("0,75×").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Débit normal") { state.speed = 1.0 }.buttonStyle(.link)
                            Button("+10 %") { state.speed = 1.10 }.buttonStyle(.link)
                            Spacer()
                            Text("1,25×").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Hésitations légères", isOn: $state.hesitations)
                    Text("Ajoute rarement un « euh… » et quelques pauses naturelles.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await state.generate() }
                    } label: {
                        HStack {
                            if state.isBusy { ProgressView().controlSize(.small) }
                            Label("Générer le MP3", systemImage: "waveform.badge.plus")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(state.isBusy || !state.isBackendReady || state.text.isEmpty)

                    if state.generatedURL != nil {
                        Divider()
                        Label("Audio généré", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if state.generatedDuration > 0 {
                            Text(formatDuration(state.generatedDuration)).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button { state.playGenerated() } label: {
                                Label(state.isPaused ? "Reprendre" : "Lecture", systemImage: "play.fill")
                            }
                            .disabled(state.isPlaying)
                            Button { state.pauseGenerated() } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .disabled(!state.isPlaying)
                            Button { state.stopGenerated() } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .disabled(!state.isPlaying && !state.isPaused)
                            Button { state.exportGenerated() } label: { Label("Enregistrer…", systemImage: "square.and.arrow.down") }
                        }
                    }
                    Spacer()
                }
            }
            .padding(24).frame(minWidth: 290, idealWidth: 310)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: supportedTypes) { result in
            if case .success(let url) = result { Task { await state.importFile(url) } }
            if case .failure(let error) = result { state.errorMessage = error.localizedDescription }
        }
    }

    private func formatDuration(_ value: Double) -> String {
        "Durée : \(Int(value) / 60) min \(Int(value) % 60) s"
    }
}

private struct VoicesView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var recorder = VoiceRecorder()
    @State private var name = "Ma voix"
    @State private var consent = false
    @State private var saved = false

    private let passage = "La lumière du matin traverse doucement la fenêtre. Je prends le temps de respirer, puis je lis ce texte avec une voix naturelle, claire et régulière. Chaque phrase doit rester calme, sans précipitation, afin de créer un échantillon fidèle de ma voix."

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Créer une voix").font(.title2.bold())
                TextField("Nom de la voix", text: $name)
                GroupBox("Texte à lire exactement") {
                    ScrollView {
                        Text(passage)
                            .font(.system(size: 17, design: .serif))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(minHeight: 180, idealHeight: 220, maxHeight: 280)
                }
                Text("Placez-vous dans une pièce calme, à environ 30 cm du microphone. Lisez naturellement, sans musique de fond.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button { recorder.toggle() } label: {
                        Label(recorder.isRecording ? "Arrêter" : "Enregistrer", systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(recorder.isRecording ? .red : .indigo).controlSize(.large)
                    .disabled(recorder.isRequestingAccess)
                    Text(String(format: "%.1f s", recorder.duration)).monospacedDigit()
                    if recorder.recordingURL != nil && !recorder.isRecording {
                        Label("Échantillon prêt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if recorder.needsMicrophoneSettings {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                        Text("VoixLocale n’a pas accès au microphone.")
                            .font(.caption)
                        Button("Ouvrir les Réglages") { recorder.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(spacing: 10) {
                    Text("Niveau micro").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: recorder.level)
                        .tint(recorder.level > 0.08 ? .green : .orange)
                    Text(recorder.level > 0.08 ? "Son détecté" : "Parlez pour tester")
                        .font(.caption).foregroundStyle(recorder.level > 0.08 ? .green : .secondary)
                        .frame(width: 100, alignment: .leading)
                }
                Toggle("Je confirme être cette personne ou disposer de son autorisation explicite.", isOn: $consent)
                    .font(.caption)
                Button {
                    guard let url = recorder.recordingURL else { return }
                    Task { saved = await state.enroll(name: name, transcript: passage, audioURL: url) }
                } label: {
                    HStack { if state.isBusy { ProgressView().controlSize(.small) }; Text("Ajouter cette voix") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    recorder.recordingURL == nil || recorder.isRecording || !consent ||
                    name.isEmpty || state.isBusy || !state.isBackendReady
                )
                Spacer()
            }
            .padding(24).frame(minWidth: 500)

            VStack(alignment: .leading, spacing: 12) {
                Text("Mes voix").font(.title2.bold())
                if state.voices.isEmpty {
                    ContentUnavailableView("Aucune voix enregistrée", systemImage: "person.wave.2")
                } else {
                    List {
                        ForEach(state.voices) { voice in
                            HStack {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.indigo)
                                VStack(alignment: .leading) {
                                    Text(voice.name).font(.headline)
                                    Text(String(format: "Échantillon %.0f s", voice.duration)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { Task { await state.deleteVoice(voice) } } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                            }.padding(.vertical, 5)
                        }
                    }.listStyle(.inset)
                }
            }
            .padding(24).frame(minWidth: 300)
        }
        .onChange(of: recorder.errorMessage) { _, value in if let value { state.errorMessage = value } }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Moteur local") {
                LabeledContent("Modèle", value: "Qwen3-TTS 1.7B Base · BF16")
                LabeledContent("Accélération", value: "Apple MLX / Metal")
                LabeledContent("Clonage", value: "Empreinte vocale stable")
                LabeledContent("Confidentialité", value: "Traitement sur ce Mac")
                LabeledContent("État", value: state.isBackendReady ? "Prêt" : "Démarrage")
            }
            Section("Export") {
                LabeledContent("Format", value: "MP3 VBR haute qualité")
                LabeledContent("Nettoyage", value: "Réduction du bruit et silences propres")
                Text("Le fichier WAV sans perte est assemblé localement avant l’encodage MP3.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Données") {
                Text("Les voix sont conservées dans le dossier Application Support de votre compte. Elles ne sont jamais envoyées sur Internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(30).frame(maxWidth: 680)
    }
}
