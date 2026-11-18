import ImageIO
import SwiftUI

enum NotebookImage {
  static func decoded(_ data: Data, max: Int) -> UIImage? {
    guard data.count <= 30 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max,
        ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cg)
  }
}
struct NotebookBlockEditor: View {
  @Binding var block: NotebookBlock
  let owner: String, disk: NotebookDisk?, editable: Bool, onSeek: ((cid: Int64, time: Int)) -> Void
  @State private var picture: UIImage?
  @State private var issue: String?
  private var asset: String {
    owner + ":" + (block.localPicture?.uuidString ?? block.photo?["url"] as? String ?? "")
  }
  var body: some View {
    Group {
      if block.localPicture != nil || block.photo != nil {
        if let picture {
          Image(uiImage: picture).resizable().scaledToFit().frame(maxHeight: 220)
        } else {
          Label(issue ?? (block.videoFrame ? "视频截图" : "笔记图片"), systemImage: "photo")
        }
      } else if let t = block.tag, let cid = NotebookBlock.integer(t["cid"]),
        let tsec = NotebookBlock.integer(t["seconds"]), let seconds = Int(exactly: tsec),
        seconds >= 0
      {
        Button {
          onSeek((cid, seconds))
        } label: {
          Label(
            String(format: "%d:%02d", seconds / 60, seconds % 60) + " "
              + (t["title"] as? String ?? ""), systemImage: "clock")
        }
      } else if let text = block.words {
        if editable {
          HStack {
            TextField(
              "写下笔记", text: Binding(get: { block.words ?? "" }, set: { block.setText($0) }),
              axis: .vertical
            ).fontWeight(block.attributes["bold"] as? Bool == true ? .bold : .regular).italic(
              block.attributes["italic"] as? Bool == true)
            Menu {
              ForEach(
                [("粗体", "bold"), ("斜体", "italic"), ("下划线", "underline"), ("删除线", "strike")], id: \.1
              ) { name, key in
                Button {
                  block.style(key)
                } label: {
                  if block.attributes[key] as? Bool == true {
                    Label(name, systemImage: "checkmark")
                  } else {
                    Text(name)
                  }
                }
              }
            } label: {
              Image(systemName: "textformat").accessibilityLabel("文字样式")
            }
          }
        } else {
          Text(text).textSelection(.enabled)
        }
      } else {
        Label("笔记附件", systemImage: "paperclip")
      }
    }.task(id: asset) {
      picture = nil
      issue = nil
      do {
        let data: Data
        if let id = block.localPicture, let disk {
          data = try Data(contentsOf: disk.pic(id), options: .mappedIfSafe)
        } else if let raw = block.photo?["url"] as? String, let u = NotebookBlock.allowedImage(raw)
        {
          data = try await BiliAPI.shared.notebookAuthorizedImage(u, owner: owner)
        } else {
          return
        }
        try Task.checkCancellation()
        picture = NotebookImage.decoded(data, max: 600)
      } catch { if !Task.isCancelled { issue = "图片未能加载" } }
    }
  }
}
struct NotebookFrame: View {
  let model: PlayerModel, allowed: () -> Bool, select: (Data) -> Void
  @StateObject private var capture: FrameCapture
  @Environment(\.dismiss) private var dismiss
  init(model: PlayerModel, allowed: @escaping () -> Bool, select: @escaping (Data) -> Void) {
    self.model = model
    self.allowed = allowed
    self.select = select
    _capture = StateObject(wrappedValue: FrameCapture(model.engine))
  }
  var body: some View {
    // Framed preview first, then 重新截取 / 加入笔记, like the screenshot panel.
    PiliNavigationStack {
      VStack(spacing: 16) {
        Group {
          if let img = capture.thumbnail { Image(uiImage: img).resizable().scaledToFit() }
          else { Rectangle().fill(.quaternary).overlay { if capture.busy { ProgressView() } } }
        }
        .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
        .padding(5).background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        if let n = capture.note { Text(n).font(.footnote).foregroundStyle(.secondary) }
        HStack {
          Button(capture.thumbnail == nil ? "截取当前画面" : "重新截取") {
            if allowed() { capture.capture(gif: false, length: 1, fps: 1) }
          }.piliButtonStyle(.glass).disabled(capture.busy || !allowed())
          Spacer()
          if let img = capture.thumbnail {
            Button("加入笔记") {
              guard allowed(), let bytes = img.jpegData(compressionQuality: 0.85) else { return }
              select(bytes)
            }.piliButtonStyle(.glassProminent)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(16)
      .navigationTitle("视频截图").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
    .onAppear { if allowed() { capture.capture(gif: false, length: 1, fps: 1) } }.onDisappear {
      capture.close()
    }
  }
}
