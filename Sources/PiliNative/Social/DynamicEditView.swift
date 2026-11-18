import PhotosUI
import SwiftUI

extension BiliAPI {
  func currentRevision(id: String, uid: String) async throws -> DynamicRevision {
    let row = try await mainDynamicRow(id, owner: uid)
    return try .init(row: row, expected: uid, id: id)
  }
  func edit(_ original: DynamicRevision, body: [String: Any], uploadID: String) async throws {
    guard let u = try await AccountJar.shared.current(), u.id == original.author, let csrf = u.csrf
    else { throw ServiceError("账号已切换") }
    guard
      try await currentRevision(id: original.id, uid: u.id).versionData() == original.versionData()
    else {
      throw ServiceError("这条动态已经更新，请重新打开后编辑")
    }
    let fields = try await sign([
      "platform": "web", "csrf": csrf, "w_dyn_req.upload_id": uploadID,
      "w_dyn_req.meta": #"{"app_meta":{"from":"create.dynamic.web","mobi_app":"web"}}"#,
      "x-bili-device-req-json": #"{"platform":"web","device":"pc","spmid":"333.1368"}"#,
    ])
    _ = try await dynPost(
      "/x/dynamic/feed/edit/dyn", body, expectedAccount: u.id, signedQuery: fields)
  }
}

struct DynamicEditView: View {
  let id: String, uid: String, changed: () -> Void
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  @State private var source: DynamicRevision?
  @State private var record: DynamicDraftFile?
  @State private var baseline: DynamicDraftFile?
  @State private var checkpoint: DynamicDraftFile?
  @State private var draft = ReplyDraft()
  @State private var cursor: NSRange?
  @State private var busy = false
  @State private var importing = false
  @State private var sent = false
  @State private var conflict = false
  @State private var confirm = false
  @State private var issue: String?
  @State private var retry = 0
  @State private var rules: MomentOwnerSettings.Permissions?
  @State private var choosingTopic = false
  @State private var reserving = false
  private let disk = DynamicDraftDisk.app
  private var scope: DynamicDraftScope? { .init(owner: uid, editing: id) }
  private var snapshot: DynamicDraftFile? {
    guard var f = record else { return nil }
    f.units = draft.pieces.map(DynamicDraftFile.Unit.init)
    f.cursor = cursor?.location
    return f
  }
  private var maySave: Bool {
    guard let r = snapshot, let source else { return false }
    return !busy && !importing && !sent && !conflict && accounts.state.active == uid
      && r.title.count <= 20
      && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !(r.originals ?? []).isEmpty || !r.pictures.isEmpty || r.reserve != nil
        || source.origin != nil)
  }
  var body: some View {
    PiliNavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let source, let scope, let rec = Binding($record), !conflict {
            editor(source, scope: scope, rec: rec)
          } else if issue == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
          }
          if let issue {
            VStack(alignment: .leading, spacing: 10) {
              Text(issue).font(.footnote).foregroundStyle(.secondary)
              if conflict {
                Button("丢弃旧草稿，载入最新内容", role: .destructive) { confirm = true }
              } else if source == nil {
                HStack(spacing: 16) {
                  Button("重新读取") { retry += 1 }
                  NavigationLink("打开创作中心") {
                    SitePage(url: URL(string: "https://member.bilibili.com/platform/home")!)
                  }
                }
                .font(.subheadline)
              }
            }
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("编辑动态").navigationBarTitleDisplayMode(.inline).disabled(busy || importing)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { if persist(clean: true) { dismiss() } }.disabled(busy || importing)
          }
          ToolbarItem(placement: .confirmationAction) {
            if busy || importing {
              ProgressView()
            } else {
              Button("保存") { submit() }.piliButtonStyle(.glassProminent).disabled(!maySave)
            }
          }
          if differs, !conflict {
            ToolbarItem(placement: .bottomBar) {
              Button("放弃本次修改", role: .destructive) { confirm = true }
            }
          }
        }
        .navigationDestination(isPresented: $choosingTopic) {
          TopicChooser { t in
            if accounts.state.active == uid {
              record?.topic = .init(id: t.id, name: t.name)
            }
          }
        }
        .navigationDestination(isPresented: $reserving) {
          ReservationEditor(uid: uid, original: record?.reserve?.reservation) { v in
            if accounts.state.active == uid {
              record?.reserve = .init(id: v.id, title: v.title, start: v.start, subtype: v.subtype)
            }
          }
        }
        .confirmationDialog("丢弃这份编辑草稿？", isPresented: $confirm) {
          Button("丢弃", role: .destructive) {
            guard let scope else { return }
            do {
              try disk.discard(scope, checkpoint: conflict ? .any : .matches(checkpoint))
              checkpoint = nil
              record = nil
              source = nil
              baseline = nil
              conflict = false
              retry += 1
            } catch { issue = error.localizedDescription }
          }
        }
    }.interactiveDismissDisabled(busy || importing)
      .task(id: retry) { await load() }
      .task(id: snapshot) {
        do {
          try await Task.sleep(for: .milliseconds(450))
          try Task.checkCancellation()
          _ = persist(clean: false)
        } catch {}
      }
      .onDisappear { _ = persist(clean: !importing) }
      .onChange(of: phase) { _, p in if p != .active { _ = persist(clean: false) } }
      .onChange(of: accounts.state.active) { _, v in if v != uid { dismiss() } }
  }
  @ViewBuilder private func editor(
    _ source: DynamicRevision, scope: DynamicDraftScope, rec: Binding<DynamicDraftFile>
  ) -> some View {
    let plain = source.resourceID == nil && source.origin == nil
    if plain {
      ComposerTopicChip(name: rec.wrappedValue.topic?.name, choose: { choosingTopic = true },
        clear: { rec.wrappedValue.topic = nil })
      ComposerTitleField(text: rec.title)
    }
    DynamicEntityInput(draft: $draft, cursor: $cursor, uid: uid, allowVote: plain) {
      if plain {
        ComposerToolButton(title: "直播预约", symbol: "calendar.badge.clock",
          active: rec.wrappedValue.reserve != nil) { reserving = true }
      }
    }
    if plain, let reserve = rec.wrappedValue.reserve {
      ComposerReserveCard(title: reserve.title, start: reserve.start) { rec.wrappedValue.reserve = nil }
    }
    HStack(alignment: .top) {
      Spacer()
      VStack(alignment: .leading, spacing: 4) {
        ComposerReplyMenu(selection: rec.comments, keepOption: true) { Self.allows($0, rules) }
        ComposerPrivacyMenu(isPrivate: rec.privateOnly)
      }
    }
    if plain {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          DynamicEditPhotos(
            source: source, scope: scope, record: rec, importing: $importing, issue: $issue)
        }
        .padding(.horizontal, 16)
      }
      .scrollClipDisabled().padding(.horizontal, -16)
    }
  }
  private var differs: Bool {
    guard var s = snapshot else { return false }
    s.cursor = nil
    return baseline != s
  }
  private static func allows(_ mode: Int, _ p: MomentOwnerSettings.Permissions?) -> Bool {
    if mode == -1 { return true }
    guard let p else { return false }
    return ((p.up_reply.status == 1) == (mode != 1) || p.up_reply.can_modify)
      && ((p.up_reply_selection.status == 1) == (mode == 2) || p.up_reply_selection.can_modify)
  }
  private func permissions(_ s: DynamicRevision) async throws -> MomentOwnerSettings.Permissions? {
    guard let oid = s.rootID, let kind = s.rootType else { return nil }
    return try await BiliAPI.shared.read(
      "/x/v2/reply/subject/interaction-status",
      ["oid": oid, "type": String(kind), "web_location": "333.1369"],
      expectedAccount: uid, as: MomentOwnerSettings.Permissions.self)
  }
  private func load() async {
    guard let scope else {
      issue = "动态编号无效"
      return
    }
    do {
      issue = nil
      let s = try await BiliAPI.shared.currentRevision(id: id, uid: uid)
      let permissions = try? await permissions(s)
      try Task.checkCancellation()
      guard accounts.state.active == uid else { return }
      var f = DynamicDraftFile(scope: scope)
      f.base = try s.versionData()
      f.title = s.title
      f.units = s.pieces.map(DynamicDraftFile.Unit.init)
      f.originals = s.pictures.map(\.id)
      f.privateOnly = s.privateOnly
      f.comments = -1
      if let i = s.topicID, let name = s.topicName { f.topic = .init(id: i, name: name) }
      if let i = s.attached.flatMap(Int64.init) {
        f.reserve = .init(id: i, title: s.reserveTitle ?? "编辑直播预约", start: .distantPast, subtype: 0)
      }
      baseline = f
      source = s
      rules = permissions
      if let old = try disk.load(scope) {
        checkpoint = old
        guard old.base == f.base, Set(old.originals ?? []).isSubset(of: Set(s.pictures.map(\.id)))
        else {
          conflict = true
          issue = "这条动态已更新，旧草稿未覆盖新内容"
          return
        }
        f = old
        issue = "已恢复编辑草稿"
      }
      record = f
      draft = f.editor()
      cursor = f.cursor.map {
        .init(location: min(max(0, $0), (draft.text as NSString).length), length: 0)
      }
    } catch {
      if !Task.isCancelled {
        issue = error.localizedDescription
        conflict = source != nil
      }
    }
  }
  @discardableResult private func persist(clean: Bool) -> Bool {
    guard !sent, !conflict, let scope, let outgoing = snapshot, baseline != nil else { return true }
    do {
      if differs {
        if clean || outgoing != checkpoint {
          try disk.save(outgoing, scope: scope, clean: clean, checkpoint: .matches(checkpoint))
          checkpoint = outgoing
        }
      } else if checkpoint != nil, !importing {
        try disk.discard(scope, checkpoint: .matches(checkpoint))
        checkpoint = nil
      }
      return true
    } catch {
      issue = error.localizedDescription
      return false
    }
  }
  private func submit() {
    guard maySave, let source, let scope, let outgoing = snapshot, persist(clean: false) else {
      return
    }
    busy = true
    Task {
      guard let finished = try? SleepExitFence.shared.enter() else { busy = false; return }; defer { finished() }
      defer { busy = false }
      do {
        guard let account = try await AccountJar.shared.current(), account.id == uid else {
          throw ServiceError("账号已切换")
        }
        let newest = try await BiliAPI.shared.currentRevision(id: id, uid: uid)
        guard try newest.versionData() == outgoing.base else {
          throw ServiceError("动态已更新，请重新打开后编辑")
        }
        if outgoing.comments >= 0, !(try await Self.allows(outgoing.comments, permissions(source)))
        {
          throw ServiceError("当前不能更改这条动态的评论设置")
        }
        if source.resourceID != nil {
          guard outgoing.pictures.isEmpty, (outgoing.originals ?? []).isEmpty,
            outgoing.reserve.map { String($0.id) } == source.attached
          else { throw ServiceError("关联稿件已变更，请重新打开后编辑") }
        }
        var pics = [[String: Any]]()
        for key in outgoing.ordered {
          switch key {
          case .original(let id):
            guard let old = source.pictures.first(where: { $0.id == id }) else {
              throw ServiceError("原图已变更")
            }
            pics.append(old.wire)
          case .local(let id):
            let bytes = try Data(contentsOf: disk.image(id, scope: scope), options: .mappedIfSafe)
            let p = try await BiliAPI.shared.upload(bytes, account: account)
            pics.append([
              "img_src": p.image_url, "img_width": p.image_width, "img_height": p.image_height,
              "img_size": p.img_size ?? Double(bytes.count) / 1024,
            ])
          }
        }
        let upload = "\(uid)_\(Int(Date().timeIntervalSince1970))_\(Int.random(in:1000...9999))"
        let body = source.payload(
          contents: outgoing.units.map(\.piece), title: outgoing.title, pictures: pics,
          topicID: outgoing.topic?.id, topicName: outgoing.topic?.name,
          isPrivate: outgoing.privateOnly,
          replyMode: outgoing.comments, uploadID: upload,
          reserve: outgoing.reserve.map { .use($0.id) } ?? .remove)
        try await BiliAPI.shared.edit(source, body: body, uploadID: upload)
        sent = true
        try? disk.discard(scope, checkpoint: .matches(checkpoint))
        if accounts.state.active == uid {
          changed()
          dismiss()
        }
      } catch { issue = error.localizedDescription }
    }
  }
}
