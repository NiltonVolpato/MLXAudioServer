import Foundation
import Testing

@testable import MLXAudioServer

@Suite("SpeechRequest Decoding")
struct SpeechRequestTests {
    @Test("Decodes all fields")
    func decodesAllFields() throws {
        let json = """
        {
            "input": "Hello world",
            "model": "mlx-community/chatterbox-turbo-8bit",
            "ref_audio": "/path/to/audio.wav",
            "ref_text": "Reference transcript"
        }
        """.data(using: .utf8)!

        let req = try JSONDecoder().decode(SpeechRequest.self, from: json)

        #expect(req.input == "Hello world")
        #expect(req.model == "mlx-community/chatterbox-turbo-8bit")
        #expect(req.refAudio == "/path/to/audio.wav")
        #expect(req.refText == "Reference transcript")
    }

    @Test("Decodes with only required input field")
    func decodesMinimal() throws {
        let json = #"{"input":"Hello"}"#.data(using: .utf8)!

        let req = try JSONDecoder().decode(SpeechRequest.self, from: json)

        #expect(req.input == "Hello")
        #expect(req.model == nil)
        #expect(req.refAudio == nil)
        #expect(req.refText == nil)
    }

    @Test("Fails without input field")
    func failsWithoutInput() {
        let json = #"{"model":"test"}"#.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SpeechRequest.self, from: json)
        }
    }
}

@Suite("ErrorResponse Encoding")
struct ErrorResponseTests {
    @Test("Encodes OpenAI-style error JSON")
    func encodesErrorJSON() throws {
        let errorResponse = ErrorResponse(error: .init(
            message: "Model not found",
            type: "invalid_request_error",
            code: "model_not_found"
        ))

        let data = try JSONEncoder().encode(errorResponse)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"message\":\"Model not found\""))
        #expect(json.contains("\"type\":\"invalid_request_error\""))
        #expect(json.contains("\"code\":\"model_not_found\""))
        #expect(json.contains("\"error\""))
    }

    @Test("Encodes with nil code")
    func encodesNilCode() throws {
        let errorResponse = ErrorResponse(error: .init(
            message: "Bad request",
            type: "invalid_request_error",
            code: nil
        ))

        let data = try JSONEncoder().encode(errorResponse)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"message\":\"Bad request\""))
        // code should be omitted from JSON when nil
        #expect(!json.contains("\"code\""))
    }
}
