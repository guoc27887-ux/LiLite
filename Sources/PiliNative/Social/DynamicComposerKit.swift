import SwiftUI

/// Pieces of the dynamic composer laid out like the original publish page: a topic chip, a bold
/// title line, the body, then scheduling / reply / visibility menus and a 100pt image strip.
struct ComposerTopicChip: View {
  let name: String?
  let choose: () -> Void
  let clear: () -> Void
  var body: some View {
    HStack(spacing: 6) {
      Button(action: choose) {
        Label(name ?? "选择话题", systemImage: "number")
          .font(.subheadline.weight(name == nil ? .regular : .semibold))
          .foregroundStyle(name == nil ? Color.secondary : Color.accentColor)
          .padding(.horizontal, name == nil ? 12 : 0).padding(.vertical, 8)
          .overlay {
            if name == nil { Capsule().stroke(.separator, lineWidth: 1) }
          }
      }
      .buttonStyle(.plain)
      if name != nil {
        Button(action: clear) {
          Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .frame(width: 22, height: 22).background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("移除话题")
      }
    }
  }
}

struct ComposerTitleField: View {
  @Binding var text: String
  var body: some View {
    TextField("标题，选填 20 字", text: $text)
      .font(.body.weight(.bold))
      .onChange(of: text) { _, value in if value.count > 20 { text = String(value.prefix(20)) } }
  }
}

/// "允许评论 ›" style menu; red when comments are closed.
struct ComposerReplyMenu: View {
  @Binding var selection: Int
  var keepOption = false
  var allows: (Int) -> Bool = { _ in true }
  private static let titles = ["允许评论", "关闭评论", "精选评论"]
  private static let symbols = ["text.bubble", "bubble.left.and.exclamationmark.bubble.right", "star.bubble"]
  var body: some View {
    Menu {
      Picker("评论设置", selection: $selection) {
        if keepOption { Label("保持原设置", systemImage: "arrow.uturn.backward").tag(-1) }
        ForEach(0..<3, id: \.self) { mode in
          Label(Self.titles[mode], systemImage: Self.symbols[mode]).tag(mode).disabled(!allows(mode))
        }
      }
    } label: {
      let on = selection >= 0 ? selection : 0
      ComposerMenuLabel(
        title: selection < 0 ? "保持原评论设置" : Self.titles[on],
        symbol: Self.symbols[on], alert: selection == 1)
    }
  }
}

struct ComposerPrivacyMenu: View {
  @Binding var isPrivate: Bool
  var lockPrivate = false
  var body: some View {
    Menu {
      Picker("可见范围", selection: $isPrivate) {
        Label("所有人可见", systemImage: "eye").tag(false)
        Label("仅自己可见", systemImage: "eye.slash").tag(true).disabled(lockPrivate)
      }
    } label: {
      ComposerMenuLabel(
        title: isPrivate ? "仅自己可见" : "所有人可见", symbol: isPrivate ? "eye.slash" : "eye",
        alert: isPrivate)
    }
  }
}

struct ComposerMenuLabel: View {
  let title: String, symbol: String
  var alert = false
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.footnote)
      Text(title)
      Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
    }
    .font(.subheadline)
    .foregroundStyle(alert ? Color.red : Color.accentColor)
    .padding(.vertical, 3)
  }
}

/// 定时发布 button; once a time is set it shows the time with a clear button.
struct ComposerScheduleButton: View {
  @Binding var date: Date?
  var disabled = false
  @State private var picking = false
  @State private var pending = Date()
  private static let format: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "M月d日 HH:mm"
    return f
  }()
  var body: some View {
    Group {
      if let date {
        Button { self.date = nil } label: {
          HStack(spacing: 6) {
            Text(Self.format.string(from: date)).monospacedDigit()
            Image(systemName: "xmark").font(.caption.weight(.bold))
          }
          .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
      } else {
        Button("定时发布") {
          pending = Date().addingTimeInterval(3600)
          picking = true
        }
        .font(.subheadline.weight(.medium))
        .piliButtonStyle(.glass).buttonBorderShape(.capsule)
        .disabled(disabled)
      }
    }
    .piliSheet(isPresented: $picking) {
      PiliNavigationStack {
        Form {
          DatePicker("发布时间", selection: $pending,
            in: Date().addingTimeInterval(360)...Date().addingTimeInterval(7 * 86_400))
            .datePickerStyle(.graphical)
        }
        .navigationTitle("定时发布").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { picking = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("确定") { date = pending; picking = false }
          }
        }
      }
      .presentationDetents([.large])
    }
  }
}

/// Live reservation attached to the post.
struct ComposerReserveCard: View {
  let title: String
  var start: Date? = nil
  let remove: () -> Void
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "calendar.badge.clock").font(.title3).foregroundStyle(.tint)
        .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
        if let start, start > .distantPast {
          Text("直播预约 · " + start.formatted(date: .abbreviated, time: .shortened))
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("直播预约").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
      }.buttonStyle(.plain).accessibilityLabel("移除预约")
    }
    .padding(10)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

/// One 100pt image of the strip: tap to crop, × to remove, menu to reorder.
struct DraftImageTile<Content: View>: View {
  var live = false
  let crop: () -> Void
  let remove: () -> Void
  var moveLeft: (() -> Void)? = nil
  var moveRight: (() -> Void)? = nil
  @ViewBuilder var content: () -> Content
  var body: some View {
    Button(action: crop) {
      content().frame(width: 100, height: 100).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomLeading) {
          if live {
            Image(systemName: "livephoto").font(.caption).foregroundStyle(.white).padding(6)
              .shadow(radius: 2)
          }
        }
    }
    .buttonStyle(.plain)
    .overlay(alignment: .topTrailing) {
      Button(action: remove) {
        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
          .frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle())
      }
      .buttonStyle(.plain).padding(5).accessibilityLabel("移除图片")
    }
    .contextMenu {
      Button("裁剪", systemImage: "crop", action: crop)
      if let moveLeft { Button("向前移动", systemImage: "arrow.left", action: moveLeft) }
      if let moveRight { Button("向后移动", systemImage: "arrow.right", action: moveRight) }
      Button("移除", systemImage: "trash", role: .destructive, action: remove)
    }
  }
}

/// The "+" tile at the end of the image strip.
struct ComposerAddPhotoLabel: View {
  var busy = false
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.1))
      if busy { ProgressView() } else {
        Image(systemName: "plus").font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
      }
    }
    .frame(width: 100, height: 100)
    .accessibilityLabel("添加图片")
  }
}

/// Icon button of the composer's bottom tool row.
struct ComposerToolButton: View {
  let title: String, symbol: String
  var active = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 21, weight: .regular))
        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.75))
        .frame(width: 40, height: 40).contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel(title)
  }
}
