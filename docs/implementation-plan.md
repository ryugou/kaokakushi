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

| # | 名称 | 主モジュール | 内容 |
| --- | --- | --- | --- |
| 1 | プロジェクト基盤 | — | Xcode プロジェクトと SwiftPM ローカルパッケージの骨格、CI、SwiftLint、`swift test` の実行基盤 |
| 2 | ドメイン層 | `Domain` | `QuotaPolicy`、`EntitlementResolver`、`BatchTriagePolicy`、`compileRenderDraft`、`ExportQueue` の状態機械、正準エンコーダ |
| 3 | 永続化アダプタ | `Persistence` | GRDB と `app.db`、`ManagedFileStore`、`ProtectedBlobStore`、`CryptoKeyStore`、`UsageLedgerStore`、`ExportSagaStore` |
| 4 | **書き出し Saga** | **`Application`** | `ExportCoordinator` / `StartupRecoveryCoordinator` / `OutputDeliveryCoordinator`、`ExportStartGate`、障害注入テスト基盤 |
| 5 | プラットフォーム層 | `MediaKit` / `Rendering` / `App` | 画像処理プロトコルの実装と適合テスト、選択の境界サービス、`ProtectedDataAvailability` |
| 6 | 編集フロー UI | `App` | detect / effect / export / processing / done |
| 7 | 課金と権限 | `Billing` | RevenueCat、Paywall、復元、`SubscriptionState` の読み込み失敗経路 |
| 8 | 広告 | `Ads` | `AdPresenter`、`AdFrequencyPolicy` の適用 |
| 9 | 一括処理とトリアージ | `Domain` / `App` | 選択分類、確認モード、キュー、一括設定プリセット |
| 10 | 履歴・カスタムスタンプ・設定 | `Domain` / `Persistence` / `App` | 寿命管理、`ProjectStampAsset` の参照、容量表示 |
| 11 | バックエンド | `server/` | Rust + Axum。リモート設定の検証規則を含む |
| 12 | リリース準備 | — | アクセシビリティ、プライバシー受入テスト、実機マトリクス、ストア申請物 |

**サブプロジェクト 3 と 4 を分けます。** コミット Saga の実装主体は `Application` であり、`Persistence` は `ExportSagaStore` の実装を提供するだけです。1 つにまとめると、モジュール割り当て（3 章）と計画が食い違います。

**4 を独立させる理由は変わりません。** 本設計で最も密度が高く、実機の障害注入テストを伴います。UI と並行して進めると、どちらの不具合か切り分けられません。

---

## 2. 依存と着手順

```
1 基盤
 ├─→ 2 ドメイン層 ──────┐
 └─→ 3 永続化アダプタ ──┴─→ 4 書き出し Saga ─→ 6 編集フロー UI ─→ 9 一括処理
                          │                      └─→ 7 課金 ─→ 8 広告
                          ├─→ 5 プラットフォーム層 ┘
                          └─→ 10 履歴・スタンプ・設定
11 バックエンド（独立）
12 リリース準備（全体の後）
```

| 関係 | 理由 |
| --- | --- |
| 2 と 3 は並行できる | ドメイン層は `swift test` だけで完結し、永続化の実装を待たない |
| 4 は 2 と 3 の両方を待つ | Saga は `Domain` の型と `Persistence` の実装の両方を使う |
| 4 の偽ストアテストは 3 を待たない | `ExportSagaStore` のプロトコルが 2 で確定していれば書ける |
| 5 は 3 を待つ | 境界サービスが `ManagedFileStore` を使う |
| 6 は 4 と 5 を待つ | 書き出しの開始と画像処理の両方を呼ぶ |

**4 の偽ストアによる saga テストは、3 の完成前に着手できます。** プロトコルさえ確定していれば偽実装で全中断点を検証でき、実 GRDB を使う適合テストだけが 3 の完成を待ちます。
## 3. モジュールの割り当て

**すべてを `MediaKit` へ実装しません。** プロトコルの一覧は [アーキテクチャ設計](architecture.md) と [画像処理アーキテクチャ](image-pipeline.md) が正本です。

| モジュール | プロトコル |
| --- | --- |
| `MediaKit` | `PickedPhotoLoader` / `FaceDetector` / `ImageEffectRenderer` / `ImageEncoder` / `MediaSaver` / `SharePresenter`（MainActor） |
| `Rendering` | `StampRasterizer` |
| `Persistence` | `ProtectedBlobStore`、`ManagedFileStore`、`UsageLedgerStore`、**`ExportSagaStore`**、GRDB、ファイル管理 |
| `Persistence/Security` | `CryptoKeyStore` |
| `Application` | `ExportStartGate` の実装、3 つの Coordinator。**コミット Saga の主体はここ**（サブプロジェクト 4） |
| `Analytics` | `CrashReporter`、`AnalyticsEvent` の送信 |
| `Ads` | `AdPresenter` |
| `App` | `PrivacyShield`、`PhotosPicker` / `fileImporter` の提示、`PhotoSelectionBridge` / `FileSelectionBridge`、`ProtectedDataAvailability` |

---

## 4. 着手前に確定が必要な未決事項

[アーキテクチャ設計](architecture.md) の未決事項のうち、実装計画の段階で決めるものです。

| 項目 | 影響するサブプロジェクト |
| --- | --- |
| 共有結果 `.unknown` 後の利用者操作 | 5、6 |
| 信頼できる時刻の取得元 | 3、4、7、11 |

実機計測で決まる項目（`lowConfidence` の閾値、`extremePose` の角度、同期方式、手順 7-b のしきい値、並列数）は、該当サブプロジェクトの実装後に計測して確定します。
