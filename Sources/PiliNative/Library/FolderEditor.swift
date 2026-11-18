import SwiftUI

struct FolderEditor: View {
  let folder: Folder?, uid: String
  var saved: () -> Void
  @State private var title: String
  @State private var intro = ""
  @State private var hidden = false
  @State private var cover = ""
  @State private var draftCover: Data?
  @State private var isDefault = false
  @State private var cropping = false
  @State private var ready = false
  @State private var saving = false
  @State private var issue: String?
  @Environment(\.dismiss) var dismiss
  init(folder: Folder?, uid: String, saved: @escaping () -> Void) {
    self.uid = uid
    self.folder = folder
    self.saved = saved
    _title = State(initialValue: folder?.title ?? "")
  }
  struct Info: Decodable { let title: String, intro: String?, attr: Int?, cover: String? }
  var body: some View {
    PiliNavigationStack {
      Form {
        if !isDefault {
          Section("封面") { FolderCoverPicker(cover: $cover, draft: $draftCover, editing: $cropping) }
        }
        Section {
          HStack(spacing: 12) {
            Text("名称").frame(width: 44, alignment: .leading)
            TextField("名称", text: $title).disabled(isDefault)
              .onChange(of: title) { _, value in
                if !isDefault, value.count > 20 { title = String(value.prefix(20)) }
              }
            if !isDefault {
              Text("\(title.count)/20").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
          }
          if !isDefault {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("简介").frame(width: 44, alignment: .leading)
              TextField("可填写简介", text: $intro, axis: .vertical).lineLimit(2...6)
                .onChange(of: intro) { _, value in
                  if value.count > 200 { intro = String(value.prefix(200)) }
                }
            }
          }
        } footer: {
          if isDefault { Text("默认收藏夹的名称和简介不能修改") }
        }
        Section {
          Toggle("公开", isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
        } footer: {
          Text(hidden ? "仅自己可见" : "所有人都可以看到这个收藏夹")
        }
        if let issue {
          Section { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }
      }
      .overlay { if !ready && issue == nil { ProgressView() } }
      .navigationTitle(folder == nil ? "创建收藏夹" : "编辑收藏夹").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { Task { await store() } }.piliButtonStyle(.glassProminent).disabled(
              !ready || saving || cropping
                || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }.task {
      if let folder {
        do {
          let v = try await BiliAPI.shared.read(
            "/x/v3/fav/folder/info", ["media_id": "\(folder.id)"], expectedAccount: uid,
            as: Info.self)
          isDefault = v.attr.map { ($0 & 2) == 0 } ?? false
          title = v.title
          intro = v.intro ?? ""
          cover = v.cover ?? ""
          hidden = ((v.attr ?? 0) & 1) == 1
          ready = true
        } catch { issue = error.localizedDescription }
      } else {
        ready = true
      }
    }.interactiveDismissDisabled(saving)
  }
  private func store() async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    var fields = ["title": title, "intro": intro, "privacy": hidden ? "1" : "0", "cover": cover]
    if let folder { fields["media_id"] = "\(folder.id)" }
    do {
      if !isDefault, let draftCover {
        cover = try await BiliAPI.shared.folderCover(draftCover, uid: uid)
        fields["cover"] = cover
        self.draftCover = nil
      }
      try await BiliAPI.shared.submit(
        folder == nil ? "/x/v3/fav/folder/add" : "/x/v3/fav/folder/edit", fields,
        expectedAccount: uid)
      saved()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
