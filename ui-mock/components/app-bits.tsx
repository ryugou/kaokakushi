"use client"

import { ChevronLeft, Crown, Lock, Megaphone, Smartphone } from "lucide-react"

import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"

export function ScreenHeader({
  title,
  onBack,
  action,
  subtitle,
}: {
  title: string
  onBack?: () => void
  action?: React.ReactNode
  subtitle?: string
}) {
  return (
    <header className="flex shrink-0 items-center gap-2 border-b bg-card px-3 py-3">
      {onBack ? (
        <Button variant="ghost" size="icon-lg" onClick={onBack} className="size-10 rounded-full">
          <ChevronLeft className="size-5" />
          <span className="sr-only">戻る</span>
        </Button>
      ) : (
        <span className="size-10" aria-hidden />
      )}
      <div className="min-w-0 flex-1 text-center">
        <h1 className="truncate font-rounded text-base font-bold">{title}</h1>
        {subtitle ? <p className="truncate text-[11px] text-muted-foreground">{subtitle}</p> : null}
      </div>
      <div className="flex min-w-10 justify-end">{action}</div>
    </header>
  )
}

export function ProBadge({ label = "Pro", className }: { label?: string; className?: string }) {
  return (
    <Badge
      className={cn("gap-1 border-transparent bg-chart-3/20 text-[10px] font-bold text-foreground", className)}
    >
      <Crown className="size-3" aria-hidden />
      {label}
    </Badge>
  )
}

export function LockDot({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "absolute right-1 top-1 grid size-5 place-items-center rounded-full bg-card/90 text-foreground shadow-sm",
        className,
      )}
      aria-hidden
    >
      <Lock className="size-3" />
    </span>
  )
}

export function PrivacyNote({ className }: { className?: string }) {
  return (
    <p className={cn("flex items-center justify-center gap-1.5 text-[11px] text-muted-foreground", className)}>
      <Smartphone className="size-3.5 shrink-0" aria-hidden />
      選択した写真は端末内で処理され、外部サーバーへ送信されません
    </p>
  )
}

export function AdSlot({ label = "広告" }: { label?: string }) {
  return (
    <div className="flex items-center gap-3 rounded-2xl border border-dashed bg-secondary/60 px-4 py-3">
      <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-card text-muted-foreground">
        <Megaphone className="size-4" aria-hidden />
      </span>
      <div className="min-w-0 flex-1">
        <p className="truncate text-xs font-medium text-foreground">スポンサー</p>
        <p className="truncate text-[11px] text-muted-foreground">
          広告は無料プランのみ表示されます
        </p>
      </div>
      <Badge variant="secondary" className="text-[10px]">
        {label}
      </Badge>
    </div>
  )
}

export function SectionTitle({
  children,
  action,
}: {
  children: React.ReactNode
  action?: React.ReactNode
}) {
  return (
    <div className="flex items-end justify-between gap-2">
      <h2 className="font-rounded text-sm font-bold text-foreground">{children}</h2>
      {action}
    </div>
  )
}
