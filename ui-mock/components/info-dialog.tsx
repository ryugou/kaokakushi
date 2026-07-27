"use client"

import { Check, FileText, HelpCircle, ShieldCheck, type LucideIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

export type InfoTopic = "privacy" | "guide" | "terms"

const CONTENT: Record<
  InfoTopic,
  { icon: LucideIcon; title: string; body: string; points: string[]; note?: string }
> = {
  privacy: {
    icon: ShieldCheck,
    title: "プライバシーについて",
    body: "選択した写真や動画は、端末内で加工され、外部サーバーへ送信されません。",
    points: [
      "顔の検出も加工も端末内で行います",
      "写真や動画をサーバーに送信しません",
      "保存時に撮影場所などの記録を消せます",
      "加工の履歴も端末内にだけ残ります",
    ],
    note: "アプリを削除すると、履歴とマイスタンプも一緒に消えます。",
  },
  guide: {
    icon: HelpCircle,
    title: "使いかたガイド",
    body: "3つのステップで、顔をかんたんに隠せます。",
    points: [
      "1. ホームで写真か動画をえらびます",
      "2. 顔が自動で見つかるので、隠したい顔をタップします",
      "3. 隠しかたをえらんで保存します",
      "うまく見つからないときは「顔をたす」で自分で囲めます",
    ],
    note: "動画は顔の動きを追いかけて隠します。長さはプランによって変わります。",
  },
  terms: {
    icon: FileText,
    title: "利用規約・ライセンス",
    body: "このアプリは、写真や動画に写った人のプライバシーを守るためのものです。",
    points: [
      "本人の許可なく他人の写真を公開しないでください",
      "加工結果を保証するものではありません",
      "有料プランはいつでも変更・解約できます",
      "アイコンは Lucide（ISCライセンス）を使用しています",
    ],
  },
}

export function InfoDialog({
  topic,
  onClose,
}: {
  topic: InfoTopic | null
  onClose: () => void
}) {
  const info = topic ? CONTENT[topic] : null
  const Icon = info?.icon

  return (
    <Dialog open={topic !== null} onOpenChange={(open) => (!open ? onClose() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        {info && Icon ? (
          <>
            <DialogHeader>
              <span className="flex size-11 items-center justify-center rounded-2xl bg-secondary text-primary">
                <Icon className="size-5" aria-hidden />
              </span>
              <DialogTitle className="font-rounded text-lg leading-snug">{info.title}</DialogTitle>
              <DialogDescription className="leading-relaxed">{info.body}</DialogDescription>
            </DialogHeader>
            <ul className="flex flex-col gap-2">
              {info.points.map((p) => (
                <li key={p} className="flex items-start gap-2 text-sm">
                  <Check className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden />
                  <span className="leading-relaxed">{p}</span>
                </li>
              ))}
            </ul>
            {info.note ? (
              <p className="rounded-2xl bg-secondary px-3 py-2.5 text-[11px] leading-relaxed text-secondary-foreground">
                {info.note}
              </p>
            ) : null}
            <Button size="lg" className="h-12 rounded-2xl text-sm font-bold" onClick={onClose}>
              とじる
            </Button>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
