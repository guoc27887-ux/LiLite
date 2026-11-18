// swift-tools-version: 5.10

import Foundation

import PackageDescription

// iOS 18 fork CI note: paths precomputed as typed Strings — the inline
// URL/string-concatenation form made the manifest compiler time out on
// GitHub's macOS runners ("unable to type-check this expression").
let vendor: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Vendor")
let vendorPath: String = vendor.path
let includeFlag: String = "-I" + vendorPath + "/include"
let libFlag: String = "-L" + vendorPath + "/lib"
let package = Package(
  name: "PiliMedia", platforms: [.iOS(.v17)],
  products: [
    .library(name: "CLiveRemux", targets: ["CLiveRemux"]),
    .library(name: "CMPV", targets: ["CMPV"])
  ],
  targets: [
    .target(name: "CMPV", dependencies: ["CLiveRemux"], publicHeadersPath: "include",
      cSettings: [.unsafeFlags([includeFlag])],
      linkerSettings: [
        .unsafeFlags([libFlag]),
        .linkedLibrary("mpv"), .linkedLibrary("placebo"),
        .linkedFramework("OpenGLES"), .linkedFramework("QuartzCore"),
        .linkedFramework("AVFoundation"), .linkedFramework("Security"),
      ]),
    .target(
      name: "CLiveRemux", publicHeadersPath: "include",
      cSettings: [.unsafeFlags([includeFlag])],
      linkerSettings: [
        .unsafeFlags([libFlag]),
        .linkedLibrary("avformat"), .linkedLibrary("avfilter"), .linkedLibrary("avcodec"),
        .linkedLibrary("swscale"), .linkedLibrary("swresample"),
        .linkedLibrary("avutil"), .linkedLibrary("dav1d"),
        .linkedLibrary("ass"), .linkedLibrary("harfbuzz"),.linkedLibrary("fribidi"),.linkedLibrary("freetype"),
        .linkedLibrary("iconv",.when(platforms:[.iOS])),.linkedLibrary("c++",.when(platforms:[.iOS])),.linkedLibrary("z"),
        .linkedFramework("CoreText",.when(platforms:[.iOS])),
        .linkedFramework("MediaToolbox", .when(platforms: [.iOS])),
        .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
        .linkedFramework("VideoToolbox", .when(platforms: [.iOS])),
        .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
        .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
        .linkedFramework("CoreFoundation", .when(platforms: [.iOS])),
        .linkedLibrary("m"),
      ])
  ])
