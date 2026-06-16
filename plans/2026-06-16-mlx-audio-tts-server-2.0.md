# MLX Audio TTS Server

## Objective

Build an HTTP server using Hummingbird and mlx-audio-swift that exposes an OpenAI-compatible `/v1/audio/speech` endpoint. The server loads a single TTS model at startup (specified via CLI flag) and returns raw PCM audio (float32, mono, model-native sample rate) in response to speech synthesis requests. Voice cloning via `ref_audio` is supported.

Target usage:
```
# Start server with any model
MLXAudioServer --model mlx-community/chatterbox-turbo-8bit --port 8000

# Generate speech
http POST localhost:8000/v1/audio/speech model=mlx-community/chatterbox-turbo-8bit ref_audio=/path/to/audio.wav input="Some text to be spoken" | play -q -t raw -
```

## Key Architecture Decisions

1. **Executable target, not library**: The package must produce a runnable server binary, so `Package.swift` must declare an `.executableTarget` (not `.library`/`.target`).

2. **Model specified via CLI flag, loaded once at startup**: The model repo is passed as `--model <repo>` on the command line. `TTS.loadModel(modelRepo:)` is called during server initialization. The `SpeechGenerationModel` instance is shared across all requests (safe because model classes like `ChatterboxModel` are `@unchecked Sendable`). No model swapping, unloading, or multi-model support.

3. **Request `model` field cross-validation**: The OpenAI-compatible request body includes a `model` field. If provided, the server compares it against the loaded model name — if they don't match, return HTTP 404 (matching OpenAI's behavior for unknown models). If the field is omitted, the server defaults to the loaded model name. This keeps the API compatible with OpenAI clients while enforcing single-model semantics.

4. **CLI flags for host/port**: `--host` (default `0.0.0.0`) and `--port` (default `8000`) control the bind address. Parsed via simple `CommandLine.arguments` iteration (no ArgumentParser dependency — keeps dependencies minimal, matching the pattern used by the mlx-audio-swift CLI tool).

5. **Raw PCM response**: The response body uses `ResponseBody(contentLength: nil) { writer in ... }` for chunked transfer encoding. Audio is converted from `MLXArray` to `[Float]` via `.asArray(Float.self)`, then to raw bytes. Content-Type is `audio/pcm`.

6. **`generate()` for now, structured for future streaming**: We call `model.generate(...)` which returns the complete `MLXArray` at once, then write it in a single `writer.write()` + `writer.finish(nil)`. The code is structured so switching to `model.generateStream(...)` is a localized change — the streaming response wrapper stays the same, only the inner audio-generation loop changes. Some models (e.g., Marvis/CSM, Qwen3) already support true incremental streaming via `generateStream`, so this path will become useful when switching models.

7. **`ref_audio` loaded server-side**: The `ref_audio` field is a filesystem path on the server. The server loads it via `loadAudioArray(from:sampleRate:)` (from `MLXAudioCore`), which handles resampling to the model's native sample rate. The resulting `MLXArray` is passed as the `refAudio` parameter to `generate()`.

## Implementation Plan

- [ ] 1. **Rewrite `Package.swift`** with correct dependencies and executable target
  - Change from `.library`/`.target` to `.executableTarget` named `MLXAudioServer`
  - Change test target name to `MLXAudioServerTests` with matching dependency
  - Add dependency: `.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")`
  - Add dependency: `.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main")` — the repo has no tagged releases yet, so `branch: "main"` is required
  - Add dependency: `.package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1")` — needed transitively for `HubCache` used by `TTS.loadModel`
  - Target dependencies: `.product(name: "Hummingbird", package: "hummingbird")`, `.product(name: "MLXAudioTTS", package: "mlx-audio-swift")`, `.product(name: "MLXAudioCore", package: "mlx-audio-swift")`, `.product(name: "HuggingFace", package: "swift-huggingface")`
  - Rationale: The current `Package.swift` declares no dependencies at all, yet the source imports `Hummingbird`, `MLXAudioCore`, and `MLXAudioTTS`. Without these dependencies the package cannot compile.

- [ ] 2. **Move and rewrite the main source file** at `Sources/MLXAudioServer/main.swift`
  - SwiftPM requires the source directory to match the executable target name
  - Parse CLI arguments from `CommandLine.arguments`: `--model` (required), `--host` (default `0.0.0.0`), `--port` (default `8000`)
  - Load model once at startup: `let model = try await TTS.loadModel(modelRepo: modelRepo)` — returns `SpeechGenerationModel`
  - Store the model repo string for request cross-validation
  - Print startup info (model name, sample rate, bind address) to stderr
  - Rationale: The existing code uses completely fictional APIs. Every API call must be replaced with the correct real API. CLI flags make the server reusable across models.

- [ ] 3. **Define the request/response types**
  - `SpeechRequest: Decodable` with fields:
    - `input: String` (required — the text to synthesize)
    - `model: String?` (optional — cross-validated against loaded model; if nil, defaults to loaded model)
    - `ref_audio: String?` (optional — filesystem path to reference audio for voice cloning)
    - `ref_text: String?` (optional — transcript of reference audio, used by some models)
  - `ErrorResponse: Encodable` with fields: `error: ErrorDetail` where `ErrorDetail` has `message: String`, `type: String`, `code: String?` — matches OpenAI error format
  - Rationale: Matches the OpenAI `/v1/audio/speech` request schema. The `model` field is kept for compatibility but enforced as single-model.

- [ ] 4. **Implement the `/v1/audio/speech` POST handler**
  - Decode request body via `try await request.decode(as: SpeechRequest.self, context: context)`
  - Cross-validate `model` field: if provided and != loaded model name, return HTTP 404 with JSON error `{"error": {"message": "Model 'X' not found", "type": "invalid_request_error"}}`
  - If `ref_audio` provided: resolve the filesystem path (expand `~`, resolve relative to CWD), check file exists, load via `loadAudioArray(from: URL(fileURLWithPath:), sampleRate: model.sampleRate)` — returns `(sampleRate, MLXArray)`. If file not found, return HTTP 404.
  - Call `try await model.generate(text: request.input, voice: nil, refAudio: refAudio, refText: request.ref_text, language: nil, generationParameters: model.defaultGenerationParameters)`
  - Rationale: This is the core endpoint. The handler is kept model-agnostic by using the `SpeechGenerationModel` protocol interface, so swapping models only requires changing the CLI flag.

- [ ] 5. **Convert and stream the audio response**
  - Convert the returned `MLXArray` to `[Float]` via `.asArray(Float.self)`
  - Convert to raw bytes and write via Hummingbird's streaming response:
    ```
    let samples = audio.asArray(Float.self)
    var buffer = ByteBufferAllocator().buffer(capacity: samples.count * MemoryLayout<Float>.size)
    samples.withUnsafeBufferPointer { ptr in
        buffer.writeBytes(UnsafeRawBufferPointer(ptr))
    }
    ```
  - Return `Response(status: .ok, headers: [.contentType: "audio/pcm"], body: ResponseBody(contentLength: buffer.readableBytes) { writer in try await writer.write(buffer); try await writer.finish(nil) })`
  - Since the full audio is known after `generate()` returns, we can set `contentLength` explicitly (no chunked encoding needed)
  - Rationale: The model returns the complete waveform at once. Writing it as a single buffered response with known content-length is simpler and more efficient than chunked encoding.

- [ ] 6. **Add error handling**
  - Wrap model loading in do/catch with a fatal error and clear message at startup
  - In the route handler, catch errors and return appropriate HTTP responses:
    - JSON decode failure → HTTP 400 `{"error": {"message": "Invalid request body", "type": "invalid_request_error"}}`
    - Model mismatch → HTTP 404 `{"error": {"message": "Model not found", "type": "invalid_request_error"}}`
    - ref_audio file not found → HTTP 404 `{"error": {"message": "Reference audio file not found", "type": "invalid_request_error"}}`
    - Generation failure → HTTP 500 `{"error": {"message": "Speech generation failed: ...", "type": "server_error"}}`
  - Rationale: A production server needs proper error responses, not crashes. OpenAI API convention is JSON error objects with status codes.

- [ ] 7. **Update tests** at `Tests/MLXAudioServerTests/MLXAudioServerTests.swift`
  - Move test directory to match new target name
  - Add a test for `SpeechRequest` decoding: verify JSON with all fields parses, verify JSON with only `input` parses (optionals default to nil)
  - Add a test for `ErrorResponse` encoding: verify it produces valid OpenAI-style error JSON
  - Rationale: Replace the placeholder test with meaningful validation of the request/response types.

## Verification Criteria

- [ ] `swift build` compiles successfully with all dependencies resolved
- [ ] Server starts with `MLXAudioServer --model mlx-community/chatterbox-turbo-8bit` and prints model info + bind address to stderr
- [ ] Server listens on port 8000 by default, or custom port via `--port`
- [ ] `http POST localhost:8000/v1/audio/speech input="Hello world"` returns raw PCM audio bytes with Content-Type `audio/pcm`
- [ ] `http POST localhost:8000/v1/audio/speech model=mlx-community/chatterbox-turbo-8bit input="Hello world"` works (model matches)
- [ ] `http POST localhost:8000/v1/audio/speech model=some-other-model input="Hello world"` returns HTTP 404 with JSON error
- [ ] `http POST localhost:8000/v1/audio/speech input="Hello world" ref_audio=/path/to/audio.wav` returns voice-cloned audio
- [ ] Missing `input` field returns HTTP 400 with JSON error
- [ ] Nonexistent `ref_audio` path returns HTTP 404 with JSON error
- [ ] Output is playable via `play -q -t raw -r 24000 -e floating-point -b 32 -c 1 -` (format flags depend on model's sample rate)

## Potential Risks and Mitigations

1. **mlx-audio-swift has no tagged releases**
   Mitigation: Use `branch: "main"` in the package dependency. Pin to the specific commit `3f6b055` if stability is needed via `.revision("3f6b055...")`.

2. **Dependency version conflicts between mlx-audio-swift and Hummingbird**
   Mitigation: Both target macOS 14+. mlx-audio-swift depends on `mlx-swift`, `mlx-swift-lm`, `swift-transformers`, `swift-huggingface` — none of which conflict with Hummingbird's NIO/HTTP dependencies. If conflicts arise, use `.upToNextMajor` version ranges and let SwiftPM resolve.

3. **ChatterboxModel requires S3TokenizerV2 for voice cloning**
   Mitigation: The model auto-downloads `mlx-community/S3TokenizerV2` during `fromPretrained`. If it fails, the model falls back to default conditioning tokens (with a warning). Voice cloning quality may be reduced but the server won't crash. Ensure `HF_TOKEN` environment variable is set if needed for gated repos.

4. **Swift 6 strict concurrency with MLX**
   Mitigation: Use `@preconcurrency import MLX` as the reference codebase does. Model classes are marked `@unchecked Sendable`, so they can be captured in `@Sendable` closures. Model generation calls are async and can be called from the Hummingbird handler's async context.

5. **Non-streaming generation for long text**
   Mitigation: `generate()` returns the entire waveform at once. For very long text, memory usage scales with output length. This is acceptable for short-to-medium TTS workloads. The code is structured so switching to `generateStream()` is a localized change — only the inner generation loop in the handler changes, not the response streaming wrapper. Sentence-boundary splitting could be added as middleware later.

6. **Model-specific behavior differences**
   Mitigation: The handler uses the `SpeechGenerationModel` protocol interface exclusively. Different models handle `refAudio`, `voice`, and `language` differently (some ignore them), but the protocol abstracts this. The server works with any model the `TTS.loadModel` factory supports without code changes.

## Alternative Approaches

1. **Use `generateStream` instead of `generate`**: Would allow writing audio chunks incrementally as they're yielded. For models with true streaming (Marvis/CSM, Qwen3), this reduces time-to-first-byte. However, Chatterbox's `generateStream` is pseudo-streaming (yields everything at once). Trade-off: Using `generateStream` universally would add complexity for no benefit on Chatterbox, but would be beneficial if switching to a streaming-capable model. The current design makes this a localized future change.

2. **Return WAV format instead of raw PCM**: Would add a 44-byte WAV header with sample rate and format metadata, making output playable without specifying format flags. Trade-off: The user explicitly requested raw PCM output. Could be added as a `response_format` parameter later.

3. **Use Swift ArgumentParser instead of manual CLI parsing**: More robust argument parsing with help text and validation. Trade-off: Adds a dependency for 3 flags. Manual parsing is simpler and matches the mlx-audio-swift CLI pattern. ArgumentParser could be adopted later if the CLI surface grows.

4. **Use `HummingbirdRouter` (result builder DSL) instead of string-path `Router`**: More type-safe and ergonomic for complex route hierarchies. Trade-off: Adds an extra dependency for a single endpoint. Not worth the overhead for this minimal server.
