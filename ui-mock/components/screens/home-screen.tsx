"use client"

import * as React from "react"
import { ChevronRight, ImageIcon, Layers, Settings, ShieldCheck, Smile, Sparkles } from "lucide-react"

import { findMedia } from "@/lib/mock-data"
import { FREE_MONTHLY_LIMIT, useApp } from "@/components/app-provider"
import { AdSlot, PrivacyNote, SectionTitle } from "@/components/app-bits"
import { InfoDialog, type InfoTopic } from "@/components/info-dialog"
import { MediaThumb } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"

export function HomeScreen() {
  const {
    go,
    plan,
    hasAds,
    canBatchFull,
    canBatchTrial,
    trialCredits,
    remainingFree,
    history,
    startEditing,
    requestUpgrade,
    openPicker,
    guardNewWork,
  } = useApp()

  const recent = history.filter((h) => h.type === "single").slice(0, 6)
  const [info, setInfo] = React.useState<InfoTopic | null>(null)
  const outOfFree = plan === "free" && remainingFree === 0

  const openBatch = () => {
    if (canBatchFull || canBatchTrial) {
      guardNewWork("まとめて加工", () => go("batch"))
      return
    }
    requestUpgrade(plan === "standard" ? "batch-standard" : "batch-credit")
  }

  return (
    <div className="flex flex-col gap-6 px-4 pt-2 pb-8">
      <header className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="grid size-9 place-items-center rounded-2xl bg-primary text-primary-foreground">
            <Sparkles className="size-5" aria-hidden />
          </span>
          <p className="font-rounded text-lg font-extrabold tracking-tight">かおかくし</p>
        </div>
        <Button variant="ghost" size="icon-lg" className="size-10 rounded-full" onClick={() => go("settings")}>
          <Settings className="size-5" />
          <span className="sr-only">設定</span>
        </Button>
      </header>

      <div className="flex flex-col gap-3">
        <button
          type="button"
          onClick={openPicker}
          className="flex h-36 flex-col items-start justify-between rounded-3xl bg-primary p-5 text-left text-primary-foreground shadow-sm transition-transform active:scale-[0.98]"
        >
          <ImageIcon className="size-9" aria-hidden />
          <span>
            <span className="block font-rounded text-lg font-bold">写真を選ぶ</span>
            <span className="block text-xs opacity-85">1枚ずつ加工します</span>
          </span>
        </button>
        <p className="text-center text-sm font-medium text-foreground text-pretty">
          顔を自動で見つけて、かんたんに隠せます
        </p>
        <PrivacyNote />
      </div>

      {plan === "free" ? (
        <Card size="sm" className="rounded-3xl">
          <CardContent className="flex items-center gap-3">
            <div className="flex size-11 shrink-0 flex-col items-center justify-center rounded-2xl bg-accent">
              <span className="font-rounded text-base font-extrabold leading-none text-accent-foreground">
                {remainingFree}
              </span>
              <span className="text-[9px] text-accent-foreground">枚</span>
            </div>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-bold">
                {outOfFree ? "今月の無料保存を使い切りました" : `今月あと${remainingFree}枚保存できます`}
              </p>
              <p className="text-[11px] text-muted-foreground">
                {outOfFree
                  ? "Standardなら1枚ずつ無制限で保存できます"
                  : `無料プランは月${FREE_MONTHLY_LIMIT}枚まで保存できます`}
              </p>
            </div>
            <Button variant="ghost" size="icon-lg" className="size-9 rounded-full" onClick={() => go("pricing")}>
              <ChevronRight className="size-5" />
              <span className="sr-only">プランを見る</span>
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {recent.length > 0 ? (
        <section className="flex flex-col gap-3">
          <SectionTitle
            action={
              <Button variant="link" size="sm" className="h-auto p-0 text-xs" onClick={() => go("history")}>
                すべて見る
              </Button>
            }
          >
            最近加工した写真
          </SectionTitle>
          <div className="-mx-4 flex gap-3 overflow-x-auto px-4 pb-1">
            {recent.map((item, index) =>
              item.type === "single" ? (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => guardNewWork("編集する", () => startEditing(item.mediaId))}
                  className="w-24 shrink-0 text-left"
                >
                  {/* 履歴のサムネイルは必ず加工後の状態で表示する */}
                  <MediaThumb
                    media={findMedia(item.mediaId)}
                    className="aspect-square w-24 ring-1 ring-foreground/10"
                    effect={item.effect}
                    priority={index === 0}
                  />
                  <p className="mt-1.5 truncate text-[11px] font-medium">{item.method}</p>
                  <p className="truncate text-[10px] text-muted-foreground">{item.processedAt}</p>
                </button>
              ) : null,
            )}
          </div>
        </section>
      ) : null}

      <section className="flex flex-col gap-3">
        <SectionTitle>べんりな使いかた</SectionTitle>
        <div className="flex flex-col gap-2">
          <ShortcutRow
            icon={Layers}
            label="まとめて加工"
            hint={
              canBatchFull
                ? "最大50枚をまとめて加工"
                : canBatchTrial
                  ? `一括処理お試し：あと${trialCredits}枚`
                  : "お試しクレジットを使い切りました"
            }
            badge={canBatchFull ? null : canBatchTrial ? "お試し" : "Pro"}
            onClick={openBatch}
          />
          <ShortcutRow
            icon={Smile}
            label="スタンプをえらぶ"
            hint="動物やかわいい絵柄もあります"
            onClick={() => go("stamps")}
          />
          <ShortcutRow
            icon={ShieldCheck}
            label="プライバシーについて"
            hint="端末内だけで処理するしくみ"
            onClick={() => setInfo("privacy")}
          />
        </div>
      </section>

      <InfoDialog topic={info} onClose={() => setInfo(null)} />

      {hasAds ? <AdSlot /> : null}
    </div>
  )
}

function ShortcutRow({
  icon: Icon,
  label,
  hint,
  badge,
  onClick,
}: {
  icon: typeof ImageIcon
  label: string
  hint: string
  badge?: string | null
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-center gap-3 rounded-2xl bg-card p-3 text-left ring-1 ring-foreground/10 transition-transform active:scale-[0.99]"
    >
      <span className="grid size-10 shrink-0 place-items-center rounded-xl bg-secondary text-primary">
        <Icon className="size-5" aria-hidden />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-bold">{label}</span>
        <span className="block truncate text-[11px] text-muted-foreground">{hint}</span>
      </span>
      {badge ? (
        <span className="shrink-0 rounded-full bg-accent px-2 py-0.5 text-[10px] font-bold text-accent-foreground">
          {badge}
        </span>
      ) : null}
      <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden />
    </button>
  )
}
