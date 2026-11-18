import SwiftUI

struct BubbleCommunity: View {
  typealias Payload = BubblePayload
  let id: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var title = "泡泡社区"
  @State private var summary = ""
  @State private var categories: [Payload.Categories.Category] = []
  @State private var category = ""
  @State private var visited: Set<String> = [""]
  @State private var top = [String:Int]()
  private var tabs: [(String,String)] {
    guard !categories.isEmpty else{return [("","全部")]}
    var ids = Set([""])
    return [("",categories[0].name ?? "全部")] + categories.dropFirst().compactMap { c in
      guard !c.id.isEmpty,ids.insert(c.id).inserted else{return nil};return(c.id,c.name ?? c.id)
    }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:0) {
      if !summary.isEmpty {
        Text(summary).lineLimit(3).piliFont(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal,16).padding(.bottom,6)
      }
      if tabs.count > 1 {
        ChipBar(items:tabs.map(\.0),selection:Binding(get:{category},set:{visited.insert($0);category=$0}),
          title:{ id in tabs.first{$0.0==id}?.1 ?? id },reselect:{ top[category,default:0] &+= 1 })
          .padding(.vertical,6)
      }
      ZStack {
        ForEach(tabs,id:\.0) { tab in
          if visited.contains(tab.0) {
            BubblePosts(tribe:id,category:tab.0,owner:accounts.state.active ?? "",active:tab.0==category,
              top:top[tab.0] ?? 0) { data in
                if let info=data.base_info?.tribee_info {title=info.title ?? "泡泡社区";summary=info.summary ?? ""}
                if let rows = data.category?.category_list {categories=rows}
                if !tabs.contains(where:{$0.0==category}) {category=""}
              }
              .opacity(tab.0==category ? 1:0).allowsHitTesting(tab.0==category).accessibilityHidden(tab.0 != category)
          }
        }
      }
    }.navigationTitle(title == "泡泡社区" ? title : title + "小站").navigationBarTitleDisplayMode(.inline)
      .id("\(id):\(accounts.state.active ?? "")")
      .onChange(of:"\(id):\(accounts.state.active ?? "")"){_,_ in
        title="泡泡社区";summary="";categories=[];category="";visited=[""];top=[:]
      }
  }
}

private struct BubblePosts:View {
  typealias Payload = BubbleCommunity.Payload
  let tribe:Int64,category:String,owner:String,active:Bool,top:Int,header:(Payload)->Void
  @State private var options:[Payload.Sort.Option]=[]
  @State private var sort:Int?
  @State private var serviceSort:Int?
  var body:some View {
    let current = sort ?? serviceSort ?? options.first?.id
    PageList(empty:"暂无帖子",grid:true,autoMore:true,active:active,scrollToTopRequest:top){ cursor in
        let page=Int(cursor ?? "1") ?? 1
        var q=["tribee_id":String(tribe),"page_num":String(page),"page_size":"20","web_location":"333.40165",
          "x-bili-device-req-json":#"{"platform":"web","device":"pc","spmid":"333.40165"}"#]
        if !category.isEmpty {q["category_id"]=category}
        q["sort_type"]=sort.map(String.init)
        let r=try await BiliAPI.shared.read("/x/tribee/v1/dyn/all",q,expectedAccount:owner,as:Payload.self)
        try Task.checkCancellation()
        if page==1 {
          if category.isEmpty {header(r)}
          var ids=Set<Int>()
          options=r.sort_info?.show_sort == true ? (r.sort_info?.sort_items ?? []).filter{ids.insert($0.id).inserted}:[]
          serviceSort=r.sort_info?.cur_sort_type
        }
        let rows=(r.content?.dyn_list ?? []).filter {!$0.dyn_id.isEmpty}
        let total=r.content?.count.flatMap(Int.init)
        return Page(items:rows,next: !rows.isEmpty && (total.map{page*20<$0} ?? (rows.count>=20)) ? String(page+1):nil)
      } row:{ r in
        NavigationLink {ArticleReader(opus:r.dyn_id)} label:{
          HStack(alignment:.firstTextBaseline,spacing:10) {
            VStack(alignment:.leading,spacing:3) {
              Text(r.title ?? "帖子").font(.subheadline).lineLimit(1).foregroundStyle(.primary)
              let meta=[r.meta?.author,r.meta?.view_stat,r.meta?.reply_count].compactMap{$0}.filter{!$0.isEmpty}
              if !meta.isEmpty {
                Text(meta.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer(minLength:0)
            if let time=r.meta?.time_text {Text(time).font(.footnote).foregroundStyle(.secondary)}
          }
          .padding(.vertical,4)
        }
      }.id("\(tribe):\(owner):\(category):\(sort ?? -1)")
      .overlay(alignment:.bottomTrailing) {
        if active, !options.isEmpty, let current {
          Menu {
            Picker("排序",selection:Binding(get:{current},set:{if $0 != (sort ?? serviceSort) {sort=$0}})){
              ForEach(options){o in Text(o.text ?? "排序 \(o.id)").tag(o.id)}
            }
          } label: {
            Label(options.first{$0.id==current}?.text ?? "排序",systemImage:"arrow.up.arrow.down")
              .font(.subheadline.weight(.semibold)).padding(.horizontal,16).padding(.vertical,12)
          }
          .piliGlass(in: Capsule(), interactive: true)
          .padding(.trailing,20).padding(.bottom,16)
        }
      }
  }
}
