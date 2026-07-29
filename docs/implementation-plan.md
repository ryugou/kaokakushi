# 実装計画

| 項目 | 内容 |
| --- | --- |
| 目的 | サブプロジェクトへの分解と、その依存関係を定める |
| 読者 | 実装の着手順を決める者 |
| 正本の範囲 | サブプロジェクトの粒度、依存、モジュール割り当て |
| 関連 | [アーキテクチャ設計](architecture.md)、[テスト計画](test-plan.md) |

各サブプロジェクトは個別に spec → plan → 実装のサイクルを回します。

---

## 1. サブプロジェクト

| # | 名称 | 内容 |
| --- | --- | --- |
| 1 | プロジェクト基盤 | Xcode プロジェクトと SwiftPM ローカルパッケージの骨格、CI、SwiftLint、`swift test` の実行基盤 |
| 2 | ドメイン層 | `QuotaPolicy`、`EntitlementResolver`、`BatchTriagePolicy`、`compileRenderDraft`、キーフレーム補間、`ExportQueue` |
| 3 | プラットフォーム層 | プロトコルの実装と適合テスト（下表）。`SharePresenter` は結果写像を先に定義してから実装する |
| 4 | 永続化とコミットジャーナル | GRDB、2 DB 構成と `ATTACH`、`ProtectedBlobStore`、`CryptoKeyStore`、障害注入テスト基盤 |
| 5 | 編集フロー UI | detect / effect / export / processing / done |
| 6 | 課金と権限 | RevenueCat、Paywall、復元、`SubscriptionState` の読み込み失敗経路 |
| 7 | 広告 | `AdPresenter`、`AdFrequencyPolicy` の適用 |
| 8 | 一括処理とトリアージ | 選択分類、確認モード、キュー、一括設定プリセット |
| 9 | 履歴・カスタムスタンプ・設定 | 寿命管理、`StampAsset` の参照カウント、容量表示 |
| 10 | バックエンド | Rust + Axum。リモート設定の検証規則を含む |
| 11 | リリース準備 | アクセシビリティ、プライバシー受入テスト、実機マトリクス、ストア申請物 |

---

## 2. 依存と着手順

```
1 基盤
 ├─→ 2 ドメイン層 ────┐
 └─→ 4 永続化 ────────┼─→ 3 プラットフォーム層 ─→ 5 編集フロー UI ─→ 8 一括処理
                      │                            └─→ 6 課金 ─→ 7 広告
                      └─→ 9 履歴・スタンプ・設定
10 バックエンド（独立）
11 リリース準備（全体の後）
```

**サブプロジェクト 4 を独立させます。** コミットジャーナルは本設計で最も密度が高く、実機の障害注入テストを伴います。UI と並行して進めると、どちらの不具合か切り分けられません。

**2 と 4 は並行できます。** ドメイン層は `swift test` だけで完結し、永続化の実装を待ちません。

---

## 3. モジュールの割り当て

**すべてを `MediaKit` へ実装しません。** プロトコルの一覧は [アーキテクチャ設計](architecture.md) と [画像処理アーキテクチャ](image-pipeline.md) が正本です。

| モジュール | プロトコル |
| --- | --- |
| `MediaKit` | `PickedPhotoLoader` / `FaceDetector` / `ImageEffectRenderer` / `ImageEncoder` / `MediaSaver` / `SharePresenter`（MainActor） |
| `Rendering` | `StampRasterizer` |
| `Persistence` | `ProtectedBlobStore`、`ManagedFileStore`、`UsageLedgerStore`、GRDB、ファイル管理 |
| `Persistence/Security` | `CryptoKeyStore` |
| `Application` | `ExportStartGate`、3 つの Coordinator |
| `Analytics` | `CrashReporter`、`AnalyticsEvent` の送信 |
| `Ads` | `AdPresenter` |
| `App` | `PrivacyShield`、`PhotosPicker` / `fileImporter` の提示、`PhotoSelectionBridge` / `FileSelectionBridge`、`ProtectedDataAvailability` |

---

## 4. 着手前に確定が必要な未決事項

[アーキテクチャ設計](architecture.md) の未決事項のうち、実装計画の段階で決めるものです。

| 項目 | 影響するサブプロジェクト |
| --- | --- |
| 共有結果 `.unknown` 後の利用者操作 | 3、5 |
| 信頼できる時刻の取得元 | 4、6、10 |

実機計測で決まる項目（`lowConfidence` の閾値、`extremePose` の角度、同期方式、手順 7-b のしきい値、並列数）は、該当サブプロジェクトの実装後に計測して確定します。
