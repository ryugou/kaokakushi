"use client"

import * as React from "react"
import {
  ChevronRight,
  Crown,
  FileText,
  HelpCircle,
  Layers,
  MapPinOff,
  Minus,
  Plus,
  ShieldCheck,
  Sparkles,
  Star,
  Sticker,
  Wand2,
} from "lucide-react"

import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import {
  FREE_MONTHLY_LIMIT,
  PLAN_LABELS,
  PLAN_PRICE_LABELS,
  useApp,
  type Plan,
} from "@/components/app-provider"
import { PrivacyNote, ProBadge, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { InfoDialog, type InfoTopic } from "@/components/info-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Switch } from "@/components/ui/switch"

export function SettingsScreen() {
  const {
    plan,
    setPlan,
    remainingFree,
    setRemainingFree,
    deviceSupports4K,
    setDeviceSupports4K,
    canBatch,
    canUseCustomStamps,
    videoLimitLabel,
    go,
    effect,
    setEffect,
    exportSettings,
    updateExport,
    requestUpgrade,
  } = useApp()
  const [autoDetect, setAutoDetect] = React.useState(true)
  const [info, setInfo] = React.useState<InfoTopic | null>(null)

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="設定" />

      <div className="flex flex-1 flex-col gap-5 px-4 py-4">
        <section className="flex flex-col gap-3 rounded-3xl bg-card p-4 ring-1 ring-foreground/10">
          <div className="flex items-center justify-between gap-2">
            <div className="flex flex-col gap-0.5">
              <p className="flex items-center gap-1.5 font-rounded text-sm font-bold">
                {plan === "pro" ? <Crown className="size-4 text-chart-3" aria-hidden /> : null}
                {PLAN_LABELS[plan]}
                <span className="text-[11px] font-medium text-muted-foreground">
                  {PLAN_PRICE_LABELS[plan]}
                </span>
              </p>
              <p className="text-[11px] text-muted-foreground">
                {plan === "free"
                  ? remainingFree === 0
                    ? "今月の無料保存を使い切りました"
                    : `今月あと${remainingFree}件保存できます（月${FREE_MONTHLY_LIMIT}件）`
                  : `単体書き出しは無制限・広告なし・動画は最大${videoLimitLabel}`}
              </p>
            </div>
            {plan === "pro" ? <ProBadge /> : plan === "standard" ? <Badge variant="secondary">Standard</Badge> : null}
          </div>
          <Button
            size="lg"
            variant={plan === "free" ? "default" : "outline"}
            className="h-12 w-full rounded-2xl font-bold"
            onClick={() => go("pricing")}
          >
            <Sparkles data-icon="inline-start" />
            {plan === "free" ? "プランを見る" : "プランを変更する"}
          </Button>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>加工のきほん設定</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <div className="flex flex-col gap-2 border-b px-4 py-3">
              <p className="flex items-center gap-2 text-xs font-medium">
                <Wand2 className="size-4 text-primary" aria-hidden />
                はじめに選ばれる隠しかた
              </p>
              <div className="grid grid-cols-4 gap-2">
                {(["mosaic", "blur", "black", "stamp"] as EffectType[]).map((t) => (
                  <button
                    key={t}
                    type="button"
                    onClick={() => setEffect((prev) => ({ ...prev, type: t }))}
                    className={
                      effect.type === t
                        ? "h-10 rounded-xl bg-primary text-[11px] font-bold text-primary-foreground"
                        : "h-10 rounded-xl bg-secondary text-[11px] font-bold text-secondary-foreground"
                    }
                  >
                    {EFFECT_LABELS[t]}
                  </button>
                ))}
              </div>
            </div>
            <ToggleRow
              icon={<Sparkles className="size-4 text-primary" aria-hidden />}
              label="顔を自動でさがす"
              hint="写真を開いたときに自動で検出します"
              checked={autoDetect}
              onChange={setAutoDetect}
            />
            <ToggleRow
              icon={<MapPinOff className="size-4 text-primary" aria-hidden />}
              label="位置情報などの記録を消す"
              hint="保存時に撮影場所の情報を残しません"
              checked={exportSettings.stripMetadata}
              onChange={(v) => updateExport({ stripMetadata: v })}
              last
            />
          </div>
          <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
            元の写真や動画は変更されません。加工したものは別のファイルとして保存されます。
          </p>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>べんりな機能</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <LinkRow
              icon={<Layers className="size-4 text-primary" aria-hidden />}
              label="まとめて加工"
              hint={canBatch ? "複数の素材を一度に加工" : "Proで使えます"}
              badge={canBatch ? undefined : <ProBadge className="text-[10px]" />}
              onClick={() => (canBatch ? go("batch") : requestUpgrade("batch"))}
            />
            <LinkRow
              icon={<Sticker className="size-4 text-primary" aria-hidden />}
              label="スタンプを見る"
              hint="カテゴリごとに選べます"
              onClick={() => go("stamps")}
            />
            <LinkRow
              icon={<Star className="size-4 text-primary" aria-hidden />}
              label="マイスタンプを作る"
              hint={canUseCustomStamps ? "自分だけのスタンプ" : "Standard以上で使えます"}
              badge={canUseCustomStamps ? undefined : <Badge variant="secondary" className="text-[10px]">Standard</Badge>}
              onClick={() => (canUseCustomStamps ? go("custom-stamp") : requestUpgrade("custom-stamp"))}
              last
            />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>安心とサポート</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <LinkRow
              icon={<ShieldCheck className="size-4 text-primary" aria-hidden />}
              label="プライバシーについて"
              hint="端末内処理のしくみ"
              onClick={() => setInfo("privacy")}
            />
            <LinkRow
              icon={<HelpCircle className="size-4 text-primary" aria-hidden />}
              label="使いかたガイド"
              hint="よくある質問"
              onClick={() => setInfo("guide")}
            />
            <LinkRow
              icon={<FileText className="size-4 text-primary" aria-hidden />}
              label="利用規約・ライセンス"
              onClick={() => setInfo("terms")}
              last
            />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>デモ用の状態切り替え</SectionTitle>
          <div className="flex flex-col gap-3 rounded-2xl bg-secondary/60 p-4 ring-1 ring-foreground/10">
            <p className="text-[11px] leading-relaxed text-muted-foreground">
              仕様確認用のスイッチです。プランや残り件数を変えて、制限の見え方を確認できます。
            </p>
            <div className="flex flex-col gap-1.5">
              <p className="text-[11px] font-bold">プラン</p>
              <div className="grid grid-cols-3 gap-2">
                {(["free", "standard", "pro"] as Plan[]).map((p) => (
                  <button
                    key={p}
                    type="button"
                    onClick={() => setPlan(p)}
                    className={
                      plan === p
                        ? "h-10 rounded-xl bg-primary text-[11px] font-bold text-primary-foreground"
                        : "h-10 rounded-xl bg-card text-[11px] font-bold text-foreground ring-1 ring-foreground/10"
                    }
                  >
                    {PLAN_LABELS[p]}
                  </button>
                ))}
              </div>
            </div>
            <div className="flex items-center justify-between gap-3">
              <p className="text-[11px] font-bold">今月の残り件数</p>
              <div className="flex items-center gap-2">
                <Button
                  size="icon"
                  variant="outline"
                  className="size-8 rounded-xl"
                  aria-label="残り件数を減らす"
                  onClick={() => setRemainingFree(Math.max(0, remainingFree - 1))}
                >
                  <Minus />
                </Button>
                <span className="w-10 text-center font-rounded text-sm font-bold">{remainingFree}</span>
                <Button
                  size="icon"
                  variant="outline"
                  className="size-8 rounded-xl"
                  aria-label="残り件数を増やす"
                  onClick={() => setRemainingFree(Math.min(FREE_MONTHLY_LIMIT, remainingFree + 1))}
                >
                  <Plus />
                </Button>
              </div>
            </div>
            <label className="flex items-center justify-between gap-3">
              <span className="min-w-0">
                <span className="block text-[11px] font-bold">この端末は4Kに対応</span>
                <span className="block text-[11px] text-muted-foreground">
                  オフにすると4K書き出しが選べなくなります
                </span>
              </span>
              <Switch checked={deviceSupports4K} onCheckedChange={setDeviceSupports4K} />
            </label>
          </div>
        </section>

        <PrivacyNote />
        <p className="pb-2 text-center text-[11px] text-muted-foreground">かおかくし ver 1.0.0</p>
      </div>

      <InfoDialog topic={info} onClose={() => setInfo(null)} />
    </div>
  )
}

function ToggleRow({
  icon,
  label,
  hint,
  checked,
  onChange,
  last,
}: {
  icon: React.ReactNode
  label: string
  hint?: string
  checked: boolean
  onChange: (value: boolean) => void
  last?: boolean
}) {
  return (
    <label
      className={
        last
          ? "flex items-center justify-between gap-3 px-4 py-3"
          : "flex items-center justify-between gap-3 border-b px-4 py-3"
      }
    >
      <span className="flex min-w-0 items-center gap-2">
        {icon}
        <span className="min-w-0">
          <span className="block text-xs font-medium">{label}</span>
          {hint ? <span className="block text-[11px] text-muted-foreground">{hint}</span> : null}
        </span>
      </span>
      <Switch checked={checked} onCheckedChange={onChange} />
    </label>
  )
}

function LinkRow({
  icon,
  label,
  hint,
  badge,
  onClick,
  last,
}: {
  icon: React.ReactNode
  label: string
  hint?: string
  badge?: React.ReactNode
  onClick: () => void
  last?: boolean
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={
        last
          ? "flex items-center justify-between gap-3 px-4 py-3 text-left"
          : "flex items-center justify-between gap-3 border-b px-4 py-3 text-left"
      }
    >
      <span className="flex min-w-0 items-center gap-2">
        {icon}
        <span className="min-w-0">
          <span className="block text-xs font-medium">{label}</span>
          {hint ? <span className="block text-[11px] text-muted-foreground">{hint}</span> : null}
        </span>
      </span>
      <span className="flex shrink-0 items-center gap-1.5">
        {badge}
        <ChevronRight className="size-4 text-muted-foreground" aria-hidden />
      </span>
    </button>
  )
}
