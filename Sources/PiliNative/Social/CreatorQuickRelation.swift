import SwiftUI

struct CreatorQuickRelation: View {
  let mid: Int64
  var knownFollowing = false
  var keyboard:PlayerKeyTicket?=nil
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if mid > 0, let uid = accounts.state.active, uid != String(mid) {
      QuickRelationButton(mid:mid,uid:uid,knownFollowing:knownFollowing,keyboard:keyboard)
        .id(uid + ":" + String(mid))
    }
  }
}
private struct QuickRelationButton: View {
  let mid: Int64, uid: String, knownFollowing: Bool
  var keyboard:PlayerKeyTicket?=nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var relation: CreatorRelation?
  @State private var busy = false
  @State private var options = false
  @State private var group = false
  @State private var issue: String?
  private var followed: Bool { relation?.followed ?? knownFollowing }
  var body: some View {
    Group{if keyboard != nil{ Color.clear.frame(width:1,height:1).accessibilityHidden(true) }
      else if followed || relation?.attribute == 128 { relationButton.piliButtonStyle(.glass) }
      else { relationButton.piliButtonStyle(.glassProminent) }
    }.controlSize(.regular).disabled(busy)
      .task {
        if keyboard==nil && !knownFollowing { await reload(reportErrors:false) }
      }
      .task(id:keyboard?.id){
        guard let ticket=keyboard,ticket.effect == .relation,ticket.owner==uid,!Task.isCancelled else{return}
        await press()
      }
      .onReceive(NotificationCenter.default.publisher(for:PlayerKeyMemory.changed)){n in
        if keyboard==nil,n.userInfo?["creator"] as? Int64 == mid,n.userInfo?["owner"] as? String == uid{Task{await reload(reportErrors:false)}}
      }
      .confirmationDialog("关注设置", isPresented: $options, titleVisibility: .visible) {
        Button(relation?.special == 1 ? "取消特别关注" : "设为特别关注") {
          Task { await write(special: relation?.special != 1) }
        }
        Button("设置分组") { group = true }
        Button("取消关注", role: .destructive) { Task { await write(action: 2) } }
        Button("取消", role: .cancel) {}
      }
      .piliSheet(isPresented: $group, onDismiss: { Task { await reload() } }) {
        PiliNavigationStack { CreatorGroupEditor(mid: mid, uid: uid) }
      }
      .alert("关注设置", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  private var relationButton: some View {
    Button {
      guard !busy, uid == accounts.state.active else { return }
      if relation?.attribute != 128 { TouchFeedback.light() }
      Task { await press() }
    } label: {
      Text(relation?.attribute == 128 ? "移出黑名单" : followed ? "已关注" : "关注")
        .font(.subheadline.weight(.semibold)).padding(.horizontal, 4)
        .contentTransition(.opacity).animation(.snappy(duration: 0.25), value: followed)
    }
  }
  private func current() async throws -> CreatorRelation {
    let result = try await BiliAPI.shared.read(
      "/x/relation", ["fid": String(mid)],
      expectedAccount: uid, as: CreatorRelation.self)
    try Task.checkCancellation()
    guard accounts.state.active == uid else { throw CancellationError() }
    return result
  }
  private func reload(reportErrors: Bool = true) async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true
    defer { busy = false }
    issue = nil
    do { relation = try await current() } catch {
      if reportErrors, !(error is CancellationError), uid == accounts.state.active {
        issue = error.localizedDescription
      }
    }
  }
  private func press() async {
    guard !busy, uid == accounts.state.active else { return }
    // A list row only knows it was followed when the page loaded. Re-read before offering a mutation.
    if relation == nil || followed {
      await reload()
      guard relation != nil,issue==nil,uid==accounts.state.active,!Task.isCancelled else { return }
      if knownFollowing && !followed && relation?.attribute != 128 { return }
    }
    if relation?.attribute == 128 {
      await write(action: 6)
    } else if followed {
      options = true
    } else {
      await write(action: 1)
    }
  }
  private func write(action: Int? = nil, special: Bool? = nil) async {
    guard !busy,!Task.isCancelled,uid==accounts.state.active,let before=relation else { return }
    busy = true
    defer { busy = false }
    do {
      if let special, before.followed {
        try await BiliAPI.shared.submit(
          "/x/relation/tag/special/" + (special ? "add" : "del"),
          ["fid": String(mid)], expectedAccount: uid)
      } else if let action,
        (action == 1 && !before.followed && before.attribute != 128)
          || (action == 2 && before.followed) || (action == 6 && before.attribute == 128)
      {
        try await BiliAPI.shared.submit(
          "/x/relation/modify",
          ["fid": String(mid), "act": String(action), "re_src": "11"], expectedAccount: uid)
        guard uid == accounts.state.active else { return }
        if action == 6 {
          var rules = RecommendationRules.current()
          rules.blockedCreators.remove(mid)
          try rules.save()
        }
      } else {
        return
      }
      NotificationCenter.default.post(name:PlayerKeyMemory.changed,object:nil,userInfo:["creator":mid,"owner":uid]);relation=nil
      relation=try await current()
    } catch {
      if !(error is CancellationError), uid == accounts.state.active {
        issue = error.localizedDescription
      }
    }
  }
}
