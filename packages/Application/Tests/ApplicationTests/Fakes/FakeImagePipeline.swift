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
// FakeImageEffectRenderer / FakeImageEncoder / FakeStampRasterizer は戻り値が未設定のまま
// 呼び出されたら `FakeNotConfiguredError` を throw する（黙って恣意的な値を返すと、テストの
// 意図しない成功を見逃す）。FakeOutputFileVerifier は正本の `verify` が typed throws
// （`OutputFileVerificationError` 以外を throw できない）のため同じパターンを適用できず、
// 代わりに `defaultOutcome` を init で必須化して「未設定」という状態自体を型で排除する
// （swift-testing はインプロセス実行のため、以前の preconditionFailure はテストプロセス全体を
// 落としてしまっていた。Task 3 レビュー Suggestion 1 の決定）。SharePresenter.share /
// StampCatalog.requirement は正本の元シグネチャが non-throwing なため、このパターンは適用しない
// （SharePresenter は `.unknown` を安全側の既定値にし、StampCatalog は未登録なら nil を返す。
// いずれも doc コメントに明記された正規の戻り値であり、恣意的な合成ではない）。
//
// Fakes 配下の型はテストターゲット外から参照されないため internal で足りる
// （DomainTests/TestSupport.swift と同じ方針。Task 3 レビュー Suggestion 2）。

/// テストが戻り値・結果を設定し忘れたまま偽実装を呼び出したことを示す。
/// internal 化（Suggestion 2）に伴い、メンバーワイズイニシャライザが自動合成されるため
/// 明示的な init は定義しない（swiftlint unneeded_synthesized_initializer）。
struct FakeNotConfiguredError: Error, Sendable, Equatable {
    let fakeTypeName: String
    let methodName: String
}

// MARK: - FakeImageEffectRenderer

struct FakeRenderCall: Sendable {
    let source: ImageSource
    let plan: RenderPlan
    let rasterAssets: [String: RasterizedStampAsset]
}

actor FakeImageEffectRenderer: ImageEffectRenderer {
    private(set) var calls: [FakeRenderCall] = []
    var failure: Error?
    var result: RenderedImage?
    /// 直列化検証用の遅延注入（Issue #7 Task 5「ExportCoordinator.generateOutput が
    /// SerialTaskQueue 経由で直列化されること」の検証で、同時実行の観測窓を作るために使う。
    /// 未設定なら遅延なし（既存の振る舞いを変えない）
    var delayNanoseconds: UInt64?
    /// render 呼び出しの同時実行数。SerialTaskQueue が正しく機能していれば常に 1 のままになる
    private var activeCallCount = 0
    private(set) var maxObservedConcurrency = 0

    init() {}

    // MARK: - 失敗・結果注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setFailure(_ value: Error?) { failure = value }
    func setResult(_ value: RenderedImage?) { result = value }
    func setDelayNanoseconds(_ value: UInt64?) { delayNanoseconds = value }

    func render(
        source: ImageSource,
        plan: RenderPlan,
        rasterAssets: [String: RasterizedStampAsset]
    ) async throws -> RenderedImage {
        calls.append(FakeRenderCall(source: source, plan: plan, rasterAssets: rasterAssets))
        activeCallCount += 1
        maxObservedConcurrency = max(maxObservedConcurrency, activeCallCount)
        defer { activeCallCount -= 1 }
        if let delayNanoseconds {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let failure { throw failure }
        guard let result else {
            throw FakeNotConfiguredError(fakeTypeName: "FakeImageEffectRenderer", methodName: "render")
        }
        return result
    }
}

// MARK: - FakeImageEncoder

struct FakeEncodeCall: Sendable {
    let image: RenderedImage
    let format: ImageFormat
    let quality: Double
    let metadata: OutputMetadata
}

actor FakeImageEncoder: ImageEncoder {
    private(set) var calls: [FakeEncodeCall] = []
    var failure: Error?
    var result: OutputFileRef?

    init() {}

    // MARK: - 失敗・結果注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setFailure(_ value: Error?) { failure = value }
    func setResult(_ value: OutputFileRef?) { result = value }

    func encode(
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

actor FakeOutputFileVerifier: OutputFileVerifier {
    /// verify の1回分の結果。`.verificationFailure` で `OutputFileVerificationError` の
    /// 全ケース（.missing / .emptyFile / .undecodable / .ioFailure）を個別に注入できる
    /// （Task 6 の .ioFailure と実体喪失系の区別テストに必要）
    enum Outcome: Sendable {
        case success(VerifiedOutputMeasurement)
        case verificationFailure(OutputFileVerificationError)
    }

    private(set) var calls: [OutputFileRef] = []
    /// OutputFileRef ごとに結果を差し替えられる
    var outcomes: [OutputFileRef: Outcome] = [:]
    /// outcomes に未登録の OutputFileRef が渡されたときに使う既定値。init で必須化することで
    /// 「未設定」という状態自体を型で起こりえなくする（Task 3 レビュー Suggestion 1）
    var defaultOutcome: Outcome

    init(defaultOutcome: Outcome) {
        self.defaultOutcome = defaultOutcome
    }

    // MARK: - 結果注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setOutcomes(_ value: [OutputFileRef: Outcome]) { outcomes = value }
    func setDefaultOutcome(_ value: Outcome) { defaultOutcome = value }

    func verify(_ file: OutputFileRef) async throws(OutputFileVerificationError) -> VerifiedOutputMeasurement {
        calls.append(file)
        switch outcomes[file] ?? defaultOutcome {
        case .success(let measurement):
            return measurement
        case .verificationFailure(let error):
            throw error
        }
    }
}

// MARK: - FakeStampRasterizer

actor FakeStampRasterizer: StampRasterizer {
    private(set) var calls: [Set<StampRasterKey>] = []
    var failure: Error?
    var result: [StampRasterKey: RasterizedStampAsset]?

    init() {}

    // MARK: - 失敗・結果注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setFailure(_ value: Error?) { failure = value }
    func setResult(_ value: [StampRasterKey: RasterizedStampAsset]?) { result = value }

    func rasterize(_ keys: Set<StampRasterKey>) async throws -> [StampRasterKey: RasterizedStampAsset] {
        calls.append(keys)
        if let failure { throw failure }
        guard let result else {
            throw FakeNotConfiguredError(fakeTypeName: "FakeStampRasterizer", methodName: "rasterize")
        }
        return result
    }
}

// MARK: - FakePickedPhotoLoader

/// `PickedPhotoLoader`（image-pipeline.md 5章「プロトコルのシグネチャ」）の偽実装
/// （Issue #8 サブプロジェクト5 A2 Task 2。SourceImportCoordinator が使う）。
///
/// 他の画像処理ポートの偽実装（FakeImageEffectRenderer 等）と異なり、戻り値は
/// `makeLoadedPhoto()`（SourceImportTestSupport.swift）を既定値とする。`load` は入力の解釈に選択肢が無い
/// 単純な委譲であり、未設定を「意図しない成功の見逃し」として検出する価値が薄い一方、
/// SourceImportCoordinator の Saga 進行（手順3以降）を検証する大半のテストは load の戻り値
/// そのものに関心が無いため、明示的な設定なしで成功させられる方が読みやすい。
actor FakePickedPhotoLoader: PickedPhotoLoader {
    private(set) var loadCalls: [ManagedFileRef] = []
    var failure: Error?
    var result: LoadedPhoto

    init(result: LoadedPhoto = makeLoadedPhoto()) {
        self.result = result
    }

    // MARK: - 失敗・結果注入セッター（actor 隔離のため外部から直接代入できない）

    func setFailure(_ value: Error?) { failure = value }
    func setResult(_ value: LoadedPhoto) { result = value }

    func load(_ file: ManagedFileRef) async throws -> LoadedPhoto {
        loadCalls.append(file)
        if let failure { throw failure }
        return result
    }
}

// MARK: - FakeMediaSaver

actor FakeMediaSaver: MediaSaver {
    private(set) var calls: [OutputFile] = []
    /// 注入可能な失敗。設定しなければ常に成功する（MediaSaver.saveToPhotoLibrary は戻り値を
    /// 持たないため「未設定」を区別する必要が無い）
    var failure: Error?
    /// 呼び出し中に足止めするゲート。設定しなければ足止めしない。テストが呼び出しの
    /// 実行中（`await gate.wait()` で中断している間）に外側の Task をキャンセルしてから
    /// `open()` する猶予を、`Task.sleep` の固定時間待ちより決定的に作るためのフック
    /// （Issue #7 レビュー第2ラウンド S-1。`gate.wait()` はキャンセルの影響を受けない
    /// `withCheckedContinuation` のため、キャンセル後も `open()` まで確実に中断し続ける）。
    var gate: OneShotGate?

    init() {}

    // MARK: - 失敗注入セッター（actor 隔離のため外部から直接代入できない。Issue #7 Task 4 準備）

    func setFailure(_ value: Error?) { failure = value }
    func setGate(_ value: OneShotGate?) { gate = value }

    func saveToPhotoLibrary(_ file: OutputFile) async throws {
        calls.append(file)
        if let gate {
            await gate.wait()
        }
        if let failure { throw failure }
    }
}

// MARK: - FakeSharePresenter

/// `SharePresenter`（image-pipeline.md「@MainActor のプロトコル」節）は `@MainActor` の
/// `AnyObject` プロトコルのため actor ではなくクラスで実装する。
@MainActor
final class FakeSharePresenter: SharePresenter {
    private(set) var calls: [OutputFile] = []
    /// doc コメントの「安全側へ倒す」に合わせ、既定値は `.unknown`
    /// （share は non-throwing のため failure 注入は無く、この戻り値が唯一の注入経路）
    var result: ShareResult = .unknown

    init() {}

    func share(_ file: OutputFile) async -> ShareResult {
        calls.append(file)
        return result
    }
}

// MARK: - FakeStampCatalog

/// `StampCatalog` は同期・non-throwing のプロトコルのため actor にできない（actor の隔離
/// メソッドは呼び出し側に await を要求してしまい、プロトコルのシグネチャと一致しない）。
/// 呼び出し記録・登録済み要件は lock で保護し `@unchecked Sendable` にする
/// （DomainTests の FakeSha256Digest と同じ方針）。
final class FakeStampCatalog: StampCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var requirementsByCode: [String: StampRequirement]
    private var recordedCalls: [String] = []

    init(requirementsByCode: [String: StampRequirement] = [:]) {
        self.requirementsByCode = requirementsByCode
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    /// テストが個々の組み込みコードの分類を登録する。未登録のコードは nil を返す
    /// （`requirement(forBuiltIn:)` の戻り値の型どおりの正規の「未知」表現であり、恣意的な
    /// デフォルト値ではない）
    func setRequirement(_ requirement: StampRequirement?, forBuiltIn code: String) {
        lock.lock()
        defer { lock.unlock() }
        requirementsByCode[code] = requirement
    }

    func requirement(forBuiltIn code: String) -> StampRequirement? {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(code)
        return requirementsByCode[code]
    }
}
