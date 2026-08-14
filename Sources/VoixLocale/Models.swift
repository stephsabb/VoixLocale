import Foundation

struct VoiceProfile: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let createdAt: String
    let duration: Double

    enum CodingKeys: String, CodingKey {
        case id, name, duration
        case createdAt = "created_at"
    }
}

struct GenerateResponse: Codable {
    let path: String
    let duration: Double
    let segments: Int
}

struct HealthResponse: Codable {
    let status: String
    let modelLoaded: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case modelLoaded = "model_loaded"
    }
}

struct ErrorResponse: Codable {
    let detail: String
}

struct EnrollRequest: Codable {
    let name: String
    let transcript: String
    let audioBase64: String

    enum CodingKeys: String, CodingKey {
        case name, transcript
        case audioBase64 = "audio_base64"
    }
}

struct GenerateRequest: Codable {
    let text: String
    let voiceID: String
    let speed: Double
    let hesitations: Bool

    enum CodingKeys: String, CodingKey {
        case text, speed, hesitations
        case voiceID = "voice_id"
    }
}

struct ExtractRequest: Codable {
    let filename: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case filename
        case dataBase64 = "data_base64"
    }
}

struct ExtractResponse: Codable { let text: String }
