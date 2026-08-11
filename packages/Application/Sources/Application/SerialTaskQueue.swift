// architecture.md 4.2「排他区間の実装規則」が定めるグローバル直列実行キューの実装。
//
// actor は再入可能であり、単独では「読み取りから保存完了まで」の論理的クリティカルセクションを
// 保持できない（`await` で中断すると同じ actor への別の呼び出しが割り込みうる）。このため
// `SerialTaskQueue` は actor の isolation を排他の根拠にせず、`Task` の連結（チェーン）で
// 直列性を保証する: `run` の呼び出しごとに「直前の `run` の完了を待ってから `op` を実行する」
// `Task` を作り、`tail` へ差し替える。`tail` の読み取りと更新の間に `await` を挟まないため、
// 並列に投入された複数の `run` 呼び出しも、actor に到達した順でチェーンへ連結される（FIFO）。
//
// v1 は並列数 1 固定。exportID 別・projectID 別の個別キューは持たない
// （すべての変更系 Coordinator がこの 1 本を共有する。4.3「排他の単位」）。

public actor SerialTaskQueue {
    /// 直前に連結した `run` 呼び出しの完了を表す。`op` の失敗（`CancellationError` を含む）を
    /// 後続の実行がブロックされる理由にしないため、失敗を保持しない `Task<Void, Never>` にしている
    /// （tail 自体は失敗を握らず完了だけを次へ伝える）。
    private var tail: Task<Void, Never>?

    public init() {}

    /// `op` を直列キューへ投入し、実行完了まで待って結果を返す。
    ///
    /// 直前に投入された `op` の完了（成功・失敗のどちらでも）を待ってから、この `op` を実行する。
    /// 直前の `op` が throw しても、この呼び出しの実行はその影響を受けない（後続を巻き込まない）。
    /// この呼び出し自身の `op` が throw した場合は、そのエラーをそのまま呼び出し元へ伝える。
    ///
    /// キャンセルチェック（architecture.md 4.2 の「キュー投入前」「取り出して処理を開始する直前」の
    /// 2 箇所）はこの関数自身が担う。`op` は非構造化 `Task`（`current`）の中で実行されるため
    /// 呼び出し元のキャンセルを自動では継承しない。そこで `withTaskCancellationHandler` を使い、
    /// 呼び出し元（`run` を `await` しているタスク）がキャンセルされたら `current.cancel()` で
    /// `current` 側へ明示的に伝播させる:
    /// - まだキューに投入していない時点でキャンセルされていれば、投入前の
    ///   `Task.checkCancellation()` が `CancellationError` を throw し、`op` は実行されない。
    /// - 直前の `op`（`previousTail`）の完了待ち中にキャンセルされた場合は、取り出して処理を
    ///   開始する直前の `Task.checkCancellation()` が `op` の実行前に検出する。
    /// - `op` の実行が既に始まっている場合、`current.cancel()` は `op` を強制中断しない。
    ///   `op` の内部から見た `Task.isCancelled` が true になるだけであり、それを見て早期
    ///   リターン・throw するかどうかは `op` 自身（呼び出し側）の責務のままである。
    ///
    /// 呼び出し元のキャンセルは `current` にのみ伝わり、キューに連結された後続の `op` の
    /// 実行を妨げない（`tail` は `current` の失敗〈キャンセルを含む〉を握らず完了だけを
    /// 次へ伝えるため）。
    public func run<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) async throws -> T {
        try Task.checkCancellation() // 4.2「キュー投入前」
        let previousTail = tail

        let current = Task<T, Error> {
            _ = await previousTail?.value
            try Task.checkCancellation() // 4.2「取り出して処理を開始する直前」
            return try await op()
        }

        tail = Task<Void, Never> {
            _ = try? await current.value
        }

        return try await withTaskCancellationHandler {
            try await current.value
        } onCancel: {
            current.cancel()
        }
    }
}
