// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "RcLottiePreview",
  platforms: [
    .macOS(.v12),
  ],
  targets: [
    .executableTarget(
      name: "rc-lottie-preview",
      dependencies: [],
      path: "swift"
    ),
  ]
)
