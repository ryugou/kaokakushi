"use client"

import * as React from "react"
import { AlertTriangle, ChevronDown, Clock, Layers, Lock, Trash2, Users } from "lucide-react"

import { cn } from "@/lib/utils"
import { findMedia, type BatchHistoryItem, type SingleHistoryItem } from "@/lib/mock-data"
import { RETENTION_LABELS, useApp } from "@/components/app-provider"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { MediaThumb } from "@/components/media-canvas"
import { AdSlot, PrivacyNote, ScreenHeader } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"

export function HistoryScreen() {
  const { history, hasAds, retention, openUnsavedPrompt } = useApp()

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="加工済み写真" subtitle={`端末内にだけ残ります・${RETENTION_LABELS[retention]}`} />

      <div className="flex flex-1 flex-col gap-3 px-4 py-4">
        {retention === "none" ? (
          <p className="rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
            「履歴を保存しない」設定です。加工が終わって画面を離れると、編集設定・検出結果・サムネイルは削除されます。
          </p>
        ) : null}

        {history.length === 0 ? (
          <Empty className="rounded-3xl bg-card ring-1 ring-foreground/10">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <Clock />
              </EmptyMedia>
              <EmptyTitle className="font-rounded">履歴はまだありません</EmptyTitle>
              <EmptyDescription>加工した写真がここに並びます</EmptyDescription>
            </EmptyHeader>
          </Empty>
        ) : (
          history.map((item, index) =>
            item.type === "batch" ? (
              <BatchRow key={item.id} item={item} onResume={openUnsavedPrompt} />
            ) : (
              <SingleRow key={item.id} item={item} priority={index === 0} onResume={openUnsavedPrompt} />
            ),
          )
        )}

        {hasAds ? <AdSlot /> : null}

        <PrivacyNote className="pt-2" />
      </div>
    </div>
  )
}

function UnsavedBanner({ onResume, count }: { onResume: () => void; count: number }) {
  return (
    <button
      type="button"
      onClick={onResume}
      className="flex w-full items-center gap-2 rounded-xl bg-chart-3/20 px-2.5 py-1.5 text-left"
    >
      <AlertTriangle className="size-3.5 shrink-0 text-foreground" aria-hidden />
      <span className="min-w-0 flex-1 truncate text-[10px] font-bold text-foreground">
        {count > 1 ? `未保存の加工済み写真が${count}枚あります` : "未保存の加工済み写真があります"}
      </span>
      <span className="shrink-0 text-[10px] font-bold text-primary">保存する</span>
    </button>
  )
}

function SingleRow({
  item,
  priority,
  onResume,
}: {
  item: SingleHistoryItem
  priority?: boolean
  onResume: () => void
}) {
  const { removeHistory, startReexport, startLockedView, duplicateAsFree, guardNewWork, startEditing, effectivePlan } =
    useApp()
  const [duplicating, setDuplicating] = React.useState(false)
  const media = findMedia(item.mediaId)
  // 有料スタンプで作った作品は、Freeでも「変更せず再書き出し」だけできる
  // 判定は作成時のプランではなく、内容が要求するプラン（requiredPlan）
  const editLocked = effectivePlan === "free" && item.paidFeature !== undefined

  return (
    <article className="flex flex-col gap-2 rounded-2xl bg-card p-3 ring-1 ring-foreground/10">
      {item.unsaved ? <UnsavedBanner onResume={onResume} count={1} /> : null}
      <div className="flex items-center gap-3">
        {/* サムネイルは必ず加工後の状態 */}
        <MediaThumb media={media} effect={item.effect} className="size-16 shrink-0" priority={priority} />
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <p className="truncate text-sm font-bold">{item.method}</p>
          <p className="truncate text-[11px] text-muted-foreground">{item.processedAt}</p>
          <div className="flex flex-wrap items-center gap-1.5">
            <Badge variant="outline" className="gap-1 text-[10px]">
              <Users className="size-2.5" aria-hidden />
              {item.faceCount}人
            </Badge>
            {editLocked ? (
              <Badge variant="outline" className="gap-1 text-[10px]">
                <Lock className="size-2.5" aria-hidden />
                そのまま書き出し可
              </Badge>
            ) : null}
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <Button
            size="sm"
            variant="secondary"
            className="h-8 rounded-xl text-[11px] font-bold"
            onClick={() =>
              guardNewWork("再書き出し", () => (editLocked ? startReexport(item) : startEditing(item.mediaId)))
            }
          >
            {editLocked ? "再書き出し" : "もう一度"}
          </Button>
          {editLocked ? (
            // 閲覧はできる。変更しようとした時点でStandardを案内する
            <>
              <Button
                size="sm"
                variant="ghost"
                className="h-7 rounded-xl px-2 text-[10px] text-muted-foreground"
                onClick={() => guardNewWork("内容を見る", () => startLockedView(item))}
              >
                内容を見る
              </Button>
              <Button
                size="sm"
                variant="ghost"
                className="h-7 rounded-xl px-2 text-[10px] text-primary"
                onClick={() => setDuplicating(true)}
              >
                Free版として複製
              </Button>
            </>
          ) : (
            <Button
              size="icon"
              variant="ghost"
              className="size-8 rounded-xl text-muted-foreground"
              onClick={() => removeHistory(item.id)}
            >
              <Trash2 className="size-4" />
              <span className="sr-only">この写真の履歴を削除</span>
            </Button>
          )}
        </div>
      </div>

      {/* 置き換え先は利用者に選ばせる。決め打ちすると意図しない見た目になる */}
      <Dialog open={duplicating} onOpenChange={(open) => (!open ? setDuplicating(false) : undefined)}>
        <DialogContent className="max-w-[330px] rounded-3xl">
          <DialogHeader>
            <DialogTitle className="font-rounded text-base leading-snug">
              どの隠し方に置き換えますか？
            </DialogTitle>
            <DialogDescription className="leading-relaxed">
              有料スタンプを使っていた部分だけを置き換えた複製を作ります。範囲の位置と大きさ、その他の設定はそのまま引き継ぎます。元の作品は変わりません。
            </DialogDescription>
          </DialogHeader>
          <div className="grid grid-cols-2 gap-2">
            {(["mosaic", "blur", "black", "stamp"] as EffectType[]).map((t) => (
              <Button
                key={t}
                size="lg"
                variant="secondary"
                className="h-12 rounded-2xl text-sm font-bold"
                onClick={() => {
                  setDuplicating(false)
                  guardNewWork("Free版として複製", () => duplicateAsFree(item, t))
                }}
              >
                {t === "stamp" ? "基本スタンプ" : EFFECT_LABELS[t]}
              </Button>
            ))}
          </div>
          <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={() => setDuplicating(false)}>
            やめる
          </Button>
        </DialogContent>
      </Dialog>
    </article>
  )
}

/** 一括処理はバッチ単位で1件にまとめる */
function BatchRow({ item, onResume }: { item: BatchHistoryItem; onResume: () => void }) {
  const { removeHistory, guardNewWork, startEditing } = useApp()
  const [open, setOpen] = React.useState(false)

  return (
    <article className="flex flex-col gap-2 rounded-2xl bg-card p-3 ring-1 ring-foreground/10">
      {item.unsaved ? <UnsavedBanner onResume={onResume} count={item.doneCount} /> : null}
      <div className="flex items-center gap-3">
        <span className="grid size-16 shrink-0 place-items-center rounded-2xl bg-secondary text-primary">
          <Layers className="size-6" aria-hidden />
        </span>
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <p className="truncate text-sm font-bold">
            まとめて加工 {item.doneCount + item.errorCount}枚
          </p>
          <p className="truncate text-[11px] text-muted-foreground">{item.processedAt}</p>
          <div className="flex flex-wrap items-center gap-1.5">
            <Badge variant="secondary" className="text-[10px]">
              {item.method}
            </Badge>
            <Badge variant="outline" className="text-[10px]">
              {item.doneCount}枚完了
              {item.errorCount > 0 ? ` ・ ${item.errorCount}枚エラー` : ""}
            </Badge>
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <Button
            size="sm"
            variant="secondary"
            className="h-8 rounded-xl text-[11px] font-bold"
            onClick={() => setOpen((o) => !o)}
          >
            <ChevronDown
              className={cn("size-3.5 transition-transform", open && "rotate-180")}
              data-icon="inline-start"
            />
            {open ? "とじる" : "開く"}
          </Button>
          <Button
            size="icon"
            variant="ghost"
            className="size-8 rounded-xl text-muted-foreground"
            onClick={() => removeHistory(item.id)}
          >
            <Trash2 className="size-4" />
            <span className="sr-only">この一括処理の履歴を削除</span>
          </Button>
        </div>
      </div>

      {open ? (
        <div className="flex flex-col gap-2 border-t pt-2">
          {/* バッチ内の1枚を開く操作は単体編集なので requiredPlan に従う */}
          <p className="text-[10px] leading-relaxed text-muted-foreground">
            写真をタップすると、1枚だけ選んで編集し直せます。
          </p>
          <div className="grid grid-cols-4 gap-2">
            {item.mediaIds.map((id) => (
              <button
                key={id}
                type="button"
                onClick={() => guardNewWork("この写真を編集", () => startEditing(id))}
                className="transition-transform active:scale-95"
              >
                <MediaThumb
                  media={findMedia(id)}
                  effect={item.effect}
                  className="aspect-square w-full ring-1 ring-foreground/10"
                />
                <span className="sr-only">この写真を編集する</span>
              </button>
            ))}
          </div>
        </div>
      ) : null}
    </article>
  )
}
