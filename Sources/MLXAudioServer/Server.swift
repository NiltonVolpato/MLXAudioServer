import Foundation
import HuggingFace
import Hummingbird
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS

// MARK: - Request/Response Types

/// OpenAI-compatible speech synthesis request.
struct SpeechRequest: Decodable {
    /// The text to synthesize (required).
    let input: String
    /// Model identifier — cross-validated against the loaded model. If omitted, defaults to the loaded model.
    let model: String?
    /// Filesystem path to reference audio for voice cloning (optional).
    let refAudio: String?
    /// Transcript of the reference audio (optional, used by some models).
    let refText: String?

    enum CodingKeys: String, CodingKey {
        case input
        case model
        case refAudio = "ref_audio"
        case refText = "ref_text"
    }
}

/// OpenAI-style error response body.
struct ErrorResponse: Encodable {
    struct ErrorDetail: Encodable {
        let message: String
        let type: String
        let code: String?
    }

    let error: ErrorDetail
}

/// Error that produces an OpenAI-style JSON error response with an HTTP status code.
struct APIError: HTTPResponseError {
    let status: HTTPResponse.Status
    let errorResponse: ErrorResponse

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let data = try JSONEncoder().encode(errorResponse)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

// MARK: - Sendable wrapper for the model

/// Wraps a `SpeechGenerationModel` in an `@unchecked Sendable` container so it can be
/// captured in Hummingbird's `@Sendable` route handler closures. This is safe because
/// concrete model types (e.g. `ChatterboxModel`) are already `@unchecked Sendable`.
final class ModelContainer: @unchecked Sendable {
    let model: any SpeechGenerationModel
    init(_ model: any SpeechGenerationModel) { self.model = model }
}

// MARK: - CLI argument parsing

struct CLIArgs {
    let model: String
    let host: String
    let port: Int
}

func parseCLIArgs() -> CLIArgs? {
    var model: String?
    var host = "0.0.0.0"
    var port = 8000

    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            i += 1
            if i < args.count { model = args[i] }
        case "--host":
            i += 1
            if i < args.count { host = args[i] }
        case "--port":
            i += 1
            if i < args.count, let p = Int(args[i]) { port = p }
        default:
            break
        }
        i += 1
    }

    guard let model else { return nil }
    return CLIArgs(model: model, host: host, port: port)
}

func printStderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// MARK: - Cache workaround

/// Fixes a bug in mlx-audio-swift's `ModelUtils.resolveOrDownloadModel` where the cache
/// is never recognized as valid for repos that ship `*_config.json` instead of `config.json`
/// (e.g. `beshkenadze/kitten-tts-g2p` ships `us_bart_config.json`). This causes the G2P
/// model to be re-downloaded on every TTS request. We create a `config.json` symlink so
/// the cache check passes and subsequent `prepare()` calls are no-ops.
///
/// Must be called after the model has been loaded (so the first download has completed).
func patchMlxAudioCacheConfigFiles() {
    let mlxAudioCache = HubCache.default.cacheDirectory
        .appendingPathComponent("mlx-audio")

    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(at: mlxAudioCache, includingPropertiesForKeys: nil) else {
        return
    }

    for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        let configJSON = dir.appendingPathComponent("config.json")
        guard !fm.fileExists(atPath: configJSON.path) else { continue }

        // Find any *_config.json and symlink it as config.json
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
        if let altConfig = files.first(where: { $0.hasSuffix("_config.json") }) {
            let target = dir.appendingPathComponent(altConfig)
            try? fm.linkItem(at: target, to: configJSON) // creates a hard link (copy fallback below)
            if !fm.fileExists(atPath: configJSON.path) {
                try? fm.copyItem(at: target, to: configJSON)
            }
        }
    }
}

// MARK: - Entry point

@main
struct MLXAudioServer {
    static func main() async throws {
        guard let args = parseCLIArgs() else {
            printStderr("Usage: MLXAudioServer --model <repo> [--host <host>] [--port <port>]")
            printStderr("")
            printStderr("Options:")
            printStderr("  --model <repo>   HuggingFace model repo or local path (required)")
            printStderr("  --host <host>    Bind address (default: 0.0.0.0)")
            printStderr("  --port <port>    Listen port (default: 8000)")
            exit(1)
        }

        // Load the model once at startup.
        printStderr("Loading model: \(args.model) ...")
        let model: any SpeechGenerationModel
        do {
            model = try await TTS.loadModel(modelRepo: args.model)
        } catch {
            printStderr("Failed to load model: \(error)")
            exit(1)
        }
        printStderr("Model loaded. Sample rate: \(model.sampleRate) Hz")

        // Patch cache so G2P/auxiliary models aren't re-downloaded on every request.
        patchMlxAudioCacheConfigFiles()

        let modelContainer = ModelContainer(model)
        let modelName = args.model

        // Build router.
        let router = Router()

        router.post("/v1/audio/speech") { request, context -> Response in
            let model = modelContainer.model

            // Decode the request body. Hummingbird's decode() converts DecodingError
            // into HTTPError with descriptive messages (e.g. "Coding key `input` not found.").
            // HTTPError is itself an HTTPResponseError, so it propagates directly.
            let speechRequest: SpeechRequest
            do {
                speechRequest = try await request.decode(as: SpeechRequest.self, context: context)
            } catch let error as HTTPError {
                throw error
            } catch {
                throw APIError(
                    status: .badRequest,
                    errorResponse: ErrorResponse(error: .init(
                        message: "Invalid request body: \(error.localizedDescription)",
                        type: "invalid_request_error",
                        code: nil
                    ))
                )
            }

            // Cross-validate the model field.
            if let requestModel = speechRequest.model, requestModel != modelName {
                throw APIError(
                    status: .notFound,
                    errorResponse: ErrorResponse(error: .init(
                        message: "Model '\(requestModel)' not found. This server only serves '\(modelName)'.",
                        type: "invalid_request_error",
                        code: "model_not_found"
                    ))
                )
            }

            // Load reference audio for voice cloning if provided.
            var refAudio: MLXArray? = nil
            if let refAudioPath = speechRequest.refAudio, !refAudioPath.isEmpty {
                let expanded = (refAudioPath as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw APIError(
                        status: .notFound,
                        errorResponse: ErrorResponse(error: .init(
                            message: "Reference audio file not found: \(refAudioPath)",
                            type: "invalid_request_error",
                            code: nil
                        ))
                    )
                }
                do {
                    (_, refAudio) = try loadAudioArray(from: url, sampleRate: model.sampleRate)
                } catch {
                    throw APIError(
                        status: .badRequest,
                        errorResponse: ErrorResponse(error: .init(
                            message: "Failed to load reference audio: \(error.localizedDescription)",
                            type: "invalid_request_error",
                            code: nil
                        ))
                    )
                }
            }

            // Generate speech.
            let audio: MLXArray
            do {
                audio = try await model.generate(
                    text: speechRequest.input,
                    voice: nil,
                    refAudio: refAudio,
                    refText: speechRequest.refText,
                    language: nil,
                    generationParameters: model.defaultGenerationParameters
                )
            } catch {
                throw APIError(
                    status: .internalServerError,
                    errorResponse: ErrorResponse(error: .init(
                        message: "Speech generation failed: \(error.localizedDescription)",
                        type: "server_error",
                        code: nil
                    ))
                )
            }

            // Convert MLXArray to raw float32 PCM bytes.
            let samples = audio.asArray(Float.self)

            // Free GPU memory held by the generated audio and any intermediate
            // tensors. MLX caches deallocated GPU buffers for reuse, but the
            // cache grows unbounded by default, causing memory to balloon
            // across requests (e.g. 11 GB resident after a few short TTS calls).
            // Clearing after each response keeps the footprint bounded.
            Memory.clearCache()
            var buffer = ByteBufferAllocator().buffer(capacity: samples.count * MemoryLayout<Float>.size)
            samples.withUnsafeBufferPointer { ptr in
                _ = buffer.writeBytes(UnsafeRawBufferPointer(ptr))
            }

            return Response(
                status: .ok,
                headers: [.contentType: "audio/pcm"],
                body: .init(byteBuffer: buffer)
            )
        }

        // Start the server.
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(args.host, port: args.port))
        )

        printStderr("Server listening on \(args.host):\(args.port)")
        try await app.runService()
    }
}
