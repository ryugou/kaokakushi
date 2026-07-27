"use client"

import * as React from "react"
import { Plus, Trash2 } from "lucide-react"

import { cn } from "@/lib/utils"
import { formatMb } from "@/lib/mock-data"
import { myStampToArt, STAMP_CATEGORIES, STAMPS, type MyStamp, type StampCategory } from "@/lib/stamps"
import { StampArtView } from "@/components/stamp-art"
import { CUSTOM_STAMP_LIMIT, useApp } from "@/components/app-provider"
import { LockDot, ProBadge, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

export function StampsScreen() {
  const {
    plan,
    requestUpgrade,
    go,
    myStamps,
    removeMyStamp,
    isStampReferenced,
    setEffect,
    canUsePremiumStamps,
    canUseCustomStamps,
    stampStorageActiveMb,
    stampStorageRetainedMb,
    retiredStampCount,
    clearMyStamps,
  } = useApp()

  const [category, setCategory] = React.useState<StampCategory>("basic")
  const [confirmTarget, setConfirmTarget] = React.useState<MyStamp | null>(null)
  const [confirmClearAll, setConfirmClearAll] = React.useState(false)

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
        <div role="tablist" aria-label="スタンプのカテゴリ" className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1">
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
                マイスタンプの登録と新規適用はStandard以上の機能です。すでに登録したスタンプの閲覧・並べ替え・削除はいつでもできます。
              </p>
            ) : null}

            <div className="flex flex-col gap-1.5 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
              <StorageRow label="登録数" value={`${myStamps.length}個 / ${CUSTOM_STAMP_LIMIT}個`} />
              <StorageRow label="登録中のマイスタンプ" value={formatMb(stampStorageActiveMb)} />
              <StorageRow
                label="過去の加工履歴で使用中"
                value={
                  retiredStampCount > 0 ? `${formatMb(stampStorageRetainedMb)}（${retiredStampCount}個）` : "なし"
                }
              />
              <StorageRow label="合計" value={formatMb(stampStorageActiveMb + stampStorageRetainedMb)} />
              {myStamps.length > 0 ? (
                <Button
                  variant="ghost"
                  size="sm"
                  className="mt-1 h-9 self-start rounded-xl px-2 text-[11px] font-bold text-destructive"
                  onClick={() => setConfirmClearAll(true)}
                >
                  すべて削除
                </Button>
              ) : null}
            </div>

            <div className="grid grid-cols-3 gap-3">
              {myStamps.map((s) => {
                const art = myStampToArt(s)
                const locked = !canUseCustomStamps
                return (
                  <div key={s.id} className="flex flex-col items-center gap-1.5">
                    <button
                      type="button"
                      onClick={() =>
                        locked
                          ? requestUpgrade("custom-stamp", `「${s.name}」はマイスタンプです。`)
                          : setEffect((prev) => ({ ...prev, type: "stamp", stampId: s.id }))
                      }
                      className="relative w-full transition-transform active:scale-95"
                    >
                      <StampArtView
                        art={art}
                        className={cn("aspect-square w-full", locked && "opacity-45")}
                        sizes="96px"
                      />
                      {locked ? <LockDot /> : null}
                      <span className="sr-only">{s.name}を使う</span>
                    </button>
                    <p className="w-full truncate text-center text-[10px] text-muted-foreground">{s.name}</p>
                    <Button
                      size="icon"
                      variant="ghost"
                      className="size-7 rounded-lg text-muted-foreground"
                      onClick={() => setConfirmTarget(s)}
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

      {/* 一覧から削除しても、過去の加工履歴が使っていれば参照用コピーは残す */}
      <Dialog open={confirmTarget !== null} onOpenChange={(open) => (!open ? setConfirmTarget(null) : undefined)}>
        <DialogContent className="max-w-[330px] rounded-3xl">
          <DialogHeader>
            <DialogTitle className="font-rounded text-base leading-snug">
              「{confirmTarget?.name}」を削除しますか？
            </DialogTitle>
            <DialogDescription className="leading-relaxed">
              {confirmTarget && isStampReferenced(confirmTarget.id)
                ? "スタンプ一覧から削除します。過去の加工履歴では引き続き使用されます。"
                : "スタンプ一覧から削除します。新しい写真では選べなくなります。"}
            </DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-2">
            <Button
              size="lg"
              variant="destructive"
              className="h-12 rounded-2xl text-sm font-bold"
              onClick={() => {
                if (confirmTarget) removeMyStamp(confirmTarget.id)
                setConfirmTarget(null)
              }}
            >
              削除する
            </Button>
            <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={() => setConfirmTarget(null)}>
              やめる
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={confirmClearAll} onOpenChange={(open) => (!open ? setConfirmClearAll(false) : undefined)}>
        <DialogContent className="max-w-[330px] rounded-3xl">
          <DialogHeader>
            <DialogTitle className="font-rounded text-base leading-snug">
              マイスタンプをすべて削除しますか？
            </DialogTitle>
            <DialogDescription className="leading-relaxed">
              マイスタンプ一覧からすべて削除します。過去の加工履歴で使用中の画像は、履歴を再現するため保持されます。完全に削除するには、その履歴を削除してください。
            </DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-2">
            <Button
              size="lg"
              variant="destructive"
              className="h-12 rounded-2xl text-sm font-bold"
              onClick={() => {
                clearMyStamps()
                setConfirmClearAll(false)
              }}
            >
              すべて削除する
            </Button>
            <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={() => setConfirmClearAll(false)}>
              やめる
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function StorageRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 text-[11px]">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  )
}
