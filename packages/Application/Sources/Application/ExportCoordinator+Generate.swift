import Foundation
import Domain

// ExportCoordinator+Generate — 書き出しの生成と中断後始末（Issue #7 Task 5）。
//
// 正本: export-saga.md 3章「手順」（手順1〜4: compileRenderDraft/bindRasterAssets →
// ImageEffectRenderer.render → ImageEncoder.encode → OutputFileVerifier.verify →
// recordGeneratedOutput）、4章「中断・やり直し・破棄」（discardExport の一律後始末）。
//
// 決定済みの設計判断（オーケストレーターの spec で確定済み。疑問視しない）:
// - StampRasterizer には依存しない。ラスタ資産は呼び出し元が事前に用意し
//   GenerateExportInput.rasterAssets として渡す（ExportRequest.swift 冒頭コメント）
// - generateOutput は手順1〜4を SerialTaskQueue 経由の単一 op として実行する。途中の
//   どの段階が失敗しても（純粋関数の throw・render/encode/verify の throw・
//   recordGeneratedOutput の throw・利用者キャンセルのいずれも）catch-all で
//   exportSagaStore.discardExport を呼んでから元のエラーを再 throw する
//   （Global Constraints「エラーの握りつぶし禁止」）
// - discardExport は「やり直す」・利用者キャンセル用の公開 API。SerialTaskQueue 経由で
//   exportSagaStore.discardExport をそのまま呼ぶ薄いラッパー（discardExport は冪等。4章）
//
// reviewer 一次レビュー fix round 1 の反映:
// - Important 1: catch 内の後始末（discardExport）はキャンセル非伝播のコンテキスト
//   （非構造化 Task）で実行する。実ストアがキャンセルを尊重する実装だと、キャンセル済みの
//   コンテキストのまま呼ぶと後始末自体が中断されうるため
// - Important 2: queue.run 自体がキュー投入前/取り出し直前でキャンセルされる窓
//   （SerialTaskQueue.run の2つの checkCancellation）では performGeneration が一度も
//   走らず、内側の catch も発火しない。generateOutput 側の外側 catch でこの窓もカバーする
// - Important 3: recordGeneratedOutput 成功後は出力ファイル参照を temporaryFiles から除く。
//   discardExport は「対応する OutputRecord が存在すれば、その出力ファイルも同一
//   トランザクションで PendingFileDeletion へ登録する」契約のため、temporaryFiles に
//   残したまま渡すと同じファイル参照を二重登録しうる
// - Important 4: bitmapID 重複時に `Dictionary(uniqueKeysWithValues:)` で trap せず、
//   Domain の不整合検出方針（Rendering/Compile.swift の throw）に揃えて throw する
//
// reviewer 一次レビュー fix round 2 の反映（W1〜W3。詳細は各 doc コメント参照）:
// - W1: 外側 catch の discardExport も SerialTaskQueue 経由にする（architecture.md 4.2
//   「変更を伴うすべての操作は単一のグローバル直列キュー1本で直列化する」からの逸脱を解消）
// - W2: discardExport 自体が失敗しても、中断の真因（元エラー）を CleanupPreservingError
//   （Cleanup.swift。レビュー第2ラウンド A で共通ヘルパー化）で保持したまま優先して throw
//   する（真因が後始末の失敗にすり替わらないようにする）
// - W3: queue.run 自身のキャンセルチェックで performGeneration が一度も走らない経路を
//   ExportCoordinatorGenerateResilienceTests.swift へ追加

/// `GenerateExportInput.rasterAssets` の不整合（reviewer 指摘 Important 4）。
public enum GenerateExportInputError: Error, Sendable, Equatable {
    /// 異なる `StampRasterKey` に同一 bitmapID の `RasterizedStampAsset` が割り当てられていた
    case duplicateBitmapID(String)
}

extension ExportCoordinator {
    /// export-saga.md 3章 手順1〜4を実行する。途中のどの段階が失敗しても
    /// `exportSagaStore.discardExport` で後始末してから元のエラーを再 throw する（4章）。
    ///
    /// Issue #32 C-2: settleExport/settleBatch と同じ理由で、queue.run へ投入する前に
    /// 復旧ゲートを待つ（cold start で起動時異常終了の残存 ExportJob に対して復旧より先に
    /// generateOutput が到達しうるため。同一セッション内の開始経路ゲート済みだけでは
    /// 前回セッションの残存行を守れない）。
    public func generateOutput(_ input: GenerateExportInput) async throws {
        try await recoveryGate.awaitRecoveryCompleted()
        do {
            try await queue.run {
                try await self.performGeneration(input)
            }
        } catch {
            // queue.run 自身のキャンセルチェック（投入前・取り出し直前）でキャンセルされた
            // 場合、performGeneration が一度も実行されず内側の catch も走らない
            // （Important 2）。ExportJob 行は startExport で既に作成済みのため、ここでも
            // discardExport を呼び後始末する（discardExport は冪等。内側で既に discard 済み
            // でも二重呼び出しは無害）。
            //
            // 非対称性（W1）: ここは queue.run の op の外側にいる catch のため、後始末を
            // queue.run 経由に通しても自己デッドロックしない（performGeneration 内側の catch
            // は既に queue.run の op 内にいるため直接呼び出しのまま。次の読み手が「揃って
            // いない」と誤って直さないよう明記する）。architecture.md 4.2「変更を伴うすべての
            // 操作は単一のグローバル直列キュー1本で直列化する」を満たすため、ここは queue.run
            // 経由にする。
            try await runCleanupPreservingError(cause: error) {
                try await runShieldedFromCancellation {
                    try await self.queue.run {
                        try await self.exportSagaStore.discardExport(input.job.exportID, temporaryFiles: [])
                    }
                }
            }
        }
    }

    /// 「やり直す」・利用者によるキャンセル用の公開 API（export-saga.md 4章）。
    /// `exportSagaStore.discardExport` は冪等なため、同じ `exportID` への複数回呼び出しは
    /// エラーにならない。`temporaryFiles` は渡し忘れを型で検出できるよう既定値を持たない
    /// （呼び出し元が明示する。reviewer 指摘 Suggestion 1）。ゲートを待つ理由は
    /// generateOutput と同じ（Issue #32 C-2）。
    public func discardExport(_ exportID: ExportID, temporaryFiles: [ManagedFileRef]) async throws {
        try await recoveryGate.awaitRecoveryCompleted()
        try await queue.run {
            try await self.exportSagaStore.discardExport(exportID, temporaryFiles: temporaryFiles)
        }
    }

    /// 手順1〜4本体。失敗時は蓄積済みの `temporaryFiles`（手順1〜3で生成した一時ファイルの
    /// 参照。export-saga.md 4章）を添えて discardExport を呼び、元のエラーを再 throw する。
    private func performGeneration(_ input: GenerateExportInput) async throws {
        var temporaryFiles: [ManagedFileRef] = []
        do {
            let draft = try compileRenderDraft(
                spec: input.renderSpec, sourceSize: input.sourceSize, targetSize: input.targetSize
            )
            let plan = try bindRasterAssets(draft: draft, assets: input.rasterAssets)
            let renderRasterAssets = try bitmapIDKeyedRasterAssets(input.rasterAssets)

            let rendered = try await imageEffectRenderer.render(
                source: input.imageSource, plan: plan, rasterAssets: renderRasterAssets
            )
            // 一時ファイルは生成された直後に積む（この後の checkCancellation で throw しても
            // discardExport の対象に含める。決定済みの設計判断5）。
            temporaryFiles.append(rendered.file.ref)
            try Task.checkCancellation()

            let outputFileRef = try await imageEncoder.encode(
                rendered,
                format: input.exportSetting.outputFormat,
                quality: input.exportSetting.compressionQuality,
                metadata: input.metadata
            )
            temporaryFiles.append(outputFileRef.ref)
            try Task.checkCancellation()

            let measurement = try await outputFileVerifier.verify(outputFileRef)
            try Task.checkCancellation()

            try await exportSagaStore.recordGeneratedOutput(RecordOutputInput(
                exportID: input.job.exportID,
                outputFile: outputFileRef,
                outputByteSize: measurement.byteSize,
                outputSHA256: measurement.sha256
            ))
            // OutputRecord が出力ファイルの参照を保持するようになったため、discardExport が
            // 二重登録しないよう temporaryFiles から取り除く（Important 3）
            temporaryFiles.removeAll { $0 == outputFileRef.ref }
            // 一方 rendered.file.ref（.rasterTemporary）は成功パスでは意図的にどこにも
            // 登録しない。参照元を持たない .rasterTemporary は次回起動をまたいでも孤児として
            // 削除してよい（architecture.md 7.5「孤児ファイルのGC」）ため、消し忘れではない
            // （reviewer 指摘 Suggestion 2）。
            try Task.checkCancellation()
        } catch {
            // var の temporaryFiles をそのまま @Sendable クロージャへ渡せないため、
            // 呼び出し直前に不変のスナップショットへ写す。
            let temporaryFilesSnapshot = temporaryFiles
            // 非対称性（W1）: ここは既に queue.run の op 内で実行されているため、
            // discardExport を queue.run 経由で呼ぶと自己デッドロックする。直接呼び出しの
            // ままにする（generateOutput 側の外側 catch とは対称にしない）。
            try await runCleanupPreservingError(cause: error) {
                try await runShieldedFromCancellation {
                    try await self.exportSagaStore.discardExport(
                        input.job.exportID, temporaryFiles: temporaryFilesSnapshot
                    )
                }
            }
        }
    }

    /// `ImageEffectRenderer.render` の `rasterAssets` 引数は bitmapID キーの辞書
    /// （image-pipeline.md「プロトコルのシグネチャ」節）。`GenerateExportInput.rasterAssets`
    /// は `StampRasterKey` キーのため、呼び出し前に詰め替える（決定済みの設計判断6）。
    /// 異なる `StampRasterKey` が同一 bitmapID を持つ入力は不整合として throw する
    /// （`Dictionary(uniqueKeysWithValues:)` は重複キーで trap するため使わない。Important 4）。
    private func bitmapIDKeyedRasterAssets(
        _ rasterAssets: [StampRasterKey: RasterizedStampAsset]
    ) throws -> [String: RasterizedStampAsset] {
        var result: [String: RasterizedStampAsset] = [:]
        for asset in rasterAssets.values {
            guard result.updateValue(asset, forKey: asset.bitmapID) == nil else {
                throw GenerateExportInputError.duplicateBitmapID(asset.bitmapID)
            }
        }
        return result
    }
}
