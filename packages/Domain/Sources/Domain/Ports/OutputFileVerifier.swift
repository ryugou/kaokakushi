import Foundation

// OutputFileVerifier — 本計画で新設するポート（正本の image-pipeline.md /
// export-saga.md / architecture.md いずれにも存在しない）。
//
// export-saga.md 3章「手順」の手順3（健全性確認: 存在確認・サイズ0でないこと・簡易デコード
// 成功の確認。いずれかが不成立なら手順4へ進まず中断として扱う）と、手順4の入力である
// `RecordOutputInput`（ExportSagaStore.swift）が要求する `outputByteSize` / `outputSHA256`
// を1回のファイル走査で賄うために新設する。
//
// `byteSize` / `sha256` は `RecordOutputInput.outputByteSize` / `outputSHA256` と同型
// （`Int64` / `Data`）にし、呼び出し側がそのまま `RecordOutputInput` へ詰め替えられるように
// する。`RecordOutputInput` はバイト列を含み値としての比較用途が正本コードブロックに無いため
// `Equatable` を追加していない（ExportSagaStore.swift の判断）。同じ判断を踏襲し、
// `VerifiedOutputMeasurement` にも `Equatable` を追加しない。
//
// アクセス修飾（public）の方針は ExportSagaStore.swift と同じ。

/// 出力ファイルの健全性を確認し、記録用の測定値を返す（export-saga.md 3章「手順3」を1回の
/// 走査で賄う、本計画の新設ポート）。存在確認・サイズ0でないこと・簡易デコード成功の
/// いずれかが不成立なら throw する（手順4 `recordGeneratedOutput` へ進めない）。
public protocol OutputFileVerifier: Sendable {
    func verify(_ file: OutputFileRef) async throws -> VerifiedOutputMeasurement
}

/// `OutputFileVerifier.verify` の測定結果（本計画の新設ポート）。
public struct VerifiedOutputMeasurement: Sendable {
    public let byteSize: Int64
    public let sha256: Data

    public init(byteSize: Int64, sha256: Data) {
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}
