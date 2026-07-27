"use client"

import * as React from "react"
import { ShieldCheck } from "lucide-react"

import { useApp } from "@/components/app-provider"
import { MediaCanvas } from "@/components/media-canvas"
import { PrivacyNote } from "@/components/app-bits"
import { Progress } from "@/components/ui/progress"

export function ProcessingScreen() {
  const { media, faces, hidden, effect, go, completeExport, effectLabel } = useApp()
  const [progress, setProgress] = React.useState(4)
  const doneRef = React.useRef(false)

  React.useEffect(() => {
    const timer = window.setInterval(() => {
      setProgress((p) => {
        if (p >= 100) return 100
        return Math.min(100, p + Math.random() * 12 + 4)
      })
    }, 220)
    return () => window.clearInterval(timer)
  }, [])

  React.useEffect(() => {
    if (progress < 100 || doneRef.current) return
    doneRef.current = true
    completeExport()
    const t = window.setTimeout(() => go("done"), 500)
    return () => window.clearTimeout(t)
  }, [progress, completeExport, go])

  if (!media) return null

  const step = progress < 35 ? "顔をさがしています" : progress < 75 ? "顔を隠しています" : "書き出しています"

  return (
    <div className="flex min-h-full flex-col items-center justify-center gap-6 px-6 py-10">
      <MediaCanvas
        media={media}
        faces={faces}
        hidden={hidden}
        effect={effect}
        className="aspect-square max-w-[240px]"
      >
        <div className="pointer-events-none absolute inset-0 bg-foreground/10" />
      </MediaCanvas>

      <div className="flex w-full max-w-[260px] flex-col items-center gap-3">
        <p className="font-rounded text-base font-bold">{step}</p>
        <Progress value={progress} className="w-full [&_[data-slot=progress-track]]:h-2.5" />
        <p className="text-xs text-muted-foreground">
          {Math.round(progress)}% ・ {effectLabel}で{hidden.length}人
        </p>
      </div>

      <div className="flex flex-col items-center gap-2">
        <p className="flex items-center gap-1.5 text-xs font-medium text-primary">
          <ShieldCheck className="size-4" aria-hidden />
          写真・動画は外部へ送信していません
        </p>
        <PrivacyNote />
      </div>
    </div>
  )
}
