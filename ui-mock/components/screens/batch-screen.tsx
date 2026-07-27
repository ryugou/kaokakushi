"use client"

import * as React from "react"
import {
  AlertTriangle,
  Check,
  CheckCircle2,
  Crown,
  Layers,
  ListChecks,
  Pause,
  Play,
  RotateCcw,
  Save,
  X,
} from "lucide-react"

import { cn } from "@/lib/utils"
import { formatDuration, MEDIA_LIBRARY } from "@/lib/mock-data"
import { STAMPS } from "@/lib/stamps"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import { BATCH_MAX_ITEMS, useApp, type ExportRatio } from "@/components/app-provider"
import { MediaThumb } from "@/components/media-canvas"
import { PrivacyNote, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"

const BATCH_EFFECTS: EffectType[] = ["mosaic", "blur", "black", "stamp"]

const RATIOS: { id: ExportRatio; label: string }[] = [
  { id: "1:1", label: "1:1" },
  { id: "4:5", label: "4:5" },
  { id: "9:16", label: "9:16" },
  { id: "original", label: "元の比率" },
]

type ItemStatus = "queued" | "detecting" | "review" | "exporting" | "done" | "error" | "canceled"

const STATUS_META: Record<ItemStatus, { label: string; className: string }> = {
  queued: { label: "未処理", className: "bg-muted text-muted-foreground" },
  detecting: { label: "顔を検出中", className: "bg-primary/15 text-primary" },
  review: { label: "確認が必要", className: "bg-chart-3/25 text-foreground" },
  exporting: { label: "書き出し中", className: "bg-primary/15 text-primary" },
  done: { label: "完了", className: "bg-primary text-primary-foreground" },
  error: { label: "エラー", className: "bg-destructive/15 text-destructive" },
  canceled: { label: "キャンセル", className: "bg-muted text-muted-foreground" },
}

/** デモ用に、素材ごとの処理結果をあらかじめ決めておく */
const PLANNED: Record<string, "ok" | "review" | "error"> = {
  m2: "review",
  m6: "error",
}

type QueueItem = { mediaId: string; status: ItemStatus; outcome: "ok" | "review" | "error" }

const ACTIVE_STATUSES: ItemStatus[] = ["queued", "detecting", "exporting"]

export function BatchScreen() {
  const { back, go, canBatch, canUseQueue, effect, setEffect, exportSettings, updateExport } = useApp()
  const [selected, setSelected] = React.useState<string[]>(["m1", "m2", "m3", "m6"])
  const [queue, setQueue] = React.useState<QueueItem[] | null>(null)
  const [running, setRunning] = React.useState(false)

  const total = queue?.length ?? selected.length
  const doneCount = queue?.filter((q) => q.status === "done").length ?? 0
  const errorCount = queue?.filter((q) => q.status === "error").length ?? 0
  const reviewCount = queue?.filter((q) => q.status === "review").length ?? 0
  const activeIndex = queue?.findIndex((q) => ACTIVE_STATUSES.includes(q.status)) ?? -1
  const remaining = queue ? queue.filter((q) => !["done", "error", "canceled"].includes(q.status)).length : 0
  const settled = queue ? total - remaining : 0
  const overall = queue && total > 0 ? Math.round((settled / total) * 100) : 0
  const finished = queue !== null && remaining === 0

  // キューを1ステップずつ進める
  React.useEffect(() => {
    if (!running || !queue) return
    const index = queue.findIndex((q) => ACTIVE_STATUSES.includes(q.status))
    if (index === -1) {
      setRunning(false)
      return
    }
    const timer = window.setTimeout(() => {
      setQueue((prev) => {
        if (!prev) return prev
        const next = [...prev]
        const item = next[index]
        if (item.status === "queued") {
          next[index] = { ...item, status: "detecting" }
        } else if (item.status === "detecting") {
          next[index] =
            item.outcome === "review"
              ? { ...item, status: "review", outcome: "ok" }
              : { ...item, status: "exporting" }
        } else if (item.status === "exporting") {
          next[index] = { ...item, status: item.outcome === "error" ? "error" : "done" }
        }
        return next
      })
    }, 620)
    return () => window.clearTimeout(timer)
  }, [running, queue])

  const toggle = (id: string) => {
    if (queue) return
    setSelected((prev) =>
      prev.includes(id)
        ? prev.filter((x) => x !== id)
        : prev.length >= BATCH_MAX_ITEMS
          ? prev
          : [...prev, id],
    )
  }

  const start = () => {
    setQueue(
      selected.map((mediaId) => ({
        mediaId,
        status: "queued" as ItemStatus,
        outcome: PLANNED[mediaId] ?? "ok",
      })),
    )
    setRunning(true)
  }

  const cancelAll = () => {
    setRunning(false)
    setQueue((prev) =>
      prev
        ? prev.map((q) => (["done", "error"].includes(q.status) ? q : { ...q, status: "canceled" }))
        : prev,
    )
  }

  const retryErrors = () => {
    setQueue((prev) => (prev ? prev.map((q) => (q.status === "error" ? { ...q, status: "queued", outcome: "ok" } : q)) : prev))
    setRunning(true)
  }

  const confirmReview = (mediaId: string) => {
    setQueue((prev) =>
      prev ? prev.map((q) => (q.mediaId === mediaId && q.status === "review" ? { ...q, status: "queued" } : q)) : prev,
    )
    setRunning(true)
  }

  const reset = () => {
    setQueue(null)
    setRunning(false)
  }

  if (!canBatch) {
    return (
      <div className="flex min-h-full flex-col">
        <ScreenHeader title="まとめて加工" onBack={back} subtitle="Proプランの機能です" />
        <div className="flex flex-1 flex-col gap-4 px-4 py-6">
          <div className="flex flex-col items-center gap-2 rounded-3xl bg-card p-6 text-center ring-1 ring-foreground/10">
            <span className="grid size-12 place-items-center rounded-2xl bg-chart-3/20">
              <Crown className="size-6 text-foreground" aria-hidden />
            </span>
            <p className="font-rounded text-sm font-bold">まとめて加工はProの機能です</p>
            <p className="text-[11px] leading-relaxed text-muted-foreground text-pretty">
              Proなら、複数の写真や動画をまとめて加工・保存できます。1回の一括処理で最大{BATCH_MAX_ITEMS}素材まで扱えます。
            </p>
            <Button
              size="lg"
              className="mt-1 h-12 w-full rounded-2xl font-bold"
              onClick={() => go("pricing")}
            >
              Proを確認する
            </Button>
          </div>
          <PrivacyNote />
        </div>
      </div>
    )
  }

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader
        title="まとめて加工"
        onBack={back}
        subtitle={`最大${BATCH_MAX_ITEMS}素材まで選べます`}
        action={
          <Badge variant="secondary" className="text-[10px]">
            {selected.length}件
          </Badge>
        }
      />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        {queue ? (
          <section className="flex flex-col gap-3 rounded-3xl bg-card p-4 ring-1 ring-foreground/10">
            <div className="flex items-start justify-between gap-2">
              <div className="flex min-w-0 flex-col gap-0.5">
                <p className="flex items-center gap-1.5 font-rounded text-sm font-bold">
                  <ListChecks className="size-4 text-primary" aria-hidden />
                  処理キュー
                </p>
                <p className="text-[11px] text-muted-foreground">
                  {total}件中{doneCount}件が完了しました
                </p>
              </div>
              <Badge variant={finished ? "default" : "secondary"} className="shrink-0 text-[10px]">
                {finished ? "処理完了" : running ? "処理中" : "一時停止中"}
              </Badge>
            </div>

            <Progress value={overall} className="w-full [&_[data-slot=progress-track]]:h-2.5" />

            <div className="grid grid-cols-3 gap-2">
              <Stat label="完了" value={`${doneCount}件`} />
              <Stat label="残り" value={`${remaining}件`} />
              <Stat label="全体の進捗" value={`${overall}%`} />
            </div>

            <p className="text-[11px] leading-relaxed text-muted-foreground">
              {finished
                ? errorCount > 0
                  ? `${errorCount}件の処理に失敗しました。ほかの素材は最後まで処理されています。`
                  : "すべての素材の処理が終わりました"
                : activeIndex >= 0 && running
                  ? `次の素材を処理しています（${MEDIA_LIBRARY.find((m) => m.id === queue[activeIndex]?.mediaId)?.title ?? ""}）`
                  : reviewCount > 0
                    ? `${reviewCount}件の確認が必要です`
                    : "一時停止しています"}
            </p>

            {reviewCount > 0 ? (
              <p className="rounded-2xl bg-chart-3/15 px-3 py-2 text-[11px] font-medium leading-relaxed text-foreground">
                {reviewCount}件の確認が必要です。確認していない素材はとばして、残りの処理を続けます。
              </p>
            ) : null}

            <div className="flex flex-wrap gap-2">
              {!finished ? (
                running ? (
                  <Button
                    size="sm"
                    variant="secondary"
                    className="h-9 rounded-xl text-[11px] font-bold"
                    onClick={() => setRunning(false)}
                  >
                    <Pause data-icon="inline-start" />
                    一時停止
                  </Button>
                ) : (
                  <Button
                    size="sm"
                    className="h-9 rounded-xl text-[11px] font-bold"
                    onClick={() => setRunning(true)}
                  >
                    <Play data-icon="inline-start" />
                    再開
                  </Button>
                )
              ) : null}
              {errorCount > 0 ? (
                <Button
                  size="sm"
                  variant="secondary"
                  className="h-9 rounded-xl text-[11px] font-bold"
                  onClick={retryErrors}
                >
                  <RotateCcw data-icon="inline-start" />
                  失敗した素材だけ再試行
                </Button>
              ) : null}
              {doneCount > 0 ? (
                <Button size="sm" variant="secondary" className="h-9 rounded-xl text-[11px] font-bold">
                  <Save data-icon="inline-start" />
                  完了した{doneCount}件だけ保存
                </Button>
              ) : null}
              {!finished ? (
                <Button
                  size="sm"
                  variant="ghost"
                  className="h-9 rounded-xl text-[11px] font-bold text-muted-foreground"
                  onClick={cancelAll}
                >
                  <X data-icon="inline-start" />
                  キャンセル
                </Button>
              ) : null}
            </div>

            <ul className="flex flex-col gap-2">
              {queue.map((item, index) => {
                const media = MEDIA_LIBRARY.find((m) => m.id === item.mediaId)
                if (!media) return null
                const meta = STATUS_META[item.status]
                const isActive = index === activeIndex && running
                return (
                  <li
                    key={item.mediaId}
                    className={cn(
                      "flex items-center gap-3 rounded-2xl bg-secondary/50 p-2",
                      isActive && "ring-2 ring-primary",
                    )}
                  >
                    <MediaThumb
                      media={media}
                      effect={["done", "exporting"].includes(item.status) ? effect : null}
                      className="size-12 shrink-0"
                    />
                    <div className="flex min-w-0 flex-1 flex-col gap-1">
                      <p className="truncate text-xs font-bold">{media.title}</p>
                      <p className="truncate text-[10px] text-muted-foreground">
                        {media.kind === "video" ? `動画 ${formatDuration(media.duration ?? 0)}` : "写真"} ・ 顔
                        {media.faces.length}件
                      </p>
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      <span className={cn("rounded-full px-2 py-0.5 text-[10px] font-bold", meta.className)}>
                        {meta.label}
                      </span>
                      {item.status === "review" ? (
                        <Button
                          size="sm"
                          variant="secondary"
                          className="h-7 rounded-lg text-[10px] font-bold"
                          onClick={() => confirmReview(item.mediaId)}
                        >
                          確認する
                        </Button>
                      ) : null}
                      {item.status === "error" ? (
                        <span className="flex items-center gap-1 text-[10px] text-destructive">
                          <AlertTriangle className="size-3" aria-hidden />
                          再試行できます
                        </span>
                      ) : null}
                    </div>
                  </li>
                )
              })}
            </ul>
          </section>
        ) : null}

        {finished && errorCount === 0 ? (
          <div className="flex flex-col items-center gap-2 rounded-3xl bg-primary/10 p-5 text-center">
            <CheckCircle2 className="size-8 text-primary" aria-hidden />
            <p className="font-rounded text-sm font-bold">{doneCount}件の処理が完了しました</p>
            <p className="text-[11px] text-muted-foreground">
              {EFFECT_LABELS[effect.type]}を全素材に適用して書き出しました
            </p>
          </div>
        ) : null}

        {!queue ? (
          <>
            <section className="flex flex-col gap-2">
              <SectionTitle>全素材へ同じ加工設定を適用</SectionTitle>
              <div className="grid grid-cols-4 gap-2">
                {BATCH_EFFECTS.map((t) => (
                  <button
                    key={t}
                    type="button"
                    onClick={() => setEffect((prev) => ({ ...prev, type: t }))}
                    className={cn(
                      "h-12 rounded-2xl text-xs font-bold transition-colors",
                      effect.type === t
                        ? "bg-primary text-primary-foreground"
                        : "bg-card text-foreground ring-1 ring-foreground/10",
                    )}
                  >
                    {EFFECT_LABELS[t]}
                  </button>
                ))}
              </div>
            </section>

            {effect.type === "stamp" ? (
              <section className="flex flex-col gap-2">
                <SectionTitle>全素材へ同じスタンプを適用</SectionTitle>
                <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1">
                  {STAMPS.slice(0, 12).map((s) => {
                    const Icon = s.icon
                    const active = effect.stampId === s.id
                    return (
                      <button
                        key={s.id}
                        type="button"
                        onClick={() => setEffect((prev) => ({ ...prev, stampId: s.id }))}
                        className="flex w-14 shrink-0 flex-col items-center gap-1"
                      >
                        <span
                          className={cn(
                            "grid size-12 place-items-center rounded-2xl",
                            s.bg,
                            active && "ring-2 ring-foreground ring-offset-2",
                          )}
                        >
                          <Icon className={cn("size-6", s.fg)} aria-hidden />
                        </span>
                        <span className="w-full truncate text-center text-[10px] text-muted-foreground">
                          {s.name}
                        </span>
                      </button>
                    )
                  })}
                </div>
              </section>
            ) : null}

            <section className="flex flex-col gap-2">
              <SectionTitle>全素材へ同じ出力比率を適用</SectionTitle>
              <div className="grid grid-cols-4 gap-2">
                {RATIOS.map((r) => (
                  <button
                    key={r.id}
                    type="button"
                    onClick={() => updateExport({ ratio: r.id })}
                    className={cn(
                      "h-11 rounded-2xl text-[11px] font-bold transition-colors",
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
              <SectionTitle
                action={
                  <span className="text-[11px] text-muted-foreground">
                    {selected.length} / {BATCH_MAX_ITEMS}素材
                  </span>
                }
              >
                写真・動画をえらぶ
              </SectionTitle>
              <div className="grid grid-cols-3 gap-2">
                {MEDIA_LIBRARY.map((m) => {
                  const on = selected.includes(m.id)
                  return (
                    <button
                      key={m.id}
                      type="button"
                      onClick={() => toggle(m.id)}
                      aria-pressed={on}
                      className={cn(
                        "relative overflow-hidden rounded-2xl transition-transform active:scale-95",
                        on ? "ring-2 ring-primary" : "ring-1 ring-foreground/10",
                      )}
                    >
                      <MediaThumb
                        media={m}
                        effect={on ? effect : null}
                        className="aspect-square w-full rounded-2xl"
                      />
                      <span
                        className={cn(
                          "absolute right-1 top-1 grid size-5 place-items-center rounded-full text-[10px] font-bold",
                          on ? "bg-primary text-primary-foreground" : "bg-card/90 text-muted-foreground",
                        )}
                        aria-hidden
                      >
                        {on ? <Check className="size-3" strokeWidth={3} /> : ""}
                      </span>
                      {m.kind === "video" ? (
                        <span className="absolute bottom-1 left-1 flex items-center gap-1 rounded-full bg-foreground/70 px-1.5 py-0.5 text-[9px] font-medium text-background">
                          <Play className="size-2.5" aria-hidden />
                          {formatDuration(m.duration ?? 0)}
                        </span>
                      ) : null}
                    </button>
                  )
                })}
              </div>
            </section>

            {canUseQueue ? (
              <p className="rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
                一部の素材が失敗しても、残りの素材は最後まで処理します。失敗した素材だけあとから再試行できます。
              </p>
            ) : null}
          </>
        ) : null}

        <PrivacyNote />
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        {queue ? (
          <Button
            size="lg"
            variant={finished ? "default" : "outline"}
            className="h-14 w-full rounded-2xl text-base font-bold"
            onClick={reset}
          >
            <Layers data-icon="inline-start" />
            {finished ? "もう一度えらぶ" : "選びなおす"}
          </Button>
        ) : (
          <Button
            size="lg"
            className="h-14 w-full rounded-2xl text-base font-bold"
            disabled={selected.length === 0}
            onClick={start}
          >
            <Layers data-icon="inline-start" />
            {selected.length}件をまとめて加工
          </Button>
        )}
      </div>
    </div>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col items-center gap-0.5 rounded-2xl bg-secondary/60 px-2 py-2">
      <span className="font-rounded text-sm font-bold">{value}</span>
      <span className="text-[10px] text-muted-foreground">{label}</span>
    </div>
  )
}
