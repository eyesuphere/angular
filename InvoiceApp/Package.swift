// swift-tools-version: 5.9
import PackageDescription

/// InvoiceCore is deliberately platform-independent: no SwiftUI, no SwiftData, no AppKit.
/// That keeps the money arithmetic, the EN 16931 mapping and the PDF/A-3 attachment
/// testable on any platform, including CI runners that are not macOS.
///
/// The macOS app target (App/) is built by the generated Xcode project, not by SwiftPM,
/// because it needs an app bundle, entitlements and a code-signed SwiftData container.
/// See project.yml, which consumes this package as a local dependency.
let package = Package(
    name: "InvoiceCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InvoiceCore", targets: ["InvoiceCore"])
    ],
    targets: [
        .target(name: "InvoiceCore"),
        .testTarget(name: "InvoiceCoreTests", dependencies: ["InvoiceCore"], resources: [.copy("Fixtures")])
    ]
)
