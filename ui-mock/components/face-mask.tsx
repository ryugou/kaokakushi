"use client"

import type * as React from "react"
import { Check } from "lucide-react"

import { cn } from "@/lib/utils"
import { resolveStampArt } from "@/lib/stamps"
import { StampArtView, useMyStamps } from "@/components/stamp-art"
import type { FaceBox } from "@/lib/mock-data"

export type EffectType = "mosaic" | "blur" | "black" | "stamp"

export type EffectConfig = {
  type: EffectType
  strength: number
  stampId: string
}

export const DEFAULT_EFFECT: EffectConfig = {
  type: "mosaic",
  strength: 60,
  stampId: "circle",
}

export const EFFECT_LABELS: Record<EffectType, string> = {
  mosaic: "モザイク",
  blur: "ぼかし",
  black: "黒塗り",
  stamp: "スタンプ",
}

function boxStyle(face: FaceBox) {
  return {
    left: `${face.x}%`,
    top: `${face.y}%`,
    width: `${face.w}%`,
    height: `${face.h}%`,
  }
}

/** 顔ひとつぶんの隠し表現 */
export function FaceMask({ face, effect }: { face: FaceBox; effect: EffectConfig }) {
  const style = boxStyle(face)

  if (effect.type === "mosaic") {
    const cell = 3 + Math.round((effect.strength / 100) * 7)
    const blur = 2 + (effect.strength / 100) * 6
    return (
      <div className="pointer-events-none absolute overflow-hidden rounded-xl" style={style}>
        <div
          className="absolute inset-0"
          style={{ backdropFilter: `blur(${blur}px)`, WebkitBackdropFilter: `blur(${blur}px)` }}
        />
        <div
          className="absolute inset-0 opacity-70"
          style={{
            backgroundImage: `linear-gradient(to right, oklch(1 0 0 / 0.45) 1px, transparent 1px),
              linear-gradient(to bottom, oklch(1 0 0 / 0.45) 1px, transparent 1px),
              linear-gradient(135deg, oklch(1 0 0 / 0.18), oklch(0 0 0 / 0.12))`,
            backgroundSize: `${cell}px ${cell}px, ${cell}px ${cell}px, 100% 100%`,
          }}
        />
      </div>
    )
  }

  if (effect.type === "blur") {
    const blur = 3 + (effect.strength / 100) * 16
    return (
      <div
        className="pointer-events-none absolute rounded-[40%]"
        style={{
          ...style,
          backdropFilter: `blur(${blur}px)`,
          WebkitBackdropFilter: `blur(${blur}px)`,
        }}
      />
    )
  }

  if (effect.type === "black") {
    return <div className="pointer-events-none absolute rounded-xl bg-foreground" style={style} />
  }

  return <StampMask stampId={effect.stampId} style={style} />
}

/** スタンプで隠す（マイスタンプにも対応） */
function StampMask({ stampId, style }: { stampId: string; style: React.CSSProperties }) {
  const myStamps = useMyStamps()
  const art = resolveStampArt(stampId, myStamps)

  return <StampArtView art={art} className="pointer-events-none absolute shadow-sm" style={style} sizes="200px" />
}

/** 顔の検出枠（選択できる） */
export function FaceFrame({
  face,
  selected,
  index,
  onToggle,
}: {
  face: FaceBox
  selected: boolean
  index: number
  onToggle: () => void
}) {
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-pressed={selected}
      className={cn(
        "absolute rounded-2xl border-2 transition-colors",
        selected
          ? "border-primary bg-primary/15"
          : "border-dashed border-card bg-foreground/5 hover:bg-foreground/10",
      )}
      style={boxStyle(face)}
    >
      <span className="sr-only">
        {index + 1}人目の顔を{selected ? "隠さない" : "隠す"}
      </span>
      <span
        className={cn(
          "absolute -right-2 -top-2 grid size-6 place-items-center rounded-full border-2 text-[11px] font-bold shadow-sm",
          selected
            ? "border-primary-foreground bg-primary text-primary-foreground"
            : "border-card bg-card text-muted-foreground",
        )}
        aria-hidden
      >
        {selected ? <Check className="size-3.5" strokeWidth={3} /> : index + 1}
      </span>
      {face.manual ? (
        <span className="absolute -bottom-6 left-0 rounded-full bg-card/90 px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
          手動
        </span>
      ) : null}
    </button>
  )
}
