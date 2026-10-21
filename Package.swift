// swift-tools-version: 6.0
// For the unit tests: `swift test`. build.sh builds the app.
import PackageDescription

let package = Package(
	name: "ClaudeCodeNotifier",
	platforms: [.macOS(.v13)],
	targets: [
		.executableTarget(name: "ClaudeCodeNotifier", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
		.testTarget(name: "ClaudeCodeNotifierTests", dependencies: ["ClaudeCodeNotifier"], path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
	]
)
