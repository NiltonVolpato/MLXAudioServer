import Hummingbird
import MLXAudioCore
import MLXAudioTTS

@main
struct MLXAudioServer {
    static func main() async throws {
        // Initialize the Swift TTS engine
        let ttsEngine = try await TTSModelConfiguration.load(
            modelIdentifier: "mlx-community/chatterbox-turbo-8bit"
        )
        
        let router = Router()
        
        // Define an OpenAI-compatible speech streaming endpoint
        router.post("/v1/audio/speech") { request, context -> Response in
            struct SpeechRequest: Decodable { let input: String }
            let body = try await request.decode(as: SpeechRequest.self, context: context)
            
            // Set up a Server-Sent Events (SSE) or raw chunked binary stream
            return Response(
                status: .ok,
                headers: [.contentType: "audio/pcm"],
                body: .init { writer in
                    let options = SpeechOptions(voicePreset: .afHeart, speechRate: 1.0)
                    
                    // Stream PCM audio chunks from MLX directly into the HTTP response buffer
                    for try await audioChunk in ttsEngine.streamSpeech(text: body.input, options: options) {
                        let rawBytes = audioChunk.toRawBytes() // Utility function to get safe buffer pointer
                        try await writer.write(ByteBuffer(bytes: rawBytes))
                    }
                    try await writer.finish()
                }
            )
        }
        
        let app = Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: 8080)))
        try await app.run()
    }
}
