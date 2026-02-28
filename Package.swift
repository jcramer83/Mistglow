// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mistglow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CLZ4",
            path: "Sources/CLZ4",
            publicHeadersPath: "include",
            cSettings: []
        ),
        .executableTarget(
            name: "Mistglow",
            dependencies: ["CLZ4"],
            path: "Sources/Mistglow",
            resources: [
                .copy("../../Resources/modelines.dat"),
            ]
        ),
    ]
)
