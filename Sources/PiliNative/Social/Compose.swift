import PhotosUI
import SwiftUI

extension BiliAPI {
  struct Uploaded: Decodable {
    let image_url: String
    let image_width: Int
    let image_height: Int
    let img_size: Double?
  }
  func upload(
    _ data: Data, account: Identity, biz: String = "new_dyn", format: IMImageFormat = .jpeg
  ) async throws -> Uploaded {
    guard let csrf = account.csrf else { throw ServiceError("登录状态已失效") }
    let boundary = "PiliNative-" + UUID().uuidString
    var body = Data()
    for (k, v) in [("category", "daily"), ("biz", biz), ("csrf", csrf)] {
      body.append(
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
    }
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"file_up\"; filename=\"photo.\(format.ext)\"\r\nContent-Type: \(format.mime)\r\n\r\n"
          .utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var r = URLRequest(
      url: URL(string: "https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs")!,
      timeoutInterval: 60)
    r.httpMethod = "POST"
    r.httpBody = body
    r.setValue(account.header, forHTTPHeaderField: "Cookie")
    r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    r.setValue("https://t.bilibili.com/", forHTTPHeaderField: "Referer")
    try Task.checkCancellation()
    guard try await AccountJar.shared.current()?.id == account.id else {
      throw ServiceError("账号已切换")
    }
    let (bytes, h) = try await webResponse(r, identity: account)
    struct R: Decodable {
      let code: Int
      let message: String?
      let data: Uploaded?
    }
    let v = try JSONDecoder().decode(R.self, from: bytes)
    guard (h as? HTTPURLResponse)?.statusCode == 200, v.code == 0, let image = v.data else {
      throw ServiceError(v.message ?? "图片上传失败")
    }
    return image
  }

  func publish(
    _ draft: DynamicDraftFile, scope: DynamicDraftScope, repost: String?,
    resource: DynamicShareResource?, suffix: [ReplyDraft.Piece] = []
  ) async throws -> String? {
    try draft.check(scope)
    guard let account = try await AccountJar.shared.current(), account.id == scope.owner else {
      throw ServiceError("账号已切换")
    }
    guard DynamicDraftScope(owner: scope.owner, repost: repost, resource: resource) == scope,
      draft.title.count <= 20
    else { throw ServiceError("草稿标题或目标无效") }
    if let date = draft.scheduled, draft.privateOnly || !DynamicDraftFile.scheduling(date) {
      throw ServiceError("定时发布请选择六分钟后至七天内的公开时间")
    }
    let disk = DynamicDraftDisk.app
    var pics: [[String: Any]] = []
    for id in draft.pictures {
      try Task.checkCancellation()
      let raw = try Data(contentsOf: disk.image(id, scope: scope), options: .mappedIfSafe)
      let p = try await upload(raw, account: account)
      pics.append([
        "img_src": p.image_url, "img_width": p.image_width, "img_height": p.image_height,
        "img_size": p.img_size ?? Double(raw.count) / 1024,
      ])
    }
    let uploadID =
      "\(resource != nil ? "0" : scope.owner)_\(Int(Date().timeIntervalSince1970))_\(Int.random(in:1000...9999))"
    let body = try DynamicPublishWire.body(
      draft: draft, scope: scope, repost: repost, resource: resource, pictures: pics,
      suffix: suffix, uploadID: uploadID)
    try Task.checkCancellation()
    let value = try await dynPost("/x/dynamic/feed/create/dyn", body, expectedAccount: scope.owner)
    return DynamicPublishWire.receiptID(value)
  }
}
struct DynamicComposer: View {
  let resource: DynamicShareResource?
  let repost: String?, initialTopic: TopicLink?, onSent: () -> Void
  init(
    repost: String? = nil, resource: DynamicShareResource? = nil, initialTopic: TopicLink? = nil,
    onSent: @escaping () -> Void
  ) {
    self.resource = resource
    self.repost = repost
    self.initialTopic = initialTopic
    self.onSent = onSent
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var scope: DynamicDraftScope?
  var body: some View {
    Group {
      if let scope, scope.owner == accounts.state.active {
        OwnedDynamicComposer(
          scope: scope, repost: repost, resource: resource, topic: initialTopic, onSent: onSent)
      } else if accounts.state.active == nil {
        PiliNavigationStack { QRLoginView().toolbar { Button("关闭") { dismiss() } } }
      } else {
        ProgressView()
      }
    }.onAppear {
      if scope == nil, let owner = accounts.state.active {
        scope = .init(owner: owner, repost: repost, resource: resource)
      }
    }
    .onChange(of: accounts.state.active) { _, owner in
      if let scope, scope.owner != owner {
        dismiss()
      } else if let owner {
        scope = DynamicDraftScope(owner: owner, repost: repost, resource: resource)
      }
    }
  }
}
private struct OwnedDynamicComposer: View {
  let resource: DynamicShareResource?
  let scope: DynamicDraftScope, repost: String?, onSent: () -> Void
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  @State private var checkpoint: DynamicDraftFile?
  @State private var record: DynamicDraftFile
  @State private var draft = ReplyDraft()
  @State private var cursor: NSRange?
  @State private var ready = false
  @State private var busy = false
  @State private var importing = false
  @State private var confirmClear = false
  @State private var discarded = false
  @State private var sent = false
  @State private var note: String?
  @State private var receipt: DynamicPostReceipt?
  @State private var origin = DynamicRepostContext()
  @State private var originReady = false
  @State private var originError: String?
  @State private var originAttempt = 0
  @State private var choosingTopic = false
  @State private var reserving = false
  @AppStorage("social.verifyPost") private var verify = false
  private let disk = DynamicDraftDisk.app
  init(
    scope: DynamicDraftScope, repost: String?, resource: DynamicShareResource?, topic: TopicLink?,
    onSent: @escaping () -> Void
  ) {
    self.scope = scope
    self.repost = repost
    self.resource = resource
    self.onSent = onSent
    var blank = DynamicDraftFile(scope: scope)
    if let topic { blank.topic = .init(id: topic.id, name: topic.name) }
    _record = State(initialValue: blank)
  }
  private var snapshot: DynamicDraftFile {
    var f = record
    f.units = draft.pieces.map(DynamicDraftFile.Unit.init)
    f.cursor = cursor?.location
    return f
  }
  private var canPost: Bool {
    ready && (repost == nil || originReady) && !busy && !importing && !sent
      && accounts.state.active == scope.owner && record.title.count <= 20
      && (scope.key != "new" || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !record.pictures.isEmpty || record.reserve != nil)
  }
  var body: some View {
    PiliNavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if ready {
            if scope.key == "new" {
              ComposerTopicChip(name: record.topic?.name, choose: { choosingTopic = true },
                clear: { record.topic = nil })
              ComposerTitleField(text: $record.title)
            }
            DynamicEntityInput(
              draft: $draft, cursor: $cursor, uid: scope.owner, allowVote: scope.key == "new",
              suggested: resource.flatMap { r in
                guard let mid = r.mentionID, let name = r.author else { return nil }
                return .init(id: mid, name: name)
              }
            ) {
              if scope.key == "new" {
                ComposerToolButton(title: "直播预约", symbol: "calendar.badge.clock",
                  active: record.reserve != nil) { reserving = true }
              }
            }
            if let resource { sharedCard(resource) }
            if let reserve = record.reserve {
              ComposerReserveCard(title: reserve.title, start: reserve.start) { record.reserve = nil }
            }
            if scope.key == "new" {
              HStack(alignment: .top) {
                ComposerScheduleButton(date: $record.scheduled, disabled: record.privateOnly)
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                  ComposerReplyMenu(selection: $record.comments)
                  ComposerPrivacyMenu(isPrivate: $record.privateOnly, lockPrivate: record.scheduled != nil)
                }
              }
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                  DynamicPhotoDraft(
                    scope: scope, images: $record.pictures, limit: 9, importing: $importing,
                    issue: $note)
                }
                .padding(.horizontal, 16)
              }
              .scrollClipDisabled().padding(.horizontal, -16)
            } else if origin.oid != nil && origin.kind != nil {
              Toggle(isOn: Binding(get: { record.alsoComment ?? false }, set: { record.alsoComment = $0 })) {
                Text("同时评论")
              }
              .toggleStyle(LoginCheckbox()).font(.subheadline)
            }
          } else if note == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
          }
          if let originError {
            HStack {
              Label(originError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
              Spacer()
              Button("重新读取原动态") { originAttempt += 1 }
            }
            .font(.footnote)
          }
          if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      }
      .scrollDismissesKeyboard(.interactively)
      .disabled(busy || importing || sent)
        .navigationTitle(scope.key == "new" ? "发布动态" : "转发动态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { if !ready || persist(clean: true) { dismiss() } }.disabled(
              busy || importing)
          }
          ToolbarItem(placement: .confirmationAction) {
            if busy || importing {
              ProgressView()
            } else {
              Button(record.scheduled == nil ? "发布" : "定时发布") { submit() }
                .piliButtonStyle(.glassProminent).disabled(!canPost)
            }
          }
          if ready && snapshot.hasContent {
            ToolbarItem(placement: .bottomBar) {
              Button("丢弃草稿", role: .destructive) { confirmClear = true }
            }
          }
        }
        .navigationDestination(isPresented: $choosingTopic) {
          TopicChooser { topic in
            if accounts.state.active == scope.owner {
              record.topic = .init(id: topic.id, name: topic.name)
            }
          }
        }
        .navigationDestination(isPresented: $reserving) {
          ReservationEditor(uid: scope.owner, original: record.reserve?.reservation) { v in
            if accounts.state.active == scope.owner {
              record.reserve = .init(id: v.id, title: v.title, start: v.start, subtype: v.subtype)
            }
          }
        }
        .confirmationDialog("丢弃这份草稿？", isPresented: $confirmClear) {
          Button("丢弃", role: .destructive) {
            do {
              try disk.discard(scope, checkpoint: ready ? .matches(checkpoint) : .any)
              discarded = true
              dismiss()
            } catch { note = error.localizedDescription }
          }
        }
        .piliSheet(
          item: $receipt,
          onDismiss: {
            if sent {
              onSent()
              dismiss()
            }
          }
        ) { DynamicPostResult(result: $0) }
    }.interactiveDismissDisabled(busy || importing)
      .onAppear { load() }
      .task(id: originAttempt) {
        originError = nil
        if let resource {
          origin = .init(oid: resource.commentOID, kind: resource.commentType)
        } else if let repost {
          do {
            let row = try await BiliAPI.shared.mainDynamicRow(repost, owner: scope.owner)
            guard let ctx = DynamicRepostContext(row: row, expected: repost)
            else { throw ServiceError("原动态暂不可用") }
            try Task.checkCancellation()
            if accounts.state.active == scope.owner {
              origin = ctx
              originReady = true
            }
          } catch { if !Task.isCancelled { originError = error.localizedDescription } }
        }
      }
      .onDisappear { if ready { _ = persist(clean: !importing) } }
      .onReceive(NotificationCenter.default.publisher(for: SleepAppExit.checkpoint)) { _ in if ready { _ = persist(clean: false) } }
    .onChange(of: phase) { _, state in if state != .active { _ = persist(clean: false) } }
      .task(id: snapshot) {
        guard ready else { return }
        do {
          try await Task.sleep(for: .milliseconds(450))
          try Task.checkCancellation()
          _ = persist(clean: false)
        } catch {}
      }
  }
  /// The shared video, article or other resource being posted, as a quoted card.
  private func sharedCard(_ resource: DynamicShareResource) -> some View {
    HStack(spacing: 10) {
      if let url = resource.cover.flatMap(GalleryPicture.source) {
        SiteThumbnail(url: url) {
          $0.resizable().scaledToFill()
        } placeholder: {
          Color.clear
        }
        .frame(width: 96, height: 60).background(.quaternary).clipped()
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(resource.title).font(.subheadline.weight(.medium)).lineLimit(2)
        if let name = resource.author, !name.isEmpty {
          Text(name).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
  private func load() {
    guard !ready else { return }
    do {
      if let saved = try disk.load(scope) {
        checkpoint = saved
        record = saved
        draft = saved.editor()
        cursor = saved.cursor.map {
          NSRange(location: min(max(0, $0), (draft.text as NSString).length), length: 0)
        }
        if saved.hasContent { note = "已恢复草稿" }
      }
      ready = true
    } catch { note = error.localizedDescription }
  }
  @discardableResult private func persist(clean: Bool) -> Bool {
    guard ready, !sent, !discarded else { return true }
    do {
      let s = snapshot
      if s.hasContent {
        if clean || s != checkpoint {
          try disk.save(s, scope: scope, clean: clean, checkpoint: .matches(checkpoint))
          checkpoint = s
        }
      } else if !importing && checkpoint != nil {
        try disk.discard(scope, checkpoint: .matches(checkpoint))
        checkpoint = nil
      }
      return true
    } catch {
      note = error.localizedDescription
      return false
    }
  }
  private func submit() {
    guard canPost else { return }
    TouchFeedback.light()
    let outgoing = snapshot
    if let time = outgoing.scheduled, !DynamicDraftFile.scheduling(time) {
      note = "请选择六分钟后至七天内的时间"
      return
    }
    guard persist(clean: false) else { return }
    let forwarding = origin
    let comment = outgoing.alsoComment == true ? forwarding.commentFields(outgoing.units) : nil
    if outgoing.alsoComment == true && comment == nil {
      note = "请输入评论内容，并重新载入原动态"
      return
    }
    busy = true
    note = nil
    Task {
      guard let finished = try? SleepExitFence.shared.enter() else { busy = false; return }; defer { finished() }
      defer { busy = false }
      do {
        let id = try await BiliAPI.shared.publish(
          outgoing, scope: scope, repost: repost, resource: resource, suffix: forwarding.suffix)
        sent = true
        try? disk.discard(scope, checkpoint: .matches(checkpoint))
        guard accounts.state.active == scope.owner else { return }
        var r = DynamicPostReceipt(
          serverID: id.flatMap { DynamicDraftScope.validID($0) ? $0 : nil }, uid: scope.owner,
          scheduled: outgoing.scheduled, privateOnly: outgoing.privateOnly,
          repost: scope.key != "new", verify: verify)
        if let comment {
          do {
            try await BiliAPI.shared.submit(
              "/x/v2/reply/add", comment, expectedAccount: scope.owner)
            r.comment = "评论已提交"
          } catch { r.comment = "转发已成功，评论未提交：" + error.localizedDescription }
        }
        if accounts.state.active == scope.owner { receipt = r }
      } catch { note = error.localizedDescription }
    }
  }
}
extension DynamicDraftFile.Reserve {
  var reservation: LiveReservation { .init(id: id, title: title, start: start, subtype: subtype) }
}
