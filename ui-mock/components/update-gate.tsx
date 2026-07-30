"use client"

import { ArrowUpCircle } from "lucide-react"

import { LATEST_VERSION, useApp } from "@/components/app-provider"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

/**
 * アプリ更新の誘導。
 *
 * 強制更新（全画面ブロック）は ADR 0005 で廃止した。残るのは任意の更新推奨のみで、
 * 「後で」を選べば skipUpdate によりそのバージョンでは再表示しない。
 */
export function UpdateGate() {
  const { updateState, skipUpdate } = useApp()

  if (updateState !== "recommended") return null

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
