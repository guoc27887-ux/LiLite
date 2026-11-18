import PhotosUI
import SwiftUI

struct NativeNotebook: View {
  let oid: Int64, owner: String
  var suppliedTitle: String? = nil, interactive = false, model: PlayerModel? = nil,
    cid: Int64? = nil, requested: Int64? = nil, startLocal = false
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  @State private var draft: NotebookDraft?
  @State private var checkpoint: NotebookDraft?
  @State private var pristine: NotebookDraft?
  @State private var receipt: String?
  @State private var note: Int64?
  @State private var ids = [Int64]()
  @State private var remote: NotebookRemote?
  @State private var granted = false
  @State private var busy = false
  @State private var ready = false
  @State private var pick: PhotosPickerItem?
  @State private var frame = false
  @State private var route: IncomingRoute?
  @State private var retryUncertain = false
  @State private var merge = false
  @State private var original = false
  @State private var alsoComment = false
  @State private var publishing = false
  @State private var replacing = false
  @State private var message: String?
  @State private var issue: String?
  @State private var refresh = 0
  @State private var part: Video.Part?
  @State private var totalParts = 0
  private var disk: NotebookDisk? { try? NotebookDisk(owner: owner, oid: oid, note: note) }
  private var editing: Bool {
    ready && !busy && remote?.locked != true && accounts.state.active == owner
  }
  private var canSend: Bool {
    editing && granted && draft?.uncertain != true && !(draft?.blocks.isEmpty ?? true)
  }
  private var activePlayback: Bool {
    guard let m = model, let cid, cid > 0 else { return false }
    return m.timeline.source?.aid == oid && m.timeline.source?.cid == cid && m.ready && !m.isPreview
  }
  var body: some View {
    Form {
      if !ready && issue == nil { ProgressView().frame(maxWidth: .infinity) }
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
          Button("重新读取云端") { refresh += 1 }
          if !ready && requested == nil && accounts.state.active == owner {
            Button("先写本机草稿") { beginLocal() }
          }
        }
      }
      if receipt != nil || message != nil {
        Section {
          if let receipt { Label(receipt, systemImage: "checkmark.circle").foregroundStyle(.green) }
          if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
      }
      if let remote, remote.locked {
        Section {
          Label(
            remote.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "笔记正在审核或已锁定", systemImage: "lock")
        }
      }
      if let value = Binding($draft) {
        Section {
          TextField("笔记标题", text: value.title).font(.headline).disabled(!editing)
          ForEach(value.blocks) { $block in
            NotebookBlockEditor(
              block: $block, owner: owner, disk: disk, editable: editing,
              onSeek: { stamp in
                if activePlayback, stamp.cid == cid {
                  model?.seek(Double(stamp.time))
                } else {
                  route = .init(
                    link: .positioned(
                      .archivePart(.archive(oid, nil), stamp.cid), Double(stamp.time)))
                }
              })
          }.onDelete { indices in
            guard editing else { return }
            draft?.blocks.remove(atOffsets: indices)
          }.onMove { from, to in
            guard editing else { return }
            draft?.blocks.move(fromOffsets: from, toOffset: to)
          }
        }
        if editableRemote {
          Section {
            HStack(spacing: 10) {
              Button { Task { await send(publish: false) } } label: {
                Label("保存到云笔记", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity)
              }
              .piliButtonStyle(.glass).disabled(!canSend)
              Button { publishing = true } label: {
                Label("公开笔记", systemImage: "globe").frame(maxWidth: .infinity)
              }
              .piliButtonStyle(.glassProminent).disabled(!canSend)
            }
            .font(.subheadline.weight(.semibold)).controlSize(.large)
            .listRowBackground(Color.clear).listRowInsets(.init())
          }
        }
        if note == nil && !ids.isEmpty && checkpoint != nil && draft?.uncertain != true {
          Button("把本机草稿追加到云笔记") { merge = true }
        }
        if draft?.uncertain == true && ready && accounts.state.active == owner {
          Button("核对云端并允许重试") { retryUncertain = true }.disabled(busy)
        }
        if checkpoint != nil {
          Button("舍弃本机草稿并重新读取", role: .destructive) { replacing = true }.disabled(busy)
        }
      }
      if ids.count > 1 {
        Section("这个视频的笔记") {
          ForEach(ids, id: \.self) { id in
            Button(id == note ? "当前笔记 \(id)" : "笔记 \(id)") {
              guard id != note, !busy, persist() else { return }
              note = id
              refresh += 1
            }
          }
        }
      }
      Section {
        NavigationLink {
          SitePage(url: NoteEditorBridge.url(oid: oid, interactive: interactive), noteOID: oid)
        } label: {
          SettingsRowLabel(title: "使用官方编辑器", symbol: "safari", color: .blue)
        }
      }
    }.navigationTitle("记笔记").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if editing {
          ToolbarItem(placement: .primaryAction) { EditButton() }
          ToolbarItemGroup(placement: .bottomBar) {
            Button { draft?.blocks.append(.init()) } label: { Label("添加文字", systemImage: "text.append") }
            PhotosPicker(selection: $pick, matching: .images) { Label("从照片添加", systemImage: "photo") }
            if activePlayback, part != nil {
              Button { addTime() } label: { Label("插入当前时间", systemImage: "clock") }
            }
            if activePlayback {
              Button { frame = true } label: { Label("插入当前画面", systemImage: "camera") }
            }
          }
        }
      }
      .task(id: refresh) { await load() }
      .task(id: cid) { await loadPart() }
      .task(id: pick) {
        guard let item = pick else { return }
        do {
          guard let data = try await item.loadTransferable(type: Data.self),
            let img = NotebookImage.decoded(data, max: 1800),
            let bytes = img.jpegData(compressionQuality: 0.85)
          else { throw ServiceError("无法读取照片") }
          try addImage(bytes, frame: false)
        } catch { issue = error.localizedDescription }
        pick = nil
      }
      .piliSheet(isPresented: $frame) {
        if let model {
          NotebookFrame(model: model, allowed: { activePlayback }) { bytes in
            do {
              try addImage(bytes, frame: true)
              frame = false
            } catch { issue = error.localizedDescription }
          }
        }
      }
      .piliSheet(isPresented: $publishing) {
        PiliNavigationStack {
          Form {
            Section("公开设置") {
              Toggle("原创笔记", isOn: $original)
              Toggle("同时发布视频评论", isOn: $alsoComment).disabled((remote?.status ?? 0) != 0)
            }
            Section("发布须知") {
              ForEach([(2, "专栏内容上传协议"), (1, "专栏规范"), (3, "专栏原创声明")], id: \.0) { n, title in
                if let u = URL(
                  string: "https://www.bilibili.com/blackboard/fe/article_specification_\(n).html")
                {
                  NavigationLink(title) { SitePage(url: u) }
                }
              }
            }
            Button("提交公开笔记") {
              publishing = false
              Task { await send(publish: true) }
            }
          }.navigationTitle("公开笔记").toolbar { Button("取消") { publishing = false } }
        }
      }
      .piliSheet(item: $route) { r in
        PiliNavigationStack {
          LinkDestination(item: r.link).toolbar { Button("关闭") { route = nil } }
        }
      }
      .confirmationDialog("把这份本机草稿追加到已有笔记？", isPresented: $merge) {
        ForEach(ids, id: \.self) { id in
          Button("追加到笔记 \(id)") { Task { await appendLocal(to: id) } }
        }
      }
      .confirmationDialog("如果云端仍是提交前的版本，保留本机内容并允许再次提交？", isPresented: $retryUncertain) {
        Button("检查云端") { Task { await unlockRetry() } }
      }
      .confirmationDialog("舍弃本机修改？", isPresented: $replacing) {
        Button("舍弃并重新读取", role: .destructive) {
          do {
            try disk?.discard(checkpoint)
            checkpoint = nil
            draft = nil
            refresh += 1
          } catch { issue = error.localizedDescription }
        }
      }
      .onChange(of: draft) { _, _ in if ready && !busy { _ = persist() } }
      .onReceive(NotificationCenter.default.publisher(for: SleepAppExit.checkpoint)) { _ in _ = persist() }
      .onChange(of: phase) { _, v in if v != .active { _ = persist() } }
      .onDisappear { _ = persist() }
      .onChange(of: accounts.state.active) { _, v in
        if v != owner {
          _ = persist()
          dismiss()
        }
      }
      .interactiveDismissDisabled(busy)
  }
  private var editableRemote: Bool {
    granted && remote?.locked != true && accounts.state.active == owner
  }
  private func addImage(_ bytes: Data, frame: Bool) throws {
    guard editing, let disk, !frame || activePlayback else { throw ServiceError("此视频当前无法截取画面") }
    let id = try disk.stage(bytes)
    var b = NotebookBlock()
    b.localPicture = id
    b.videoFrame = frame
    draft?.blocks.append(b)
  }
  private func loadPart() async {
    guard let source = model?.timeline.source, source.aid == oid, source.cid == cid,
      let bv = source.bvid
    else { return }
    do {
      let video = try await BiliAPI.shared.detail(bv)
      try Task.checkCancellation()
      if let list = video.pages, let p = list.first(where: { $0.cid == cid }) {
        part = p
        totalParts = list.count
      } else if video.cid == cid, let cid {
        part = .init(cid: cid, page: 1, part: video.title)
        totalParts = 1
      }
    } catch {}
  }
  private func addTime() {
    guard activePlayback, let m = model, let p = part, p.cid == cid, m.seconds.isFinite,
      m.seconds >= 0, m.seconds < Double(Int32.max)
    else { return }
    do {
      draft?.blocks.append(
        try .timestamp(
          cid: p.cid, index: p.page, count: totalParts, seconds: Int(m.seconds), title: p.part))
    } catch { issue = error.localizedDescription }
  }
  @discardableResult private func persist() -> Bool {
    guard ready, let draft, let disk, draft != checkpoint, checkpoint != nil || draft != pristine,
      remote?.locked != true
    else { return true }
    do {
      try disk.save(draft, matching: checkpoint)
      checkpoint = draft
      return true
    } catch {
      issue = error.localizedDescription
      return false
    }
  }
  @MainActor private func load() async {
    guard !busy, accounts.state.active == owner else { return }
    ready = false
    granted = false
    issue = nil
    message = nil
    do {
      let verified = try await BiliAPI.shared.notebookIDs(oid: oid, owner: owner)
      try Task.checkCancellation()
      let originalLocal = try NotebookDisk(owner: owner, oid: oid, note: nil).load()
      let desired = note ?? requested ?? (startLocal && originalLocal != nil ? nil : verified.first)
      if let id = desired, !verified.contains(id) { throw ServiceError("此笔记不在当前账号的视频笔记列表中") }
      let latest: NotebookRemote?
      if let id = desired {
        latest = try await BiliAPI.shared.notebookInfo(oid: oid, id: id, owner: owner)
      } else {
        latest = nil
      }
      try Task.checkCancellation()
      guard accounts.state.active == owner else { return }
      let storage = try NotebookDisk(owner: owner, oid: oid, note: desired)
      let own = try storage.load()
      let stranded =
        desired != nil && checkpoint == nil
        ? try NotebookDisk(owner: owner, oid: oid, note: nil).load() : nil
      if let stranded, stranded.uncertain, own == nil {
        let storage = try NotebookDisk(owner: owner, oid: oid, note: nil)
        if let latest, stranded.sameContent(as: latest) {
          try storage.discard(stranded)
          receipt = "已从云端核对笔记正文"
        } else {
          note = nil
          ids = verified
          remote = nil
          draft = stranded
          checkpoint = stranded
          ready = true
          issue = "之前的提交结果待核对；视频已有云端笔记"
          return
        }
      }
      note = desired
      ids = verified
      remote = latest
      checkpoint = own
      pristine = nil
      let base = latest?.base
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      if let own {
        draft = own
        if own.uncertain, let latest, own.sameContent(as: latest) {
          var matched = own
          matched.base = latest.base
          matched.uncertain = false
          matched.hash = Int64(Date().timeIntervalSince1970 * 1000)
          try storage.save(matched, matching: own)
          checkpoint = matched
          draft = matched
          granted = true
          receipt = "已从云端核对笔记正文"
        } else if own.uncertain || own.base != base {
          issue = "云端与本机状态需要核对，可以打开官方编辑器查看"
          granted = false
        } else {
          granted = desired != nil || verified.isEmpty
        }
      } else {
        let name = latest?.title.isEmpty == false ? latest!.title : (suppliedTitle ?? "视频笔记")
        draft = NotebookDraft(
          title: String(name.prefix(40)), blocks: latest?.blocks ?? [.init()], base: base, hash: now
        )
        pristine = draft
        granted = true
      }
      ready = true
    } catch {
      if !Task.isCancelled, accounts.state.active == owner {
        issue = error.localizedDescription
        if let initial = requested { note = initial }
        if let saved = try? disk?.load() {
          draft = saved
          checkpoint = saved
          ready = true
        }
      }
    }
  }
  @MainActor private func beginLocal() {
    guard accounts.state.active == owner else { return }
    note = nil
    do {
      guard let disk else { return }
      let existing = try disk.load()
      draft =
        existing
        ?? NotebookDraft(
          title: String((suppliedTitle ?? "视频笔记").prefix(40)), blocks: [.init()], base: nil,
          hash: Int64(Date().timeIntervalSince1970 * 1000))
      checkpoint = existing
      pristine = existing == nil ? draft : nil
      ready = true
      granted = false
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func appendLocal(to id: Int64) async {
    guard note == nil, !busy, accounts.state.active == owner, var old = draft, let source = disk,
      persist()
    else { return }
    busy = true
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      guard try await api.notebookIDs(oid: oid, owner: owner).contains(id) else {
        throw ServiceError("云端笔记未找到")
      }
      let other = try await api.notebookInfo(oid: oid, id: id, owner: owner)
      guard !other.locked, accounts.state.active == owner else { throw ServiceError("当前无法编辑云端笔记") }
      let destination = try NotebookDisk(owner: owner, oid: oid, note: id)
      guard try destination.load() == nil else { throw ServiceError("云笔记还有其他本机修改，请先处理") }
      for i in old.blocks.indices {
        if let picture = old.blocks[i].localPicture {
          old.blocks[i].localPicture = try destination.stage(
            Data(contentsOf: source.pic(picture), options: .mappedIfSafe))
        }
      }
      old.blocks = other.blocks + [.init(text: "\n")] + old.blocks
      old.base = other.base
      old.uncertain = false
      try destination.save(old, matching: nil)
      try source.discard(checkpoint)
      note = id
      remote = other
      checkpoint = old
      draft = old
      pristine = nil
      granted = true
      message = "已追加到本机草稿，保存后才会更新云端"
      issue = nil
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func unlockRetry() async {
    guard !busy, var value = draft, value.uncertain, let disk, accounts.state.active == owner else {
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.notebookValidate(
        oid: oid, note: note, base: value.base, owner: owner)
      guard accounts.state.active == owner else { return }
      value.uncertain = false
      try disk.save(value, matching: checkpoint)
      checkpoint = value
      draft = value
      granted = true
      issue = nil
      message = "云端仍是原版本，可以重新提交"
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func send(publish: Bool) async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard canSend, let disk, var value = draft, persist() else { return }
    busy = true
    defer { busy = false }
    issue = nil
    message = nil
    do {
      let api = BiliAPI.shared
      try await api.notebookValidate(oid: oid, note: note, base: value.base, owner: owner)
      // Validate before uploading any selected picture.
      var preview = value
      for i in preview.blocks.indices where preview.blocks[i].localPicture != nil {
        preview.blocks[i] = try preview.blocks[i].uploaded(
          "https://api.bilibili.com/x/note/image?preview=1")
      }
      _ = try preview.form(
        oid: oid, note: note, publish: publish, original: original,
        comment: alsoComment && (remote?.status ?? 0) == 0)
      for i in value.blocks.indices {
        if let id = value.blocks[i].localPicture {
          let data = try Data(contentsOf: disk.pic(id), options: .mappedIfSafe)
          let location = try await api.notebookUpload(data, owner: owner)
          value.blocks[i] = try value.blocks[i].uploaded(location)
          try disk.save(value, matching: checkpoint)
          checkpoint = value
          draft = value
        }
      }
      let fields = try value.form(
        oid: oid, note: note, publish: publish, original: original,
        comment: alsoComment && (remote?.status ?? 0) == 0)
      try await api.notebookValidate(oid: oid, note: note, base: value.base, owner: owner)
      guard accounts.state.active == owner else { throw ServiceError("账号已切换") }
      value.uncertain = true
      try disk.save(value, matching: checkpoint)
      checkpoint = value
      draft = value
      let result = try await api.notebookSubmit(fields, owner: owner, known: note)
      try disk.discard(checkpoint)
      guard accounts.state.active == owner else { return }
      ready = false
      draft = nil
      checkpoint = nil
      note = result
      refresh += 1
      receipt = publish ? "已提交公开审核" : "已保存到云笔记"
    } catch let rejection as NotebookRejected {
      if rejection.code != 79508 && accounts.state.active == owner {
        value.uncertain = false
        do {
          try disk.save(value, matching: checkpoint)
          checkpoint = value
          draft = value
        } catch {
          issue = error.localizedDescription
          return
        }
      }
      if accounts.state.active == owner { issue = rejection.localizedDescription }
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}
