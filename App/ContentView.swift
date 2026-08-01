import SwiftUI

/// Issue #4（プロジェクト基盤）時点のプレースホルダ画面。
///
/// 実際の画面遷移（Route による1箇所の switch。architecture.md 3.4）や
/// 状態管理は、Application 層の Coordinator が実装される後続 Issue で置き換える。
struct ContentView: View {
    var body: some View {
        Text("顔かくし")
    }
}

#Preview {
    ContentView()
}
