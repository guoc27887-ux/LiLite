import SwiftUI

struct ArchiveCoinPicker: View {
  let owner:String, already:Int, maximum:Int, confirm:(Int,Bool)->Void
  @EnvironmentObject private var accounts:AccountContext
  @Environment(\.dismiss) private var dismiss
  @AppStorage("detail.coinLike") private var withLike=false
  @State private var amount=1
  @State private var balance:Double?
  @State private var drop:Date?
  @State private var send:Task<Void,Never>?
  @Environment(\.accessibilityReduceMotion) private var reduce
  @Environment(\.scenePhase) private var phase
  private var available: [Int] {
    (1...2).filter { $0<=maximum-already && (balance ?? 2)>=Double($0) }
  }
  var body:some View{
    PiliNavigationStack{
      ScrollView{
        VStack(spacing:18){
          ArchiveCoinStage(amount:amount,started:drop,reduce:reduce,choose:{n in if available.contains(n){amount=n}},pay:submit)
          Picker("数量",selection:$amount){
            ForEach(1...2,id:\.self){n in if n<=maximum-already{Text("\(n) 枚").tag(n)}}
          }.pickerStyle(.segmented).frame(maxWidth:240)
          HStack(spacing:16){
            Toggle(isOn:$withLike){Text("同时点赞")}.toggleStyle(LoginCheckbox())
            Spacer()
            if let balance{Text("硬币余额 "+balance.formatted()).monospacedDigit().foregroundStyle(.secondary)}
          }.font(.subheadline)
          if already>0{Text("已投 \(already) 枚").font(.footnote).foregroundStyle(.secondary)}
          Button(action:submit){
            Text("投 \(amount) 枚硬币").font(.body.weight(.semibold)).frame(maxWidth:260).padding(.vertical,4)
          }.piliButtonStyle(.glassProminent).controlSize(.large)
            .disabled(drop != nil || !available.contains(amount) || accounts.state.active != owner)
        }.padding(.horizontal,24).padding(.vertical,12)
      }.disabled(drop != nil).navigationTitle("投币").navigationBarTitleDisplayMode(.inline)
        .toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){cancel();dismiss()}}}
        .onChange(of:phase){_,v in if v != .active{cancel()}}
        .onChange(of:accounts.state.active){_,_ in cancel();dismiss()}
        .onDisappear{cancel()}
        .task(id:owner){
          let state=try? await BiliAPI.shared.profile(expectedAccount:owner)
          guard !Task.isCancelled,accounts.state.active==owner,let who=state,String(who.mid)==owner else{return}
          balance=who.money;if let first=available.first,!available.contains(amount){amount=first}
        }
    }.presentationDetents([.medium,.large])
  }
  private func cancel(){send?.cancel();send=nil;drop=nil}
  private func submit(){
    guard drop==nil,phase == .active,accounts.state.active==owner,available.contains(amount) else{return}
    let n=amount,like=withLike
    drop = .now;TouchFeedback.light()
    send=Task{@MainActor in
      if !reduce{do{try await Task.sleep(for:.milliseconds(400))}catch{return}}
      guard !Task.isCancelled,accounts.state.active==owner,phase == .active,available.contains(n) else{cancel();return}
      dismiss();confirm(n,like)
    }
  }
}
