"use client"

import { ArrowUpCircle, Download, Share2 } from "lucide-react"

import { generatedCount, LATEST_VERSION, useApp } from "@/components/app-provider"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

/**
 * アプリ更新の誘導。
 *
 * 強制更新は全画面で塞ぐが、未保存の加工済み写真がある場合は先に受け渡しの導線を出す。
 * ここを塞ぐと「無料枠は消費したのに写真は受け取れない」状態を作ってしまう。
 */
export function UpdateGate() {
  const { updateState, pendingOutput, savePending, sharePending, skipUpdate } = useApp()

  if (updateState === "none") return null

  const pending = generatedCount(pendingOutput)

  /* 強制更新：未保存があるあいだは受け渡しだけを許す ---------------- */
  if (updateState === "required") {
    return (
      <div className="absolute inset-0 z-50 flex flex-col justify-end bg-foreground/70 backdrop-blur-sm">
        <div className="flex flex-col gap-4 rounded-t-3xl bg-card p-5">
          <div className="flex flex-col gap-1.5">
            <p className="flex items-center gap-2 font-rounded text-base font-bold">
              <ArrowUpCircle className="size-5 text-primary" aria-hidden />
              アプリの更新が必要です
            </p>
            <p className="text-xs leading-relaxed text-muted-foreground text-pretty">
              最新版 {LATEST_VERSION} へ更新してください。
            </p>
          </div>

          {pending > 0 ? (
            <>
              <div className="flex flex-col gap-1 rounded-2xl bg-chart-3/15 px-3 py-2.5">
                <p className="text-[11px] font-bold leading-relaxed text-foreground text-pretty">
                  保存していない加工済み写真が{pending}枚あります。
                </p>
                <p className="text-[11px] leading-relaxed text-muted-foreground text-pretty">
                  先に保存してから更新してください。更新すると受け取れなくなります。
                </p>
              </div>

              <div className="grid grid-cols-2 gap-2">
                <Button size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={savePending}>
                  <Download data-icon="inline-start" />
                  写真を保存
                </Button>
                <Button
                  variant="outline"
                  size="lg"
                  className="h-12 rounded-2xl text-sm font-bold"
                  onClick={sharePending}
                >
                  <Share2 data-icon="inline-start" />
                  共有する
                </Button>
              </div>
            </>
          ) : null}

          <Button
            variant={pending > 0 ? "ghost" : "default"}
            size="lg"
            className="h-12 rounded-2xl text-sm font-bold"
          >
            App Store を開く
          </Button>

          <p className="text-center text-[11px] leading-relaxed text-muted-foreground text-pretty">
            {pending > 0
              ? "保存または共有が終わるまで、ほかの操作はできません"
              : "更新するまでアプリを使用できません"}
          </p>
        </div>
      </div>
    )
  }

  /* 任意更新：スキップできる ------------------------------------- */
  return (
    <Dialog open onOpenChange={(open) => (!open ? skipUpdate() : undefined)}>
      <DialogContent className="max-w-[320px] rounded-3xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 font-rounded text-base">
            <ArrowUpCircle className="size-5 text-primary" aria-hidden />
            新しいバージョンがあります
          </DialogTitle>
          <DialogDescription className="text-pretty">
            {LATEST_VERSION} が公開されています。更新すると最新の改善が反映されます。
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-2">
          <Button size="lg" className="h-12 rounded-2xl text-sm font-bold">
            App Store を開く
          </Button>
          <Button
            variant="ghost"
            size="lg"
            className="h-12 rounded-2xl text-sm font-bold"
            onClick={skipUpdate}
          >
            後で
          </Button>
        </div>

        <p className="text-center text-[11px] leading-relaxed text-muted-foreground text-pretty">
          「後で」を選ぶと、このバージョンについては再表示しません
        </p>
      </DialogContent>
    </Dialog>
  )
}
