import SwiftUI

struct DynamicPortal: Decodable {
  struct Person: Decodable, Identifiable {
    let mid: Int64, uname: String?, face: String?
    var has_update: Bool?
    init(mid: Int64, uname: String?, face: String? = nil) {
      self.mid = mid
      self.uname = uname
      self.face = face
    }
    var id: Int64 { mid }
    enum Keys: String, CodingKey { case mid, uname, face, has_update }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      mid = try c.decode(ServiceID.self, forKey: .mid).number ?? 0
      face = try c.decodeIfPresent(String.self, forKey: .face)
      uname = try c.decodeIfPresent(String.self, forKey: .uname)
      has_update =
        (try? c.decode(Bool.self, forKey: .has_update))
        ?? (try? c.decode(Int.self, forKey: .has_update)).map { $0 != 0 }
    }
  }
  struct Live: Decodable {
    struct Room: Decodable, Identifiable {
      let mid: Int64?, uname: String?, title: String?, face: String?, room_id: Int64?
      var id: Int64 { room_id ?? mid ?? 0 }
      enum Keys: String, CodingKey { case mid, uname, title, face, room_id }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        mid = try? c.decode(ServiceID.self, forKey: .mid).number
        room_id = try? c.decode(ServiceID.self, forKey: .room_id).number
        uname = try c.decodeIfPresent(String.self, forKey: .uname)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        face = try? c.decode(String.self, forKey: .face)
      }
    }
    let count: ServiceID?, items: [Room]?
  }
  struct Users: Decodable { let items: [Person]?, has_more: Bool?, offset: String? }
  let up_list: Users?, live_users: Live?
}
struct CommunityFilterPanel: View {
  @AppStorage("social.upPanelPosition") private var position = FeedPanelPosition.leftFixed.rawValue
  @AppStorage("social.waterfall") private var waterfall: Bool?
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage(FeedScope.setting) private var defaultFeed = 0
  @AppStorage("social.dispute") private var showDispute = false
  @AppStorage("social.interaction") private var showInteraction = true
  @AppStorage("social.actionBar") private var actionBar = true
  @AppStorage("social.allFollowed") private var allFollowed = false
  @AppStorage("social.expandLive") private var expandLive = false
  @AppStorage("social.verifyPost") private var verifyPost = false
  @AppStorage("social.verifyReply") private var verifyReply = false
  @AppStorage("social.dynamicRegex") private var regex = ""
  @AppStorage("social.hideGoods") private var goods = false
  @State private var draft = ""
  @State private var issue: String?
  var body: some View {
    Form {
      Section("动态") {
        Picker(selection: $position) {
          ForEach(FeedPanelPosition.allCases) { Text($0.label).tag($0.rawValue) }
        } label: {
          SettingsRowLabel(title: "UP 主面板", symbol: "person.2.crop.square.stack", color: .blue)
        }.settingAnchor("CommunityFilterPanel/UP 主面板")
        Picker(selection: $defaultFeed) {
          ForEach(FeedScope.allCases) { Text($0.label).tag($0.rawValue) }
        } label: {
          SettingsRowLabel(title: "默认分类", symbol: "line.3.horizontal.decrease", color: .blue)
        }.settingAnchor("CommunityFilterPanel/默认分类")
        SettingToggle(title: "瀑布流布局", symbol: "square.grid.2x2", color: .teal,
          isOn: Binding(get: { waterfall ?? horizontal }, set: { waterfall = $0 }))
          .settingAnchor("CommunityFilterPanel/瀑布流布局")
        if waterfall != nil {
          Button("布局跟随横屏设置") { waterfall = nil }.settingAnchor("CommunityFilterPanel/布局跟随横屏设置")
        }
        SettingToggle(title: "显示关注的全部 UP 主", symbol: "person.3", color: .indigo, isOn: $allFollowed)
          .settingAnchor("CommunityFilterPanel/显示关注的全部 UP 主")
        SettingToggle(title: "展开正在直播的 UP 主", symbol: "dot.radiowaves.left.and.right", color: .pink, isOn: $expandLive)
          .settingAnchor("CommunityFilterPanel/展开正在直播的 UP 主")
        SettingToggle(title: "显示互动摘要", symbol: "hand.thumbsup", color: .orange, isOn: $showInteraction)
          .settingAnchor("CommunityFilterPanel/显示互动摘要")
        SettingToggle(title: "显示争议信息", symbol: "exclamationmark.bubble", color: .yellow, isOn: $showDispute)
          .settingAnchor("CommunityFilterPanel/显示争议信息")
        SettingToggle(title: "显示动态详情操作栏", symbol: "rectangle.bottomthird.inset.filled", color: .gray, isOn: $actionBar)
          .settingAnchor("CommunityFilterPanel/显示动态详情操作栏")
        SettingToggle(title: "隐藏带货动态", symbol: "cart.badge.minus", color: .red, isOn: $goods)
          .settingAnchor("CommunityFilterPanel/隐藏带货动态")
      }.settingAnchor("CommunityFilterPanel/动态")
      Section {
        SettingToggle(title: "评论", symbol: "text.bubble", color: .green, isOn: $verifyReply)
          .settingAnchor("CommunityFilterPanel/评论")
        SettingToggle(title: "公开动态和转发", symbol: "square.and.pencil", color: .green, isOn: $verifyPost)
          .settingAnchor("CommunityFilterPanel/公开动态和转发")
      } header: {
        Text("发布后检查公开可见性")
      } footer: {
        Text("发布后用游客身份确认内容是否公开可见")
      }
      .settingAnchor("CommunityFilterPanel/发布后检查公开可见性")
      Section {
        HStack {
          TextField("输入表达式", text: $draft).settingAnchor("CommunityFilterPanel/输入表达式")
            .font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("保存") {
            do {
              if !draft.isEmpty {
                _ = try NSRegularExpression(pattern: draft, options: .caseInsensitive)
              }
              regex = draft
              issue = nil
            } catch { issue = "表达式无效" }
          }
          .piliButtonStyle(.glassProminent).controlSize(.small).disabled(draft == regex)
        }
      } header: {
        Text("屏蔽动态关键词（正则表达式）")
      } footer: {
        if let issue { Text(issue).foregroundStyle(.red) }
        else { Text("匹配到的动态不会显示，例如 抽奖|转发") }
      }
      .settingAnchor("CommunityFilterPanel/屏蔽动态关键词（正则表达式）")
    }.navigationTitle("动态设置").navigationBarTitleDisplayMode(.inline).onAppear { draft = regex }
  }
}
