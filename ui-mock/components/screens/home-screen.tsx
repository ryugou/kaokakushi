"use client"

import * as React from "react"
import { ChevronRight, ImageIcon, Settings, Sparkles } from "lucide-react"

import { findMedia } from "@/lib/mock-data"
import { useApp } from "@/components/app-provider"
import { AdSlot, SectionTitle } from "@/components/app-bits"
import { InfoDialog, type InfoTopic } from "@/components/info-dialog"
import { MediaThumb } from "@/components/media-canvas"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"

export function HomeScreen() {
  const { go, plan, hasAds, remainingFree, history, startEditing, guardNewWork, openStartSheet } = useApp()

  const recent = history.filter((h) => h.type === "single").slice(0, 6)
  const [info, setInfo] = React.useState<InfoTopic | null>(null)
  const outOfFree = plan === "free" && remainingFree === 0

  // Free だけ、ボタンの中で残り枚数を示す（常設カードは残0枚のときだけ下に出す）
  const heroSubtext = plan === "free" ? `今月あと${remainingFree}枚` : "写真の顔をかんたんに隠せます"

  return (
    <div className="flex flex-col gap-6 px-4 pt-2 pb-8">
      <header className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="grid size-9 place-items-center rounded-2xl bg-primary text-primary-foreground">
            <Sparkles className="size-5" aria-hidden />
          </span>
          <p className="font-rounded text-lg font-extrabold tracking-tight">顔かくし</p>
        </div>
        <Button variant="ghost" size="icon-lg" className="size-10 rounded-full" onClick={() => go("settings")}>
          <Settings className="size-5" />
          <span className="sr-only">設定</span>
        </Button>
      </header>

      <div className="flex flex-col gap-3">
        <button
          type="button"
          onClick={openStartSheet}
          className="flex h-32 flex-col items-start justify-between rounded-3xl bg-primary p-5 text-left text-primary-foreground shadow-sm transition-transform active:scale-[0.98]"
        >
          <ImageIcon className="size-8" aria-hidden />
          <span>
            <span className="block font-rounded text-lg font-bold">加工をはじめる</span>
            <span className="block text-xs opacity-85">{heroSubtext}</span>
          </span>
        </button>
        <button
          type="button"
          onClick={() => setInfo("privacy")}
          className="text-center text-[11px] text-muted-foreground underline-offset-2 hover:underline"
        >
          写真は端末の中だけで処理されます
        </button>
      </div>

      {outOfFree ? (
        <Card size="sm" className="rounded-3xl">
          <CardContent className="flex items-center gap-3">
            <div className="flex size-11 shrink-0 flex-col items-center justify-center rounded-2xl bg-accent">
              <span className="font-rounded text-base font-extrabold leading-none text-accent-foreground">
                {remainingFree}
              </span>
              <span className="text-[9px] text-accent-foreground">枚</span>
            </div>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-bold">今月の無料保存を使い切りました</p>
              <p className="text-[11px] text-muted-foreground">Standardなら1枚ずつ無制限で保存できます</p>
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

      <InfoDialog topic={info} onClose={() => setInfo(null)} />

      {hasAds ? <AdSlot /> : null}
    </div>
  )
}
