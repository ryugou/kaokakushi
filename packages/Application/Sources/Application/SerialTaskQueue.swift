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
    /// 2 箇所）はこの関数の責務ではない。呼び出し側（Application の各 Coordinator）が、
    /// 投入前の判断と `op` 冒頭での `Task.checkCancellation()` を担う。
    public func run<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) async throws -> T {
        let previousTail = tail

        let current = Task<T, Error> {
            _ = await previousTail?.value
            return try await op()
        }

        tail = Task<Void, Never> {
            _ = try? await current.value
        }

        return try await current.value
    }
}
