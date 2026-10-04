// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UCWatchdog",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "uc-watchdog", targets: ["UCWatchdog"])],
    targets: [.executableTarget(name: "UCWatchdog", resources: [.copy("Resources/AppIcon.icns")])]
)
