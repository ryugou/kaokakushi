"use client"

import { Camera, CheckCircle2, Download, Home, Music2, Share2 } from "lucide-react"

import { useApp, type ExportQuality } from "@/components/app-provider"
import { MediaCanvas } from "@/components/media-canvas"
import { AdSlot, PrivacyNote } from "@/components/app-bits"
import { Button } from "@/components/ui/button"

const QUALITY_LABELS: Record<ExportQuality, string> = {
  standard: "標準",
  "1080p": "1080p",
  "4k": "4K",
}

export function DoneScreen() {
  const {
    media,
    faces,
    hidden,
    effect,
    effectLabel,
    plan,
    hasAds,
    remainingFree,
    go,
    exportSettings,
    openKindChooser,
  } = useApp()

  if (!media) return null

  return (
    <div className="flex min-h-full flex-col gap-5 px-4 py-6">
      <div className="flex flex-col items-center gap-1.5 text-center">
        <span className="grid size-14 place-items-center rounded-full bg-primary/12 text-primary">
          <CheckCircle2 className="size-8" aria-hidden />
        </span>
        <h1 className="font-rounded text-lg font-bold">保存しました</h1>
        <p className="text-xs text-muted-foreground">
          {effectLabel}で{hidden.length}人の顔を隠しました
        </p>
      </div>

      <MediaCanvas
        media={media}
        faces={faces}
        hidden={hidden}
        effect={effect}
        className="mx-auto aspect-square max-w-[280px]"
      />

      <div className="flex flex-col gap-2">
        <p className="font-rounded text-sm font-bold">シェアする</p>
        <div className="grid grid-cols-3 gap-2">
          <ShareButton icon={<Camera className="size-5" aria-hidden />} label="Instagram" />
          <ShareButton icon={<Music2 className="size-5" aria-hidden />} label="TikTok" />
          <ShareButton icon={<Share2 className="size-5" aria-hidden />} label="その他" />
        </div>
      </div>

      <div className="flex flex-col gap-1.5 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
        <Row label="保存先" value="カメラロール" />
        <Row label="サイズ" value={exportSettings.ratio === "original" ? "元の比率" : exportSettings.ratio} />
        <Row label="画質" value={QUALITY_LABELS[exportSettings.quality]} />
        <Row label="位置情報" value={exportSettings.stripMetadata ? "削除済み" : "そのまま"} />
        {plan === "free" ? <Row label="今月の残り" value={`あと${remainingFree}件`} /> : null}
      </div>

      <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
        元の写真や動画は変更されません
      </p>

      {hasAds ? <AdSlot /> : null}

      <div className="flex flex-col gap-2">
        <Button size="lg" className="h-13 w-full rounded-2xl font-bold" onClick={() => go("home")}>
          <Home data-icon="inline-start" />
          ホームにもどる
        </Button>
        <Button
          size="lg"
          variant="outline"
          className="h-13 w-full rounded-2xl font-bold"
          onClick={() => {
            go("home")
            openKindChooser()
          }}
        >
          <Download data-icon="inline-start" />
          別の素材を加工する
        </Button>
      </div>

      <PrivacyNote />
    </div>
  )
}

function ShareButton({ icon, label }: { icon: React.ReactNode; label: string }) {
  return (
    <button
      type="button"
      className="flex h-20 flex-col items-center justify-center gap-1.5 rounded-2xl bg-card text-xs font-medium ring-1 ring-foreground/10 transition-transform active:scale-95"
    >
      <span className="text-primary">{icon}</span>
      {label}
    </button>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 text-xs">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  )
}
