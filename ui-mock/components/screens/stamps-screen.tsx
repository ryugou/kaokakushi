"use client"

import * as React from "react"
import { Plus, Trash2 } from "lucide-react"

import { cn } from "@/lib/utils"
import { myStampToArt, STAMP_CATEGORIES, STAMPS, type StampCategory } from "@/lib/stamps"
import { StampArtView } from "@/components/stamp-art"
import { useApp } from "@/components/app-provider"
import { LockDot, ProBadge, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { Button } from "@/components/ui/button"

export function StampsScreen() {
  const { plan, requestUpgrade, go, myStamps, removeMyStamp, setEffect, canUsePremiumStamps, canUseCustomStamps } =
    useApp()
  const [category, setCategory] = React.useState<StampCategory>("basic")

  const items = STAMPS.filter((s) => s.category === category)

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader
        title="スタンプ"
        subtitle="顔を隠すデザインを選べます"
        action={
          plan === "pro" ? <ProBadge label="Pro" /> : plan === "standard" ? <ProBadge label="Standard" /> : null
        }
      />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        <div
          role="tablist"
          aria-label="スタンプのカテゴリ"
          className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1"
        >
          {STAMP_CATEGORIES.map((c) => (
            <button
              key={c.id}
              type="button"
              role="tab"
              aria-selected={category === c.id}
              onClick={() => setCategory(c.id)}
              className={cn(
                "h-9 shrink-0 rounded-full px-4 text-xs font-bold transition-colors",
                category === c.id
                  ? "bg-primary text-primary-foreground"
                  : "bg-card text-muted-foreground ring-1 ring-foreground/10",
              )}
            >
              {c.label}
            </button>
          ))}
        </div>

        {category === "mine" ? (
          <div className="flex flex-col gap-3">
            <SectionTitle
              action={
                <Button
                  size="sm"
                  variant="secondary"
                  className="h-8 rounded-xl text-[11px] font-bold"
                  onClick={() => (canUseCustomStamps ? go("custom-stamp") : requestUpgrade("custom-stamp"))}
                >
                  <Plus data-icon="inline-start" />
                  追加
                </Button>
              }
            >
              マイスタンプ
            </SectionTitle>
            {!canUseCustomStamps ? (
              <p className="rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
                自作スタンプの登録はStandard以上の機能です。登録したスタンプはいつでも使えます。
              </p>
            ) : null}
            <div className="grid grid-cols-3 gap-3">
              {myStamps.map((s) => {
                const art = myStampToArt(s)
                return (
                  <div key={s.id} className="flex flex-col items-center gap-1.5">
                    <button
                      type="button"
                      onClick={() => setEffect((prev) => ({ ...prev, type: "stamp", stampId: s.id }))}
                      className="w-full transition-transform active:scale-95"
                    >
                      <StampArtView art={art} className="aspect-square w-full" sizes="96px" />
                      <span className="sr-only">{s.name}を使う</span>
                    </button>
                    <p className="w-full truncate text-center text-[10px] text-muted-foreground">{s.name}</p>
                    <Button
                      size="icon"
                      variant="ghost"
                      className="size-7 rounded-lg text-muted-foreground"
                      onClick={() => removeMyStamp(s.id)}
                    >
                      <Trash2 className="size-3.5" />
                      <span className="sr-only">{s.name}を削除</span>
                    </Button>
                  </div>
                )
              })}
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-4 gap-3">
            {items.map((s) => {
              const Icon = s.icon
              const locked = Boolean(s.premium) && !canUsePremiumStamps
              return (
                <button
                  key={s.id}
                  type="button"
                  onClick={() =>
                    locked
                      ? requestUpgrade("premium-stamp", `「${s.name}」は追加スタンプです。`)
                      : setEffect((prev) => ({ ...prev, type: "stamp", stampId: s.id }))
                  }
                  className="flex flex-col items-center gap-1.5"
                >
                  <span
                    className={cn(
                      "relative grid aspect-square w-full place-items-center rounded-2xl",
                      s.bg,
                      locked && "opacity-55",
                    )}
                  >
                    <Icon className={cn("size-7", s.fg)} aria-hidden />
                    {locked ? <LockDot /> : null}
                  </span>
                  <span className="w-full truncate text-center text-[10px] text-muted-foreground">{s.name}</span>
                </button>
              )
            })}
          </div>
        )}

        <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
          スタンプは加工画面でも選べます。選んだスタンプは顔の大きさに合わせて自動でサイズが変わります。
        </p>
      </div>
    </div>
  )
}
