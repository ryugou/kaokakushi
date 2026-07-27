"use client"

import { Clock, Play, Trash2, Users } from "lucide-react"

import { findMedia, formatDuration } from "@/lib/mock-data"
import { useApp } from "@/components/app-provider"
import { MediaThumb } from "@/components/media-canvas"
import { AdSlot, PrivacyNote, ScreenHeader } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"

export function HistoryScreen() {
  const { history, removeHistory, startEditing, hasAds } = useApp()

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="加工の履歴" subtitle="端末内にだけ残ります" />

      <div className="flex flex-1 flex-col gap-3 px-4 py-4">
        {history.length === 0 ? (
          <Empty className="rounded-3xl bg-card ring-1 ring-foreground/10">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <Clock />
              </EmptyMedia>
              <EmptyTitle className="font-rounded">履歴はまだありません</EmptyTitle>
              <EmptyDescription>加工した写真や動画がここに並びます</EmptyDescription>
            </EmptyHeader>
          </Empty>
        ) : (
          history.map((item, index) => {
            const media = findMedia(item.mediaId)
            return (
              <article
                key={item.id}
                className="flex items-center gap-3 rounded-2xl bg-card p-3 ring-1 ring-foreground/10"
              >
                <MediaThumb
                  media={media}
                  effect={item.effect}
                  className="size-16 shrink-0"
                  priority={index === 0}
                />
                <div className="flex min-w-0 flex-1 flex-col gap-1">
                  <p className="truncate text-sm font-bold">{media.title}</p>
                  <p className="truncate text-[11px] text-muted-foreground">{item.processedAt}</p>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <Badge variant="secondary" className="text-[10px]">
                      {item.method}
                    </Badge>
                    <Badge variant="outline" className="gap-1 text-[10px]">
                      <Users className="size-2.5" aria-hidden />
                      {item.faceCount}人
                    </Badge>
                    {item.kind === "video" ? (
                      <Badge variant="outline" className="gap-1 text-[10px]">
                        <Play className="size-2.5" aria-hidden />
                        {formatDuration(media.duration ?? 0)}
                      </Badge>
                    ) : null}
                  </div>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  <Button
                    size="sm"
                    variant="secondary"
                    className="h-8 rounded-xl text-[11px] font-bold"
                    onClick={() => startEditing(item.mediaId)}
                  >
                    もう一度
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className="size-8 rounded-xl text-muted-foreground"
                    onClick={() => removeHistory(item.id)}
                  >
                    <Trash2 className="size-4" />
                    <span className="sr-only">{media.title}の履歴を削除</span>
                  </Button>
                </div>
              </article>
            )
          })
        )}

        {hasAds ? <AdSlot /> : null}

        <PrivacyNote className="pt-2" />
      </div>
    </div>
  )
}
