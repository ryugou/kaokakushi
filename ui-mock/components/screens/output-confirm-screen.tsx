"use client"

import { CheckCircle2, RotateCcw } from "lucide-react"

import { useApp } from "@/components/app-provider"
import { MediaCanvas } from "@/components/media-canvas"
import { PrivacyNote } from "@/components/app-bits"
import { Button } from "@/components/ui/button"

/**
 * 出力確認画面（confirm）。
 *
 * ADR 0006: 枠の確定は生成の完了時点ではなく、ここでの明示的な完了操作で行う。
 * 「完了する」を押すまでは、この画面から「やり直す」で何度でも無料に差し替えられる。
 */
export function OutputConfirmScreen() {
  const { media, faces, hidden, effect, effectLabel, plan, remainingFree, completePending, redoPending } = useApp()

  if (!media) return null

  return (
    <div className="flex min-h-full flex-col gap-5 px-4 py-6">
      <div className="flex flex-col items-center gap-1.5 text-center">
        <span className="grid size-14 place-items-center rounded-full bg-primary/12 text-primary">
          <CheckCircle2 className="size-8" aria-hidden />
        </span>
        <h1 className="font-rounded text-lg font-bold">加工した写真ができました</h1>
        <p className="text-xs text-muted-foreground text-pretty">
          {hidden.length > 0 ? `${effectLabel}で${hidden.length}人の顔を隠しました` : "顔加工なしで書き出しました"}
        </p>
      </div>

      <MediaCanvas
        media={media}
        faces={faces}
        hidden={hidden}
        effect={effect}
        className="mx-auto aspect-square max-w-[280px]"
      />

      <div className="flex flex-col gap-2">
        <Button size="lg" className="h-13 w-full rounded-2xl font-bold" onClick={completePending}>
          完了する
        </Button>
        <Button size="lg" variant="outline" className="h-13 w-full rounded-2xl font-bold" onClick={redoPending}>
          <RotateCcw data-icon="inline-start" />
          やり直す
        </Button>
      </div>

      <div className="flex flex-col gap-1">
        <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
          完了すると1枚として確定します。完了後の作り直しは新しい1枚として数えます。
        </p>
        <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
          やり直しは無料枠を消費しません。
        </p>
        {plan === "free" ? (
          <p className="px-1 text-center text-[11px] leading-relaxed text-muted-foreground">
            今月の残り あと{remainingFree}枚
          </p>
        ) : null}
      </div>

      <PrivacyNote />
    </div>
  )
}
