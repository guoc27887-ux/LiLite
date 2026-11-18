import PiliWire

import SwiftUI

struct IMShareButton: View {
  let card: IMShareCard
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active {
      NavigationLink {
        IMShareSheet(card: card, uid: uid)
      } label: {
        Label("分享至私信", systemImage: "paperplane")
      }
    }
  }
}
struct IMCardPreview: View {
  let card: IMShareCard
  var body: some View {
    MediaRow(cover: card.thumb, title: card.title, badge: card.kind.label,
      subtitle: card.author, thumbWidth: 112)
  }
}
struct IMShareSheet: View {
  let payload: IMForwardContent, uid: String
  var verify: (() async throws -> IMForwardContent)? = nil
  init(card: IMShareCard, uid: String) {
    payload = .card(card)
    self.uid = uid
  }
  init(
    content: IMForwardContent, uid: String, verify: @escaping () async throws -> IMForwardContent
  ) {
    payload = content
    self.uid = uid
    self.verify = verify
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var people: [Creator] = []
  @State private var selected = Set<Int64>()
  @State private var sentCard = Set<Int64>()
  @State private var done = Set<Int64>()
  @State private var picker = false
  @State private var busy = false
  @State private var started = false
  @State private var note = ""
  @State private var recentIssue: String?
  @State private var failures: [Int64: String] = [:]
  func add(_ p: Creator, select: Bool) {
    guard p.mid > 0, String(p.mid) != uid else { return }
    if !people.contains(where: { $0.mid == p.mid }) { people.append(p) }
    if select { selected.insert(p.mid) }
  }
  var body: some View {
    Form {
      Section {
        switch payload {
        case .card(let c): IMCardPreview(card: c)
        case .text(let t): Text(t).lineLimit(5)
        case .photo(let p):
          SiteThumbnail(url: p.url) {
            $0.resizable().scaledToFit()
          } placeholder: {
            Color.clear
          }.frame(maxHeight: 160)
        }
      }
      Section("收件人") {
        ForEach(people) { p in
          Button {
            if selected.contains(p.mid) { selected.remove(p.mid) } else { selected.insert(p.mid) }
          } label: {
            HStack(spacing: 12) {
              ProfileAvatar(url: p.face.flatMap(httpsURL), size: 36)
              Text(p.uname ?? String(p.mid)).foregroundStyle(.primary)
              Spacer()
              if done.contains(p.mid) {
                Label("已发送", systemImage: "checkmark").font(.footnote).foregroundStyle(.green)
              } else {
                Image(systemName: selected.contains(p.mid) ? "checkmark.circle.fill" : "circle")
                  .font(.title3).foregroundStyle(selected.contains(p.mid) ? Color.accentColor : Color.secondary)
              }
            }
            .contentShape(Rectangle())
          }.disabled(started)
          if let failure = failures[p.mid] {
            Text(failure).foregroundStyle(.secondary).font(.footnote)
          }
        }
        if let recentIssue { Text(recentIssue).font(.footnote).foregroundStyle(.secondary) }
        Button { picker = true } label: {
          Label("从通讯录添加", systemImage: "person.crop.circle.badge.plus")
        }.disabled(started)
      }
      Section("附言") {
        TextField("说点什么（可选）", text: $note, axis: .vertical).lineLimit(1...4).disabled(started).onChange(of: note) {
          _, s in if s.count > 100 { note = String(s.prefix(100)) }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      Group {
        if !selected.isEmpty, done == selected {
          Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity).padding(.vertical, 4) }
        } else {
          Button { Task { await send() } } label: {
            HStack {
              if busy { ProgressView().tint(.white) }
              Text(busy ? "发送中" : started ? "重试未完成的发送" : selected.isEmpty ? "选择收件人" : "发送给 \(selected.count) 人")
            }
            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4)
          }
          .disabled(selected.isEmpty || busy || accounts.state.active != uid)
        }
      }
      .piliButtonStyle(.glassProminent).controlSize(.large)
      .padding(.horizontal, 20).padding(.bottom, 8)
    }
    .navigationTitle("分享至私信").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(busy)
      .piliSheet(isPresented: $picker) {
        PiliNavigationStack {
          IMContactBook(uid: uid) { p in add(p, select: true) }.toolbar {
            Button("完成") { picker = false }
          }
        }
      }
      .onChange(of: accounts.state.active) { _, u in if u != uid { dismiss() } }
      .task {
        do {
          let recent = try await BiliAPI.shared.instantMessaging(for: uid).shareContacts()
          try Task.checkCancellation()
          guard accounts.state.active == uid else { return }
          for p in recent {
            add(
              .init(mid: p.talkerID, uname: p.talkerUname, face: p.talkerIcon, sign: nil),
              select: false)
          }
        } catch { if !Task.isCancelled { recentIssue = "可从通讯录选择收件人" } }
      }
  }
  @MainActor private func send() async {
    guard !busy, !selected.isEmpty, accounts.state.active == uid else { return }
    busy = true
    started = true
    defer { busy = false }
    let content: IMForwardContent
    do { if let verify { content = try await verify() } else { content = payload } } catch {
      for id in selected where !done.contains(id) { failures[id] = error.localizedDescription }
      return
    }
    let message = note.trimmingCharacters(in: .whitespacesAndNewlines)
    for p in people where selected.contains(p.mid) && !done.contains(p.mid) {
      guard accounts.state.active == uid, !Task.isCancelled else { return }
      failures[p.mid] = nil
      do {
        if !sentCard.contains(p.mid) {
          switch content {
          case .card(let c):
            try await BiliAPI.shared.sendDirect(
              to: p.mid, text: nil, image: nil, share: c, expectedUser: uid)
          case .text(let t):
            try await BiliAPI.shared.sendDirect(to: p.mid, text: t, image: nil, expectedUser: uid)
          case .photo(let i):
            try await BiliAPI.shared.sendDirect(
              to: p.mid, text: nil, image: nil, forwardPhoto: i, expectedUser: uid)
          }
          sentCard.insert(p.mid)
        }
        if !message.isEmpty {
          try await BiliAPI.shared.sendDirect(
            to: p.mid, text: message, image: nil, expectedUser: uid)
        }
        done.insert(p.mid)
      } catch {
        failures[p.mid] =
          (sentCard.contains(p.mid) ? "内容已发送，附言未确认" : "发送未确认") + "：" + error.localizedDescription
      }
    }
  }
}
