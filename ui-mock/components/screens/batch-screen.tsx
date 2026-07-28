"use client"

import * as React from "react"
import {
  AlertTriangle,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Crown,
  HardDrive,
  Layers,
  ListChecks,
  Pause,
  Play,
  RotateCcw,
  Sparkles,
  X,
} from "lucide-react"

import { cn } from "@/lib/utils"
import {
  estimateBatch,
  findMedia,
  formatMb,
  REVIEW_REASON_LABELS,
  type ReviewIssue,
  type ReviewReason,
} from "@/lib/mock-data"
import { STAMPS } from "@/lib/stamps"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import {
  BATCH_MAX_ITEMS,
  BATCH_STATUS_LABELS,
  deliveredCount,
  generatedCount,
  isDecided,
  RESOLUTION_LABELS,
  useApp,
  type BatchItem,
  type ExportRatio,
  type ReviewResolution,
} from "@/components/app-provider"
import { MediaCanvas, MediaThumb } from "@/components/media-canvas"
import { PrivacyNote, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

const BATCH_EFFECTS: EffectType[] = ["mosaic", "blur", "black", "stamp"]

const RATIOS: { id: ExportRatio; label: string }[] = [
  { id: "1:1", label: "1:1" },
  { id: "4:5", label: "4:5" },
  { id: "9:16", label: "9:16" },
  { id: "original", label: "元の比率" },
]

export function BatchScreen() {
  const { batchStage } = useApp()

  return (
    <div className="flex min-h-full flex-col">
      {batchStage === "setup" ? <SetupStage /> : null}
      {batchStage === "detecting" ? <DetectingStage /> : null}
      {batchStage === "review" ? <ReviewStage /> : null}
      {batchStage === "queue" ? <QueueStage /> : null}
      {batchStage === "summary" ? <SummaryStage /> : null}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* 1. 写真えらび・共通設定                                             */
/* ------------------------------------------------------------------ */

function SetupStage() {
  const {
    back,
    go,
    plan,
    canBatchFull,
    canBatchTrial,
    trialCredits,
    batchMaxSelectable,
    batchMode,
    setBatchMode,
    batchSelection,
    toggleBatchSelection,
    clearBatchSelection,
    openBatchPicker,
    effect,
    setEffect,
    exportSettings,
    updateExport,
    startBatchDetection,
    freeSpaceMb,
    pendingOutput,
    openUnsavedPrompt,
    requestUpgrade,
    canUsePremiumStamps,
    batchItems,
    backToReview,
    onCommonVisualChanged,
  } = useApp()

  // 検出後に共通設定を変えたら、影響を受ける写真の確認状態を解除する
  const changeCommon = (run: () => void) => {
    run()
    if (batchItems.length > 0) onCommonVisualChanged()
  }

  // 通常の一括処理もお試しクレジットも使えない場合
  if (!canBatchFull && !canBatchTrial) {
    return (
      <>
        <ScreenHeader title="まとめて加工" onBack={back} subtitle="Proプランの機能です" />
        <div className="flex flex-1 flex-col gap-4 px-4 py-6">
          <div className="flex flex-col items-center gap-2 rounded-3xl bg-card p-6 text-center ring-1 ring-foreground/10">
            <span className="grid size-12 place-items-center rounded-2xl bg-chart-3/20">
              <Crown className="size-6 text-foreground" aria-hidden />
            </span>
            <p className="font-rounded text-sm font-bold">お試しクレジットを使い切りました</p>
            <p className="text-[11px] leading-relaxed text-muted-foreground text-pretty">
              新しい写真をまとめて処理するにはProが必要です。一度お試しした写真があれば、その写真は引き続きまとめて処理できます。
            </p>
            <p className="text-[11px] leading-relaxed text-muted-foreground text-pretty">
              Proなら最大{BATCH_MAX_ITEMS}枚までまとめて処理できます。一覧で仕上がりを見渡し、注意が必要な写真だけを開いて直せます。
            </p>
            <Button size="lg" className="mt-1 h-12 w-full rounded-2xl font-bold" onClick={() => go("pricing")}>
              Proを確認する
            </Button>
          </div>
          <PrivacyNote />
        </div>
      </>
    )
  }

  const unsavedBatch = pendingOutput?.kind === "batch" && generatedCount(pendingOutput) > 0
  const estimate = estimateBatch(batchSelection)
  const notEnoughSpace = batchSelection.length > 0 && estimate.required > freeSpaceMb

  return (
    <>
      <ScreenHeader
        title="まとめて加工"
        onBack={back}
        subtitle={canBatchFull ? `最大${BATCH_MAX_ITEMS}枚まで選べます` : `お試し：あと${trialCredits}枚`}
        action={
          <Badge variant="secondary" className="text-[10px]">
            {batchSelection.length}枚
          </Badge>
        }
      />

      <div className="flex flex-1 flex-col gap-5 px-4 py-4">
        {!canBatchFull ? (
          <div className="flex items-start gap-2 rounded-2xl bg-accent/70 px-3 py-2.5">
            <Sparkles className="mt-0.5 size-4 shrink-0 text-accent-foreground" aria-hidden />
            <div className="min-w-0">
              <p className="text-[11px] font-bold text-accent-foreground">
                一括処理お試し：あと{trialCredits}枚
              </p>
              <p className="text-[11px] leading-relaxed text-accent-foreground/85 text-pretty">
                月間の無料枠とは別枠です。書き出しに成功した枚数ぶんだけ減ります。
                {plan === "free" ? "使えるかくし方はFreeのままです。" : null}
              </p>
            </div>
          </div>
        ) : null}

        {unsavedBatch ? (
          <button
            type="button"
            onClick={openUnsavedPrompt}
            className="flex items-start gap-2 rounded-2xl bg-chart-3/20 px-3 py-2.5 text-left"
          >
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-foreground" aria-hidden />
            <p className="text-[11px] leading-relaxed text-foreground text-pretty">
              保存していない一括処理の写真があります。先に保存または破棄してください。
            </p>
          </button>
        ) : null}

        <section className="flex flex-col gap-2">
          <SectionTitle>すすめかた</SectionTitle>
          {batchItems.length > 0 ? (
            <div className="flex flex-col gap-2 rounded-2xl bg-secondary px-3 py-2.5">
              <p className="text-[11px] leading-relaxed text-secondary-foreground">
                検出結果は保持しています。設定を変えると、変更の影響を受ける写真だけ確認し直しになります。個別に調整した写真は共通設定の影響を受けません。
              </p>
              <Button
                size="sm"
                variant="secondary"
                className="h-9 self-start rounded-xl text-[11px] font-bold"
                onClick={backToReview}
              >
                確認へもどる
              </Button>
            </div>
          ) : null}
          <div className="grid grid-cols-2 gap-2">
            <ModeCard
              active={batchMode === "auto"}
              title="おまかせ一括"
              lines={["全員に同じ加工", "一覧で見渡す", "気になる写真だけ直す"]}
              onClick={() => setBatchMode("auto")}
            />
            <ModeCard
              active={batchMode === "one-by-one"}
              title="1枚ずつ確認"
              lines={["1枚ずつ大きく表示", "順番に確認", "最後にまとめて保存"]}
              onClick={() => setBatchMode("one-by-one")}
            />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle
            action={
              <span className="text-[11px] text-muted-foreground">
                {batchSelection.length} / {batchMaxSelectable}枚
              </span>
            }
          >
            写真をえらぶ
          </SectionTitle>
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="lg"
              className="h-12 flex-1 rounded-2xl text-sm font-bold"
              onClick={openBatchPicker}
              disabled={batchItems.length > 0}
            >
              写真を選ぶ
            </Button>
            {batchSelection.length > 0 ? (
              <Button
                variant="ghost"
                size="lg"
                className="h-12 rounded-2xl text-sm text-muted-foreground"
                onClick={clearBatchSelection}
                disabled={batchItems.length > 0}
              >
                クリア
              </Button>
            ) : null}
          </div>
          {batchSelection.length > 0 ? (
            <div className="grid grid-cols-4 gap-2">
              {batchSelection.map((id) => (
                <button
                  key={id}
                  type="button"
                  onClick={() => toggleBatchSelection(id)}
                  disabled={batchItems.length > 0}
                  className="relative overflow-hidden rounded-2xl ring-1 ring-foreground/10 transition-transform active:scale-95 disabled:opacity-60"
                >
                  <MediaThumb media={findMedia(id)} className="aspect-square w-full rounded-2xl" />
                  <span className="absolute right-1 top-1 grid size-5 place-items-center rounded-full bg-card/90 text-muted-foreground">
                    <X className="size-3" aria-hidden />
                  </span>
                </button>
              ))}
            </div>
          ) : null}
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>全部の写真へ同じかくし方を使う</SectionTitle>
          <div className="grid grid-cols-4 gap-2">
            {BATCH_EFFECTS.map((t) => (
              <button
                key={t}
                type="button"
                onClick={() => changeCommon(() => setEffect((prev) => ({ ...prev, type: t })))}
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
            <SectionTitle>スタンプ</SectionTitle>
            <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1">
              {STAMPS.filter((s) => !s.premium || canUsePremiumStamps)
                .slice(0, 12)
                .map((s) => {
                  const Icon = s.icon
                  const active = effect.stampId === s.id
                  return (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => changeCommon(() => setEffect((prev) => ({ ...prev, stampId: s.id })))}
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
                      <span className="w-full truncate text-center text-[10px] text-muted-foreground">{s.name}</span>
                    </button>
                  )
                })}
            </div>
            {!canUsePremiumStamps ? (
              <button
                type="button"
                onClick={() => requestUpgrade("premium-stamp")}
                className="self-start text-[11px] font-bold text-primary underline-offset-2 hover:underline"
              >
                追加スタンプを使うには
              </button>
            ) : null}
          </section>
        ) : null}

        <section className="flex flex-col gap-2">
          <SectionTitle>全部の写真へ同じ縦横比を使う</SectionTitle>
          <div className="grid grid-cols-4 gap-2">
            {RATIOS.map((r) => (
              <button
                key={r.id}
                type="button"
                onClick={() => changeCommon(() => updateExport({ ratio: r.id }))}
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

        {batchSelection.length > 0 ? (
          <section className="flex flex-col gap-2">
            <SectionTitle>空き容量の確認</SectionTitle>
            <div className="flex flex-col gap-1.5 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
              <EstimateRow label="選んだ枚数" value={`${estimate.count}枚`} />
              <EstimateRow label="推定出力容量" value={formatMb(estimate.output)} />
              <EstimateRow label="推定一時処理容量" value={formatMb(estimate.temp)} />
              <EstimateRow label="必要な空き容量" value={`${formatMb(estimate.required)}（1.2倍）`} />
              <EstimateRow label="現在の空き容量" value={formatMb(freeSpaceMb)} />
            </div>
            {notEnoughSpace ? (
              <p className="flex items-start gap-1.5 rounded-2xl bg-destructive/10 px-3 py-2.5 text-[11px] leading-relaxed text-destructive">
                <HardDrive className="mt-0.5 size-3.5 shrink-0" aria-hidden />
                この写真をまとめて加工するには空き容量が不足しています。写真の枚数を減らしてください。
              </p>
            ) : null}
          </section>
        ) : null}

        <PrivacyNote />
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button
          size="lg"
          className="h-14 w-full rounded-2xl text-base font-bold"
          disabled={batchSelection.length === 0 || notEnoughSpace || unsavedBatch}
          onClick={startBatchDetection}
        >
          <Layers data-icon="inline-start" />
          {batchItems.length > 0 ? `枚を検出しなおす` : `枚の顔を検出する`}
        </Button>
      </div>
    </>
  )
}

function ModeCard({
  active,
  title,
  lines,
  onClick,
}: {
  active: boolean
  title: string
  lines: string[]
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "flex flex-col gap-1.5 rounded-2xl p-3 text-left transition-colors",
        active ? "bg-primary text-primary-foreground" : "bg-card text-foreground ring-1 ring-foreground/10",
      )}
    >
      <span className="font-rounded text-sm font-bold">{title}</span>
      <span className="flex flex-col gap-0.5 text-[10px] leading-relaxed opacity-85">
        {lines.map((l) => (
          <span key={l}>{l}</span>
        ))}
      </span>
    </button>
  )
}

function EstimateRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 text-xs">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* 2. 検出とサムネイル生成                                             */
/* ------------------------------------------------------------------ */

function DetectingStage() {
  const { batchItems } = useApp()
  const ready = batchItems.filter((i) => i.thumbReady).length
  const total = batchItems.length
  const percent = total > 0 ? Math.round((ready / total) * 100) : 0

  return (
    <div className="flex min-h-full flex-col items-center justify-center gap-6 px-6 py-10">
      <div className="flex w-full max-w-[260px] flex-col items-center gap-3">
        <p className="font-rounded text-base font-bold">顔をさがしています</p>
        <Progress value={percent} className="w-full [&_[data-slot=progress-track]]:h-2.5" />
        <p className="text-xs text-muted-foreground">
          {ready} / {total}枚
        </p>
      </div>
      <PrivacyNote />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* 3. 一覧確認                                                         */
/* ------------------------------------------------------------------ */

function ReviewStage() {
  const {
    batchMode,
    batchItems,
    effect,
    unresolvedCount,
    reviewCount,
    allThumbsReady,
    reachedEnd,
    markReachedEnd,
    gridConfirmed,
    confirmGrid,
    canConfirmGrid,
    startBatchExport,
    resolveIssue,
    resolveGroup,
    redetect,
    markOverride,
    reviewedIds,
    markReviewed,
    overrideCount,
    backToSetup,
  } = useApp()

  const [onlyReview, setOnlyReview] = React.useState(false)
  const [preview, setPreview] = React.useState<BatchItem | null>(null)
  const [step, setStep] = React.useState(0)
  const endRef = React.useRef<HTMLDivElement>(null)

  // 一覧の末尾まで到達したかを見る（おまかせ一括の確認条件）
  React.useEffect(() => {
    if (batchMode !== "auto") return
    const el = endRef.current
    if (!el) return
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) markReachedEnd()
      },
      { threshold: 0.4 },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [batchMode, markReachedEnd, onlyReview])

  const shown = onlyReview ? batchItems.filter((i) => i.issues.length > 0) : batchItems

  // 理由ごとの一括確認。「顔が検出されませんでした」は対象にしない
  const groupable = React.useMemo(() => {
    // 枚数を数える。同じ写真に同じ理由が複数あっても1枚として数える
    const map = new Map<ReviewReason, number>()
    batchItems.forEach((item) => {
      if (isDecided(item) || item.issues.some((i) => i.reason === "no-face")) return
      const reasons = new Set(item.issues.filter((i) => !item.decisions[i.id]).map((i) => i.reason))
      reasons.forEach((r) => map.set(r, (map.get(r) ?? 0) + 1))
    })
    return [...map.entries()]
  }, [batchItems])

  const noFaceItems = batchItems.filter((i) => i.issues.some((x) => x.reason === "no-face") && !isDecided(i))

  if (batchMode === "one-by-one") {
    const item = batchItems[step]
    const media = item ? findMedia(item.mediaId) : null
    const doneCount = reviewedIds.length

    return (
      <>
        <ScreenHeader
          title="1枚ずつ確認"
          onBack={backToSetup}
          subtitle={`${doneCount} / ${batchItems.length}枚を確認しました`}
        />
        <div className="flex flex-1 flex-col gap-4 px-4 py-4">
          {media && item ? (
            <>
              <MediaCanvas
                media={media}
                faces={media.faces}
                hidden={media.faces.map((f) => f.id)}
                effect={effect}
                className="aspect-square"
              />
              <div className="flex items-center justify-between gap-2">
                <p className="truncate text-sm font-bold">{media.title}</p>
                <StatusBadge item={item} reviewed={reviewedIds.includes(item.mediaId)} />
              </div>

              {item.issues.length > 0 && !isDecided(item) ? (
                <IssueList issues={item.issues} decisions={item.decisions} />
              ) : null}

              <div className="grid grid-cols-2 gap-2">
                <Button
                  variant="outline"
                  size="lg"
                  className="h-12 rounded-2xl text-sm"
                  disabled={step === 0}
                  onClick={() => setStep((s) => Math.max(0, s - 1))}
                >
                  <ChevronLeft data-icon="inline-start" />
                  前へ
                </Button>
                <Button
                  size="lg"
                  className="h-12 rounded-2xl text-sm font-bold"
                  onClick={() => {
                    item.issues.forEach((i) => resolveIssue(item.mediaId, i.id, "accepted-as-is"))
                    markReviewed(item.mediaId)
                    setStep((s) => Math.min(batchItems.length - 1, s + 1))
                  }}
                >
                  確認済みにする
                  <ChevronRight data-icon="inline-end" />
                </Button>
              </div>

              <Button
                variant="ghost"
                size="lg"
                className="h-11 rounded-2xl text-sm text-muted-foreground"
                onClick={() => markOverride(item.mediaId)}
              >
                この写真だけ個別に調整する
              </Button>

              {/* 再検出すると顔の対応づけができないため、この写真の判断はすべて破棄する */}
              <Button
                variant="ghost"
                size="sm"
                className="h-10 rounded-2xl text-[11px] text-muted-foreground"
                onClick={() => redetect(item.mediaId)}
              >
                <RotateCcw data-icon="inline-start" />
                顔を検出し直す（この写真の確認はやり直しになります）
              </Button>
            </>
          ) : null}
        </div>

        <div className="sticky bottom-0 flex flex-col gap-2 border-t bg-card/95 p-4 backdrop-blur">
          {!canConfirmGrid ? (
            <p className="text-center text-[11px] leading-relaxed text-muted-foreground text-pretty">
              {unresolvedCount > 0
                ? `${unresolvedCount}枚の確認が必要です`
                : `残り${batchItems.length - doneCount}枚の確認がのこっています`}
            </p>
          ) : null}
          <Button
            size="lg"
            className="h-14 w-full rounded-2xl text-base font-bold"
            disabled={!canConfirmGrid}
            onClick={() => {
              confirmGrid()
              startBatchExport()
            }}
          >
            {batchItems.length}枚をまとめて保存
          </Button>
        </div>
      </>
    )
  }

  return (
    <>
      <ScreenHeader
        title="仕上がりを確認"
        onBack={backToSetup}
        subtitle={`${batchItems.length}枚 ・ 要確認${reviewCount}枚`}
      />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        <p className="rounded-2xl bg-secondary px-3 py-2.5 text-[11px] leading-relaxed text-secondary-foreground text-pretty">
          検出できなかった顔はアプリでは分かりません。すべての写真に一度目を通してください。タップすると大きく確認できます。
        </p>

        <div className="flex items-center justify-between gap-2">
          <div className="flex gap-2">
            <FilterChip active={!onlyReview} label={`すべて（${batchItems.length}）`} onClick={() => setOnlyReview(false)} />
            <FilterChip
              active={onlyReview}
              label={`要確認（${reviewCount}）`}
              onClick={() => setOnlyReview(true)}
            />
          </div>
          {overrideCount > 0 ? (
            <span className="shrink-0 text-[10px] font-bold text-muted-foreground">個別設定 {overrideCount}枚</span>
          ) : null}
        </div>

        {groupable.length > 0 ? (
          <div className="flex flex-col gap-2 rounded-2xl bg-chart-3/15 p-3">
            <p className="text-[11px] font-bold text-foreground">まとめて確認できます</p>
            <div className="flex flex-wrap gap-2">
              {groupable.map(([reason, count]) => (
                <Button
                  key={reason}
                  size="sm"
                  variant="secondary"
                  className="h-8 rounded-xl text-[10px] font-bold"
                  onClick={() => resolveGroup(reason)}
                >
                  {REVIEW_REASON_LABELS[reason]}（{count}枚）
                </Button>
              ))}
            </div>
          </div>
        ) : null}

        {noFaceItems.length > 0 ? (
          <div className="flex flex-col gap-2 rounded-2xl bg-destructive/10 p-3">
            <p className="flex items-center gap-1.5 text-[11px] font-bold text-destructive">
              <AlertTriangle className="size-3.5 shrink-0" aria-hidden />
              顔が検出されなかった写真が{noFaceItems.length}枚あります
            </p>
            <p className="text-[11px] leading-relaxed text-foreground">
              まとめて確認はできません。1枚ずつ開いて内容を確かめてください。
            </p>
          </div>
        ) : null}

        <div className="grid grid-cols-3 gap-2">
          {shown.map((item) => {
            const media = findMedia(item.mediaId)
            const needsAction = item.issues.length > 0 && !isDecided(item)
            return (
              <button
                key={item.mediaId}
                type="button"
                onClick={() => setPreview(item)}
                className={cn(
                  "relative overflow-hidden rounded-2xl transition-transform active:scale-95",
                  needsAction ? "ring-2 ring-chart-3" : "ring-1 ring-foreground/10",
                )}
              >
                {/* サムネイルは必ず加工後の状態を表示する */}
                <MediaThumb
                  media={media}
                  effect={item.thumbReady ? effect : null}
                  className="aspect-square w-full rounded-2xl"
                />
                {!item.thumbReady ? (
                  <span className="absolute inset-0 grid place-items-center bg-card/70 text-[10px] font-bold text-muted-foreground">
                    生成中
                  </span>
                ) : null}
                <span className="absolute left-1 top-1">
                  <StatusBadge item={item} compact />
                </span>
                {item.hasOverride ? (
                  <span className="absolute bottom-1 left-1 rounded-full bg-foreground/75 px-1.5 py-0.5 text-[9px] font-bold text-background">
                    個別設定あり
                  </span>
                ) : null}
              </button>
            )
          })}
        </div>

        <div ref={endRef} className="flex flex-col items-center gap-2 py-2">
          {reachedEnd ? (
            <p className="text-[11px] font-medium text-muted-foreground">一覧の最後まで表示しました</p>
          ) : (
            <p className="text-[11px] text-muted-foreground">下までスクロールしてください</p>
          )}
          <Button
            variant={gridConfirmed ? "secondary" : "outline"}
            size="lg"
            className="h-12 w-full rounded-2xl text-sm font-bold"
            disabled={!canConfirmGrid || gridConfirmed}
            onClick={confirmGrid}
          >
            {gridConfirmed ? (
              <>
                <Check data-icon="inline-start" />
                一覧を確認しました
              </>
            ) : (
              "一覧の仕上がりを確認しました"
            )}
          </Button>
        </div>

        <PrivacyNote />
      </div>

      <div className="sticky bottom-0 flex flex-col gap-2 border-t bg-card/95 p-4 backdrop-blur">
        {!gridConfirmed ? (
          <p className="text-center text-[11px] leading-relaxed text-muted-foreground text-pretty">
            {!allThumbsReady
              ? "サムネイルを生成しています"
              : unresolvedCount > 0
                ? `${unresolvedCount}枚の確認が必要です`
                : !reachedEnd
                  ? "一覧を最後まで確認してください"
                  : "「一覧の仕上がりを確認しました」を押してください"}
          </p>
        ) : null}
        <Button
          size="lg"
          className="h-14 w-full rounded-2xl text-base font-bold"
          disabled={!gridConfirmed}
          onClick={startBatchExport}
        >
          <Layers data-icon="inline-start" />
          {batchItems.length}枚をまとめて保存
        </Button>
      </div>

      <PreviewDialog
        item={preview}
        onClose={() => setPreview(null)}
        onResolve={(id, issueId, resolution) => {
          resolveIssue(id, issueId, resolution)
        }}
        onOverride={(id) => {
          markOverride(id)
          setPreview(null)
        }}
      />
    </>
  )
}

function FilterChip({ active, label, onClick }: { active: boolean; label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "h-8 rounded-full px-3 text-[11px] font-bold transition-colors",
        active ? "bg-primary text-primary-foreground" : "bg-card text-muted-foreground ring-1 ring-foreground/10",
      )}
    >
      {label}
    </button>
  )
}

/** 警告は「発生」ごとに並べる。同じ理由でも顔ごとに別の行になる */
function IssueList({
  issues,
  decisions,
}: {
  issues: ReviewIssue[]
  decisions: Record<string, ReviewResolution>
}) {
  const pending = issues.filter((i) => !decisions[i.id])
  if (pending.length === 0) return null
  return (
    <div className="flex flex-col gap-1 rounded-2xl bg-chart-3/15 px-3 py-2.5">
      <p className="flex items-center gap-1.5 text-[11px] font-bold text-foreground">
        <AlertTriangle className="size-3.5 shrink-0" aria-hidden />
        {pending.length}件の確認が必要です
      </p>
      <ul className="flex flex-col gap-0.5 pl-5 text-[11px] leading-relaxed text-foreground">
        {pending.map((i) => (
          <li key={i.id} className="list-disc">
            {i.label}
          </li>
        ))}
      </ul>
    </div>
  )
}

/** 通常／要確認／確認済みの3状態だけを表示する。「安全」とは表示しない */
function StatusBadge({ item, compact, reviewed }: { item: BatchItem; compact?: boolean; reviewed?: boolean }) {
  const state =
    item.issues.length === 0
      ? reviewed
        ? { label: "確認済み", className: "bg-primary text-primary-foreground" }
        : { label: "通常", className: "bg-card/90 text-muted-foreground" }
      : isDecided(item)
        ? { label: "確認済み", className: "bg-primary text-primary-foreground" }
        : { label: "要確認", className: "bg-chart-3 text-background" }

  return (
    <span
      className={cn(
        "rounded-full px-2 py-0.5 font-bold",
        compact ? "text-[9px]" : "text-[10px]",
        state.className,
      )}
    >
      {state.label}
    </span>
  )
}

function PreviewDialog({
  item,
  onClose,
  onResolve,
  onOverride,
}: {
  item: BatchItem | null
  onClose: () => void
  onResolve: (mediaId: string, issueId: string, resolution: ReviewResolution) => void
  onOverride: (mediaId: string) => void
}) {
  const { effect } = useApp()
  const media = item ? findMedia(item.mediaId) : null
  const needsAction = item ? item.issues.length > 0 && !isDecided(item) : false

  return (
    <Dialog open={item !== null} onOpenChange={(open) => (!open ? onClose() : undefined)}>
      <DialogContent className="max-w-[340px] rounded-3xl">
        {media && item ? (
          <>
            <DialogHeader>
              <DialogTitle className="font-rounded text-base">{media.title}</DialogTitle>
              <DialogDescription>
                {media.faces.length > 0 ? `${media.faces.length}人の顔を隠しています` : "顔は検出されていません"}
              </DialogDescription>
            </DialogHeader>

            <MediaCanvas
              media={media}
              faces={media.faces}
              hidden={media.faces.map((f) => f.id)}
              effect={effect}
              className="aspect-square"
            />

            {/* 警告は消さず、理由ごとにどう扱うと決めたかを記録する */}
            <div className="flex flex-col gap-3">
              {item.issues.map((issue) => {
                const decided = item.decisions[issue.id]
                return (
                  <div key={issue.id} className="flex flex-col gap-1.5 rounded-2xl bg-chart-3/15 p-3">
                    <p className="flex items-center gap-1.5 text-[11px] font-bold text-foreground">
                      <AlertTriangle className="size-3.5 shrink-0" aria-hidden />
                      {issue.label}
                    </p>
                    {decided ? (
                      <p className="text-[11px] leading-relaxed text-foreground">
                        判断：{RESOLUTION_LABELS[decided]}（警告の記録は残ります）
                      </p>
                    ) : (
                      <div className="flex flex-col gap-1.5">
                        {(
                          [
                            ["accepted-as-is", "見たうえで、このままでよい"],
                            ["manual-region-added", "手動で隠す範囲を追加した"],
                            ["unmasked-export-confirmed", "顔を隠さずそのまま保存する"],
                          ] as [ReviewResolution, string][]
                        ).map(([value, label]) => (
                          <Button
                            key={value}
                            size="sm"
                            variant={value === "unmasked-export-confirmed" ? "outline" : "secondary"}
                            className={cn(
                              "h-9 rounded-xl text-[11px] font-bold",
                              value === "unmasked-export-confirmed" && "text-destructive",
                            )}
                            onClick={() => onResolve(item.mediaId, issue.id, value)}
                          >
                            {label}
                          </Button>
                        ))}
                      </div>
                    )}
                  </div>
                )
              })}
              {needsAction ? (
                <p className="text-[11px] leading-relaxed text-muted-foreground">
                  すべての警告に判断を記録すると、この写真は確認済みになります。
                </p>
              ) : null}
              <Button
                variant="ghost"
                size="lg"
                className="h-11 rounded-2xl text-sm"
                onClick={() => onOverride(item.mediaId)}
              >
                この写真だけ個別に調整する
              </Button>
              <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={onClose}>
                とじる
              </Button>
            </div>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}

/* ------------------------------------------------------------------ */
/* 4. 処理キュー                                                       */
/* ------------------------------------------------------------------ */

function QueueStage() {
  const { batchItems, batchRunning, pauseBatch, resumeBatch, cancelBatch, effect } = useApp()

  const total = batchItems.length
  const doneCount = batchItems.filter((i) => i.status === "done").length
  const errorCount = batchItems.filter((i) => i.status === "error").length
  const settled = batchItems.filter((i) => ["done", "error", "canceled"].includes(i.status)).length
  const remaining = total - settled
  const percent = total > 0 ? Math.round((settled / total) * 100) : 0

  return (
    <>
      <ScreenHeader title="まとめて保存中" subtitle={`${total}枚中${doneCount}枚が完了しました`} />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        <section className="flex flex-col gap-3 rounded-3xl bg-card p-4 ring-1 ring-foreground/10">
          <div className="flex items-start justify-between gap-2">
            <p className="flex items-center gap-1.5 font-rounded text-sm font-bold">
              <ListChecks className="size-4 text-primary" aria-hidden />
              処理キュー
            </p>
            <Badge variant="secondary" className="shrink-0 text-[10px]">
              {batchRunning ? "処理中" : "一時停止中"}
            </Badge>
          </div>

          <Progress value={percent} className="w-full [&_[data-slot=progress-track]]:h-2.5" />

          <div className="grid grid-cols-3 gap-2">
            <Stat label="完了" value={`${doneCount}枚`} />
            <Stat label="残り" value={`${remaining}枚`} />
            <Stat label="エラー" value={`${errorCount}枚`} />
          </div>

          <div className="flex flex-wrap gap-2">
            {batchRunning ? (
              <Button size="sm" variant="secondary" className="h-9 rounded-xl text-[11px] font-bold" onClick={pauseBatch}>
                <Pause data-icon="inline-start" />
                一時停止
              </Button>
            ) : (
              <Button size="sm" className="h-9 rounded-xl text-[11px] font-bold" onClick={resumeBatch}>
                <Play data-icon="inline-start" />
                再開
              </Button>
            )}
            <Button
              size="sm"
              variant="ghost"
              className="h-9 rounded-xl text-[11px] font-bold text-muted-foreground"
              onClick={cancelBatch}
            >
              <X data-icon="inline-start" />
              キャンセル
            </Button>
          </div>
        </section>

        <QueueList items={batchItems} effect={effect} />

        <PrivacyNote />
      </div>
    </>
  )
}

function QueueList({ items, effect }: { items: BatchItem[]; effect: ReturnType<typeof useApp>["effect"] }) {
  return (
    <ul className="flex flex-col gap-2">
      {items.map((item) => {
        const media = findMedia(item.mediaId)
        return (
          <li key={item.mediaId} className="flex items-center gap-3 rounded-2xl bg-secondary/50 p-2">
            <MediaThumb media={media} effect={effect} className="size-12 shrink-0" />
            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
              <p className="truncate text-xs font-bold">{media.title}</p>
              <p className="truncate text-[10px] text-muted-foreground">
                顔{media.faces.length}件
                {item.hasOverride ? " ・ 個別設定あり" : ""}
              </p>
            </div>
            <span
              className={cn(
                "shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold",
                item.status === "done"
                  ? "bg-primary text-primary-foreground"
                  : item.status === "error"
                    ? "bg-destructive/15 text-destructive"
                    : item.status === "exporting"
                      ? "bg-primary/15 text-primary"
                      : "bg-muted text-muted-foreground",
              )}
            >
              {BATCH_STATUS_LABELS[item.status]}
            </span>
          </li>
        )
      })}
    </ul>
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

/* ------------------------------------------------------------------ */
/* 5. 完了サマリ                                                       */
/* ------------------------------------------------------------------ */

function SummaryStage() {
  const {
    batchItems,
    effect,
    retryBatchErrors,
    resetBatch,
    go,
    pendingOutput,
    savePending,
    sharePending,
    canBatchFull,
    trialCredits,
    batchTrialUsed,
  } = useApp()

  const doneCount = batchItems.filter((i) => i.status === "done").length
  const errorCount = batchItems.filter((i) => i.status === "error").length
  const canceledCount = batchItems.filter((i) => i.status === "canceled").length
  const pendingNow = generatedCount(pendingOutput)
  const deliveredNow = deliveredCount(pendingOutput)
  const delivered = pendingNow === 0

  return (
    <>
      <ScreenHeader title="まとめて加工の結果" />

      <div className="flex flex-1 flex-col gap-4 px-4 py-4">
        <div className="flex flex-col items-center gap-2 rounded-3xl bg-primary/10 p-5 text-center">
          <CheckCircle2 className="size-8 text-primary" aria-hidden />
          <p className="font-rounded text-sm font-bold">{doneCount}枚の加工が完了しました</p>
          <p className="text-[11px] leading-relaxed text-muted-foreground text-pretty">
            {errorCount > 0 ? `${errorCount}枚の処理に失敗しました。` : null}
            {canceledCount > 0 ? `${canceledCount}枚はキャンセルしました。` : null}
            {EFFECT_LABELS[effect.type]}を適用しています。
          </p>
        </div>

        {!canBatchFull && batchTrialUsed ? (
          <div className="flex flex-col gap-1.5 rounded-2xl bg-accent/70 px-3 py-2.5">
            <p className="text-[11px] font-bold text-accent-foreground">
              {trialCredits > 0 ? `一括処理お試し：あと${trialCredits}枚` : "お試しクレジットを使い切りました"}
            </p>
            <p className="text-[11px] leading-relaxed text-accent-foreground/85">
              Proなら最大{BATCH_MAX_ITEMS}枚までまとめて処理できます。
            </p>
            <Button
              size="sm"
              className="mt-1 h-9 self-start rounded-xl text-[11px] font-bold"
              onClick={() => go("pricing")}
            >
              Proを確認する
            </Button>
          </div>
        ) : null}

        {/* 保存は写真ごとに成否が決まる。部分的に成功した状態を表示する */}
        {deliveredNow > 0 && !delivered ? (
          <div className="flex items-start gap-2 rounded-2xl bg-chart-3/20 px-3 py-2.5">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-foreground" aria-hidden />
            <p className="text-[11px] leading-relaxed text-foreground text-pretty">
              {deliveredNow}枚を保存しました。残り{pendingNow}枚は保存できていません。空き容量を確認して、もう一度お試しください。
            </p>
          </div>
        ) : null}

        {!delivered ? (
          <div className="flex flex-col gap-2">
            <Button size="lg" className="h-13 w-full rounded-2xl font-bold" onClick={savePending}>
              {pendingNow}枚をまとめて保存
            </Button>
            <Button
              variant="outline"
              size="lg"
              className="h-13 w-full rounded-2xl font-bold"
              onClick={sharePending}
            >
              共有する
            </Button>
            <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
              保存や共有を何度行っても、追加でクレジットは消費しません。
            </p>
          </div>
        ) : (
          <p className="rounded-2xl bg-secondary px-3 py-2.5 text-center text-[11px] leading-relaxed text-secondary-foreground">
            保存しました。元の写真は変更されていません。
          </p>
        )}

        {errorCount > 0 ? (
          <Button
            variant="secondary"
            size="lg"
            className="h-12 w-full rounded-2xl text-sm font-bold"
            onClick={retryBatchErrors}
          >
            <RotateCcw data-icon="inline-start" />
            失敗した{errorCount}枚だけ再試行
          </Button>
        ) : null}

        <QueueList items={batchItems} effect={effect} />

        <PrivacyNote />
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button
          size="lg"
          variant="outline"
          className="h-14 w-full rounded-2xl text-base font-bold"
          onClick={resetBatch}
        >
          <Layers data-icon="inline-start" />
          もう一度えらぶ
        </Button>
      </div>
    </>
  )
}
