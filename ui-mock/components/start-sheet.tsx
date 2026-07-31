"use client"

import { ImageIcon, Layers } from "lucide-react"

import { useApp } from "@/components/app-provider"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

/**
 * 加工の開始を1アクションに統一するシート。
 * ホーム（大きな「加工をはじめる」ボタン）とフッター（中央ボタン）の
 * どちらから開いても、この1つのシートが「1枚ずつ」「まとめて」を選ばせる。
 * 開閉状態は app-provider が1つだけ持ち、呼び出し口はここへ集約する。
 */
export function StartSheet() {
  const {
    startSheetOpen,
    closeStartSheet,
    openPicker,
    canBatchFull,
    canBatchTrial,
    trialCredits,
    guardNewWork,
    go,
    requestUpgrade,
  } = useApp()

  // openBatch 相当。home-screen にあった既存ロジックをそのまま移した（変更なし）
  const openBatch = () => {
    if (canBatchFull || canBatchTrial) {
      guardNewWork("まとめて加工", () => go("batch"))
      return
    }
    requestUpgrade("batch-credit")
  }

  const batchBadge = canBatchFull ? null : canBatchTrial ? "お試し" : "Pro"
  const batchHint = canBatchFull
    ? "最大50枚をまとめて"
    : canBatchTrial
      ? `お試しであと${trialCredits}枚ためせます`
      : "お試しは使い切りました"

  return (
    <Dialog open={startSheetOpen} onOpenChange={(open) => (!open ? closeStartSheet() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        <DialogHeader>
          <DialogTitle className="font-rounded text-lg leading-snug">加工をはじめる</DialogTitle>
          <DialogDescription className="leading-relaxed">どちらの方法で進めますか？</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-2">
          <button
            type="button"
            onClick={() => {
              closeStartSheet()
              openPicker()
            }}
            className="flex items-start gap-3 rounded-2xl bg-primary p-4 text-left text-primary-foreground transition-transform active:scale-[0.98]"
          >
            <ImageIcon className="mt-0.5 size-5 shrink-0" aria-hidden />
            <span>
              <span className="block font-rounded text-sm font-bold">1枚ずつ加工</span>
              <span className="block text-xs opacity-85">顔を自動で見つけて、かんたんに隠せます</span>
            </span>
          </button>

          <button
            type="button"
            onClick={() => {
              closeStartSheet()
              openBatch()
            }}
            className="flex items-start gap-3 rounded-2xl bg-secondary p-4 text-left text-secondary-foreground ring-1 ring-foreground/10 transition-transform active:scale-[0.98]"
          >
            <Layers className="mt-0.5 size-5 shrink-0 text-primary" aria-hidden />
            <span className="min-w-0 flex-1">
              <span className="flex items-center gap-1.5">
                <span className="font-rounded text-sm font-bold">まとめて加工</span>
                {batchBadge ? (
                  <span className="rounded-full bg-accent px-2 py-0.5 text-[10px] font-bold text-accent-foreground">
                    {batchBadge}
                  </span>
                ) : null}
              </span>
              <span className="block text-xs text-muted-foreground">{batchHint}</span>
            </span>
          </button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
