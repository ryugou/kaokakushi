"use client"

import { Check, Crown } from "lucide-react"

import {
  BATCH_MAX_ITEMS,
  FREE_MONTHLY_LIMIT,
  TRIAL_CREDITS,
  useApp,
  type Plan,
  type UpgradeReason,
} from "@/components/app-provider"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

type Copy = {
  target: Exclude<Plan, "free">
  title: string
  body: string
  primary: string
  benefits: string[]
  /** 課金訴求ではなく、仕様上の上限を伝えるだけの通知 */
  notice?: boolean
}

function buildCopy(reason: UpgradeReason): Copy {
  switch (reason) {
    case "export-limit":
      return {
        target: "standard",
        title: "今月の無料保存を使い切りました",
        body: "Standardなら、写真を1枚ずつ無制限で保存できます。",
        primary: "月300円で無制限にする",
        benefits: [
          "1枚ずつの書き出しが無制限になります",
          "広告が表示されません",
          "追加スタンプとマイスタンプが使えます",
        ],
      }
    case "premium-stamp":
      return {
        target: "standard",
        title: "追加スタンプを使えます",
        body: "Standardなら、すべての追加スタンプを利用できます。",
        primary: "Standardを確認する",
        benefits: [
          "かわいい・動物・季節などの追加スタンプ",
          "マイスタンプも登録できます",
          "基本スタンプはFreeでもそのまま使えます",
        ],
      }
    case "custom-stamp":
      return {
        target: "standard",
        title: "自分だけのスタンプを作れます",
        body: "Standardなら、端末内の画像を自分専用のスタンプとして登録できます。",
        primary: "Standardを確認する",
        benefits: ["写真やPNGからスタンプを作成", "最大100個まで登録できます", "追加スタンプもすべて使えます"],
      }
    // お試し枠を使い切った（5枚まで。ADR 0006により素材の同一性は問わない）
    case "batch-credit":
      return {
        target: "pro",
        title: `お試しの${TRIAL_CREDITS}枚を使い切りました`,
        body: `お試しで処理できるのは合計${TRIAL_CREDITS}枚までです。Proなら1回で最大${BATCH_MAX_ITEMS}枚をまとめて処理できます。`,
        primary: "Proを確認する",
        benefits: [
          `1回で最大${BATCH_MAX_ITEMS}枚、まとめて片づきます`,
          "一覧で見渡して、注意が必要な写真だけ直せます",
          "確認済みの写真は自動で進みます",
        ],
      }
    // お試し枠の総枚数を超えた。すべて消費済みの写真でも発火する
    case "batch-size":
      return {
        target: "pro",
        title: `お試しでは一度に${TRIAL_CREDITS}枚までです`,
        body: `一度に選べるのは${TRIAL_CREDITS}枚までです。Proなら最大${BATCH_MAX_ITEMS}枚をまとめて処理できます。`,
        primary: "Proを確認する",
        benefits: [
          `1回の一括処理で最大${BATCH_MAX_ITEMS}枚`,
          "一覧で仕上がりを見渡し、注意が必要な写真だけ直せます",
          "失敗した写真だけあとから再試行できます",
        ],
      }
    // Pro が 1 バッチの上限を超えた。課金訴求ではなく仕様上の通知
    case "batch-limit":
      return {
        target: "pro",
        notice: true,
        title: "選べる枚数の上限です",
        body: `1回の一括処理では最大${BATCH_MAX_ITEMS}枚まで選べます。`,
        primary: "わかりました",
        benefits: [
          "残りの写真は次のバッチとして処理できます",
          "確認済みの写真は自動で進みます",
          "失敗した写真だけあとから再試行できます",
        ],
      }
    case "edit-locked":
      return {
        target: "standard",
        title: "編集にはStandardが必要です",
        body: "このプロジェクトはそのまま書き出せます。編集するにはStandardが必要です。",
        primary: "Standardを確認する",
        benefits: [
          "変更せずに書き出すだけならFreeのままできます",
          "追加スタンプとマイスタンプを新しい写真へ使えます",
          "1枚ずつの書き出しが無制限になります",
        ],
      }
  }
}

export function UpgradeModal() {
  const { upgrade, closeUpgrade, go } = useApp()
  const info = upgrade ? buildCopy(upgrade.reason) : null

  return (
    <Dialog open={upgrade !== null} onOpenChange={(open) => (!open ? closeUpgrade() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        {info ? (
          <>
            <DialogHeader>
              <span className="flex size-11 items-center justify-center rounded-2xl bg-chart-3/20 text-foreground">
                <Crown className="size-5" aria-hidden />
              </span>
              <DialogTitle className="font-rounded text-lg leading-snug text-pretty">{info.title}</DialogTitle>
              <DialogDescription className="leading-relaxed">
                {upgrade?.detail ? `${upgrade.detail} ` : ""}
                {info.body}
              </DialogDescription>
            </DialogHeader>
            <ul className="flex flex-col gap-2">
              {info.benefits.map((b) => (
                <li key={b} className="flex items-start gap-2 text-sm">
                  <Check className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden />
                  <span className="leading-relaxed">{b}</span>
                </li>
              ))}
            </ul>
            {upgrade?.reason === "export-limit" ? (
              <p className="rounded-2xl bg-secondary px-3 py-2.5 text-[11px] leading-relaxed text-secondary-foreground">
                無料プランは月{FREE_MONTHLY_LIMIT}枚まで保存できます。残り枚数は毎月1日にもどります。
              </p>
            ) : null}
            <div className="flex flex-col gap-2">
              <Button
                size="lg"
                className="h-12 rounded-2xl text-sm font-bold"
                onClick={() => {
                  closeUpgrade()
                  if (!info.notice) go("pricing")
                }}
              >
                {info.primary}
              </Button>
              {/* 上限の通知にはアップグレード誘導を付けない */}
              {!info.notice ? (
                <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={closeUpgrade}>
                  今はやめる
                </Button>
              ) : null}
            </div>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
