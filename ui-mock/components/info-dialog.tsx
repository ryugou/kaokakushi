"use client"

import { Check, FileText, HelpCircle, MessageSquare, ShieldCheck, type LucideIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

export type InfoTopic = "privacy" | "guide" | "terms" | "feedback"

const CONTENT: Record<
  InfoTopic,
  { icon: LucideIcon; title: string; body: string; points: string[]; note?: string }
> = {
  privacy: {
    icon: ShieldCheck,
    title: "プライバシーポリシー",
    body: "選択した写真は端末内で加工され、外部サーバーへ送信されません。",
    points: [
      "顔の検出も加工も端末内で行います",
      "写真をサーバーに送信しません",
      "保存時に位置情報や撮影機器の記録を消せます",
      "加工の履歴も端末内にだけ残ります",
    ],
    note: "広告の表示、購入の確認、不具合の解析には通信が発生します。写真そのものは送信しません。",
  },
  guide: {
    icon: HelpCircle,
    title: "使いかたガイド",
    body: "3つのステップで、顔をかんたんに隠せます。",
    points: [
      "1. ホームで写真をえらびます",
      "2. 顔が自動で見つかります。はじめはすべて隠す状態です",
      "3. 残したい顔をタップして、かくし方をえらんで保存します",
      "見つからない顔があるときは「手動で範囲を追加」で自分で囲めます",
    ],
    note: "写っている顔をすべて見つけられるとはかぎりません。保存する前に仕上がりをご確認ください。",
  },
  feedback: {
    icon: MessageSquare,
    title: "ご意見・ご要望",
    body: "こんな機能がほしい、という声を教えてください。",
    points: [
      "使いにくかったところ",
      "うまく顔が見つからなかった写真の種類",
      "ほしいスタンプ",
      "動画への対応",
    ],
    note: "いただいた内容は、今後の改善の参考にします。写真そのものは送信されません。",
  },
  terms: {
    icon: FileText,
    title: "利用規約・ライセンス",
    body: "このアプリは、写真に写った人のプライバシーを守るためのものです。",
    points: [
      "本人の許可なく他人の写真を公開しないでください",
      "すべての顔を検出することや、加工結果を保証するものではありません",
      "有料プランはいつでも変更・解約できます",
      "アイコンは Lucide（ISCライセンス）を使用しています",
    ],
  },
}

export function InfoDialog({ topic, onClose }: { topic: InfoTopic | null; onClose: () => void }) {
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
