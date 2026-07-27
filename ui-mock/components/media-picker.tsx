"use client"

import Image from "next/image"
import { Play } from "lucide-react"

import { formatDuration, MEDIA_LIBRARY, type MediaKind } from "@/lib/mock-data"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { PrivacyNote } from "@/components/app-bits"
import { useApp } from "@/components/app-provider"

export function MediaPicker({
  kind,
  onClose,
  onSelect,
}: {
  kind: MediaKind | null
  onClose: () => void
  onSelect: (id: string) => void
}) {
  const { videoLimitSec, videoLimitLabel } = useApp()
  const items = MEDIA_LIBRARY.filter((m) => (kind ? m.kind === kind : true))

  return (
    <Dialog open={kind !== null} onOpenChange={(open) => (!open ? onClose() : undefined)}>
      <DialogContent className="max-w-[340px] rounded-3xl">
        <DialogHeader>
          <DialogTitle className="font-rounded">
            {kind === "video" ? "動画を選ぶ" : "写真を選ぶ"}
          </DialogTitle>
          <DialogDescription>
            {kind === "video" ? `端末のライブラリから選びます・上限${videoLimitLabel}` : "端末のライブラリから選びます"}
          </DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-3 gap-2">
          {items.map((item) => {
            const tooLong = item.kind === "video" && (item.duration ?? 0) > videoLimitSec
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => onSelect(item.id)}
                className="relative aspect-square overflow-hidden rounded-2xl bg-muted ring-1 ring-foreground/10 transition-transform active:scale-95"
              >
                <Image
                  src={item.src || "/placeholder.svg"}
                  alt={item.title}
                  fill
                  sizes="120px"
                  className={tooLong ? "object-cover opacity-55" : "object-cover"}
                />
                {item.kind === "video" ? (
                  <span
                    className={
                      tooLong
                        ? "absolute bottom-1 left-1 flex items-center gap-1 rounded-full bg-chart-4 px-1.5 py-0.5 text-[9px] font-bold text-background"
                        : "absolute bottom-1 left-1 flex items-center gap-1 rounded-full bg-foreground/70 px-1.5 py-0.5 text-[9px] font-medium text-background"
                    }
                  >
                    <Play className="size-2.5" aria-hidden />
                    {formatDuration(item.duration ?? 0)}
                  </span>
                ) : null}
                {tooLong ? (
                  <span className="absolute right-1 top-1 rounded-full bg-foreground px-1.5 py-0.5 text-[9px] font-bold text-background">
                    上限超え
                  </span>
                ) : null}
              </button>
            )
          })}
        </div>
        <PrivacyNote />
      </DialogContent>
    </Dialog>
  )
}
