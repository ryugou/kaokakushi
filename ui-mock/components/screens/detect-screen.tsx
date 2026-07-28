"use client"

import { AlertTriangle, Plus, ScanFace, X } from "lucide-react"

import { faceNeedsReview, triage } from "@/lib/mock-data"
import { useApp } from "@/components/app-provider"
import { ScreenHeader } from "@/components/app-bits"
import { MediaCanvas } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"

export function DetectScreen() {
  const { media, faces, hidden, toggleFace, hideAll, showAll, addManualFace, back, go } = useApp()

  if (!media) return null

  const noFace = faces.length === 0
  const warnings = triage(media).filter((i) => i.reason !== "no-face")
  const reviewFaces = faces.filter(faceNeedsReview).length

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader
        title="隠す顔を確認"
        onBack={back}
        action={
          <Button variant="ghost" className="h-10 rounded-full px-3 font-bold text-primary" onClick={() => go("effect")}>
            次へ
          </Button>
        }
      />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        <MediaCanvas
          media={media}
          faces={faces}
          hidden={hidden}
          selectable
          onToggleFace={toggleFace}
          className="aspect-square"
        />

        {noFace ? (
          <>
            <div className="flex items-start gap-2 rounded-2xl bg-chart-3/20 px-3 py-2.5">
              <AlertTriangle className="mt-0.5 size-4 shrink-0 text-foreground" aria-hidden />
              <p className="text-xs font-medium leading-relaxed text-foreground text-pretty">
                顔は検出されませんでした。写っている顔が見つからないことがあります。書き出す前に写真をご確認ください。
              </p>
            </div>

            <div className="flex flex-col gap-2">
              <Button size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={addManualFace}>
                <Plus data-icon="inline-start" />
                手動で隠す範囲を追加する
              </Button>
              <Button
                variant="outline"
                size="lg"
                className="h-12 rounded-2xl text-sm font-bold"
                onClick={() => go("export")}
              >
                顔加工なしで書き出し設定へ
              </Button>
              <Button
                variant="ghost"
                size="lg"
                className="h-12 rounded-2xl text-sm text-muted-foreground"
                onClick={back}
              >
                <X data-icon="inline-start" />
                編集を終了する
              </Button>
            </div>
          </>
        ) : (
          <>
            <div className="flex items-center justify-center gap-2 rounded-2xl bg-accent/70 px-3 py-2.5 text-center">
              <ScanFace className="size-4 shrink-0 text-accent-foreground" aria-hidden />
              <p className="text-xs font-medium leading-relaxed text-accent-foreground text-pretty">
                {faces.length}人の顔が見つかりました。すべて隠す状態から始まります。残したい顔はタップしてください
              </p>
            </div>

            {warnings.length > 0 || reviewFaces > 0 ? (
              <div className="flex flex-col gap-1.5 rounded-2xl bg-chart-3/15 px-3 py-2.5">
                <p className="flex items-center gap-1.5 text-[11px] font-bold text-foreground">
                  <AlertTriangle className="size-3.5 shrink-0" aria-hidden />
                  確認が必要です
                </p>
                <ul className="flex flex-col gap-0.5 pl-5 text-[11px] leading-relaxed text-foreground">
                  {warnings.map((i) => (
                    <li key={i.id} className="list-disc">
                      {i.label}
                    </li>
                  ))}
                </ul>
                <p className="pl-5 text-[11px] leading-relaxed text-muted-foreground">
                  これらの顔も隠す設定のままです。必要に応じて手動で範囲を足してください。
                </p>
              </div>
            ) : null}

            <div className="grid grid-cols-2 gap-2">
              <Button size="lg" className="h-12 rounded-2xl text-sm" onClick={hideAll}>
                すべて隠す
              </Button>
              <Button variant="outline" size="lg" className="h-12 rounded-2xl text-sm" onClick={showAll}>
                すべて残す
              </Button>
            </div>

            <Button
              variant="ghost"
              size="lg"
              className="h-12 rounded-2xl text-sm text-muted-foreground"
              onClick={addManualFace}
            >
              <Plus data-icon="inline-start" />
              手動で範囲を追加
            </Button>
          </>
        )}
      </div>

      {!noFace ? (
        <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
          <Button size="lg" className="h-14 w-full rounded-2xl text-base font-bold" onClick={() => go("effect")}>
            {hidden.length > 0 ? `${hidden.length}人の顔を隠す` : "隠さずに次へ"}
          </Button>
        </div>
      ) : null}
    </div>
  )
}
