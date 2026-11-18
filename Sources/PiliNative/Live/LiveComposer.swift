import SwiftUI

extension BiliAPI {
  func liveEmoteGroups(_ room:Int64,owner:String) async throws -> [LiveEmoteChoices.Group] {
    try await read("/xlive/web-ucenter/v2/emoticon/GetEmoticons", ["platform":"pc","room_id":String(room)],
      host:"api.live.bilibili.com",expectedAccount:owner,as:LiveEmoteChoices.self).groups
  }
  func sendLive(_ text: String, room: Int64, emoji: Bool, reply: LiveReplyTarget?, owner: String)
    async throws -> String?
  {
    guard let user = try await AccountJar.shared.current(), let csrf = user.csrf else {
      throw ServiceError("请先登录")
    }
    guard room > 0, user.id == owner else { throw ServiceError("账号已切换") }
    var c = URLComponents(string: "https://api.live.bilibili.com/msg/send")!
    c.queryItems = try await sign(["web_location": "444.8"]).map(URLQueryItem.init)
    let boundary = UUID().uuidString
    var req = URLRequest(url: c.url!)
    req.httpMethod = "POST"
    req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
    req.setValue("https://live.bilibili.com/\(room)", forHTTPHeaderField: "Referer")
    req.setValue(user.header, forHTTPHeaderField: "Cookie")
    var values = [
      "bubble": "0", "msg": text, "color": "16777215", "mode": "1", "fontsize": "25",
      "rnd": "\(Int(Date().timeIntervalSince1970))", "roomid": "\(room)", "csrf": csrf,
      "csrf_token": csrf,
    ]
    if emoji {
      values["dm_type"] = "1"
      values["emoticonOptions"] = "[object Object]"
    } else {
      values.merge([
        "room_type": "0", "jumpfrom": "0", "reply_mid": "0", "reply_attr": "0", "replay_dmid": "",
        "reply_type": "0", "reply_uname": "", "statistics": "{\"appId\":100,\"platform\":5}",
      ]) { $1 }
      if let reply {
        guard let fields = reply.fields(room: room, account: owner) else {
          throw ServiceError("回复对象已变更")
        }
        values.merge(fields) { $1 }
      }
    }
    var form = Data()
    for (k, v) in values {
      form.append(
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
    }
    form.append(Data("--\(boundary)--\r\n".utf8))
    req.httpBody = form
    guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
    let (bytes, response) = try await webResponse(req, identity: user)
    struct Result: Decodable { let code: Int, message: String?, msg: String? }
    let result = try JSONDecoder().decode(Result.self, from: bytes)
    let issue = [result.message, result.msg].compactMap { $0 }.first { !$0.isEmpty }
    guard (response as? HTTPURLResponse)?.statusCode == 200, result.code == 0 else {
      throw ServiceError(issue ?? "弹幕发送失败")
    }
    return issue.flatMap{ ["0","ok","success","发送成功"].contains($0.lowercased()) ? nil:$0 }
  }
}
struct LiveComposer: View {
  let room: Int64
  @Binding var reply: LiveReplyTarget?
  var focusOnEntry=false
  @State private var focusCount=0
  @State private var selection:NSRange?
  @State private var inserted=[String:LiveEmoji]()
  @EnvironmentObject var accounts: AccountContext
  @State private var text = ""
  @State private var busy = false
  @State private var emotes = false
  @State private var chosen: LiveEmoji?
  @State private var error: String?
  @State private var receipt:String?
  var body: some View {
    Group { composer }.onChange(of: "\(room):\(accounts.state.active ?? "")") { _, _ in
      reply=nil;text="";selection=nil;inserted=[:];chosen=nil;emotes=false;error=nil;receipt=nil
    }
  }
  @ViewBuilder private var composer:some View {
    if accounts.state.active == nil {
      NavigationLink("登录后发送弹幕") { QRLoginView() }.padding(.horizontal)
    } else {
      if let reply {
        HStack {
          Label("回复 @" + reply.name, systemImage: "arrowshape.turn.up.left").foregroundStyle(.secondary)
          Spacer()
          Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            .buttonStyle(.plain).accessibilityLabel("取消回复")
        }.piliFont(.caption).padding(.horizontal, 20)
      }
      if let receipt { Text(receipt).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
      let icons=inserted.keys.sorted().filter{text.contains($0)}
      if !icons.isEmpty {ScrollView(.horizontal) {HStack {ForEach(icons,id:\.self){key in
        if let icon=inserted[key]?.url.flatMap(GalleryPicture.source){
          RemoteArtwork(url:icon){$0.resizable().scaledToFit()} placeholder:{Color.clear}
            .frame(width:26,height:26).accessibilityLabel(key)
        }
      }}.padding(.horizontal)}}
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          if let chosen {
            Button { self.chosen = nil } label: {
              HStack(spacing: 4) {
                Text(chosen.emoji ?? "表情")
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
              }
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
          } else {
            LiveDraftField(text:$text,selection:$selection,focusCount:focusCount,submit:{submitDraft()}).frame(height:36)
          }
          Button {
            emotes = true
          } label: {
            Image(systemName: "face.smiling").font(.title3).foregroundStyle(.secondary)
          }.buttonStyle(.plain).accessibilityLabel("选择表情")
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        Button { submitDraft() } label: {
          if busy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
        }
        .piliButtonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
        .accessibilityLabel("发送")
        .disabled(chosen == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.onAppear{if focusOnEntry{focusCount += 1}}.onChange(of: reply) { _, target in
        if target != nil {
          chosen = nil
          focusCount += 1
        }
      }.disabled(busy).padding(.horizontal).padding(.vertical, 4)
        .piliSheet(isPresented: $emotes) {
          PiliNavigationStack {
            if let owner=accounts.state.active {
              LiveEmotePicker(room:room,owner:owner){e,asText in
                guard owner == accounts.state.active,e.available else{return};emotes=false
                if asText,let token=e.emoji {
                  let next=LiveEmoteChoices.insert(token,in:text,selection:selection);chosen=nil
                  inserted[token]=e;text=next.0;selection=next.1;focusCount += 1
                } else if e.emoticon_unique != nil {
                  chosen=e;submitDraft(instant:e)
                }
              }
            }
          }
        }.alert(
          "弹幕发送失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
          Button("好") {}
        } message: {
          Text(error ?? "")
        }
    }
  }
  private func submitDraft(instant:LiveEmoji? = nil) {
    guard !busy, let owner = accounts.state.active else { return }
    let emote=instant ?? chosen
    let body=emote?.emoticon_unique ?? text
    let emoji=emote != nil
    guard emoji || !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
    if !emoji { TouchFeedback.light() }
    let target = reply
    let canonical = room
    busy = true;receipt=nil
    Task {
      defer { busy = false }
      do {
        let result=try await BiliAPI.shared.sendLive(
          body, room: canonical, emoji: emoji, reply: target, owner: owner)
        guard owner == accounts.state.active, room == canonical else { return }
        receipt=result
        if reply == target { reply = nil }
        chosen = nil
        if !emoji {text="";selection=nil;inserted=[:]}
      } catch { if accounts.state.active == owner,room == canonical {self.error = error.localizedDescription} }
    }
  }
}
struct LiveFollows: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var count: Int?
  @State private var seen = Set<Int64>()
  var body: some View {
    if let owner = accounts.state.active {
      PageList(empty:"暂无开播的关注主播",grid:true,autoMore:true) { cursor in
        let page = Int(cursor ?? "1") ?? 1
        let r = try await BiliAPI.shared.read("/xlive/web-ucenter/user/following",
          ["page":String(page),"page_size":"9","ignoreRecord":"1","hit_ab":"true"],host:"api.live.bilibili.com",
          expectedAccount:owner,as:LiveFollowPage.self)
        try Task.checkCancellation(); guard accounts.state.active == owner else { throw CancellationError() }
        if page == 1 { seen.removeAll() }; count = r.live_count
        let fresh = r.onAir.filter { seen.insert($0.id).inserted }
        return Page(items:fresh,next:r.next(after:page,uniqueSeen:seen.count))
      } row: { r in LiveFollowingCard(room:r) }
        .id(owner).navigationTitle(count.map { "\($0) 人正在直播" } ?? "关注直播")
    } else {
      ContentUnavailableView { Label("关注的直播",systemImage:"person.2") }
        actions:{NavigationLink("登录") { QRLoginView() }}
    }
  }
}
