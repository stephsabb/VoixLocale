import XCTest
@testable import VoixLocale

final class VoixLocaleTests: XCTestCase {
    func testGenerateRequestCoding() throws {
        let data = try JSONEncoder().encode(GenerateRequest(
            text: "Bonjour", voiceID: "abc", speed: 1.1, hesitations: true
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["voice_id"] as? String, "abc")
        XCTAssertEqual(json["hesitations"] as? Bool, true)
    }
}
