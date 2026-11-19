// swift-tools-version: 5.10
import PackageDescription
import Foundation

// The Linux Swift driver otherwise stamps the deployment target as the linked SDK.
// iOS 18 compatibility fork: deployment target lowered to iOS 18.0.
// The linked-SDK version is still passed through so the Mach-O records the real SDK,
// but the minimum platform version is 18.0 instead of upstream's 17.0.
// Without the real SDK version iOS 26+ runs the app in the legacy (pre-Liquid Glass) compatibility appearance.
let linkedSDK = ProcessInfo.processInfo.environment["PILI_IOS_SDK_VERSION"]
let sdkLinkFlags: [LinkerSetting] = linkedSDK.map {
  [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "18.0", "-Xlinker", $0], .when(platforms: [.iOS]))]
} ?? []
// Development device builds (`build.sh --sign-dev`) keep -O but compile in parallel batches and
// incrementally instead of one single-threaded whole-module job; delivery builds are unchanged.
let fastBuild = ProcessInfo.processInfo.environment["PILI_FAST_BUILD"] == "1"
let developmentFlags: [SwiftSetting] = fastBuild ? [.unsafeFlags(["-no-whole-module-optimization"])] : []

// build.sh stages the official arm64 device frameworks for xtool's cross-linker.
let firebaseDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("FirebaseSDK")
let firebaseFrameworks = (try? FileManager.default.contentsOfDirectory(atPath: firebaseDirectory.path)) ?? []
let firebaseLinkFlags = firebaseFrameworks.sorted().filter { $0.hasSuffix(".framework") }
  .flatMap { ["-framework", String($0.dropLast(".framework".count))] }

let package = Package(
  name: "PiliNative",
  platforms: [.iOS("18.0")],
  products: [.library(name: "PiliNative", targets: ["PiliNative"])],
  dependencies: [.package(path: "Wire"), .package(path: "ArchiveKit"), .package(path: "MediaKit"), .package(path: "ColorKit")],
  targets: [
    .target(
      name: "CFirebaseTelemetry",
      cSettings: [.unsafeFlags(["-F", firebaseDirectory.path])],
      linkerSettings: [
        .unsafeFlags(["-F", firebaseDirectory.path, "-Xlinker", "-ObjC"] + firebaseLinkFlags),
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
      swiftSettings: developmentFlags,
      linkerSettings: sdkLinkFlags)
  ]
)
