# 実装計画

| 項目 | 内容 |
| --- | --- |
| 目的 | サブプロジェクトへの分解と、その依存関係を定める |
| 読者 | 実装の着手順を決める者 |
| 正本の範囲 | サブプロジェクトの粒度、依存、モジュール割り当て |
| 関連 | [アーキテクチャ設計](architecture.md)、[テスト計画](test-plan.md)、[ADR 0005](adr/0005-drop-tamper-resistance-backend-and-heavy-fault-tolerance.md)（サーバレス化）、[ADR 0006](adr/0006-accounting-per-delivered-output.md)（勘定の単位） |

各サブプロジェクトは個別に spec → plan → 実装のサイクルを回します。実装対象はすべてクライアント側です（ADR 0005）。

---

## 1. サブプロジェクト

| # | 名称 | 主モジュール | 内容 |
| --- | --- | --- | --- |
| 1 | プロジェクト基盤 | — | Xcode プロジェクトと SwiftPM ローカルパッケージの骨格、CI、SwiftLint、`swift test` の実行基盤 |
| 2 | ドメイン層 | `Domain` | クォータ判定（`evaluateMonthlyQuota` / `rollPeriod`）、権限解決（`resolveCapabilities`）、トリアージ（`triage`）、`compileRenderDraft` / `bindRasterAssets`、`ExportQueue` の状態機械、設定ハッシュの正準エンコーダ |
| 3 | 永続化アダプタ | `Persistence` | GRDB と `app.db`、`ManagedFileStore`、`ExportSagaStore`、`OutputDeliveryStore`、`WorkingSourceStore`、`HistoryDeletionStore` |
| 4 | 書き出しフロー | `Application` | `ExportCoordinator` / `StartupRecoveryCoordinator` / `OutputDeliveryCoordinator`、直列実行キュー、`settledAt` と reissue の勘定規則 |
| 5 | プラットフォーム層 | `MediaKit` / `Rendering` / `App` / `Application` | 画像処理プロトコルの実装と適合テスト、選択の境界サービス、`SourceImportCoordinator`（インポート／再選択／再接続／複製の 4 Saga）、`ProtectedDataAvailability` |
| 6 | 編集フロー UI | `App` | detect / effect / export / processing / **出力確認（confirm）** / done |
| 7 | 課金と権限 | `Billing` | RevenueCat、Paywall、購入復元、`SubscriptionState` の読み込み失敗経路 |
| 8 | 広告 | `Ads` | `AdPresenter`、広告表示頻度の判定の適用 |
| 9 | 一括処理とトリアージ | `Domain` / `App` | 選択枚数と残クレジットの判定、確認モード、キュー、一括設定プリセット、**バッチの完了操作**（結果一覧での一括確定） |
| 10 | 履歴・カスタムスタンプ・設定・更新誘導 | `Domain` / `Persistence` / `App` / `Application` | 寿命管理、`HistoryDeletionCoordinator`（`Project` / `Batch` 削除、編集中の破棄）、`ProjectStampAsset` の参照、容量表示、更新誘導（iTunes Lookup） |
| 11 | リリース準備 | — | アクセシビリティ、プライバシー受入テスト、実機マトリクス、ストア申請物 |

---

## 2. 依存と着手順

```
1 基盤
  ↓
2 Domain の契約を確定（前半）
   値型（UsageLedger / ExportJob / ExportRecord / OutputRecord /
         ManagedFileRef 系 / ID 型）
   永続化ポート（ExportSagaStore / OutputDeliveryStore /
                 WorkingSourceStore / HistoryDeletionStore / ManagedFileStore）
   設定ハッシュの正準化（canonical-schema.md）
  ↓
3 以降を並行
   ├─ 2' Domain の純粋関数と状態機械
   ├─ 3  Persistence アダプタ
   └─ 5  プラットフォーム層（3 の ManagedFileStore を待つ）
  ↓
4 Application の書き出しフロー
  ↓
6 編集フロー UI ─→ 9 一括処理
   └─→ 7 課金 ─→ 8 広告
10 履歴・スタンプ・設定・更新誘導（3 の後）
11 リリース準備（全体の後）
```

- **`Persistence` は `Domain` の完成を待たず、契約（2 の前半）だけを待ちます。** 値型・ポート・設定ハッシュが確定しなければテーブル定義とデコードが決まりません
- 2 の後半（純粋関数）と 3 は並行できます
- 4 は 2 と 3 の両方を待ちます。ただし**偽ストアによる状態機械のテストは 3 を待ちません**（ポートが確定していれば偽実装で全経路を書けます）
- 6 は 4 と 5 を待ちます（書き出しの開始と画像処理の両方を呼ぶため）

**4 を独立させるのは、勘定の確定（単一トランザクション・settledAt・reissue）が本設計で最も密度が高いためです。** UI と並行で進めると不具合の切り分けができません。

---

## 3. モジュールの割り当て

プロトコルの一覧と定義は [アーキテクチャ設計](architecture.md) と [画像処理](image-pipeline.md) が正本です。

| モジュール | 主な内容 |
| --- | --- |
| `MediaKit` | `PickedPhotoLoader` / `FaceDetector` / `ImageEffectRenderer` / `ImageEncoder` / `MediaSaver` / `SharePresenter`（MainActor） |
| `Rendering` | `StampRasterizer` |
| `Persistence` | `ManagedFileStore`、`ExportSagaStore`、`OutputDeliveryStore`、`WorkingSourceStore`、`HistoryDeletionStore`、GRDB、ファイル管理 |
| `Application` | `ExportCoordinator` / `StartupRecoveryCoordinator` / `OutputDeliveryCoordinator`（サブプロジェクト 4）、`SourceImportCoordinator`（サブプロジェクト 5）、`HistoryDeletionCoordinator`（サブプロジェクト 10） |
| `Analytics` | `CrashReporter`（Sentry） |
| `Ads` | `AdPresenter` |
| `App` | `PrivacyShield`、`PhotosPicker` / `fileImporter` の提示、`PhotoSelectionBridge` / `FileSelectionBridge`、`ProtectedDataAvailability` |

---

## 4. 着手前に確定が必要な未決事項

**ありません。** 実機計測で決まる項目（`lowConfidenceThreshold`、`extremePose` の角度）は、該当サブプロジェクトの実装後に計測して確定します（[アーキテクチャ設計](architecture.md) の 12.2）。

| 確定済みの項目 | 内容 | 正本 |
| --- | --- | --- |
| 共有結果 `.unknown` 後の利用者操作 | 現在の状態を維持する。手動で `delivered` にする操作は設けない | [書き出し Saga](export-saga.md) の 7.0 |
| 勘定の単位 | 完了した成果物。完了前のやり直しは reissue（追加消費なし） | [ADR 0006](adr/0006-accounting-per-delivered-output.md) |
