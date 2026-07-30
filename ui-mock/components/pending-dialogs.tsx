"use client"

import { AlertTriangle, Download, Share2, Trash2 } from "lucide-react"

import { generatedCount, useApp } from "@/components/app-provider"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

/**
 * 加工済み出力の生成が終わった時点で無料枠を消費するため、
 * 保存も共有もしないまま写真を失う経路を作らない。
 */

function pendingLabel(count: number) {
  return count > 1 ? `保存していない加工済み写真が${count}枚あります` : "保存していない加工済み写真があります"
}

/** 新しい加工を始めようとしたとき、完了画面を離れようとしたときの確認 */
export function UnsavedOutputDialog() {
  const {
    pendingOutput,
    unsavedPromptOpen,
    closeUnsavedPrompt,
    savePending,
    sharePending,
    askDiscard,
    keepPendingForLater,
    retention,
  } = useApp()

  const count = generatedCount(pendingOutput)
  const canKeepForLater = retention !== "none"

  return (
    <Dialog open={unsavedPromptOpen} onOpenChange={(open) => (!open ? closeUnsavedPrompt() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        <DialogHeader>
          <span className="flex size-11 items-center justify-center rounded-2xl bg-chart-3/20 text-foreground">
            <AlertTriangle className="size-5" aria-hidden />
          </span>
          <DialogTitle className="font-rounded text-lg leading-snug text-pretty">
            {count > 1 ? `完了していない写真が${count}枚あります` : "完了していない写真があります"}
          </DialogTitle>
          <DialogDescription className="leading-relaxed">
            {canKeepForLater
              ? "破棄するとやり直しは無料ですが、この出力は失われます。あとで保存する場合は履歴から再開できます。"
              : "破棄するとやり直しは無料ですが、この出力は失われます。履歴を保存しない設定のため、あとから開くことはできません。"}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-2">
          <Button size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={savePending}>
            <Download data-icon="inline-start" />
            {count > 1 ? "まとめて保存する" : "保存する"}
          </Button>
          <Button variant="outline" size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={sharePending}>
            <Share2 data-icon="inline-start" />
            共有する
          </Button>
          {canKeepForLater ? (
            <Button variant="secondary" size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={keepPendingForLater}>
              あとで保存
            </Button>
          ) : null}
          <Button
            variant="ghost"
            size="lg"
            className="h-11 rounded-2xl text-sm text-destructive"
            onClick={askDiscard}
          >
            <Trash2 data-icon="inline-start" />
            破棄する
          </Button>
          <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={closeUnsavedPrompt}>
            もどる
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

/** 破棄しても、使った無料枠やクレジットは戻らない */
export function DiscardDialog() {
  const { discardPromptOpen, closeDiscard, discardPending, pendingOutput } = useApp()

  const usedTrial = pendingOutput?.usedTrial ?? false
  const count = generatedCount(pendingOutput)

  return (
    <Dialog open={discardPromptOpen} onOpenChange={(open) => (!open ? closeDiscard() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        <DialogHeader>
          <span className="flex size-11 items-center justify-center rounded-2xl bg-destructive/15 text-destructive">
            <Trash2 className="size-5" aria-hidden />
          </span>
          <DialogTitle className="font-rounded text-lg leading-snug text-pretty">
            {count > 1 ? `${count}枚の加工済み写真を破棄します` : "この加工済み写真を破棄します"}
          </DialogTitle>
          <DialogDescription className="leading-relaxed">
            {usedTrial
              ? "使用した一括処理クレジットは戻りません。"
              : "使用した無料枠は戻りません。"}
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-2">
          <Button
            size="lg"
            variant="destructive"
            className="h-12 rounded-2xl text-sm font-bold"
            onClick={discardPending}
          >
            破棄する
          </Button>
          <Button variant="ghost" size="lg" className="h-11 rounded-2xl" onClick={closeDiscard}>
            もどる
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

/**
 * 異常終了したあとの復旧。
 * これは履歴ではなく「受け渡しが完了していない出力」の復旧なので、
 * 履歴を保存しない設定でも表示する。
 */
export function RecoveryDialog() {
  const { recoveryOpen, closeRecovery, pendingOutput, savePending, sharePending, askDiscard } = useApp()
  const count = generatedCount(pendingOutput)
  // 受け渡し済みの出力では復旧案内を出さない
  const needsRecovery = generatedCount(pendingOutput) > 0

  return (
    <Dialog open={recoveryOpen && needsRecovery} onOpenChange={(open) => (!open ? closeRecovery() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        <DialogHeader>
          <span className="flex size-11 items-center justify-center rounded-2xl bg-primary/12 text-primary">
            <Download className="size-5" aria-hidden />
          </span>
          <DialogTitle className="font-rounded text-lg leading-snug text-pretty">
            {pendingLabel(count)}
          </DialogTitle>
          <DialogDescription className="leading-relaxed">
            前回の加工が保存されないまま終了しました。いま保存または共有できます。
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-2">
          <Button size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={savePending}>
            <Download data-icon="inline-start" />
            {count > 1 ? "まとめて保存する" : "保存する"}
          </Button>
          <Button variant="outline" size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={sharePending}>
            <Share2 data-icon="inline-start" />
            共有する
          </Button>
          <Button variant="ghost" size="lg" className="h-11 rounded-2xl text-destructive" onClick={askDiscard}>
            破棄する
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
