// swift-tools-version: 6.0
import PackageDescription

// The census dials with Winnow's own PeerConnection, consumed here as an
// ordinary package dependency. The rebuilt wallet (winnowwallet/winnow) folds
// the old BitcoinCore/BitcoinP2P products into one WalletCore library, with
// the SOCKS5 proxy support on main.
let package = Package(
    name: "winnow-census",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WinnowCensus", targets: ["WinnowCensus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/winnowwallet/winnow", revision: "a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7"),
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
