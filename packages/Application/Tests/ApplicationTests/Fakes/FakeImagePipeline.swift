import Foundation
import Domain

// FakeImageEffectRenderer / FakeImageEncoder / FakeOutputFileVerifier / FakeStampRasterizer /
// FakeMediaSaver / FakeSharePresenter / FakeStampCatalog — Domain の画像処理・受け渡し・
// スタンプ関連ポートの in-memory 偽実装（Issue #7 Task 3）。
//
// 正本は各ポート宣言の doc コメント（Ports/ImagePipeline.swift・Ports/OutputPresentation.swift・
// Ports/OutputFileVerifier.swift・Rendering/StampRasterizer.swift・Accounting/ExportAuthorization.swift
// の StampCatalog）。実装は別サブプロジェクト（MediaKit）の担当であり、変換ロジックの正本が
// 存在しないため、戻り値は恣意的なデフォルトを合成せずテストに注入させる。
//
// FakeImageEffectRenderer / FakeImageEncoder / FakeStampRasterizer / FakeOutputFileVerifier は
// 戻り値が未設定のまま呼び出されたら `FakeNotConfiguredError` を throw する（黙って恣意的な
// 値を返すと、テストの意図しない成功を見逃す）。SharePresenter.share / StampCatalog.requirement
// は正本の元シグネチャが non-throwing なため、このパターンは適用しない
// （SharePresenter は `.unknown` を安全側の既定値にし、StampCatalog は未登録なら nil を返す。
// いずれも doc コメントに明記された正規の戻り値であり、恣意的な合成ではない）。

/// テストが戻り値・結果を設定し忘れたまま偽実装を呼び出したことを示す。
public struct FakeNotConfiguredError: Error, Sendable, Equatable {
    public let fakeTypeName: String
    public let methodName: String

    public init(fakeTypeName: String, methodName: String) {
        self.fakeTypeName = fakeTypeName
        self.methodName = methodName
    }
}

// MARK: - FakeImageEffectRenderer

public struct FakeRenderCall: Sendable {
    public let source: ImageSource
    public let plan: RenderPlan
    public let rasterAssets: [String: RasterizedStampAsset]
}

public actor FakeImageEffectRenderer: ImageEffectRenderer {
    public private(set) var calls: [FakeRenderCall] = []
    public var failure: Error?
    public var result: RenderedImage?

    public init() {}

    public func render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]
    ) async throws -> RenderedImage {
        calls.append(FakeRenderCall(source: source, plan: plan, rasterAssets: rasterAssets))
        if let failure { throw failure }
        guard let result else {
            throw FakeNotConfiguredError(fakeTypeName: "FakeImageEffectRenderer", methodName: "render")
        }
        return result
    }
}

// MARK: - FakeImageEncoder

public struct FakeEncodeCall: Sendable {
    public let image: RenderedImage
    public let format: ImageFormat
    public let quality: Double
    public let metadata: OutputMetadata
}

public actor FakeImageEncoder: ImageEncoder {
    public private(set) var calls: [FakeEncodeCall] = []
    public var failure: Error?
    public var result: OutputFileRef?

    public init() {}

    public func encode(
        _ image: RenderedImage,
        format: ImageFormat,
        quality: Double,
        metadata: OutputMetadata
    ) async throws -> OutputFileRef {
        calls.append(FakeEncodeCall(image: image, format: format, quality: quality, metadata: metadata))
        if let failure { throw failure }
        guard let result else {
            throw FakeNotConfiguredError(fakeTypeName: "FakeImageEncoder", methodName: "encode")
        }
        return result
    }
}

// MARK: - FakeOutputFileVerifier

public actor FakeOutputFileVerifier: OutputFileVerifier {
    /// verify の1回分の結果。`.verificationFailure` で `OutputFileVerificationError` の
    /// 全ケース（.missing / .emptyFile / .undecodable / .ioFailure）を個別に注入できる
    /// （Task 6 の .ioFailure と実体喪失系の区別テストに必要）
    public enum Outcome: Sendable {
        case success(VerifiedOutputMeasurement)
        case verificationFailure(OutputFileVerificationError)
    }

    public private(set) var calls: [OutputFileRef] = []
    /// OutputFileRef ごとに結果を差し替えられる
    public var outcomes: [OutputFileRef: Outcome] = [:]
    /// outcomes に未登録の OutputFileRef が渡されたときに使う既定値
    public var defaultOutcome: Outcome?

    public init() {}

    public func verify(_ file: OutputFileRef) async throws(OutputFileVerificationError) -> VerifiedOutputMeasurement {
        calls.append(file)
        guard let outcome = outcomes[file] ?? defaultOutcome else {
            // typed throws のため FakeNotConfiguredError を投げられない。設定忘れは
            // プログラマエラーとして即停止する（オーケストレーター確定判断）
            preconditionFailure("FakeOutputFileVerifier.verify: outcomes/defaultOutcome が未設定")
        }
        switch outcome {
        case .success(let measurement):
            return measurement
        case .verificationFailure(let error):
            throw error
        }
    }
}

// MARK: - FakeStampRasterizer

public actor FakeStampRasterizer: StampRasterizer {
    public private(set) var calls: [Set<StampRasterKey>] = []
    public var failure: Error?
    public var result: [StampRasterKey: RasterizedStampAsset]?

    public init() {}

    public func rasterize(_ keys: Set<StampRasterKey>) async throws -> [StampRasterKey: RasterizedStampAsset] {
        calls.append(keys)
        if let failure { throw failure }
        guard let result else {
            throw FakeNotConfiguredError(fakeTypeName: "FakeStampRasterizer", methodName: "rasterize")
        }
        return result
    }
}

// MARK: - FakeMediaSaver

public actor FakeMediaSaver: MediaSaver {
    public private(set) var calls: [OutputFile] = []
    /// 注入可能な失敗。設定しなければ常に成功する（MediaSaver.saveToPhotoLibrary は戻り値を
    /// 持たないため「未設定」を区別する必要が無い）
    public var failure: Error?

    public init() {}

    public func saveToPhotoLibrary(_ file: OutputFile) async throws {
        calls.append(file)
        if let failure { throw failure }
    }
}

// MARK: - FakeSharePresenter

/// `SharePresenter`（image-pipeline.md「@MainActor のプロトコル」節）は `@MainActor` の
/// `AnyObject` プロトコルのため actor ではなくクラスで実装する。
@MainActor
public final class FakeSharePresenter: SharePresenter {
    public private(set) var calls: [OutputFile] = []
    /// doc コメントの「安全側へ倒す」に合わせ、既定値は `.unknown`
    /// （share は non-throwing のため failure 注入は無く、この戻り値が唯一の注入経路）
    public var result: ShareResult = .unknown

    public init() {}

    public func share(_ file: OutputFile) async -> ShareResult {
        calls.append(file)
        return result
    }
}

// MARK: - FakeStampCatalog

/// `StampCatalog` は同期・non-throwing のプロトコルのため actor にできない（actor の隔離
/// メソッドは呼び出し側に await を要求してしまい、プロトコルのシグネチャと一致しない）。
/// 呼び出し記録・登録済み要件は lock で保護し `@unchecked Sendable` にする
/// （DomainTests の FakeSha256Digest と同じ方針）。
public final class FakeStampCatalog: StampCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var requirementsByCode: [String: StampRequirement]
    private var recordedCalls: [String] = []

    public init(requirementsByCode: [String: StampRequirement] = [:]) {
        self.requirementsByCode = requirementsByCode
    }

    public var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    /// テストが個々の組み込みコードの分類を登録する。未登録のコードは nil を返す
    /// （`requirement(forBuiltIn:)` の戻り値の型どおりの正規の「未知」表現であり、恣意的な
    /// デフォルト値ではない）
    public func setRequirement(_ requirement: StampRequirement?, forBuiltIn code: String) {
        lock.lock()
        defer { lock.unlock() }
        requirementsByCode[code] = requirement
    }

    public func requirement(forBuiltIn code: String) -> StampRequirement? {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(code)
        return requirementsByCode[code]
    }
}
