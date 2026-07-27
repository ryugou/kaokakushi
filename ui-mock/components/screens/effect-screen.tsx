"use client"

import { Blend, Grid2x2, Square, Sticker } from "lucide-react"

import { cn } from "@/lib/utils"
import { myStampToArt, STAMPS } from "@/lib/stamps"
import { StampArtView } from "@/components/stamp-art"
import { useApp } from "@/components/app-provider"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import { LockDot, ProBadge } from "@/components/app-bits"
import { MediaCanvas } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"
import { Slider } from "@/components/ui/slider"

const METHODS: { type: EffectType; icon: typeof Blend }[] = [
  { type: "mosaic", icon: Grid2x2 },
  { type: "blur", icon: Blend },
  { type: "black", icon: Square },
  { type: "stamp", icon: Sticker },
]

export function EffectScreen() {
  const { media, faces, hidden, effect, setEffect, back, go, canUsePremiumStamps, requestUpgrade, myStamps } = useApp()

  if (!media) return null

  const basicStamps = STAMPS.filter((s) => s.category === "basic")
  const extraStamps = STAMPS.filter((s) => s.category !== "basic").slice(0, 8)

  return (
    <div className="flex min-h-full flex-col">
      <div className="flex flex-1 flex-col gap-3 px-4 py-3">
        <div className="flex items-center justify-between">
          <Button variant="ghost" className="h-10 rounded-full px-3" onClick={back}>
            戻る
          </Button>
          <h1 className="font-rounded text-base font-bold">かくし方を選ぶ</h1>
          <span className="w-16" aria-hidden />
        </div>

        <MediaCanvas
          media={media}
          faces={faces}
          hidden={hidden}
          effect={effect}
          className="aspect-square"
        />

        <div className="-mx-4 flex gap-2 overflow-x-auto px-4 py-1">
          {METHODS.map(({ type, icon: Icon }) => {
            const active = effect.type === type
            return (
              <button
                key={type}
                type="button"
                onClick={() => setEffect((prev) => ({ ...prev, type }))}
                className={cn(
                  "flex h-20 w-20 shrink-0 flex-col items-center justify-center gap-1.5 rounded-2xl text-xs font-bold transition-colors",
                  active
                    ? "bg-primary text-primary-foreground"
                    : "bg-card text-muted-foreground ring-1 ring-foreground/10",
                )}
              >
                <Icon className="size-6" aria-hidden />
                {EFFECT_LABELS[type]}
              </button>
            )
          })}
        </div>

        {effect.type === "mosaic" || effect.type === "blur" ? (
          <div className="flex flex-col gap-2 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
            <div className="flex items-center justify-between text-xs font-medium">
              <span>強さ</span>
              <span className="text-muted-foreground">{Math.round(effect.strength)}</span>
            </div>
            <Slider
              value={[effect.strength]}
              min={10}
              max={100}
              step={1}
              onValueChange={(v) =>
                setEffect((prev) => ({ ...prev, strength: Array.isArray(v) ? v[0] : v }))
              }
              className="py-2"
            />
            <div className="flex justify-between text-[11px] text-muted-foreground">
              <span>よわめ</span>
              <span>つよめ</span>
            </div>
          </div>
        ) : null}

        {effect.type === "black" ? (
          <p className="rounded-2xl bg-card p-4 text-xs leading-relaxed text-muted-foreground ring-1 ring-foreground/10">
            顔の部分をしっかり塗りつぶします。いちばん確実に隠したいときにおすすめです。
          </p>
        ) : null}

        {effect.type === "stamp" ? (
          <div className="flex flex-col gap-3 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
            <p className="text-xs font-bold">基本スタンプ</p>
            <div className="grid grid-cols-4 gap-2">
              {basicStamps.map((stamp) => {
                const Icon = stamp.icon
                const active = effect.stampId === stamp.id
                return (
                  <button
                    key={stamp.id}
                    type="button"
                    onClick={() => setEffect((prev) => ({ ...prev, stampId: stamp.id }))}
                    className={cn(
                      "flex flex-col items-center gap-1 rounded-2xl p-2 transition-colors",
                      active ? "bg-accent" : "hover:bg-muted",
                    )}
                  >
                    <span className={cn("grid size-10 place-items-center rounded-full", stamp.bg)}>
                      <Icon className={cn("size-5", stamp.fg)} aria-hidden />
                    </span>
                    <span className="text-[10px] font-medium">{stamp.name}</span>
                  </button>
                )
              })}
            </div>

            <div className="flex items-center justify-between">
              <p className="text-xs font-bold">追加スタンプ</p>
              {canUsePremiumStamps ? null : <ProBadge label="Standard以上" />}
            </div>
            <div className="grid grid-cols-4 gap-2">
              {extraStamps.map((stamp) => {
                const Icon = stamp.icon
                const locked = Boolean(stamp.premium) && !canUsePremiumStamps
                const active = effect.stampId === stamp.id
                return (
                  <button
                    key={stamp.id}
                    type="button"
                    onClick={() =>
                      locked
                        ? requestUpgrade("premium-stamp", `「${stamp.name}」は追加スタンプです。`)
                        : setEffect((prev) => ({ ...prev, stampId: stamp.id }))
                    }
                    className={cn(
                      "relative flex flex-col items-center gap-1 rounded-2xl p-2 transition-colors",
                      active ? "bg-accent" : "hover:bg-muted",
                    )}
                  >
                    <span
                      className={cn(
                        "grid size-10 place-items-center rounded-full",
                        stamp.bg,
                        locked && "opacity-45",
                      )}
                    >
                      <Icon className={cn("size-5", stamp.fg)} aria-hidden />
                    </span>
                    <span className="text-[10px] font-medium">{stamp.name}</span>
                    {locked ? <LockDot /> : null}
                  </button>
                )
              })}
            </div>

            {myStamps.length > 0 ? (
              <>
                <p className="text-xs font-bold">マイスタンプ</p>
                <div className="grid grid-cols-4 gap-2">
                  {myStamps.map((stamp) => {
                    const active = effect.stampId === stamp.id
                    return (
                      <button
                        key={stamp.id}
                        type="button"
                        onClick={() => setEffect((prev) => ({ ...prev, stampId: stamp.id }))}
                        className={cn(
                          "flex flex-col items-center gap-1 rounded-2xl p-2 transition-colors",
                          active ? "bg-accent" : "hover:bg-muted",
                        )}
                      >
                        <StampArtView art={myStampToArt(stamp)} className="size-10" sizes="40px" />
                        <span className="w-full truncate text-[10px] font-medium">{stamp.name}</span>
                      </button>
                    )
                  })}
                </div>
              </>
            ) : null}

            <Button variant="ghost" size="sm" className="self-start px-0 text-xs" onClick={() => go("stamps")}>
              スタンプをもっと見る
            </Button>
          </div>
        ) : null}
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button size="lg" className="h-14 w-full rounded-2xl text-base font-bold" onClick={() => go("export")}>
          書き出し設定へ
        </Button>
      </div>
    </div>
  )
}
