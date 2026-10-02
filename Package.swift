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
        .package(url: "https://github.com/winnowwallet/winnow", revision: "6a9ff4c3cd94711d2273de320a8c0e8173209ec3"),
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
