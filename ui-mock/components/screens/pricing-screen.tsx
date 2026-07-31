"use client"

import { Check, Crown, Layers, Minus } from "lucide-react"

import { cn } from "@/lib/utils"
import { BATCH_MAX_ITEMS, FREE_MONTHLY_LIMIT, TRIAL_CREDITS, useApp, type Plan } from "@/components/app-provider"
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
    lead: "顔を隠して保存するところまで、ぜんぶ使えます",
    features: [
      { label: `1枚ずつの書き出しは月${FREE_MONTHLY_LIMIT}枚まで`, ok: true },
      { label: "顔の自動検出と手動での範囲追加", ok: true },
      { label: "モザイク・ぼかし・黒塗り・基本スタンプ", ok: true },
      { label: "縦横比の変更・背景ぼかし・メタデータ設定", ok: true },
      { label: `一括処理はお試しの${TRIAL_CREDITS}枚ぶんだけ`, ok: true },
      { label: "広告が表示されます", ok: false },
      { label: "追加スタンプ・マイスタンプ", ok: false },
    ],
  },
  {
    id: "standard",
    name: "Standard",
    price: "月300円",
    note: "日常的に写真を1枚ずつ加工する人向け",
    lead: "回数を気にせず、1枚ずつていねいに加工したい方に",
    highlight: true,
    features: [
      { label: "1枚ずつの書き出しが無制限", ok: true },
      { label: "Freeの全機能", ok: true },
      { label: "広告なし", ok: true },
      { label: "追加スタンプが使えます", ok: true },
      { label: "マイスタンプを最大100個まで登録できます", ok: true },
      { label: `一括処理はお試しの${TRIAL_CREDITS}枚ぶんだけ`, ok: true },
      { label: "まとめて自動で進める一括処理", ok: false },
    ],
  },
  {
    id: "pro",
    name: "Pro",
    price: "月980円",
    note: "イベントの写真をまとめて片づけるプラン",
    lead: "旅行やイベントの写真を最大50枚選び、顔をまとめて検出します。一覧で仕上がりを見渡し、注意が必要な写真だけを開いて直せば、そのまま一括で保存できます。",
    features: [
      { label: "Standardの全機能", ok: true },
      { label: `1回の一括処理で最大${BATCH_MAX_ITEMS}枚`, ok: true },
      { label: "おまかせ一括と1枚ずつ確認の2つのすすめかた", ok: true },
      { label: "要確認の写真だけを抽出して確認", ok: true },
      { label: "確認済みの写真は自動で進みます", ok: true },
      { label: "失敗した写真だけあとから再試行", ok: true },
      { label: "いつもの設定をそのまま使え、あとから見返せます", ok: true },
    ],
  },
]

type Cell = string | boolean

const COMPARISON: { label: string; values: [Cell, Cell, Cell] }[] = [
  { label: "1枚ずつの書き出し", values: [`月${FREE_MONTHLY_LIMIT}枚`, "無制限", "無制限"] },
  { label: "顔の自動検出", values: [true, true, true] },
  { label: "手動で範囲を追加", values: [true, true, true] },
  { label: "モザイク・ぼかし・黒塗り", values: [true, true, true] },
  { label: "基本スタンプ", values: [true, true, true] },
  { label: "追加スタンプ", values: [false, true, true] },
  { label: "マイスタンプ", values: [false, "100個", "100個"] },
  { label: "縦横比・背景ぼかし", values: [true, true, true] },
  { label: "メタデータ設定", values: [true, true, true] },
  { label: "広告", values: ["あり", "なし", "なし"] },
  { label: "一括処理", values: [`お試し${TRIAL_CREDITS}枚`, `お試し${TRIAL_CREDITS}枚`, `最大${BATCH_MAX_ITEMS}枚`] },
  { label: "処理キュー", values: [false, false, true] },
  { label: "一括設定プリセット", values: [false, false, true] },
  { label: "バッチ履歴", values: [false, false, true] },
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
                  p.id === "pro" ? "bg-chart-3/15 text-foreground" : "bg-secondary text-secondary-foreground",
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

        <p className="rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
          写真に写っていない顔をアプリが見つけられないことがあります。書き出す前に、ご自身で仕上がりをご確認ください。同じ人物を写真をまたいで判定することはできません。
        </p>

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
          選んだ写真は外部サーバーへ送信されません。プランを変えても、加工した写真と履歴は残ります。
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
