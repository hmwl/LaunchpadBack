// swift-tools-version:5.9
// Optional: open in Xcode. The recommended build is ./build.sh (plain swiftc).
import PackageDescription

let package = Package(
    name: "LaunchpadBack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchpadBack",
            path: "Sources/LaunchpadBack",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
