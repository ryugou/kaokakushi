"use client"

import * as React from "react"
import { Pause, Play, Plus, ScanFace } from "lucide-react"

import { cn } from "@/lib/utils"
import { formatDuration } from "@/lib/mock-data"
import { useApp } from "@/components/app-provider"
import { ScreenHeader } from "@/components/app-bits"
import { MediaCanvas } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"

export function DetectScreen() {
  const { media, faces, hidden, toggleFace, hideAll, showAll, addManualFace, back, go } = useApp()
  const [playing, setPlaying] = React.useState(false)

  if (!media) return null

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader
        title="隠す顔を選択"
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

        <div className="flex items-center justify-center gap-2 rounded-2xl bg-accent/70 px-3 py-2.5 text-center">
          <ScanFace className="size-4 shrink-0 text-accent-foreground" aria-hidden />
          <p className="text-xs font-medium leading-relaxed text-accent-foreground text-pretty">
            {faces.length}人の顔が見つかりました。顔をタップして、隠す・隠さないを切り替えられます
          </p>
        </div>

        {media.kind === "video" ? (
          <div className="flex flex-col gap-2 rounded-2xl bg-card p-3 ring-1 ring-foreground/10">
            <div className="flex items-center gap-3">
              <Button
                size="icon-lg"
                className="size-11 shrink-0 rounded-full"
                onClick={() => setPlaying((p) => !p)}
              >
                {playing ? <Pause className="size-5" /> : <Play className="size-5" />}
                <span className="sr-only">{playing ? "一時停止" : "再生"}</span>
              </Button>
              <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                <div className="relative h-8 overflow-hidden rounded-xl bg-muted">
                  <div className="flex h-full">
                    {Array.from({ length: 10 }).map((_, i) => (
                      <span
                        key={i}
                        className={cn("h-full flex-1 border-r border-card/70", i % 2 ? "bg-primary/15" : "bg-primary/25")}
                      />
                    ))}
                  </div>
                  <span
                    className={cn(
                      "absolute top-0 h-full w-0.5 bg-foreground",
                      playing ? "animate-[scrub_6s_linear_infinite]" : "left-[18%]",
                    )}
                  />
                </div>
                <div className="flex justify-between text-[10px] text-muted-foreground">
                  <span>0:00</span>
                  <span>顔を追跡します</span>
                  <span>{formatDuration(media.duration ?? 0)}</span>
                </div>
              </div>
            </div>
          </div>
        ) : null}

        <div className="grid grid-cols-2 gap-2">
          <Button variant="outline" size="lg" className="h-12 rounded-2xl text-sm" onClick={hideAll}>
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
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button size="lg" className="h-14 w-full rounded-2xl text-base font-bold" onClick={() => go("effect")}>
          {hidden.length > 0 ? `${hidden.length}人の顔を隠す` : "隠さずに次へ"}
        </Button>
      </div>
    </div>
  )
}
