"use client"

import { Check, Crown, Layers, Minus } from "lucide-react"

import { cn } from "@/lib/utils"
import { FREE_MONTHLY_LIMIT, useApp, type Plan } from "@/components/app-provider"
import { PrivacyNote, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"

type PlanCard = {
  id: Plan
  name: string
  price: string
  note: string
  lead: string
  features: { label: string; ok: boolean }[]
  highlight?: boolean
}

const PLANS: PlanCard[] = [
  {
    id: "free",
    name: "Free",
    price: "無料",
    note: "まず便利さを体験するプラン",
    lead: "基本機能はすべて使えます",
    features: [
      { label: `単体書き出しは月${FREE_MONTHLY_LIMIT}件まで`, ok: true },
      { label: "写真・動画の両方に対応", ok: true },
      { label: "モザイク・ぼかし・黒塗り・基本スタンプ", ok: true },
      { label: "動画は1件あたり最大60秒", ok: true },
      { label: "広告が表示されます", ok: false },
      { label: "追加スタンプ・自作スタンプ", ok: false },
      { label: "一括処理", ok: false },
    ],
  },
  {
    id: "standard",
    name: "Standard",
    price: "月300円",
    note: "日常的に1件ずつ使うプラン",
    lead: "写真や短い動画を1件ずつ加工する方に",
    highlight: true,
    features: [
      { label: "単体書き出しが無制限", ok: true },
      { label: "Freeの全機能", ok: true },
      { label: "広告なし", ok: true },
      { label: "追加スタンプが使えます", ok: true },
      { label: "自作スタンプを登録できます", ok: true },
      { label: "動画は1件あたり最大5分", ok: true },
      { label: "一括処理・処理キュー・4K出力", ok: false },
    ],
  },
  {
    id: "pro",
    name: "Pro",
    price: "月980円",
    note: "大量素材をまとめて時短するプラン",
    lead: "大量の写真・動画をまとめて処理したい人向け",
    features: [
      { label: "Standardの全機能", ok: true },
      { label: "写真・動画の一括処理と一括書き出し", ok: true },
      { label: "処理キューで進捗を個別に確認", ok: true },
      { label: "一部が失敗しても残りを継続・個別に再試行", ok: true },
      { label: "1回の一括処理で最大50素材", ok: true },
      { label: "動画は1件あたり最大30分", ok: true },
      { label: "対応端末では4K出力", ok: true },
    ],
  },
]

type Cell = string | boolean

const COMPARISON: { label: string; values: [Cell, Cell, Cell] }[] = [
  { label: "単体書き出し", values: [`月${FREE_MONTHLY_LIMIT}件`, "無制限", "無制限"] },
  { label: "写真・動画", values: [true, true, true] },
  { label: "顔の自動検出", values: [true, true, true] },
  { label: "動画内の顔追跡", values: [true, true, true] },
  { label: "モザイク・ぼかし", values: [true, true, true] },
  { label: "基本スタンプ", values: [true, true, true] },
  { label: "追加スタンプ", values: [false, true, true] },
  { label: "自作スタンプ", values: [false, true, true] },
  { label: "広告", values: ["あり", "なし", "なし"] },
  { label: "動画上限", values: ["60秒", "5分", "30分"] },
  { label: "一括処理", values: [false, false, true] },
  { label: "処理キュー", values: [false, false, true] },
  { label: "4K出力", values: [false, false, "対応端末のみ"] },
]

export function PricingScreen() {
  const { plan, setPlan, back } = useApp()

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="プラン" onBack={back} subtitle="いつでも変更・解約できます" />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        {PLANS.map((p) => {
          const current = plan === p.id
          return (
            <section
              key={p.id}
              className={cn(
                "flex flex-col gap-3 rounded-3xl bg-card p-4",
                p.highlight ? "ring-2 ring-primary" : "ring-1 ring-foreground/10",
              )}
            >
              <div className="flex items-start justify-between gap-2">
                <div className="flex min-w-0 flex-col gap-0.5">
                  <p className="flex items-center gap-1.5 font-rounded text-base font-bold">
                    {p.id === "pro" ? <Crown className="size-4 text-chart-3" aria-hidden /> : null}
                    {p.name}
                  </p>
                  <p className="text-[11px] text-muted-foreground text-pretty">{p.note}</p>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  <p className="font-rounded text-lg font-bold">{p.price}</p>
                  {p.highlight ? <Badge className="text-[10px]">おすすめ</Badge> : null}
                </div>
              </div>

              <p
                className={cn(
                  "flex items-start gap-1.5 rounded-2xl px-3 py-2 text-[11px] leading-relaxed",
                  p.id === "pro"
                    ? "bg-chart-3/15 text-foreground"
                    : "bg-secondary text-secondary-foreground",
                )}
              >
                {p.id === "pro" ? <Layers className="mt-0.5 size-3.5 shrink-0" aria-hidden /> : null}
                {p.lead}
              </p>

              <ul className="flex flex-col gap-1.5">
                {p.features.map((f) => (
                  <li key={f.label} className="flex items-start gap-2 text-xs">
                    <span
                      className={cn(
                        "mt-0.5 grid size-4 shrink-0 place-items-center rounded-full",
                        f.ok ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground",
                      )}
                      aria-hidden
                    >
                      {f.ok ? <Check className="size-3" strokeWidth={3} /> : <Minus className="size-3" />}
                    </span>
                    <span className={cn("leading-relaxed", f.ok ? "text-foreground" : "text-muted-foreground")}>
                      {f.label}
                    </span>
                  </li>
                ))}
              </ul>

              <Button
                size="lg"
                variant={current ? "secondary" : p.highlight ? "default" : "outline"}
                disabled={current}
                className="h-12 w-full rounded-2xl font-bold"
                onClick={() => setPlan(p.id)}
              >
                {current ? "利用中のプラン" : p.id === "free" ? "Freeにする" : `${p.name}にする`}
              </Button>
            </section>
          )
        })}

        <section className="flex flex-col gap-2">
          <SectionTitle>できることをくらべる</SectionTitle>
          <div className="overflow-hidden rounded-3xl bg-card ring-1 ring-foreground/10">
            <div className="grid grid-cols-[1.35fr_1fr_1fr_1fr] border-b bg-secondary/60">
              <span className="px-2.5 py-2 text-[10px] font-bold text-muted-foreground">機能</span>
              {(["free", "standard", "pro"] as Plan[]).map((id) => (
                <span
                  key={id}
                  className={cn(
                    "px-1 py-2 text-center text-[10px] font-bold",
                    id === "standard" ? "bg-primary/10 text-primary" : "text-foreground",
                  )}
                >
                  {id === "free" ? "Free" : id === "standard" ? "Standard" : "Pro"}
                  <span className="block text-[9px] font-medium text-muted-foreground">
                    {id === "free" ? "無料" : id === "standard" ? "月300円" : "月980円"}
                  </span>
                </span>
              ))}
            </div>
            {COMPARISON.map((row, i) => (
              <div
                key={row.label}
                className={cn(
                  "grid grid-cols-[1.35fr_1fr_1fr_1fr] items-center",
                  i < COMPARISON.length - 1 && "border-b",
                )}
              >
                <span className="px-2.5 py-2 text-[10px] font-medium text-foreground">{row.label}</span>
                {row.values.map((v, j) => (
                  <span
                    key={j}
                    className={cn(
                      "flex h-full items-center justify-center px-1 py-2 text-center text-[10px]",
                      j === 1 && "bg-primary/5",
                    )}
                  >
                    <ComparisonValue value={v} />
                  </span>
                ))}
              </div>
            ))}
          </div>
        </section>

        <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
          選んだ写真や動画は外部サーバーへ送信されません。プランを変えても加工した素材は残ります。
        </p>
        <PrivacyNote />
      </div>
    </div>
  )
}

function ComparisonValue({ value }: { value: Cell }) {
  if (value === true) {
    return (
      <>
        <Check className="size-3.5 text-primary" strokeWidth={3} aria-hidden />
        <span className="sr-only">対応</span>
      </>
    )
  }
  if (value === false) {
    return (
      <>
        <Minus className="size-3.5 text-muted-foreground" aria-hidden />
        <span className="sr-only">非対応</span>
      </>
    )
  }
  return <span className="font-medium leading-tight text-pretty">{value}</span>
}
