// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMerge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "iMerge", targets: ["iMerge"])
    ],
    targets: [
        .executableTarget(
            name: "iMerge",
            path: "iMerge",
            exclude: ["Info.plist", "Assets.xcassets"]
        )
    ]
)
