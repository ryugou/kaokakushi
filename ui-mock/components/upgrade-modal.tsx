"use client"

import { Check, Crown } from "lucide-react"

import { FREE_MONTHLY_LIMIT, useApp, type Plan, type UpgradeReason } from "@/components/app-provider"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

type Copy = {
  target: Exclude<Plan, "free">
  title: string
  body: string
  primary: string
  benefits: string[]
}

function buildCopy(reason: UpgradeReason, plan: Plan): Copy {
  switch (reason) {
    case "export-limit":
      return {
        target: "standard",
        title: "今月の無料保存を使い切りました",
        body: "Standardなら、写真も動画も1件ずつ無制限で保存できます。",
        primary: "月300円で無制限にする",
        benefits: [
          "単体書き出しが無制限になります",
          "広告が表示されません",
          "動画は1件あたり最大5分まで加工できます",
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
          "自作スタンプも登録できます",
          "基本スタンプはFreeでもそのまま使えます",
        ],
      }
    case "custom-stamp":
      return {
        target: "standard",
        title: "自分だけのスタンプを作れます",
        body: "Standardなら、端末内の画像を自分専用のスタンプとして登録できます。",
        primary: "Standardを確認する",
        benefits: ["絵柄・かたち・色をえらんで作成", "いくつでも保存できます", "追加スタンプもすべて使えます"],
      }
    case "batch":
      return {
        target: "pro",
        title: "まとめて加工できます",
        body: "Proなら、複数の写真や動画をまとめて加工・保存できます。",
        primary: "Proを確認する",
        benefits: [
          "1回の一括処理で最大50素材",
          "処理キューで素材ごとの進捗を確認",
          "一部が失敗しても残りの処理を続けます",
        ],
      }
    case "long-video":
      return plan === "free"
        ? {
            target: "standard",
            title: "長い動画も加工できます",
            body: "無料プランは60秒までです。Standardでは最大5分、Proでは最大30分の動画に対応しています。",
            primary: "Standardを確認する",
            benefits: ["Standardは1件あたり最大5分", "Proは1件あたり最大30分", "顔の動きを追いかけて隠します"],
          }
        : {
            target: "pro",
            title: "もっと長い動画に対応します",
            body: "Standardは5分までです。Proでは最大30分の動画に対応しています。",
            primary: "Proを確認する",
            benefits: ["1件あたり最大30分の動画", "複数の動画をまとめて処理", "対応端末では4K書き出し"],
          }
    case "export-4k":
      return {
        target: "pro",
        title: "4Kで書き出せます",
        body: "Proでは、対応端末で4K書き出しを利用できます。",
        primary: "Proを確認する",
        benefits: ["対応端末で4K出力", "FreeとStandardは最大1080p", "一括処理でも同じ設定を適用できます"],
      }
  }
}

export function UpgradeModal() {
  const { upgrade, closeUpgrade, go, plan } = useApp()
  const info = upgrade ? buildCopy(upgrade.reason, plan) : null

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
                無料プランは月{FREE_MONTHLY_LIMIT}件まで保存できます。残り件数は毎月1日にもどります。
              </p>
            ) : null}
            <div className="flex flex-col gap-2">
              <Button
                size="lg"
                className="h-12 rounded-2xl text-sm font-bold"
                onClick={() => {
                  closeUpgrade()
                  go("pricing")
                }}
              >
                {info.primary}
              </Button>
              <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={closeUpgrade}>
                今はやめる
              </Button>
            </div>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
