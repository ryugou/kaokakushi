"use client"

import { Camera, MapPinOff, Music2, ShieldCheck, Sparkles } from "lucide-react"

import { cn } from "@/lib/utils"
import { formatDuration } from "@/lib/mock-data"
import {
  useApp,
  type ExportQuality,
  type ExportRatio,
  type ExportTarget,
} from "@/components/app-provider"
import { LockDot, ScreenHeader } from "@/components/app-bits"
import { MediaCanvas } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"
import { Switch } from "@/components/ui/switch"

const TARGETS: { id: ExportTarget; label: string; hint: string; ratio: ExportRatio }[] = [
  { id: "ig-post", label: "Instagram投稿", hint: "正方形", ratio: "1:1" },
  { id: "ig-story", label: "ストーリーズ／リール", hint: "たて長", ratio: "9:16" },
  { id: "tiktok", label: "TikTok", hint: "たて長", ratio: "9:16" },
  { id: "original", label: "元のサイズ", hint: "そのまま", ratio: "original" },
]

const RATIOS: { id: ExportRatio; label: string }[] = [
  { id: "1:1", label: "1:1" },
  { id: "4:5", label: "4:5" },
  { id: "9:16", label: "9:16" },
  { id: "original", label: "元の比率" },
]

const QUALITIES: { id: ExportQuality; label: string; hint: string }[] = [
  { id: "standard", label: "標準", hint: "軽くて速い" },
  { id: "1080p", label: "1080p", hint: "きれい" },
  { id: "4k", label: "4K", hint: "対応端末のみ" },
]

const CROP_INSET: Record<ExportRatio, string> = {
  "1:1": "0%",
  "4:5": "10%",
  "9:16": "21.9%",
  original: "0%",
}

export function ExportScreen() {
  const {
    media,
    faces,
    hidden,
    effect,
    exportSettings,
    updateExport,
    back,
    go,
    canExport,
    requestUpgrade,
    canExport4K,
    deviceSupports4K,
    videoLimitLabel,
  } = useApp()

  if (!media) return null

  const isVideo = media.kind === "video"
  const inset = CROP_INSET[exportSettings.ratio]

  const handleSave = () => {
    if (!canExport) {
      requestUpgrade("export-limit")
      return
    }
    go("processing")
  }

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="書き出し設定" onBack={back} />

      <div className="flex flex-1 flex-col gap-5 px-4 py-4">
        <MediaCanvas media={media} faces={faces} hidden={hidden} effect={effect} className="aspect-square">
          <div
            className="pointer-events-none absolute inset-y-0 rounded-lg outline-2 outline-background/90"
            style={{
              left: inset,
              right: inset,
              boxShadow: "0 0 0 9999px oklch(0.26 0.025 240 / 0.45)",
            }}
          />
          <span className="pointer-events-none absolute bottom-2 left-1/2 -translate-x-1/2 rounded-full bg-foreground/70 px-2.5 py-1 text-[10px] font-medium text-background">
            {exportSettings.ratio === "original" ? "元の比率" : exportSettings.ratio}
          </span>
        </MediaCanvas>

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">投稿先</h2>
          <div className="grid grid-cols-2 gap-2">
            {TARGETS.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => updateExport({ target: t.id, ratio: t.ratio })}
                className={cn(
                  "flex h-16 flex-col items-start justify-center gap-0.5 rounded-2xl px-3 text-left transition-colors",
                  exportSettings.target === t.id
                    ? "bg-primary text-primary-foreground"
                    : "bg-card text-foreground ring-1 ring-foreground/10",
                )}
              >
                <span className="flex items-center gap-1.5 text-xs font-bold">
                  {t.id.startsWith("ig") ? (
                    <Camera className="size-3.5" aria-hidden />
                  ) : t.id === "tiktok" ? (
                    <Music2 className="size-3.5" aria-hidden />
                  ) : (
                    <Sparkles className="size-3.5" aria-hidden />
                  )}
                  {t.label}
                </span>
                <span className="text-[10px] opacity-80">{t.hint}</span>
              </button>
            ))}
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">縦横比</h2>
          <div className="grid grid-cols-4 gap-2">
            {RATIOS.map((r) => (
              <button
                key={r.id}
                type="button"
                onClick={() => updateExport({ ratio: r.id })}
                className={cn(
                  "h-12 rounded-2xl text-xs font-bold transition-colors",
                  exportSettings.ratio === r.id
                    ? "bg-primary text-primary-foreground"
                    : "bg-card text-foreground ring-1 ring-foreground/10",
                )}
              >
                {r.label}
              </button>
            ))}
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">画質</h2>
          <div className="grid grid-cols-3 gap-2">
            {QUALITIES.map((q) => {
              const locked = q.id === "4k" && !canExport4K
              const unsupported = q.id === "4k" && canExport4K && !deviceSupports4K
              return (
                <button
                  key={q.id}
                  type="button"
                  onClick={() => {
                    if (locked) {
                      requestUpgrade("export-4k")
                      return
                    }
                    if (unsupported) return
                    updateExport({ quality: q.id })
                  }}
                  aria-disabled={unsupported}
                  className={cn(
                    "relative flex h-14 flex-col items-center justify-center gap-0.5 rounded-2xl text-xs font-bold transition-colors",
                    exportSettings.quality === q.id
                      ? "bg-primary text-primary-foreground"
                      : "bg-card text-foreground ring-1 ring-foreground/10",
                    (locked || unsupported) && "opacity-55",
                  )}
                >
                  {q.label}
                  <span className="text-[10px] font-medium opacity-80">
                    {unsupported ? "この端末は非対応" : locked ? "Pro" : q.hint}
                  </span>
                  {locked ? <LockDot /> : null}
                </button>
              )
            })}
          </div>
          <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
            {canExport4K
              ? "Proでは対応端末で4K書き出しを利用できます。"
              : "FreeとStandardは最大1080pで書き出せます。4KはProの機能です。"}
          </p>
        </section>

        {isVideo ? (
          <section className="flex flex-col gap-2">
            <h2 className="font-rounded text-sm font-bold">動画の設定</h2>
            <div className="flex flex-col gap-1 rounded-2xl bg-card p-2 ring-1 ring-foreground/10">
              <SettingRow
                label="音声を残す"
                hint="消すと無音で保存されます"
                checked={exportSettings.keepAudio}
                onChange={(v) => updateExport({ keepAudio: v })}
              />
              <SettingRow
                label="背景をぼかして縦動画にする"
                hint="よこ長の動画をたて長に整えます"
                checked={exportSettings.verticalBlur}
                onChange={(v) => updateExport({ verticalBlur: v })}
              />
              <div className="flex items-center justify-between gap-3 px-3 py-3 text-xs">
                <span className="font-medium">動画の長さ</span>
                <span className="text-muted-foreground">
                  {formatDuration(media.duration ?? 0)} ／ 上限{videoLimitLabel}
                </span>
              </div>
              <div className="flex items-center justify-between gap-3 px-3 py-3 text-xs">
                <span className="font-medium">予想処理時間</span>
                <span className="text-muted-foreground">
                  約{Math.max(5, Math.round((media.duration ?? 10) * 0.6))}秒
                </span>
              </div>
            </div>
          </section>
        ) : null}

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">安心のための設定</h2>
          <div className="rounded-2xl bg-card p-2 ring-1 ring-foreground/10">
            <SettingRow
              label="位置情報などの記録を消す"
              hint="撮影場所や機種の情報を残しません"
              icon={<MapPinOff className="size-4 text-primary" aria-hidden />}
              checked={exportSettings.stripMetadata}
              onChange={(v) => updateExport({ stripMetadata: v })}
            />
          </div>
          <p className="flex items-start gap-1.5 px-1 text-[11px] leading-relaxed text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-3.5 shrink-0" aria-hidden />
            書き出しも端末内で行われます。選択した写真や動画は外部サーバーへ送信されません。元の写真や動画は変更されず、加工結果は別ファイルとして保存されます。
          </p>
        </section>
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button size="lg" className="h-14 w-full rounded-2xl text-base font-bold" onClick={handleSave}>
          保存する
        </Button>
      </div>
    </div>
  )
}

function SettingRow({
  label,
  hint,
  checked,
  onChange,
  icon,
}: {
  label: string
  hint?: string
  checked: boolean
  onChange: (value: boolean) => void
  icon?: React.ReactNode
}) {
  return (
    <label className="flex items-center justify-between gap-3 rounded-2xl px-3 py-3">
      <span className="flex min-w-0 items-center gap-2">
        {icon}
        <span className="min-w-0">
          <span className="block text-xs font-medium">{label}</span>
          {hint ? <span className="block text-[11px] text-muted-foreground">{hint}</span> : null}
        </span>
      </span>
      <Switch checked={checked} onCheckedChange={onChange} />
    </label>
  )
}
