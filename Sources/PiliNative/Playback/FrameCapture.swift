import AVFoundation
import CoreImage
import ImageIO
import Photos
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class FrameCapture: ObservableObject {
  @Published var busy = false
  @Published private(set) var recording = false
  @Published var progress = 0.0
  @Published private(set) var file: URL?
  @Published private(set) var thumbnail: UIImage?
  @Published var note: String?
  private weak var player: (any PlaybackEngine)?
  private weak var bound: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?, finishEarly = false
  private var work: Task<Void, Never>?
  private let ci = CIContext(options: [.cacheIntermediates: false])
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pili-frame-" + UUID().uuidString, isDirectory: true)
  init(_ player: any PlaybackEngine) { self.player = player }
  deinit {
    let folder = self.folder
    try? FileManager.default.removeItem(at: folder)
  }
  func attach() {
    guard let item = player?.nativePlayer?.currentItem else { return }
    if bound === item, output != nil { return }
    if let bound, let output { bound.remove(output) }
    let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    o.suppressesPlayerRendering = false
    item.add(o)
    output = o
    bound = item
  }
  func close() {
    work?.cancel()
    if let bound, let output { bound.remove(output) }
    bound = nil
    output = nil
  }
  func stop() { finishEarly = true }
  func capture(gif: Bool, length: Int, fps: Int) {
    guard !busy else { return }
    if let mpv = player as? MPVPlayer { captureMPV(mpv, gif: gif, length: length, fps: fps); return }
    attach()
    guard let player = player?.nativePlayer, let item = bound, let output else {
      note = "请等待播放器就绪"
      return
    }
    busy = true
    progress = 0
    note = nil
    finishEarly = false
    file = nil
    thumbnail = nil
    work = Task {
      defer {
        busy = false
        recording = false
      }
      do {
        guard !(try await item.asset.load(.hasProtectedContent)) else {
          throw ServiceError("此视频不支持画面截取")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transform =
          try await item.asset.loadTracks(withMediaType: .video).first?.load(.preferredTransform)
          ?? .identity
        if gif {
          recording = true
          try await record(
            player: player, item: item, output: output, transform: transform, length: length,
            fps: fps)
        } else {
          let t = player.currentTime()
          var image: CGImage?
          for _ in 0..<8 {
            try Task.checkCancellation()
            guard player.currentItem === item else { throw ServiceError("视频已切换") }
            if let (cg, _) = frame(
              output, at: player.currentTime(), transform: transform, maxSide: nil)
            {
              image = cg
              break
            }
            try await Task.sleep(for: .milliseconds(30))
          }
          if image == nil {
            let gen = AVAssetImageGenerator(asset: item.asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
            image = try await gen.image(at: t).image
          }
          try Task.checkCancellation()
          guard let image, player.currentItem === item else { throw ServiceError("未取得当前画面") }
          let dest = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
          try await Task.detached(priority: .userInitiated) {
            try Self.writeFrame(image, to: dest, type: .png)
          }.value
          file = dest
          thumbnail = UIImage(cgImage: image)
        }
      } catch { if !Task.isCancelled { note = error.localizedDescription } }
    }
  }
  private func captureMPV(_ mpv: MPVPlayer, gif: Bool, length: Int, fps: Int) {
    guard mpv.playbackReady, let item = mpv.currentItem else { note = "请等待播放器就绪"; return }
    guard !gif || ((1...10).contains(length) && [5, 8, 10, 12, 15].contains(fps)) else { return }
    busy = true
    progress = 0
    note = nil
    finishEarly = false
    file = nil
    thumbnail = nil
    work = Task {
      let startPaused = mpv.rate == 0
      var frames: [URL] = []
      defer {
        busy = false
        recording = false
        if gif, startPaused, mpv.currentItem === item { mpv.pause() }
        for frame in frames { try? FileManager.default.removeItem(at: frame) }
      }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !gif {
          let url = folder.appendingPathComponent(UUID().uuidString + ".png")
          try await mpv.screenshot(to: url)
          try Task.checkCancellation()
          guard mpv.currentItem === item, let image = UIImage(contentsOfFile: url.path) else { throw ServiceError("未取得当前画面") }
          file = url
          thumbnail = image
          return
        }
        recording = true
        if startPaused { mpv.play() }
        var timing = CaptureTiming(seconds: Double(length), fps: fps)
        var lastFrame = ContinuousClock.now
        capture: while !finishEarly {
          try Task.checkCancellation()
          guard mpv.currentItem === item else { throw ServiceError("视频已切换") }
          let t = mpv.currentTime().seconds
          switch try timing.next(t) {
          case .complete: break capture
          case .skip: break
          case .capture:
            let url = folder.appendingPathComponent(UUID().uuidString + ".png")
            frames.append(url)
            try await mpv.screenshot(to: url)
            let image = try await Task.detached(priority: .userInitiated) {
              guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 540,
                ] as CFDictionary) else { throw ServiceError("未取得当前画面") }
              try Self.writeFrame(image, to: url, type: .png)
              return image
            }.value
            thumbnail = UIImage(cgImage: image)
            lastFrame = .now
          }
          if let first = timing.samples.first { progress = min(1, max(0, (t - first) / Double(length))) }
          if !frames.isEmpty && mpv.timeControlStatus == .paused { break }
          if lastFrame.duration(to: .now) > .seconds(10) { throw ServiceError("没有收到新画面，请在视频播放时重试") }
          try await Task.sleep(for: .milliseconds(max(12, 500 / fps)))
        }
        guard frames.count >= 2 else { throw ServiceError("录制时间太短，未取得足够画面") }
        let url = folder.appendingPathComponent(UUID().uuidString + ".gif")
        let files = frames
        let delays = timing.delays()
        try await Task.detached(priority: .userInitiated) { try Self.gif(files, delays: delays, to: url) }.value
        try Task.checkCancellation()
        file = url
        progress = 1
      } catch { if !Task.isCancelled { note = error.localizedDescription } }
    }
  }
  private func frame(
    _ output: AVPlayerItemVideoOutput, at time: CMTime, transform: CGAffineTransform,
    maxSide: CGFloat?
  ) -> (CGImage, Double)? {
    var actual = CMTime.invalid
    guard time.isNumeric,
      let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &actual)
    else { return nil }
    var image = CIImage(cvPixelBuffer: buf).transformed(by: transform)
    if let maxSide {
      let k = min(1, maxSide / max(1, max(image.extent.width, image.extent.height)))
      image = image.transformed(by: .init(scaleX: k, y: k))
    }
    guard let cg = ci.createCGImage(image, from: image.extent.integral) else { return nil }
    return (cg, actual.isNumeric ? actual.seconds : time.seconds)
  }
  private func record(
    player: AVPlayer, item: AVPlayerItem, output: AVPlayerItemVideoOutput,
    transform: CGAffineTransform, length: Int, fps: Int
  ) async throws {
    guard (1...10).contains(length), [5, 8, 10, 12, 15].contains(fps) else {
      throw ServiceError("动图录制设置无效")
    }
    let startPaused = player.rate == 0
    if startPaused { player.play() }
    defer { if startPaused && player.currentItem === item { player.pause() } }
    var timing = CaptureTiming(seconds: Double(length), fps: fps)
    var frames = [URL]()
    defer { for f in frames { try? FileManager.default.removeItem(at: f) } }
    var lastFrame = ContinuousClock.now
    outer: while !finishEarly {
      try Task.checkCancellation()
      guard player.currentItem === item else { throw ServiceError("视频已切换") }
      if item.status == .failed { throw item.error ?? ServiceError("视频播放失败") }
      let time = player.currentTime()
      if let first = timing.samples.first, time.isNumeric {
        if let last = timing.samples.last, time.seconds - last > 1.5 {
          throw ServiceError("播放进度已改变，请重新录制")
        }
        if time.seconds - first >= Double(length) { break }
        progress = min(1, max(0, (time.seconds - first) / Double(length)))
      }
      if let (cg, t) = frame(output, at: time, transform: transform, maxSide: 540) {
        switch try timing.next(t) {
        case .skip: break
        case .complete: break outer
        case .capture:
          lastFrame = .now
          let u = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
          frames.append(u)
          try await Task.detached(priority: .userInitiated) {
            try Self.writeFrame(cg, to: u, type: .png)
          }.value
          thumbnail = UIImage(cgImage: cg)
        }
      }
      if !frames.isEmpty && player.rate == 0 && player.timeControlStatus == .paused { break }
      if lastFrame.duration(to: .now) > .seconds(10) { throw ServiceError("没有收到新画面，请在视频播放时重试") }
      try await Task.sleep(for: .milliseconds(max(12, 500 / fps)))
    }
    guard frames.count >= 2 else { throw ServiceError("录制时间太短，未取得足够画面") }
    let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("gif")
    let files = frames
    let delays = timing.delays()
    try await Task.detached(priority: .userInitiated) {
      try Self.gif(files, delays: delays, to: url)
    }.value
    try Task.checkCancellation()
    file = url
    progress = 1
  }
  nonisolated private static func writeFrame(_ image: CGImage, to url: URL, type: UTType) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw ServiceError("无法创建图片") }
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { throw ServiceError("写入图片失败") }
  }
  nonisolated private static func gif(_ frames: [URL], delays: [Double], to url: URL) throws {
    guard frames.count == delays.count,
      let d = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
    else { throw ServiceError("无法创建动图") }
    CGImageDestinationSetProperties(
      d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (f, delay) in zip(frames, delays) {
      guard let s = CGImageSourceCreateWithURL(f as CFURL, nil) else {
        throw ServiceError("找不到录制的画面")
      }
      CGImageDestinationAddImageFromSource(
        d, s, 0,
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
          ]
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(d), let s = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(s) == frames.count
    else { throw ServiceError("生成动图失败") }
  }
  func save() async {
    guard let file, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      if let choice = try await FolderGrants.shared.current(.pictures) {
        let ext = file.pathExtension
        try await FolderGrants.shared.withFolder(choice.id, writing: true) {
          try FolderExport.write(
            [
              .init(
                source: file, stem: ext.lowercased() == "gif" ? "轻哩 动图" : "轻哩 截图",
                ext: ext)
            ], into: $0, group: nil)
        }
        note = "已存入文件夹"
        return
      }
    } catch {
      note = error.localizedDescription
      return
    }
    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard permission == .authorized || permission == .limited else {
      note = "请允许保存到照片"
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
      }
      note = "已存入照片"
    } catch { note = error.localizedDescription }
  }
}
struct CaptureButton: View {
  let player: any PlaybackEngine
  @State private var sheet = false
  var body: some View {
    Button {
      sheet = true
    } label: {
      Image(systemName: "camera").accessibilityLabel("截图与动图")
    }
    .piliSheet(isPresented: $sheet) { CapturePanel(player).presentationDetents([.medium, .large]) }
  }
}
struct CapturePanel: View {
  let automatic: Bool
  @State private var triggered = false
  @StateObject private var capture: FrameCapture
  @State private var gif = false
  @State private var length = 3
  @State private var fps = 10
  @Environment(\.dismiss) private var dismiss
  init(_ p: any PlaybackEngine, automatic: Bool = false) {
    self.automatic = automatic
    _capture = StateObject(wrappedValue: FrameCapture(p))
  }
  /// The original captures first and shows the framed picture; a tap saves it. Here the
  /// preview leads, with 截图/动图 chips, the GIF length and rate inline, and 保存 / 分享.
  var body: some View {
    PiliNavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          Group {
            if let file = capture.file {
              GalleryZoom(file: file)
            } else if let thumb = capture.thumbnail {
              Image(uiImage: thumb).resizable().scaledToFit()
            } else {
              Rectangle().fill(.quaternary).overlay {
                if capture.busy { ProgressView() } else {
                  Image(systemName: "camera").font(.title2).foregroundStyle(.secondary)
                }
              }
            }
          }
          .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
          .padding(5).background(Color(uiColor: .systemBackground))
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
          .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
          .onTapGesture { if capture.file != nil, !capture.busy { Task { await capture.save() } } }
          HStack(spacing: 8) {
            chip("截图", !gif) { gif = false }
            chip("动图", gif) { gif = true }
            if gif {
              Menu { Picker("时长", selection: $length) { ForEach(1...10, id: \.self) { Text("\($0) 秒").tag($0) } } }
                label: { chipLabel("\(length) 秒", false) }
              Menu { Picker("帧率", selection: $fps) { ForEach([5, 8, 10, 12, 15], id: \.self) { Text("\($0) fps").tag($0) } } }
                label: { chipLabel("\(fps) fps", false) }
            }
            Spacer(minLength: 0)
          }.disabled(capture.busy)
          if capture.recording {
            ProgressView(value: capture.progress)
          }
          if let note = capture.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
          HStack(spacing: 12) {
            if capture.recording {
              Button("结束录制") { capture.stop() }.piliButtonStyle(.glassProminent)
            } else {
              Button(gif ? "开始录制" : capture.file == nil ? "截取当前画面" : "重新截取") { capture.capture(gif: gif, length: length, fps: fps) }
                .piliButtonStyle(.glass).disabled(capture.busy)
            }
            Spacer()
            if let file = capture.file {
              ShareLink(item: file) { Label("分享", systemImage: "square.and.arrow.up") }.piliButtonStyle(.glass)
              Button("保存") { Task { await capture.save() } }.piliButtonStyle(.glassProminent).disabled(capture.busy)
            }
          }
        }
        .padding(16)
      }
      .navigationTitle(gif ? "动图" : "截图").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }.task {
      capture.attach()
      // Opening the panel takes the shot at once, like the original's 截图 button.
      if !triggered {
        triggered = true
        try? await Task.sleep(for: .milliseconds(100))
        if !Task.isCancelled { capture.capture(gif: false, length: 1, fps: 10) }
      }
    }.onDisappear { capture.close() }
  }
  private func chipLabel(_ title: String, _ on: Bool) -> some View {
    Text(title).font(.subheadline.weight(on ? .semibold : .regular))
      .foregroundStyle(on ? Color.accentColor : Color.primary)
      .padding(.horizontal, 14).padding(.vertical, 7)
      .background(on ? Color.accentColor.opacity(0.14) : Color(uiColor: .tertiarySystemFill), in: Capsule())
  }
  private func chip(_ title: String, _ on: Bool, _ pick: @escaping () -> Void) -> some View {
    Button { TouchFeedback.light(); pick() } label: { chipLabel(title, on) }.buttonStyle(.plain)
  }
}
