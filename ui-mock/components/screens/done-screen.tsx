"use client"

import { Camera, CheckCircle2, Download, Home, ImagePlus, Share2, Sparkles } from "lucide-react"

import { generatedCount, useApp } from "@/components/app-provider"
import { MediaCanvas } from "@/components/media-canvas"
import { AdSlot, PrivacyNote } from "@/components/app-bits"
import { Button } from "@/components/ui/button"

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
    openPicker,
    pendingOutput,
    savePending,
    sharePending,
    guardNewWork,
  } = useApp()

  if (!media) return null

  const delivered = generatedCount(pendingOutput) === 0
  const meta = exportSettings.metadata

  return (
    <div className="flex min-h-full flex-col gap-5 px-4 py-6">
      <div className="flex flex-col items-center gap-1.5 text-center">
        <span className="grid size-14 place-items-center rounded-full bg-primary/12 text-primary">
          {delivered ? <CheckCircle2 className="size-8" aria-hidden /> : <Sparkles className="size-8" aria-hidden />}
        </span>
        <h1 className="font-rounded text-lg font-bold">
          {delivered ? "保存しました" : "加工した写真ができました"}
        </h1>
        <p className="text-xs text-muted-foreground text-pretty">
          {hidden.length > 0 ? `${effectLabel}で${hidden.length}人の顔を隠しました` : "顔加工なしで書き出しました"}
        </p>
      </div>

      <MediaCanvas
        media={media}
        faces={faces}
        hidden={hidden}
        effect={effect}
        className="mx-auto aspect-square max-w-[280px]"
      />

      {/* 生成が終わった時点で枠を消費しているので、受け渡しまで到達させる */}
      {!delivered ? (
        <div className="flex flex-col gap-2">
          <Button size="lg" className="h-13 w-full rounded-2xl font-bold" onClick={savePending}>
            <Download data-icon="inline-start" />
            写真ライブラリへ保存
          </Button>
          <div className="grid grid-cols-3 gap-2">
            <ShareButton icon={<Camera className="size-5" aria-hidden />} label="Instagram" onClick={sharePending} />
            <ShareButton icon={<Share2 className="size-5" aria-hidden />} label="その他へ共有" onClick={sharePending} />
            <ShareButton
              icon={<Download className="size-5" aria-hidden />}
              label="ファイルへ"
              onClick={sharePending}
            />
          </div>
          <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
            保存や共有は何度でも行えます。追加で無料枠は消費しません。
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          <p className="font-rounded text-sm font-bold">ほかにも渡せます</p>
          <div className="grid grid-cols-3 gap-2">
            <ShareButton icon={<Camera className="size-5" aria-hidden />} label="Instagram" onClick={sharePending} />
            <ShareButton icon={<Share2 className="size-5" aria-hidden />} label="その他へ共有" onClick={sharePending} />
            <ShareButton
              icon={<Download className="size-5" aria-hidden />}
              label="もう一度保存"
              onClick={savePending}
            />
          </div>
          <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
            追加で無料枠は消費しません。この画面を離れると一時ファイルは削除されます。
          </p>
        </div>
      )}

      <div className="flex flex-col gap-1.5 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
        <Row label="サイズ" value={exportSettings.ratio === "original" ? "元の比率" : exportSettings.ratio} />
        <Row label="位置情報" value={meta.stripLocation ? "削除済み" : "そのまま"} />
        <Row label="撮影機器の情報" value={meta.stripDevice ? "削除済み" : "そのまま"} />
        <Row label="撮影日時" value={meta.keepCaptureDate ? "保持" : "削除済み（並び順は維持）"} />
        {plan === "free" ? <Row label="今月の残り" value={`あと${remainingFree}枚`} /> : null}
      </div>

      <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
        元の写真は変更されません
      </p>

      {hasAds ? <AdSlot /> : null}

      <div className="flex flex-col gap-2">
        <Button
          size="lg"
          variant={delivered ? "default" : "outline"}
          className="h-13 w-full rounded-2xl font-bold"
          onClick={() => guardNewWork("ホームにもどる", () => go("home"))}
        >
          <Home data-icon="inline-start" />
          ホームにもどる
        </Button>
        <Button
          size="lg"
          variant="outline"
          className="h-13 w-full rounded-2xl font-bold"
          onClick={() => {
            guardNewWork("別の写真を加工する", () => go("home"))
            openPicker()
          }}
        >
          <ImagePlus data-icon="inline-start" />
          別の写真を加工する
        </Button>
      </div>

      <PrivacyNote />
    </div>
  )
}

function ShareButton({
  icon,
  label,
  onClick,
}: {
  icon: React.ReactNode
  label: string
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex h-20 flex-col items-center justify-center gap-1.5 rounded-2xl bg-card px-1 text-[11px] font-medium ring-1 ring-foreground/10 transition-transform active:scale-95"
    >
      <span className="text-primary">{icon}</span>
      <span className="w-full truncate text-center">{label}</span>
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
