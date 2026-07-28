"use client"

import * as React from "react"
import {
  ChevronRight,
  Crown,
  Database,
  FileText,
  ArrowUpCircle,
  HardDrive,
  HelpCircle,
  Layers,
  MessageSquare,
  RefreshCcw,
  ShieldCheck,
  Sparkles,
  Star,
  Sticker,
  Wand2,
} from "lucide-react"

import { cn } from "@/lib/utils"
import { formatMb } from "@/lib/mock-data"
import { EFFECT_LABELS, type EffectType } from "@/components/face-mask"
import {
  FREE_MONTHLY_LIMIT,
  PLAN_LABELS,
  PLAN_PRICE_LABELS,
  HISTORY_LIMIT_MB,
  PLAN_STATUS_LABELS,
  RETENTION_LABELS,
  TRIAL_CREDITS,
  useApp,
  type Plan,
  type PlanStatus,
  type Retention,
} from "@/components/app-provider"
import { PrivacyNote, ProBadge, ScreenHeader, SectionTitle } from "@/components/app-bits"
import { InfoDialog, type InfoTopic } from "@/components/info-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Switch } from "@/components/ui/switch"

const RETENTIONS: Retention[] = ["none", "7d", "30d", "no-expiry"]

export function SettingsScreen() {
  const {
    plan,
    setPlan,
    planStatus,
    setPlanStatus,
    effectivePlan,
    remainingFree,
    setRemainingFree,
    trialCredits,
    setTrialConsumed,
    canBatchFull,
    canBatchTrial,
    canUseCustomStamps,
    go,
    effect,
    setEffect,
    requestUpgrade,
    retention,
    setRetention,
    historyStorageMb,
    historyLimitMb,
    setHistoryLimitMb,
    history,
    myStamps,
    stampStorageActiveMb,
    stampStorageRetainedMb,
    retiredStampCount,
    lowStorage,
    setLowStorage,
    simulateCrash,
    simulateUpdate,
    pendingOutput,
    guardNewWork,
  } = useApp()

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
                <span className="text-[11px] font-medium text-muted-foreground">{PLAN_PRICE_LABELS[plan]}</span>
              </p>
              <p className="text-[11px] text-muted-foreground">
                {plan === "free"
                  ? remainingFree === 0
                    ? "今月の無料保存を使い切りました"
                    : `今月あと${remainingFree}枚保存できます（月${FREE_MONTHLY_LIMIT}枚）`
                  : plan === "standard"
                    ? "1枚ずつの書き出しは無制限・広告なし"
                    : `最大50枚の一括処理・広告なし`}
              </p>
            </div>
            {plan === "pro" ? <ProBadge /> : plan === "standard" ? <Badge variant="secondary">Standard</Badge> : null}
          </div>

          <div className="flex flex-col gap-1.5 rounded-2xl bg-secondary/60 p-3">
            <InfoRow
              label="今月の無料枠"
              value={plan === "free" ? `あと${remainingFree}枚 / ${FREE_MONTHLY_LIMIT}枚` : "無制限"}
            />
            <InfoRow
              label="一括処理お試しクレジット"
              value={canBatchFull ? "Proは消費しません" : `あと${trialCredits}枚 / ${TRIAL_CREDITS}枚`}
            />
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
          <div className="grid grid-cols-2 gap-2">
            <Button variant="secondary" size="sm" className="h-10 rounded-xl text-[11px] font-bold">
              <RefreshCcw data-icon="inline-start" />
              購入を復元
            </Button>
            <Button variant="secondary" size="sm" className="h-10 rounded-xl text-[11px] font-bold">
              サブスクリプション管理
            </Button>
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>加工のきほん設定</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <div className="flex flex-col gap-2 px-4 py-3">
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
          </div>
          <p className="px-1 text-[11px] leading-relaxed text-muted-foreground">
            検出した顔は、はじめはすべて隠す状態になります。残したい顔だけタップして切り替えます。
          </p>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>履歴</SectionTitle>
          <div className="flex flex-col gap-3 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
            <p className="text-xs font-medium">保存期間</p>
            <div className="grid grid-cols-2 gap-2">
              {RETENTIONS.map((r) => (
                <button
                  key={r}
                  type="button"
                  onClick={() => setRetention(r)}
                  className={cn(
                    "h-11 rounded-xl text-[11px] font-bold transition-colors",
                    retention === r
                      ? "bg-primary text-primary-foreground"
                      : "bg-secondary text-secondary-foreground",
                  )}
                >
                  {RETENTION_LABELS[r]}
                </button>
              ))}
            </div>
            <p className="text-[11px] leading-relaxed text-muted-foreground">
              写真ライブラリへ保存した加工済み写真は、この設定にかかわらず削除されません。保存期限なしを選んだ場合も、履歴の使用容量上限を超えると古い履歴から削除されます。
            </p>
            {retention === "none" ? (
              <p className="rounded-xl bg-secondary px-3 py-2 text-[11px] leading-relaxed text-secondary-foreground">
                履歴を保存しない場合、あとから同じ編集内容を開くことはできません。加工が終わって画面を離れた時点で、編集設定・検出結果・サムネイル・加工用の中間データを削除します。保存していない加工済み写真だけは、保存・共有・破棄まで一時的に保持します。
              </p>
            ) : null}
            <div className="flex flex-col gap-1.5 border-t pt-3">
              <InfoRow
                label="履歴の使用容量"
                value={`${formatMb(historyStorageMb)} / ${formatMb(historyLimitMb)}`}
                icon={<Database className="size-3.5" aria-hidden />}
              />
            </div>
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>マイスタンプ</SectionTitle>
          <div className="flex flex-col gap-1.5 rounded-2xl bg-card p-4 ring-1 ring-foreground/10">
            <InfoRow label="登録数" value={`${myStamps.length}個 / 100個`} />
            <InfoRow label="登録中のマイスタンプ" value={formatMb(stampStorageActiveMb)} />
            <InfoRow
              label="過去の加工履歴で使用中"
              value={retiredStampCount > 0 ? `${formatMb(stampStorageRetainedMb)}（${retiredStampCount}個）` : "なし"}
            />
            <InfoRow
              label="合計"
              value={formatMb(stampStorageActiveMb + stampStorageRetainedMb)}
            />
            <p className="pt-1 text-[11px] leading-relaxed text-muted-foreground">
              過去の加工履歴で使用中の画像は、履歴を再現するために保持されます。完全に削除するには、その履歴を削除してください。
            </p>
            <Button
              variant="secondary"
              size="sm"
              className="mt-1 h-10 rounded-xl text-[11px] font-bold"
              onClick={() => go("stamps")}
            >
              マイスタンプを管理する
            </Button>
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>べんりな機能</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <LinkRow
              icon={<Layers className="size-4 text-primary" aria-hidden />}
              label="まとめて加工"
              hint={
                canBatchFull
                  ? "最大50枚をまとめて加工"
                  : canBatchTrial
                    ? `お試し：あと${trialCredits}枚`
                    : "Proで使えます"
              }
              badge={canBatchFull ? undefined : <ProBadge className="text-[10px]" label={canBatchTrial ? "お試し" : "Pro"} />}
              onClick={() =>
                canBatchFull || canBatchTrial
                  ? guardNewWork("まとめて加工", () => go("batch"))
                  : requestUpgrade("batch-credit")
              }
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
              badge={
                canUseCustomStamps ? undefined : (
                  <Badge variant="secondary" className="text-[10px]">
                    Standard
                  </Badge>
                )
              }
              onClick={() => (canUseCustomStamps ? go("custom-stamp") : requestUpgrade("custom-stamp"))}
              last
            />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <SectionTitle>安心とサポート</SectionTitle>
          <div className="flex flex-col rounded-2xl bg-card ring-1 ring-foreground/10">
            <div className="flex flex-col gap-1 border-b px-4 py-3">
              <p className="flex items-center gap-2 text-xs font-medium">
                <ShieldCheck className="size-4 text-primary" aria-hidden />
                写真の扱い
              </p>
              <p className="text-[11px] leading-relaxed text-muted-foreground">
                元の写真は変更されません。選択した写真は外部サーバーへ送信されません。広告の表示や購入の確認には通信を使います。
              </p>
            </div>
            <LinkRow
              icon={<ShieldCheck className="size-4 text-primary" aria-hidden />}
              label="プライバシーポリシー"
              onClick={() => setInfo("privacy")}
            />
            <LinkRow
              icon={<HelpCircle className="size-4 text-primary" aria-hidden />}
              label="使いかたガイド"
              hint="よくある質問"
              onClick={() => setInfo("guide")}
            />
            <LinkRow
              icon={<MessageSquare className="size-4 text-primary" aria-hidden />}
              label="ご意見・ご要望"
              hint="ほしい機能を教えてください"
              onClick={() => setInfo("feedback")}
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
              仕様確認用のスイッチです。プランや残り枚数を変えて、制限の見え方を確認できます。
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

            <StepperRow
              label="今月の残り枚数"
              value={remainingFree}
              max={FREE_MONTHLY_LIMIT}
              onChange={setRemainingFree}
            />
            <StepperRow
              label="一括処理クレジット"
              value={trialCredits}
              max={TRIAL_CREDITS}
              onChange={(n) => setTrialConsumed(TRIAL_CREDITS - n)}
            />

            <div className="flex flex-col gap-1.5">
              <p className="text-[11px] font-bold">契約の状態</p>
              <div className="grid grid-cols-4 gap-2">
                {(["active", "grace", "pending", "expired"] as PlanStatus[]).map((s) => (
                  <button
                    key={s}
                    type="button"
                    onClick={() => setPlanStatus(s)}
                    className={
                      planStatus === s
                        ? "h-10 rounded-xl bg-primary text-[10px] font-bold text-primary-foreground"
                        : "h-10 rounded-xl bg-card text-[10px] font-bold text-foreground ring-1 ring-foreground/10"
                    }
                  >
                    {PLAN_STATUS_LABELS[s]}
                  </button>
                ))}
              </div>
              <p className="text-[11px] leading-relaxed text-muted-foreground">
                支払い確認中と期限切れでは有料機能を付与しません。いまの実効プランは
                {PLAN_LABELS[effectivePlan]}です。
              </p>
            </div>

            <label className="flex items-center justify-between gap-3">
              <span className="min-w-0">
                <span className="block text-[11px] font-bold">空き容量を不足させる</span>
                <span className="block text-[11px] text-muted-foreground">
                  一括処理の開始前チェックと、保存の部分成功を確認できます
                </span>
              </span>
              <Switch checked={lowStorage} onCheckedChange={setLowStorage} />
            </label>

            <label className="flex items-center justify-between gap-3">
              <span className="min-w-0">
                <span className="block text-[11px] font-bold">履歴の容量上限を 1MB にする</span>
                <span className="block text-[11px] text-muted-foreground">
                  容量超過で古い履歴が削除される挙動を確認できます
                </span>
              </span>
              <Switch
                checked={historyLimitMb < HISTORY_LIMIT_MB}
                onCheckedChange={(v) => setHistoryLimitMb(v ? 1 : HISTORY_LIMIT_MB)}
              />
            </label>

            <Button
              variant="outline"
              size="sm"
              className="h-10 rounded-xl text-[11px] font-bold"
              disabled={!pendingOutput}
              onClick={simulateCrash}
            >
              <HardDrive data-icon="inline-start" />
              異常終了後の復旧を表示
            </Button>
            {!pendingOutput ? (
              <p className="text-[11px] leading-relaxed text-muted-foreground">
                先に写真を1枚加工して、保存せずに完了画面を離れると試せます。
              </p>
            ) : null}

            <div className="grid grid-cols-2 gap-2">
              <Button
                variant="outline"
                size="sm"
                className="h-10 rounded-xl text-[11px] font-bold"
                onClick={() => simulateUpdate("recommended")}
              >
                <ArrowUpCircle data-icon="inline-start" />
                任意更新の案内
              </Button>
              <Button
                variant="outline"
                size="sm"
                className="h-10 rounded-xl text-[11px] font-bold"
                onClick={() => simulateUpdate("required")}
              >
                <ArrowUpCircle data-icon="inline-start" />
                強制更新
              </Button>
            </div>
            <p className="text-[11px] leading-relaxed text-muted-foreground">
              未保存の加工済み写真があるときに強制更新を出すと、受け渡しの導線が先に表示されます。
            </p>
          </div>
        </section>

        <PrivacyNote />
        <p className="pb-2 text-center text-[11px] text-muted-foreground">顔かくし ver 1.0.0</p>
      </div>

      <InfoDialog topic={info} onClose={() => setInfo(null)} />
    </div>
  )
}

function InfoRow({ label, value, icon }: { label: string; value: string; icon?: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3 text-[11px]">
      <span className="flex items-center gap-1.5 text-muted-foreground">
        {icon}
        {label}
      </span>
      <span className="font-medium">{value}</span>
    </div>
  )
}

function StepperRow({
  label,
  value,
  max,
  onChange,
}: {
  label: string
  value: number
  max: number
  onChange: (n: number) => void
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <p className="text-[11px] font-bold">{label}</p>
      <div className="flex items-center gap-2">
        <Button
          size="icon"
          variant="outline"
          className="size-8 rounded-xl"
          aria-label={`${label}を減らす`}
          onClick={() => onChange(Math.max(0, value - 1))}
        >
          −
        </Button>
        <span className="w-10 text-center font-rounded text-sm font-bold">{value}</span>
        <Button
          size="icon"
          variant="outline"
          className="size-8 rounded-xl"
          aria-label={`${label}を増やす`}
          onClick={() => onChange(Math.min(max, value + 1))}
        >
          ＋
        </Button>
      </div>
    </div>
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
