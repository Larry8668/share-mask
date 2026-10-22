// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sharemask",
    platforms: [.macOS(.v14)],
    targets: [
        // Private CoreGraphics virtual-display API. Declarations + a tiny façade only.
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // Private CoreGraphics Services / SkyLight calls (screen-watcher detection).
        .target(
            name: "CGSPrivate",
            path: "Sources/CGSPrivate",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "sharemask",
            dependencies: ["CGVirtualDisplayShim", "CGSPrivate"],
            path: "Sources/sharemask",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .testTarget(
            name: "sharemaskTests",
            dependencies: ["sharemask"],
            path: "Tests/sharemaskTests"
        ),
    ]
)
