"use client"

import * as React from "react"
import { AlertTriangle, Clock, Lock, Trash2, Users } from "lucide-react"

import { findMedia, type HistoryItem, type SingleHistoryItem } from "@/lib/mock-data"
import { RETENTION_LABELS, useApp } from "@/components/app-provider"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { MediaThumb } from "@/components/media-canvas"
import { AdSlot, PrivacyNote, ScreenHeader } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"

type GridTile = {
  key: string
  mediaId: string
  effect: SingleHistoryItem["effect"]
  processedAt: string
  method: string
  source: HistoryItem
}

export function HistoryScreen() {
  const { history, hasAds, retention, openUnsavedPrompt } = useApp()
  const [selected, setSelected] = React.useState<GridTile | null>(null)

  // 単体もバッチ内の1枚も、区別なく同じグリッドに並べる（写真アプリ相当のフラット表示）
  // history は新しい加工ほど先頭に追加されるため、そのままの並びで日付降順になる
  const tiles = React.useMemo<GridTile[]>(() => {
    const list: GridTile[] = []
    for (const item of history) {
      if (item.type === "single") {
        list.push({
          key: item.id,
          mediaId: item.mediaId,
          effect: item.effect,
          processedAt: item.processedAt,
          method: item.method,
          source: item,
        })
      } else {
        for (const mediaId of item.mediaIds) {
          list.push({
            key: `${item.id}-${mediaId}`,
            mediaId,
            effect: item.effect,
            processedAt: item.processedAt,
            method: item.method,
            source: item,
          })
        }
      }
    }
    return list
  }, [history])

  const unsavedItem = history.find((h) => h.unsaved)
  const unsavedCount = unsavedItem ? (unsavedItem.type === "batch" ? unsavedItem.doneCount : 1) : 0

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="加工済み写真" subtitle={`端末内にだけ残ります・${RETENTION_LABELS[retention]}`} />

      <div className="flex flex-1 flex-col gap-3 px-4 py-4">
        {retention === "none" ? (
          <p className="rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
            「履歴を保存しない」設定です。加工が終わって画面を離れると、編集設定・検出結果・サムネイルは削除されます。
          </p>
        ) : null}

        {unsavedItem ? <UnsavedBanner onResume={openUnsavedPrompt} count={unsavedCount} /> : null}

        {tiles.length === 0 ? (
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
          <div className="grid grid-cols-3 gap-1.5">
            {tiles.map((tile, index) => (
              <button
                key={tile.key}
                type="button"
                onClick={() => setSelected(tile)}
                className="transition-transform active:scale-95"
              >
                {/* サムネイルは必ず加工後の状態 */}
                <MediaThumb
                  media={findMedia(tile.mediaId)}
                  effect={tile.effect}
                  className="aspect-square w-full ring-1 ring-foreground/10"
                  priority={index === 0}
                />
                <span className="sr-only">
                  {tile.method}・{tile.processedAt}
                </span>
              </button>
            ))}
          </div>
        )}

        {hasAds ? <AdSlot /> : null}

        <PrivacyNote className="pt-2" />
      </div>

      <PhotoActionSheet tile={selected} onClose={() => setSelected(null)} />
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

/**
 * サムネイルをタップすると開く操作シート。
 * 単体の履歴か、バッチ由来の1枚かで内容を出し分ける。
 * バッチ由来の削除は、そのバッチ全体の履歴を削除する（写真1枚だけを
 * バッチから取り除く手段は下層にないため、シート内でその旨を明示する）。
 */
function PhotoActionSheet({ tile, onClose }: { tile: GridTile | null; onClose: () => void }) {
  const {
    removeHistory,
    startReexport,
    startLockedView,
    duplicateAsFree,
    guardNewWork,
    startEditing,
    effectivePlan,
  } = useApp()
  const [duplicating, setDuplicating] = React.useState<SingleHistoryItem | null>(null)

  const single = tile?.source.type === "single" ? tile.source : null
  // 有料スタンプで作った作品は、Freeでも「変更せず再書き出し」だけできる
  // 判定は作成時のプランではなく、内容が要求するプラン（requiredPlan）
  const editLocked = single !== null && effectivePlan === "free" && single.paidFeature !== undefined

  return (
    <>
      <Dialog open={tile !== null} onOpenChange={(open) => (!open ? onClose() : undefined)}>
        <DialogContent className="max-w-[330px] rounded-3xl">
          {tile ? (
            <>
              <DialogHeader>
                <div className="mx-auto">
                  <MediaThumb
                    media={findMedia(tile.mediaId)}
                    effect={tile.effect}
                    className="size-24 ring-1 ring-foreground/10"
                  />
                </div>
                <DialogTitle className="text-center font-rounded text-base leading-snug">{tile.method}</DialogTitle>
                <DialogDescription className="text-center leading-relaxed">{tile.processedAt}</DialogDescription>
              </DialogHeader>

              {single ? (
                <div className="flex flex-wrap items-center justify-center gap-1.5">
                  <Badge variant="outline" className="gap-1 text-[10px]">
                    <Users className="size-2.5" aria-hidden />
                    {single.faceCount}人
                  </Badge>
                  {editLocked ? (
                    <Badge variant="outline" className="gap-1 text-[10px]">
                      <Lock className="size-2.5" aria-hidden />
                      そのまま書き出し可
                    </Badge>
                  ) : null}
                </div>
              ) : null}

              <div className="flex flex-col gap-2">
                {single ? (
                  editLocked ? (
                    <>
                      <Button
                        size="lg"
                        className="h-12 rounded-2xl text-sm font-bold"
                        onClick={() => {
                          onClose()
                          guardNewWork("再書き出し", () => startReexport(single))
                        }}
                      >
                        再書き出し
                      </Button>
                      <Button
                        size="lg"
                        variant="secondary"
                        className="h-11 rounded-2xl text-sm font-bold"
                        onClick={() => {
                          onClose()
                          guardNewWork("内容を見る", () => startLockedView(single))
                        }}
                      >
                        内容を見る
                      </Button>
                      <Button
                        size="lg"
                        variant="ghost"
                        className="h-11 rounded-2xl text-sm font-bold text-primary"
                        onClick={() => {
                          onClose()
                          setDuplicating(single)
                        }}
                      >
                        Free版として複製
                      </Button>
                    </>
                  ) : (
                    <>
                      <Button
                        size="lg"
                        className="h-12 rounded-2xl text-sm font-bold"
                        onClick={() => {
                          onClose()
                          guardNewWork("もう一度", () => startEditing(single.mediaId))
                        }}
                      >
                        もう一度
                      </Button>
                      <Button
                        size="lg"
                        variant="ghost"
                        className="h-11 rounded-2xl text-sm font-bold text-destructive"
                        onClick={() => {
                          onClose()
                          removeHistory(single.id)
                        }}
                      >
                        <Trash2 data-icon="inline-start" />
                        この写真の履歴を削除
                      </Button>
                    </>
                  )
                ) : (
                  <>
                    <Button
                      size="lg"
                      className="h-12 rounded-2xl text-sm font-bold"
                      onClick={() => {
                        const mediaId = tile.mediaId
                        onClose()
                        guardNewWork("この写真を編集", () => startEditing(mediaId))
                      }}
                    >
                      この写真を編集
                    </Button>
                    <Button
                      size="lg"
                      variant="ghost"
                      className="h-11 rounded-2xl text-sm font-bold text-destructive"
                      onClick={() => {
                        const batchId = tile.source.id
                        onClose()
                        removeHistory(batchId)
                      }}
                    >
                      <Trash2 data-icon="inline-start" />
                      この一括処理の履歴を削除
                    </Button>
                    <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
                      同じ一括処理で加工した他の写真の履歴も、まとめて削除されます。
                    </p>
                  </>
                )}
                <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={onClose}>
                  とじる
                </Button>
              </div>
            </>
          ) : null}
        </DialogContent>
      </Dialog>

      {/* 置き換え先は利用者に選ばせる。決め打ちすると意図しない見た目になる */}
      <Dialog open={duplicating !== null} onOpenChange={(open) => (!open ? setDuplicating(null) : undefined)}>
        <DialogContent className="max-w-[330px] rounded-3xl">
          <DialogHeader>
            <DialogTitle className="font-rounded text-base leading-snug">どの隠し方に置き換えますか？</DialogTitle>
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
                  const target = duplicating
                  setDuplicating(null)
                  if (target) guardNewWork("Free版として複製", () => duplicateAsFree(target, t))
                }}
              >
                {t === "stamp" ? "基本スタンプ" : EFFECT_LABELS[t]}
              </Button>
            ))}
          </div>
          <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={() => setDuplicating(null)}>
            やめる
          </Button>
        </DialogContent>
      </Dialog>
    </>
  )
}
