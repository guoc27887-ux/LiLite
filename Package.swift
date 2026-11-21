// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Built by LiLite.xcodeproj (the app target) for iphoneos or iphonesimulator; see build.sh.
// Development device builds (`build.sh --sign-dev`) keep -O but compile in parallel batches and
// incrementally instead of one single-threaded whole-module job; delivery builds are unchanged.
let fastBuild = ProcessInfo.processInfo.environment["PILI_FAST_BUILD"] == "1"
let developmentFlags: [SwiftSetting] = fastBuild ? [.unsafeFlags(["-no-whole-module-optimization"])] : []

// `build.sh --prepare` packs Firebase's official static frameworks (device + simulator slices)
// into static-library XCFrameworks in FirebaseSDK/xcframeworks (Tools/firebase_sdk.py); each one
// is a binary target here. Framework headers are identical for both slices: -F FirebaseSDK/iphoneos.
let firebaseSDK = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("FirebaseSDK")
let firebaseXCFrameworks = firebaseSDK.appendingPathComponent("xcframeworks")
let firebaseNames = ((try? FileManager.default.contentsOfDirectory(atPath: firebaseXCFrameworks.path)) ?? [])
  .filter { $0.hasSuffix(".xcframework") }.map { String($0.dropLast(".xcframework".count)) }.sorted()
let firebaseTargets: [Target] = firebaseNames.map {
  .binaryTarget(name: $0, path: "FirebaseSDK/xcframeworks/\($0).xcframework")
}

let package = Package(
  name: "PiliNative",
  platforms: [.iOS("18.0")],
  products: [.library(name: "PiliNative", targets: ["PiliNative"])],
  dependencies: [.package(path: "Wire"), .package(path: "ArchiveKit"), .package(path: "MediaKit"), .package(path: "ColorKit")],
  targets: firebaseTargets + [
    .target(
      name: "CFirebaseTelemetry",
      dependencies: firebaseNames.map { .target(name: $0) },
      // -fno-modules: textual #import of the plain ObjC headers. Importing the framework modules
      // would pull in the per-slice *-Swift.h headers, which differ between device and simulator.
      cSettings: [.unsafeFlags(["-F", firebaseSDK.appendingPathComponent("iphoneos").path, "-fno-modules"])],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-ObjC"]),
        .linkedLibrary("sqlite3"), .linkedLibrary("z"), .linkedLibrary("c++"),
        .linkedFramework("SystemConfiguration"), .linkedFramework("Security")
      ]),
    .target(
      name: "PiliNative",
      dependencies: [
        "CFirebaseTelemetry",
        .product(name: "PiliWire", package: "Wire"),
        .product(name: "PiliArchive", package: "ArchiveKit"),
        .product(name: "MaterialColorUtilities", package: "ColorKit"),
        .product(name: "CLiveRemux", package: "MediaKit"),
        .product(name: "CMPV", package: "MediaKit"),
      ],
      resources: [.copy("Notices"), .copy("UpscaleAssets")],
      swiftSettings: developmentFlags)
  ]
)
