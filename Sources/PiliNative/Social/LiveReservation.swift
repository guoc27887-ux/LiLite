import SwiftUI

struct LiveReservation: Identifiable {
  let id: Int64, title: String, start: Date, subtype: Int
}
extension BiliAPI {
  func reservation(_ id: Int64, uid: String, subtype: Int) async throws -> LiveReservation {
    struct Info: Decodable {
      let id: Int64, title: String, live_plan_start_time: Int64, sub_type: Int?
    }
    let r = try await read(
      "/x/new-reserve/up/reserve/info",
      ["from": "1", "id": String(id), "web_location": "333.1365"], expectedAccount: uid,
      as: Info.self)
    guard r.id == id else { throw ServiceError("预约编号不匹配") }
    return .init(
      id: r.id, title: r.title, start: Date(timeIntervalSince1970: Double(r.live_plan_start_time)),
      subtype: r.sub_type ?? subtype)
  }
  func saveReservation(_ id: Int64?, uid: String, title: String, start: Date, subtype: Int)
    async throws -> LiveReservation
  {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let interval = start.timeIntervalSinceNow
    guard !name.isEmpty, name.count <= 14, [0, 1].contains(subtype), interval >= 300,
      interval <= 90 * 86400
    else { throw ServiceError("请输入有效的预约标题和时间") }
    var f = [
      "type": "2", "sub_type": String(subtype), "from": "1", "title": name,
      "live_plan_start_time": String(Int64(start.timeIntervalSince1970)),
    ]
    if let id { f["id"] = String(id) }
    let data = try await submitResponse(
      "/x/new-reserve/up/reserve/" + (id == nil ? "create" : "update"), f, expectedAccount: uid)
    struct Envelope: Decodable {
      struct Info: Decodable { let sid: Int64? }
      let data: Info?
    }
    let receipt = try JSONDecoder().decode(Envelope.self, from: data).data?.sid
    if receipt == nil, let id {
      let confirmed = try await reservation(id, uid: uid, subtype: subtype)
      guard confirmed.title == name, abs(confirmed.start.timeIntervalSince(start)) < 1,
        confirmed.subtype == subtype
      else { throw ServiceError("预约已提交，请重新读取以确认状态") }
      return confirmed
    }
    guard let sid = receipt, sid > 0 else { throw ServiceError("预约服务没有返回编号") }
    if let id, sid != id { throw ServiceError("预约服务返回了不同的编号") }
    return .init(id: sid, title: name, start: start, subtype: subtype)
  }
}
struct ReservationEditor: View {
  let uid: String, original: LiveReservation?, select: (LiveReservation) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var title = ""
  @State private var subtype = 0
  @State private var date: Date =
    Calendar.current.date(
      bySettingHour: 20, minute: 0, second: 0,
      of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    ?? Date().addingTimeInterval(86400)
  @State private var busy = false
  @State private var ready = false
  @State private var issue: String?
  @State private var attempt = 0
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        row("类型") {
          Menu {
            Picker("类型", selection: $subtype) {
              Text("公开直播").tag(0)
              Text("大航海直播").tag(1)
            }
          } label: {
            HStack(spacing: 4) {
              Text(subtype == 0 ? "公开直播" : "大航海直播")
              Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }.foregroundStyle(.primary)
          }
          Spacer(minLength: 0)
        }
        Divider()
        row("时间") {
          DatePicker(
            "开播时间", selection: $date, in: Date().addingTimeInterval(300)...Date().addingTimeInterval(90 * 86400),
            displayedComponents: [.date, .hourAndMinute]).labelsHidden()
          Spacer(minLength: 0)
        }
        Divider()
        row("标题") {
          TextField("请填写标题，最多 14 字", text: Binding(get: { title }, set: { title = String($0.prefix(14)) }))
          Text("\(title.count)/14").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        Divider()
        Button { Task { await save() } } label: {
          HStack {
            if busy { ProgressView() }
            Text(original == nil ? "添加预约" : "保存预约")
          }
          .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .piliButtonStyle(.glassProminent).controlSize(.large)
        .disabled(
          busy || !ready || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || title.count > 14 || date.timeIntervalSinceNow < 300)
        .padding(.top, 36)
        if let issue {
          VStack(alignment: .leading, spacing: 8) {
            Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
            if !ready { Button("重试") { attempt += 1 } }
          }
          .padding(.top, 16)
        }
      }
      .padding(.horizontal, 16).padding(.top, 8)
    }
    .navigationTitle(original == nil ? "添加直播预约" : "编辑直播预约").navigationBarTitleDisplayMode(.inline)
    .onChange(of: accounts.state.active) { _, active in
      if active != uid { dismiss() }
    }.task(id: attempt) {
      guard let original else {
        ready = true
        return
      }
      do {
        let r = try await BiliAPI.shared.reservation(
          original.id, uid: uid, subtype: original.subtype)
        try Task.checkCancellation()
        title = r.title
        subtype = r.subtype
        date = r.start
        ready = true
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 12) {
      Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
      content()
    }
    .frame(minHeight: 52)
  }
  @MainActor private func save() async {
    guard !busy, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      let r = try await BiliAPI.shared.saveReservation(
        original?.id, uid: uid, title: title, start: date, subtype: subtype)
      guard accounts.state.active == uid else { return }
      select(r)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
