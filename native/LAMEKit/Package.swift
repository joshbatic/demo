// swift-tools-version: 5.9
// LAME 3.100 (LGPL), the MP3 encoder the web app uses as lamejs, built for *[demo]'s native app.
// Sources taken from SwiftLAME (hidden-spectrum/SwiftLAME). A local package, because its compiler
// flags (warnings off) are only allowed for packages that aren't fetched by URL.
import PackageDescription

let package = Package(
    name: "LAMEKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "LAME", targets: ["LAME"])],
    targets: [
        .target(
            name: "LAME",
            exclude: ["libmp3lame/vector", "COPYING", "LICENSE", "README"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .unsafeFlags(["-w"])
            ]
        )
    ]
)
