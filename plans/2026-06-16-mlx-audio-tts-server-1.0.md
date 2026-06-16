# MLX Audio TTS Server

## Objective

Build an HTTP server using Hummingbird and mlx-audio-swift that exposes an OpenAI-compatible `/v1/audio/speech` endpoint. The server loads a fixed TTS model (`mlx-community/chatterbox-turbo-8bit`) at startup and streams raw PCM audio (float32, 24 kHz, mono) in response to speech synthesis requests. Voice cloning via `ref_audio` is supported.

Target usage:
```
http POST localhost:8000/v1/audio/speech model=mlx-community/chatterbox-turbo-8bit ref_audio=/path/to/audio.wav input="Some text to be spoken" | play -q -t raw -
```

## Key Architecture Decisions

1. **Executable target, not library**: The package must produce a runnable server binary, so `Package.swift` must declare an `.executableTarget` (not `.library`/`.target`).

2. **Model loaded once at startup**: `TTS.loadModel(modelRepo:)` is called during server initialization. The `SpeechGenerationModel` instance is shared across all requests (safe because ChatterboxModel is `@unchecked Sendable`).

3. **Raw PCM streaming**: The response body uses `ResponseBody(contentLength: nil) { writer in ... }` for chunked transfer encoding. Audio is converted from `MLXArray` to `[Float]` via `.asArray(Float.self)`, then to raw bytes via `withUnsafeBytes`. Content-Type is `audio/pcm` to match the user's `play -q -t raw -` pipeline.

4. **Non-streaming generation wrapped in streaming response**: Chatterbox's `generateStream` is pseudo-streaming (it generates everything then yields once). We call `generate()` directly and write the entire audio buffer in a single `writer.write()` call, then `writer.finish(nil)`. This is simpler and avoids the overhead of the stream proxy. Future work could switch to `generateStream` if true incremental streaming is added.

5. **`ref_audio` loaded server-side**: The `ref_audio` field is a filesystem path. The server loads it via `loadAudioArray(from:sampleRate:)` (from `MLXAudioCore`), which handles resampling to the model's native sample rate (24000 Hz). The resulting `MLXArray` is passed as the `refAudio` parameter to `generate()`.

6. **Port 8000** (per user's example command), bind to `0.0.0.0` for accessibility.

## Implementation Plan

- [ ] 1. **Rewrite `Package.swift`** with correct dependencies and executable target
  - Change from `.library`/`.target` to `.executableTarget` named `MLXAudioServer`
  - Change test target dependency name to match
  - Add dependency: `.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")`
  - Add dependency: `.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main")` — the repo has no tagged releases yet, so `branch: "main"` is required
  - Add dependency: `.package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1")` — needed transitively for `HubCache` used by `TTS.loadModel`
  - Target dependencies: `.product(name: "Hummingbird", package: "hummingbird")`, `.product(name: "MLXAudioTTS", package: "mlx-audio-swift")`, `.product(name: "MLXAudioCore", package: "mlx-audio-swift")`, `.product(name: "HuggingFace", package: "swift-huggingface")`
  - Rationale: The current `Package.swift` declares no dependencies at all, yet the source imports `Hummingbird`, `MLXAudioCore`, and `MLXAudioTTS`. Without these dependencies the package cannot compile.

- [ ] 2. **Rewrite `Sources/main/main.swift`** to use the real mlx-audio-swift and Hummingbird APIs
  - Move source to `Sources/MLXAudioServer/main.swift` to match the new executable target name (SwiftPM requires the source directory to match the target name for executable targets)
  - Replace the fictional `TTSModelConfiguration.load(...)` / `ttsEngine.streamSpeech(...)` / `SpeechOptions` / `toRawBytes()` APIs with the real APIs:
    - Model loading: `let model = try await TTS.loadModel(modelRepo: "mlx-community/chatterbox-turbo-8bit")` — returns `SpeechGenerationModel`
    - Define a `SpeechRequest` Decodable struct with fields: `input: String`, `model: String?` (accepted but ignored — model is fixed), `ref_audio: String?` (filesystem path), `ref_text: String?` (optional transcript for reference audio)
    - In the route handler: decode the request, optionally load ref audio via `loadAudioArray(from: URL(fileURLWithPath:), sampleRate: model.sampleRate)`, call `model.generate(text:voice:refAudio:refText:language:generationParameters:)`, convert the returned `MLXArray` to `[Float]` via `.asArray(Float.self)`, convert to raw bytes, write via `ResponseBody` streaming closure
  - Use `import Hummingbird` (which re-exports `HummingbirdCore` types: `Response`, `ResponseBody`, `ByteBuffer`, `ByteBufferAllocator`)
  - Use `import MLXAudioTTS` (provides `TTS`, `SpeechGenerationModel`)
  - Use `import MLXAudioCore` (provides `loadAudioArray`)
  - Use `@preconcurrency import MLX` for `MLXArray` type
  - Set port to 8000 per the user's example command
  - Rationale: The existing code uses completely fictional APIs that don't exist in either library. Every API call must be replaced with the correct real API.

- [ ] 3. **Handle raw PCM byte conversion**
  - Convert `MLXArray` audio output to raw little-endian float32 bytes:
    ```
    let samples = audio.asArray(Float.self)  // [Float]
    let byteCount = samples.count * MemoryLayout<Float>.size
    var buffer = ByteBufferAllocator().buffer(capacity: byteCount)
    samples.withUnsafeBufferPointer { ptr in
        buffer.writeBytes(UnsafeRawBufferPointer(ptr))
    }
    ```
  - Write the buffer via `try await writer.write(buffer)` then `try await writer.finish(nil)`
  - Set response headers: `[.contentType: "audio/pcm"]`
  - Rationale: The user pipes output to `play -q -t raw -` which expects raw PCM samples. Float32 mono at 24 kHz is the native format from Chatterbox.

- [ ] 4. **Add error handling**
  - Wrap model loading in do/catch with a clear startup error message
  - Wrap request handling in do/catch: return HTTP 400 for bad JSON decode, HTTP 404 for ref_audio file not found, HTTP 500 for generation failures
  - Use `HTTPResponse.Status` codes and return JSON error bodies for non-streaming errors
  - Rationale: A production server needs proper error responses, not crashes. The OpenAI API convention is to return JSON error objects with appropriate status codes.

- [ ] 5. **Update `Tests/mainTests/mainTests.swift`**
  - Update test target name to match new executable target name
  - Add a basic test for `SpeechRequest` decoding (verifying JSON with `input`, `ref_audio` fields parses correctly)
  - Rationale: The placeholder test should be replaced with at least a request struct validation test.

## Verification Criteria

- [ ] `swift build` compiles successfully with all dependencies resolved
- [ ] Server starts and listens on port 8000
- [ ] `http POST localhost:8000/v1/audio/speech input="Hello world"` returns raw PCM audio bytes with Content-Type `audio/pcm`
- [ ] `http POST localhost:8000/v1/audio/speech input="Hello world" ref_audio=/path/to/audio.wav` returns voice-cloned audio
- [ ] Output is playable via `| play -q -t raw -` (or `| play -q -t raw -r 24000 -e floating-point -b 32 -c 1 -` for explicit format)
- [ ] Missing `input` field returns HTTP 400 with error message
- [ ] Nonexistent `ref_audio` path returns HTTP 404 with error message

## Potential Risks and Mitigations

1. **mlx-audio-swift has no tagged releases**
   Mitigation: Use `branch: "main"` in the package dependency. Pin to the specific commit `3f6b055` if stability is needed via `.revision("3f6b055...")`.

2. **Dependency version conflicts between mlx-audio-swift and Hummingbird**
   Mitigation: Both target macOS 14+. mlx-audio-swift depends on `mlx-swift`, `mlx-swift-lm`, `swift-transformers`, `swift-huggingface` — none of which conflict with Hummingbird's NIO/HTTP dependencies. If conflicts arise, use `.upToNextMajor` version ranges and let SwiftPM resolve.

3. **ChatterboxModel requires S3TokenizerV2 for voice cloning**
   Mitigation: The model auto-downloads `mlx-community/S3TokenizerV2` during `fromPretrained`. If it fails, the model falls back to default conditioning tokens (with a warning). Voice cloning quality may be reduced but the server won't crash. Ensure `HF_TOKEN` environment variable is set if needed for gated repos.

4. **Swift 6 strict concurrency with MLX**
   Mitigation: Use `@preconcurrency import MLX` as the reference codebase does. The `ChatterboxModel` is marked `@unchecked Sendable`, so it can be captured in `@Sendable` closures. Model generation calls are async and can be called from the Hummingbird handler's async context.

5. **Large audio responses may consume significant memory**
   Mitigation: Chatterbox's `generate()` returns the entire waveform at once (not true streaming). For very long text inputs, the response could be large. This is acceptable for the initial implementation. Future work could investigate true streaming via the S3Gen flow-matching ODE solver.

## Alternative Approaches

1. **Use `generateStream` instead of `generate`**: Would allow writing audio chunks incrementally as they're yielded. However, Chatterbox's `generateStream` is pseudo-streaming (yields everything at once), so there's no practical benefit. Simpler to use `generate()` directly. Trade-off: If true streaming is added to Chatterbox in the future, switching to `generateStream` would reduce time-to-first-byte.

2. **Return WAV format instead of raw PCM**: Would add a WAV header (44 bytes) with sample rate and format metadata, making it playable without specifying format flags. Trade-off: The user explicitly requested raw PCM output (`play -q -t raw -`), and WAV adds complexity for header generation. Could be added as a `response_format` parameter later.

3. **Use `HummingbirdRouter` (result builder DSL) instead of string-path `Router`**: More type-safe and ergonomic for complex route hierarchies. Trade-off: Adds an extra dependency for a single endpoint. Not worth the overhead for this minimal server.
