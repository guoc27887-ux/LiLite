import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AvatarEditor: View {
  let uid: String, changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var picker: PhotosPickerItem?
  @State private var photo: UIImage?
  @State private var gif: Data?
  @State private var keepAnimation = true
  @State private var scale = 1.0
  @State private var horizontal = 0.5
  @State private var vertical = 0.5
  @State private var busy = false
  @State private var issue: String?
  private let side: CGFloat = 224
  private func rect(_ image: UIImage, side: CGFloat) -> CGRect {
    let factor = max(side / image.size.width, side / image.size.height) * CGFloat(scale)
    let w = image.size.width * factor
    let h = image.size.height * factor
    return CGRect(x: (side - w) * horizontal, y: (side - h) * vertical, width: w, height: h)
  }
  @State private var dragStart: (Double, Double)?
  @State private var pinchStart: Double?
  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        cropper.padding(.top, 20)
        if let photo, !(gif != nil && keepAnimation) {
          Text("拖动调整位置，双指缩放").font(.footnote).foregroundStyle(.secondary)
          HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $scale, in: 1...4).accessibilityLabel("缩放")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
          }
          .padding(.horizontal, 32)
          .onChange(of: scale) { _, _ in clamp(photo) }
        }
        if gif != nil {
          Toggle("保留动图", isOn: $keepAnimation).padding(.horizontal, 32)
        }
        if let issue {
          Text(issue).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        VStack(spacing: 12) {
          PhotosPicker(selection: $picker, matching: .images) {
            Label(photo == nil ? "从相册选择" : "重新选择", systemImage: "photo.on.rectangle")
              .frame(maxWidth: 260).padding(.vertical, 4)
          }
          .piliButtonStyle(.glass)
          .controlSize(.large)
          if let photo {
            Button { Task { await save(photo) } } label: {
              HStack {
                if busy { ProgressView().tint(.white) }
                Text(busy ? "正在上传" : "保存头像")
              }
              .frame(maxWidth: 260).padding(.vertical, 4)
            }
            .piliButtonStyle(.glassProminent).controlSize(.large).disabled(busy)
          }
        }
        Text("支持 JPG、PNG 与 5 MB 以内的 GIF 动图").font(.caption).foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("修改头像").navigationBarTitleDisplayMode(.inline).disabled(busy)
      .task(id: picker) {
        guard let picker else { return }
        photo = nil
        gif = nil
        issue = nil
        do {
          guard let d = try await picker.loadTransferable(type: Data.self),
            d.count <= 32 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(d as CFData, nil)
          else { throw ServiceError("照片无法读取或过大") }
          let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
          ]
          guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
          else { throw ServiceError("不是可用的图片") }
          try Task.checkCancellation()
          photo = UIImage(cgImage: img)
          if CGImageSourceGetType(source) as String? == UTType.gif.identifier
            && CGImageSourceGetCount(source) > 1 && d.count <= 5 * 1024 * 1024
          {
            gif = d
          }
          scale = 1
          horizontal = 0.5
          vertical = 0.5
          keepAnimation = true
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
  }
  /// Square crop stage with the circular avatar mask; drag moves, pinch zooms.
  @ViewBuilder private var cropper: some View {
    let stage: CGFloat = 280
    ZStack {
      RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.quaternary)
      if let photo {
        if gif != nil && keepAnimation {
          Image(uiImage: photo).resizable().scaledToFill().frame(width: side, height: side)
            .clipShape(Circle())
        } else {
          let frame = rect(photo, side: side)
          ZStack(alignment: .topLeading) {
            Color.white
            Image(uiImage: photo).resizable().frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
          }
          .frame(width: side, height: side).clipShape(Circle())
          .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 2) }
          .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
          .contentShape(Rectangle())
          .gesture(drag(photo).simultaneously(with: pinch(photo)))
          .accessibilityLabel("头像预览")
        }
      } else {
        VStack(spacing: 10) {
          Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 54))
            .foregroundStyle(.secondary)
          Text("选择一张照片作为头像").font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: stage, height: stage)
  }
  private func drag(_ photo: UIImage) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { g in
        let start = dragStart ?? (horizontal, vertical)
        dragStart = start
        let frame = rect(photo, side: side)
        let spareX = frame.width - side, spareY = frame.height - side
        if spareX > 0.5 { horizontal = min(1, max(0, start.0 - Double(g.translation.width / spareX))) }
        if spareY > 0.5 { vertical = min(1, max(0, start.1 - Double(g.translation.height / spareY))) }
      }
      .onEnded { _ in dragStart = nil }
  }
  private func pinch(_ photo: UIImage) -> some Gesture {
    MagnifyGesture()
      .onChanged { g in
        let start = pinchStart ?? scale
        pinchStart = start
        scale = min(4, max(1, start * Double(g.magnification)))
      }
      .onEnded { _ in pinchStart = nil }
  }
  private func clamp(_ photo: UIImage) {
    horizontal = min(1, max(0, horizontal))
    vertical = min(1, max(0, vertical))
  }
  @MainActor private func save(_ image: UIImage) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let bytes: Data
      let animated = keepAnimation && gif != nil
      if animated, let gif {
        bytes = gif
      } else {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: .init(width: 768, height: 768), format: format)
        bytes = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
          UIColor.white.setFill()
          ctx.fill(.init(x: 0, y: 0, width: 768, height: 768))
          image.draw(in: rect(image, side: 768))
        }
      }
      try await BiliAPI.shared.uploadAvatar(bytes, uid: uid, animated: animated)
      changed()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
