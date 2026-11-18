import PiliWire

import SwiftUI

struct IMPreferences: View {
  let uid: String
  var type: PiliIM_IMSettingType = .settingTypeNeedAll
  var changed: ((Int32, PiliIM_Setting) -> Void)? = nil
  @State private var values: [Int32: PiliIM_Setting] = [:]
  @State private var title = "消息设置"
  @State private var loaded = false
  @State private var saving = false
  @State private var issue: String?
  private var api: IMGateway { BiliAPI.shared.instantMessaging(for: uid) }

  var body: some View {
    Form {
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          Button("重试") { Task { await reload() } }
        }
      }
      ForEach(values.keys.sorted(), id: \.self) { key in
        if let value = values[key] {
          if case .select = value.content {
            Section { setting(key, value).disabled(saving) }
          } else {
            setting(key, value).disabled(saving)
          }
        }
      }
    }
    .overlay {
      if !loaded && issue == nil { ProgressView() }
      else if loaded && values.isEmpty { ContentUnavailableView("暂无设置", systemImage: "gearshape") }
    }
    .navigationTitle(title).navigationBarTitleDisplayMode(.inline).task(id: type.rawValue) { await reload() }
  }
  @MainActor private func reload() async {
    guard !saving else { return }
    issue = nil
    do {
      let response = try await api.settings(type)
      try Task.checkCancellation()
      title = response.pageTitle.isEmpty ? "消息设置" : response.pageTitle
      values = response.settings
      loaded = true
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @MainActor private func save(_ key: Int32, _ value: PiliIM_Setting) async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    do {
      try await api.set(key, value)
      values[key] = value
      changed?(key, value)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
  private func label(_ title: String, _ subtitle: String, _ summary: String = "") -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).foregroundStyle(.primary)
        if !subtitle.isEmpty { Text(subtitle).piliFont(.caption).foregroundStyle(.secondary) }
      }
      if !summary.isEmpty {
        Spacer(minLength: 8)
        Text(summary).piliFont(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }
  @ViewBuilder private func setting(_ key: Int32, _ value: PiliIM_Setting) -> some View {
    switch value.content {
    case .switch(let s):
      Toggle(
        isOn: Binding(
          get: { s.switchOn },
          set: { on in
            guard on != s.switchOn else { return }
            var copy = value
            copy.switch.switchOn = on
            Task { await save(key, copy) }
          })
      ) { label(s.title, s.subtitle) }
    case .select(let s): choices(key, value, s.item, window: false)
    case .text(let s): Text(s.text)
    case .redirect(let r): redirect(key, value, r)
    case nil: EmptyView()
    }
  }
  private func summary(_ r: PiliIM_SettingRedirect) -> String {
    for key in r.settingPage.subSettings.keys.sorted() {
      guard let entry = r.settingPage.subSettings[key] else { continue }
      if let s = entry.select.item.first(where: \.selected) { return s.text }
      if entry.switch.switchOn { return entry.switch.title }
    }
    return r.selectedSummary
  }
  @ViewBuilder private func redirect(
    _ key: Int32, _ value: PiliIM_Setting, _ r: PiliIM_SettingRedirect
  ) -> some View {
    if r.settingPage.parentSettingType != .settingTypeNeedAll
      && r.settingPage.parentSettingType != type
    {
      NavigationLink {
        IMPreferences(uid: uid, type: r.settingPage.parentSettingType) { k, v in
          guard var current = values[key] else { return }
          current.redirect.settingPage.subSettings[k] = v
          values[key] = current
          changed?(key, current)
        }
      } label: {
        label(r.title, r.subtitle, summary(r))
      }
    } else if key == Int32(PiliIM_IMSettingType.settingTypeBlackList.rawValue) || r.title == "黑名单" {
      NavigationLink {
        BlacklistView(uid: uid)
      } label: {
        label(r.title, r.subtitle)
      }
    } else if key == Int32(PiliIM_IMSettingType.settingTypeKeywordBlocking.rawValue)
      || r.title == "消息屏蔽词"
    {
      NavigationLink {
        IMKeywordBlocking(uid: uid)
      } label: {
        label(r.title, r.subtitle)
      }
    } else {
      switch r.content {
      case .windowSelect(let w):
        Menu {
          choices(key, value, w.item, window: true)
        } label: {
          label(r.title, r.subtitle, summary(r))
        }
      case .popup(let p):
        NavigationLink {
          Form {
            Text(p.title).piliFont(.headline)
            Text(p.subtitle)
            if let url = httpsURL(p.url) { NavigationLink("了解更多") { SitePage(url: url) } }
          }.navigationTitle(r.title)
        } label: {
          label(r.title, r.subtitle)
        }
      case .settingPage(let p):
        if let url = httpsURL(p.url) {
          NavigationLink {
            SitePage(url: url)
          } label: {
            label(r.title, r.subtitle)
          }
        } else {
          label(r.title, r.subtitle, summary(r))
        }
      case .otherPage(let p):
        if let url = httpsURL(p.url) {
          NavigationLink {
            SitePage(url: url)
          } label: {
            label(r.title, r.subtitle)
          }
        } else {
          label(r.title, r.subtitle)
        }
      case nil: label(r.title, r.subtitle, summary(r))
      }
    }
  }
  @ViewBuilder private func choices(
    _ key: Int32, _ value: PiliIM_Setting, _ items: [PiliIM_SelectItem], window: Bool
  ) -> some View {
    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
      Button {
        guard !item.selected else { return }
        var copy = value
        var list = items
        for i in list.indices { list[i].selected = i == idx }
        if window {
          copy.redirect.windowSelect.item = list
          copy.redirect.selectedSummary = item.text
        } else {
          copy.select.item = list
        }
        Task { await save(key, copy) }
      } label: {
        HStack {
          Text(item.text).foregroundStyle(.primary)
          Spacer()
          if item.selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
        }
      }
    }
  }
}
struct IMKeywordBlocking: View {
  let uid: String
  @State private var state: PiliIM_KeywordBlockingListReply?
  @State private var draft = ""
  @State private var busy = false
  @State private var issue: String?
  @State private var removal: String?
  private var api: IMGateway { BiliAPI.shared.instantMessaging(for: uid) }
  private var term: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var addProblem: String? {
    guard let state else { return "请先载入屏蔽词" }
    if term.isEmpty { return "请输入关键词" }
    if state.items.contains(where: { $0.keyword == term }) { return "这个词已被屏蔽" }
    if state.listLimit > 0 && state.items.count >= Int(state.listLimit) {
      return state.listLimitText.isEmpty ? "已达到屏蔽词数量上限" : state.listLimitText
    }
    if state.charLimit > 0 && term.count > Int(state.charLimit) {
      return "每个屏蔽词最多 \(state.charLimit) 个字"
    }
    return nil
  }
  var body: some View {
    Form {
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          Button("重新载入") { Task { await reload() } }.disabled(busy)
        }
      }
      if let state {
        Section {
          HStack {
            TextField("输入要屏蔽的词", text: $draft).onSubmit { Task { await change(term, add: true) } }
            Button("添加") { Task { await change(term, add: true) } }
              .piliButtonStyle(.glassProminent).controlSize(.small)
              .disabled(busy || addProblem != nil)
          }
        } footer: {
          if !term.isEmpty, let reason = addProblem {
            Text(reason).foregroundStyle(.red)
          } else if !state.listLimitText.isEmpty {
            Text(state.listLimitText)
          }
        }
        Section {
          if state.items.isEmpty { Text("暂无屏蔽词").foregroundStyle(.secondary) }
          ForEach(state.items.map(\.keyword), id: \.self) { word in
            HStack {
              Text(word)
              Spacer()
              Button { removal = word } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("删除 " + word)
            }
            .swipeActions { Button("删除", role: .destructive) { removal = word } }
          }
        } header: {
          HStack {
            Text("已屏蔽")
            Spacer()
            if state.listLimit > 0 { Text("\(state.items.count)/\(state.listLimit)").monospacedDigit() }
          }
        }
      }
    }
    .overlay { if busy && state == nil { ProgressView() } }
    .navigationTitle("消息屏蔽词").navigationBarTitleDisplayMode(.inline).task(id: uid) { await reload() }
      .confirmationDialog(
        "删除这个屏蔽词？",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        presenting: removal
      ) { word in Button("删除", role: .destructive) { Task { await change(word, add: false) } } }
  }
  @MainActor private func reload() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await api.keywords()
      try Task.checkCancellation()
      state = result
      issue = nil
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @MainActor private func change(_ word: String, add: Bool) async {
    guard !busy, !word.isEmpty, !add || addProblem == nil else { return }
    busy = true
    defer { busy = false }
    do {
      try await api.keyword(word, add: add)
      if add { draft = "" }
      state = nil
      state = try await api.keywords()
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
