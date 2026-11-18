import SwiftUI

/// Icon-over-title tab strip used by the sign-in page (the original client's login TabBar).
struct LoginTabStrip<Tab: Hashable>: View {
  let tabs: [(tab: Tab, title: String, symbol: String)]
  @Binding var selection: Tab
  @Namespace private var indicator
  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.tab) { item in
        let on = item.tab == selection
        Button {
          withAnimation(.snappy(duration: 0.25)) { selection = item.tab }
        } label: {
          VStack(spacing: 4) {
            Image(systemName: item.symbol).font(.system(size: 19, weight: .medium)).frame(height: 24)
            Text(item.title).font(.footnote.weight(on ? .semibold : .regular))
          }
          .foregroundStyle(on ? Color.accentColor : Color.secondary)
          .frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 9)
          .overlay(alignment: .bottom) {
            if on {
              Capsule().fill(Color.accentColor).frame(width: 28, height: 3)
                .matchedGeometryEffect(id: "indicator", in: indicator)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .overlay(alignment: .bottom) { Divider() }
  }
}

/// Underlined input row with a leading symbol and a clear button, like the original's TextFields.
struct LoginField<Trailing: View>: View {
  let symbol: String
  let title: String
  @Binding var text: String
  var secure = false
  var keyboard: UIKeyboardType = .default
  var content: UITextContentType? = nil
  @ViewBuilder var trailing: () -> Trailing
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 24)
      Group {
        if secure { SecureField(title, text: $text) } else { TextField(title, text: $text) }
      }
      .keyboardType(keyboard).textContentType(content)
      .textInputAutocapitalization(.never).autocorrectionDisabled()
      .onChange(of: text) { _, value in
        let stripped = value.filter { !$0.isWhitespace }
        if stripped != value { text = stripped }
      }
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }.buttonStyle(.plain).accessibilityLabel("清除")
      }
      trailing()
    }
    .frame(minHeight: 48)
    .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
  }
}
extension LoginField where Trailing == EmptyView {
  init(symbol: String, title: String, text: Binding<String>, secure: Bool = false,
    keyboard: UIKeyboardType = .default, content: UITextContentType? = nil) {
    self.init(symbol: symbol, title: title, text: text, secure: secure, keyboard: keyboard,
      content: content) { EmptyView() }
  }
}

/// Scrolling column for one sign-in method: a centred headline, the method's controls and a
/// quiet footnote, narrowed on wide screens.
struct LoginPane<Content: View>: View {
  let headline: String
  var note: String? = nil
  var footnote: String? = nil
  @ViewBuilder var content: () -> Content
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Text(headline).font(.headline).padding(.top, 24)
        if let note { Text(note).font(.footnote).foregroundStyle(.tint).multilineTextAlignment(.center) }
        content()
        if let footnote {
          Text(footnote).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            .padding(.top, 4)
        }
      }
      .padding(.horizontal, 24).padding(.bottom, 28)
      .frame(maxWidth: 480).frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }
}

/// The capsule "登录" action under each form.
struct LoginSubmit: View {
  var title = "登录"
  var busy = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if busy { ProgressView().tint(.white) } else { Image(systemName: "arrow.right.circle") }
        Text(busy ? "请稍候" : title)
      }
      .font(.body.weight(.semibold)).frame(maxWidth: 260).padding(.vertical, 4)
    }
    .piliButtonStyle(.glassProminent).controlSize(.large)
  }
}

enum LoginCopy {
  static let trusted = "请务必在轻哩开源仓库等可信渠道下载安装。"
  static let password = """
    根据哔哩哔哩官方登录接口规范，密码将在本地加盐、加密后传输。
    盐与公钥均由官方提供；以 RSA/ECB/PKCS1Padding 方式加密。
    账号密码仅用于该登录接口，不予保存；本地仅存储登录凭证。
    """ + "\n" + trusted
  static let sms = "手机号仅用于哔哩哔哩官方发送验证码与登录接口，不予保存；\n本地仅存储登录凭证。\n" + trusted
}
