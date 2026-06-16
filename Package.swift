// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MLXAudioServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // HTTP server framework
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // MLX-based TTS (no tagged releases yet — track main branch)
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        // Required transitively for HubCache used by TTS.loadModel
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "MLXAudioServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .testTarget(
            name: "MLXAudioServerTests",
            dependencies: ["MLXAudioServer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
