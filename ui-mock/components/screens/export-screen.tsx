"use client"

import { AlertTriangle, Camera, CalendarClock, Lock, MapPinOff, ShieldCheck, Sparkles } from "lucide-react"

import { cn } from "@/lib/utils"
import {
  useApp,
  type ExportRatio,
  type ExportTarget,
  type FitMode,
} from "@/components/app-provider"
import { ScreenHeader } from "@/components/app-bits"
import { MediaCanvas } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"
import { Switch } from "@/components/ui/switch"

const TARGETS: { id: ExportTarget; label: string; hint: string; ratio: ExportRatio }[] = [
  { id: "ig-post", label: "Instagram投稿", hint: "正方形", ratio: "1:1" },
  { id: "ig-story", label: "ストーリーズ", hint: "たて長", ratio: "9:16" },
  { id: "original", label: "元のサイズ", hint: "そのまま", ratio: "original" },
]

const RATIOS: { id: ExportRatio; label: string }[] = [
  { id: "1:1", label: "1:1" },
  { id: "4:5", label: "4:5" },
  { id: "9:16", label: "9:16" },
  { id: "original", label: "元の比率" },
]

const FIT_MODES: { id: FitMode; label: string; hint: string }[] = [
  { id: "crop", label: "切り抜く", hint: "中央を残します" },
  { id: "blur", label: "背景をぼかす", hint: "余白をぼかしで埋めます" },
  { id: "contain", label: "全体を収める", hint: "余白は単色になります" },
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
    updateMetadata,
    back,
    go,
    plan,
    remainingFree,
    canExportSingle,
    requestUpgrade,
    skipFaces,
    reexportOf,
  } = useApp()

  if (!media) return null

  const inset = CROP_INSET[exportSettings.ratio]
  const meta = exportSettings.metadata
  const locked = reexportOf !== null && plan === "free"

  const handleSave = () => {
    if (!canExportSingle) {
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

        {locked ? (
          <div className="flex items-start gap-2 rounded-2xl bg-secondary px-3 py-2.5">
            <Lock className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden />
            <p className="text-[11px] leading-relaxed text-secondary-foreground text-pretty">
              このプロジェクトはそのまま書き出せます。編集するにはStandardが必要です。
            </p>
          </div>
        ) : null}

        {skipFaces ? (
          <div className="flex items-start gap-2 rounded-2xl bg-chart-3/20 px-3 py-2.5">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-foreground" aria-hidden />
            <p className="text-[11px] leading-relaxed text-foreground text-pretty">
              顔は検出されませんでした。
              {plan === "free"
                ? `このまま保存すると、今月の無料枠を1枚使用します（残り${remainingFree}枚）。`
                : "このまま保存すると、顔を隠さずに書き出します。"}
            </p>
          </div>
        ) : null}

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">投稿先</h2>
          <div className="grid grid-cols-3 gap-2">
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
                <span className="flex items-center gap-1.5 text-[11px] font-bold">
                  {t.id.startsWith("ig") ? (
                    <Camera className="size-3.5 shrink-0" aria-hidden />
                  ) : (
                    <Sparkles className="size-3.5 shrink-0" aria-hidden />
                  )}
                  <span className="truncate">{t.label}</span>
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
          <h2 className="font-rounded text-sm font-bold">比率が変わるときの処理</h2>
          <div className="grid grid-cols-3 gap-2">
            {FIT_MODES.map((f) => (
              <button
                key={f.id}
                type="button"
                onClick={() => updateExport({ fitMode: f.id })}
                className={cn(
                  "flex h-16 flex-col items-center justify-center gap-0.5 rounded-2xl px-2 text-center text-[11px] font-bold transition-colors",
                  exportSettings.fitMode === f.id
                    ? "bg-primary text-primary-foreground"
                    : "bg-card text-foreground ring-1 ring-foreground/10",
                )}
              >
                {f.label}
                <span className="text-[10px] font-medium opacity-80">{f.hint}</span>
              </button>
            ))}
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h2 className="font-rounded text-sm font-bold">記録される情報</h2>
          <div className="rounded-2xl bg-card p-2 ring-1 ring-foreground/10">
            <SettingRow
              label="位置情報を削除"
              hint="撮影場所を残しません"
              icon={<MapPinOff className="size-4 text-primary" aria-hidden />}
              checked={meta.stripLocation}
              onChange={(v) => updateMetadata({ stripLocation: v })}
            />
            <SettingRow
              label="撮影機器の情報を削除"
              hint="端末名やレンズの情報を残しません"
              checked={meta.stripDevice}
              onChange={(v) => updateMetadata({ stripDevice: v })}
            />
            <SettingRow
              label="コメント・編集ソフトの情報を削除"
              checked={meta.stripEditor}
              onChange={(v) => updateMetadata({ stripEditor: v })}
            />
            <SettingRow
              label="撮影日時を保持"
              hint="写真アプリの並び順を保ちます"
              icon={<CalendarClock className="size-4 text-primary" aria-hidden />}
              checked={meta.keepCaptureDate}
              onChange={(v) => updateMetadata({ keepCaptureDate: v })}
            />
          </div>
          <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
            撮影日時を削除しても、写真アプリ内の並び順は元の写真に合わせます。
          </p>
          <p className="flex items-start gap-1.5 px-1 text-[11px] leading-relaxed text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-3.5 shrink-0" aria-hidden />
            元の写真は変更されません。選択した写真は外部サーバーへ送信されず、加工結果は別ファイルとして保存されます。
          </p>
        </section>
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button size="lg" className="h-14 w-full rounded-2xl text-base font-bold" onClick={handleSave}>
          加工した写真をつくる
        </Button>
        {plan === "free" ? (
          <p className="pt-2 text-center text-[11px] text-muted-foreground">
            {canExportSingle ? `今月あと${remainingFree}枚保存できます` : "今月の無料保存を使い切りました"}
          </p>
        ) : null}
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
