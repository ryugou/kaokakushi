import SwiftUI

/// アプリのエントリポイント。
///
/// Issue #4（プロジェクト基盤）時点では DI の組み立ては未実装。
/// Application / MediaKit / Rendering / Persistence / Billing / Ads / Analytics の
/// 各アダプタを注入する Composition Root は、各パッケージの実装が揃う後続 Issue で
/// ここに追加する（architecture.md 3.2）。
@main
struct KaoKakushiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
