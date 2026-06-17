# MLXAudioServer

An HTTP server that exposes [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) text-to-speech models behind an OpenAI-compatible `/v1/audio/speech` endpoint. Built with [Hummingbird](https://github.com/hummingbird-project/hummingbird).

A single TTS model is loaded at startup and shared across all requests. The server returns raw float32 PCM audio (mono, model-native sample rate).

## Requirements

- macOS 14.0+ on Apple Silicon
- Xcode 16+ (required to compile MLX's Metal shaders)

## Build

**For development / testing**, use `swift build` (fast iteration, but Metal shaders are not compiled):

```sh
swift build
```

If you run a `swift build` binary, you'll need a `mlx.metallib` next to it (see [Metal Shaders](#metal-shaders)).

**For release / distribution**, use the build script which runs `xcodebuild` to compile Metal shaders and bundle them correctly:

```sh
./scripts/build-release.sh [output_dir]   # default: dist/
```

This produces a self-contained binary + `mlx-swift_Cmlx.bundle` (3.6 MB compiled Metal kernels). No external metallib needed.

## Run

```sh
dist/MLXAudioServer --model mlx-community/chatterbox-turbo-8bit
```

### CLI flags

| Flag | Default | Description |
|---|---|---|
| `--model <repo>` | *(required)* | HuggingFace model repo or **local path** to a model directory |
| `--host <addr>` | `0.0.0.0` | Bind address |
| `--port <port>` | `8000` | Listen port |

The model is downloaded from HuggingFace on first run and cached locally. You can also pass a local filesystem path to avoid re-downloading a model you already have:

```sh
# Use a model from the standard HuggingFace cache
dist/MLXAudioServer --model ~/.cache/huggingface/hub/models--mlx-community--Kokoro-82M-4bit/snapshots/<hash>/
```

## API

### `POST /v1/audio/speech`

**Request body** (JSON):

| Field | Type | Required | Description |
|---|---|---|---|
| `input` | string | yes | The text to synthesize |
| `model` | string | no | Model identifier. If provided, must match the loaded model (returns 404 otherwise). If omitted, defaults to the loaded model. |
| `ref_audio` | string | no | Server-side filesystem path to reference audio for voice cloning (Chatterbox, etc.) |
| `ref_text` | string | no | Transcript of the reference audio |

**Response:** Raw float32 little-endian PCM audio, mono, at the model's native sample rate (24000 Hz for Chatterbox and Kokoro). Content-Type: `audio/pcm`.

### Examples

Basic TTS:
```sh
http POST localhost:8000/v1/audio/speech input="Hello world!" | \
    play -t raw -r 24000 -e floating-point -b 32 -c 1 -
```

With explicit model (must match the loaded model):
```sh
http POST localhost:8000/v1/audio/speech \
    model=mlx-community/Kokoro-82M-4bit \
    input="Hello world!" | \
    play -t raw -r 24000 -e floating-point -b 32 -c 1 -
```

Voice cloning with `ref_audio` (Chatterbox):
```sh
http POST localhost:8000/v1/audio/speech \
    ref_audio=/path/to/voice.wav \
    input="Some text to be spoken" | \
    play -t raw -r 24000 -e floating-point -b 32 -c 1 -
```

### Error responses

Errors follow the OpenAI format:

```json
{
    "error": {
        "message": "Model 'wrong-model' not found. This server only serves 'mlx-community/Kokoro-82M-4bit'.",
        "type": "invalid_request_error",
        "code": "model_not_found"
    }
}
```

| Status | When |
|---|---|
| 400 | Malformed JSON, missing `input` field, or bad `ref_audio` file |
| 404 | Model mismatch, or `ref_audio` file not found |
| 500 | Speech generation failure |

## Distribution

To deploy to another Mac:

1. Build on the same architecture (Apple Silicon):
   ```sh
   ./scripts/build-release.sh dist/
   ```

2. Copy the binary and bundle to the target machine:
   ```sh
   scp -r dist/ mac-mini:~/MLXAudioServer/
   ```

3. Run on the target:
   ```sh
   ssh mac-mini
   ~/MLXAudioServer/MLXAudioServer --model mlx-community/chatterbox-turbo-8bit
   ```

The binary is statically linked (no dylib dependencies beyond system frameworks). The `mlx-swift_Cmlx.bundle` directory must sit next to the binary — it contains the compiled Metal kernels.

## Metal Shaders

SwiftPM cannot compile MLX's Metal kernel shaders (`.metal` files). `xcodebuild` can, and bundles the result as `default.metallib` inside `mlx-swift_Cmlx.bundle`. MLX finds it at runtime via the SwiftPM bundle search path.

The build script (`scripts/build-release.sh`) handles this automatically by using `xcodebuild` instead of `swift build`.

**If you use `swift build` directly** (for development), you'll need a metallib from another source. The simplest is the Homebrew `mlx` formula:

```sh
brew install mlx
cp /opt/homebrew/lib/mlx.metallib .build/debug/mlx.metallib
```

The metallib version should match the `mlx-swift` version used by `mlx-audio-swift`. A version mismatch may cause crashes or incorrect results.

## Supported Models

Any model supported by `mlx-audio-swift`'s `TTS.loadModel` works, including:

| Model | `ref_audio` | Sample rate |
|---|---|---|
| `mlx-community/chatterbox-turbo-8bit` | Yes (voice cloning) | 24000 Hz |
| `mlx-community/chatterbox-turbo-fp16` | Yes (voice cloning) | 24000 Hz |
| `mlx-community/Kokoro-82M-4bit` | No (uses voice vectors) | 24000 Hz |

The server is model-agnostic — it uses the `SpeechGenerationModel` protocol interface, so no code changes are needed when switching models.

## Notes

- **Cache location:** mlx-audio-swift caches models under `~/.cache/huggingface/hub/mlx-audio/`, which is separate from the standard HuggingFace Hub cache (`~/.cache/huggingface/hub/models--*`). This is a design choice in the library, not this server.

- **G2P re-download fix:** The server patches the cache after model load to work around a bug where mlx-audio-swift re-downloads the G2P model (`beshkenadze/kitten-tts-g2p`) on every request because it ships `us_bart_config.json` instead of `config.json`.
