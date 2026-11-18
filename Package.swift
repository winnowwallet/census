// swift-tools-version: 6.0
import PackageDescription

// The census dials with the Swift Winnow app's PeerConnection, consumed here
// as an ordinary package dependency: WalletCore from winnowwallet/winnow's
// main branch. Package.resolved is not committed, so every build resolves the
// newest main. The wallet that ships is winnowwallet/winnow-lean, which
// census-input builds on (lakefile.toml).
let package = Package(
    name: "winnow-census",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WinnowCensus", targets: ["WinnowCensus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/winnowwallet/winnow", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "WinnowCensus",
            dependencies: [
                .product(name: "WalletCore", package: "winnow"),
            ]
        ),
    ]
)
