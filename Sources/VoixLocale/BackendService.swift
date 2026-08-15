import Foundation

enum BackendError: LocalizedError {
    case unavailable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Le moteur local ne répond pas. Vérifiez le journal de VoixLocale."
        case .message(let value): value
        }
    }
}

final class BackendService: @unchecked Sendable {
    static let shared = BackendService()
    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var process: Process?
    private var startupError: Error?
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoixLocale.log")

    func start() {
        guard process == nil else { return }
        startupError = nil
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("backend/run_backend.sh"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("backend/run_backend.sh")
        ].compactMap { $0 }
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            startupError = BackendError.message("Le lanceur du moteur local est introuvable dans l’application.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [script.path]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            task.standardOutput = handle
            task.standardError = handle
        }
        do {
            try task.run()
            process = task
        } catch {
            startupError = error
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    func waitUntilReady(seconds: Int = 900) async throws {
        for _ in 0..<(seconds * 2) {
            if (try? await health()) != nil { return }
            if let startupError { throw startupError }
            if let process, !process.isRunning {
                throw BackendError.message(backendExitMessage())
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw BackendError.unavailable
    }

    private func backendExitMessage() -> String {
        let fallback = "Le moteur local s’est arrêté au démarrage. Vérifiez les prérequis avec scripts/check_requirements.sh."
        guard let data = try? Data(contentsOf: logURL),
              let contents = String(data: data.suffix(4_000), encoding: .utf8) else {
            return fallback
        }
        let details = contents
            .split(separator: "\n")
            .suffix(12)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return fallback }
        return "Le moteur local s’est arrêté au démarrage :\n\n\(details)"
    }

    func health() async throws -> HealthResponse {
        try await request(path: "/health", method: "GET", body: Optional<String>.none)
    }

    func voices() async throws -> [VoiceProfile] {
        try await request(path: "/api/voices", method: "GET", body: Optional<String>.none)
    }

    func enroll(name: String, transcript: String, audioURL: URL) async throws -> VoiceProfile {
        let data = try Data(contentsOf: audioURL)
        return try await request(path: "/api/voices", method: "POST", body: EnrollRequest(
            name: name, transcript: transcript, audioBase64: data.base64EncodedString()
        ))
    }

    func deleteVoice(id: String) async throws {
        let _: VoiceProfile = try await request(path: "/api/voices/\(id)", method: "DELETE", body: Optional<String>.none)
    }

    func extract(url: URL) async throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let response: ExtractResponse = try await request(path: "/api/extract", method: "POST", body: ExtractRequest(
            filename: url.lastPathComponent, dataBase64: data.base64EncodedString()
        ))
        return response.text
    }

    func generate(
        text: String, voiceID: String, speed: Double, hesitations: Bool
    ) async throws -> GenerateResponse {
        try await request(path: "/api/generate", method: "POST", body: GenerateRequest(
            text: text, voiceID: voiceID, speed: speed, hesitations: hesitations
        ), timeout: 3600)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String, method: String, body: Body?, timeout: TimeInterval = 60
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data).detail)
            throw BackendError.message(detail ?? "Erreur locale \(http.statusCode)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
