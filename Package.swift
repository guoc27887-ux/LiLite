// swift-tools-version: 5.10
import PackageDescription
import Foundation

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
