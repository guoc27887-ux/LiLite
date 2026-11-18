import PhotosUI
import SwiftUI

struct NewVote: View {
  var existing: VoteRef?
  let selected: (VoteRef) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var owner: String?
  @State private var title = ""
  @State private var intro = ""
  @State private var imageMode = false
  @State private var options = [DraftOption(), DraftOption()]
  @State private var maxChoices = 1
  @State private var until = Date().addingTimeInterval(86400)
  @State private var ready = false
  @State private var busy = false
  @State private var retry = 0
  @State private var issue: String?
  private struct DraftOption: Identifiable {
    let id = UUID()
    var text = "", image = ""
    var chosen: PhotosPickerItem?
  }
  private var valid: Bool {
    guard ready, owner != nil, owner == accounts.state.active, (1...32).contains(title.count), intro.count <= 100,
      (2...20).contains(options.count), until > .now, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return options.allSatisfy {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 20
        && (!imageMode || $0.chosen != nil || !$0.image.isEmpty)
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if !ready && issue == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
        if ready {
          Text("投票类型").font(.subheadline).padding(.top, 8)
          HStack(spacing: 16) {
            typeCard("文字投票", on: !imageMode) { imageMode = false }
            typeCard("图片投票", on: imageMode) { imageMode = true }
          }
          .padding(.top, 12)
          Spacer().frame(height: 36)
          inputRow("投票标题") { TextField("请填写标题", text: limited($title, 32)) }
          Divider()
          inputRow("投票说明") { TextField("投票说明", text: limited($intro, 100), axis: .vertical).lineLimit(1...4) }
          Divider()
          Spacer().frame(height: 36)
          ForEach(Array($options.enumerated()), id: \.element.id) { index, $option in
            inputRow("选项\(index + 1)") {
              HStack(spacing: 10) {
                TextField("选项内容，最多 20 字", text: limited($option.text, 20))
                if imageMode {
                  PhotosPicker(selection: $option.chosen, matching: .images) {
                    optionImage(option)
                  }.buttonStyle(.plain)
                }
                if options.count > 2 {
                  Button {
                    options.remove(at: index); maxChoices = min(maxChoices, options.count)
                  } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                      .frame(width: 26, height: 26).background(.quaternary, in: Circle())
                  }.buttonStyle(.plain).accessibilityLabel("移除选项\(index + 1)")
                }
              }
            }
            Divider()
          }
          if options.count < 20 {
            Button { options.append(.init()) } label: {
              Label("添加选项", systemImage: "plus").font(.footnote.weight(.medium))
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(.secondary)
            .padding(.top, 12)
          }
          Spacer().frame(height: 36)
          inputRow("单选/多选", width: 100) {
            Menu {
              Picker("单选/多选", selection: $maxChoices) {
                ForEach(1...max(1, options.count), id: \.self) { n in
                  Text(n == 1 ? "单选" : "最多选\(n)项").tag(n)
                }
              }
            } label: {
              HStack(spacing: 4) {
                Text(maxChoices == 1 ? "单选" : "最多选\(maxChoices)项")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
              }.foregroundStyle(.primary)
            }
          }
          Divider()
          inputRow("投票截止时间", width: 100) {
            DatePicker("投票截止时间", selection: $until,
              in: Date().addingTimeInterval(300)...Date().addingTimeInterval(90 * 86400))
              .labelsHidden()
            Spacer(minLength: 0)
          }
          Divider()
          Button { Task { await save() } } label: {
            HStack {
              if busy { ProgressView() }
              Text(existing == nil ? "发起投票" : "保存投票")
            }
            .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
          }
          .piliButtonStyle(.glassProminent).controlSize(.large).disabled(busy || !valid)
          .padding(.top, 36)
        }
        if let issue {
          VStack(alignment: .leading, spacing: 8) {
            Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
            if !ready, existing != nil { Button("重新读取") { retry += 1 } }
          }
          .padding(.top, 16)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 40)
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(existing == nil ? "发起投票" : "编辑投票").navigationBarTitleDisplayMode(.inline)
    .disabled(busy).interactiveDismissDisabled(busy)
      .task(id: retry) { await prepare() }
      .onChange(of: accounts.state.active) { _, id in if let owner, id != owner { dismiss() } }
  }
  private func inputRow<Content: View>(_ label: String, width: CGFloat = 65,
    @ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 12) {
      Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
      content()
    }
    .frame(minHeight: 50)
  }
  private func limited(_ text: Binding<String>, _ max: Int) -> Binding<String> {
    Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(max)) })
  }
  private func typeCard(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.subheadline.weight(on ? .semibold : .regular))
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(on ? Color.accentColor.opacity(0.1) : Color.clear,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(on ? Color.accentColor : Color(uiColor: .separator), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
          if on {
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
              .padding(3).background(Color.accentColor,
                in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomTrailingRadius: 10))
          }
        }
    }
    .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
  }
  @ViewBuilder private func optionImage(_ option: DraftOption) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
      if option.chosen != nil {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
      } else if let url = GalleryPicture.source(option.image) {
        SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
      } else {
        Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
      }
    }
    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityLabel(option.chosen != nil ? "已选图片" : "选择图片")
  }
  private func prepare() async {
    issue = nil
    guard let uid = accounts.state.active else { issue = "请先登录"; return }
    owner = uid
    guard let existing else { ready = true; return }
    do {
      let response = try await BiliAPI.shared.read("/x/vote/vote_info", ["vote_id": String(existing.id)], expectedAccount: uid, as: VoteView.Envelope.self)
      let v = response.vote_info
      guard v.vote_publisher == Int64(uid) else { throw ServiceError("只能编辑自己发起的投票") }
      let rows = v.options ?? []
      guard (2...20).contains(rows.count), let end = v.end_time else { throw ServiceError("投票信息不完整") }
      guard end > Int64(Date().timeIntervalSince1970) else { throw ServiceError("投票已结束") }
      try Task.checkCancellation()
      title = v.title ?? ""; intro = v.desc ?? ""
      imageMode = v.type == 1 || rows.contains { $0.img_url?.isEmpty == false }
      options = rows.map { DraftOption(text: $0.opt_desc ?? "", image: $0.img_url ?? "") }
      maxChoices = min(rows.count, max(1, v.choice_cnt ?? 1))
      until = Date(timeIntervalSince1970: Double(end)); ready = true
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  private func save() async {
    guard !busy, valid, let owner else { return }
    busy = true; issue = nil
    defer { busy = false }
    do {
      guard let user = try await AccountJar.shared.current(), user.id == owner, let mid = Int64(owner) else { throw ServiceError("账号已切换") }
      var encoded = [[String: String]]()
      for index in options.indices {
        if imageMode, let item = options[index].chosen {
          guard let raw = try await item.loadTransferable(type: Data.self), raw.count <= 64 * 1024 * 1024,
            let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.85),
            jpeg.count <= 16 * 1024 * 1024 else { throw ServiceError("无法读取选项图片，或图片过大") }
          guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
          let uploaded = try await BiliAPI.shared.upload(jpeg, account: user, biz: "vote")
          options[index].image = uploaded.image_url; options[index].chosen = nil
        }
        encoded.append(["opt_desc": options[index].text, "img_url": imageMode ? options[index].image : ""])
      }
      let duration = Int(until.timeIntervalSinceNow)
      guard (1...(90 * 86400)).contains(duration) else { throw ServiceError("请选择未来 90 天内的截止时间") }
      var fields: [String: Any] = ["title": title, "desc": intro, "type": imageMode ? 1 : 0, "choice_cnt": maxChoices,
        "duration": duration, "options": encoded, "only_fans_level": 0, "vote_publisher": mid]
      if let existing { fields["vote_id"] = existing.id }
      let reply = try await BiliAPI.shared.dynPost(existing == nil ? "/x/vote/create" : "/x/vote/update", ["vote_info": fields], expectedAccount: owner)
      guard let id = (reply["vote_id"] as? NSNumber)?.int64Value ?? (reply["vote_id"] as? String).flatMap(Int64.init),
        id > 0, existing.map({ $0.id == id }) ?? true else { throw ServiceError("未取得有效投票编号") }
      guard accounts.state.active == owner else { return }
      selected(.init(id: id, title: title)); dismiss()
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}
