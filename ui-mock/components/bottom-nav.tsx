"use client"

import { Clock, Home, Settings, Sparkles, Sticker } from "lucide-react"

import { cn } from "@/lib/utils"
import { useApp, type Screen } from "@/components/app-provider"

const ITEMS: { screen: Screen; label: string; icon: typeof Home }[] = [
  { screen: "home", label: "ホーム", icon: Home },
  { screen: "history", label: "履歴", icon: Clock },
  { screen: "stamps", label: "スタンプ", icon: Sticker },
  { screen: "settings", label: "設定", icon: Settings },
]

export function BottomNav({ onNew }: { onNew: () => void }) {
  const { screen, go } = useApp()

  return (
    <nav aria-label="メインメニュー" className="relative shrink-0 border-t bg-card/95 backdrop-blur">
      <div className="grid grid-cols-5 items-end px-2 pt-2 pb-3">
        {ITEMS.slice(0, 2).map((item) => (
          <NavButton key={item.screen} item={item} active={screen === item.screen} onClick={() => go(item.screen)} />
        ))}

        <div className="flex justify-center">
          <button
            type="button"
            onClick={onNew}
            className="-mt-8 flex size-16 flex-col items-center justify-center gap-0.5 rounded-full bg-primary text-primary-foreground shadow-lg shadow-primary/30 transition-transform active:scale-95"
          >
            <Sparkles className="size-6" aria-hidden />
            <span className="text-[9px] font-bold">加工する</span>
          </button>
        </div>

        {ITEMS.slice(2).map((item) => (
          <NavButton key={item.screen} item={item} active={screen === item.screen} onClick={() => go(item.screen)} />
        ))}
      </div>
    </nav>
  )
}

function NavButton({
  item,
  active,
  onClick,
}: {
  item: { screen: Screen; label: string; icon: typeof Home }
  active: boolean
  onClick: () => void
}) {
  const Icon = item.icon
  return (
    <button
      type="button"
      onClick={onClick}
      aria-current={active ? "page" : undefined}
      className={cn(
        "flex h-14 flex-col items-center justify-center gap-1 rounded-2xl text-[11px] font-medium transition-colors",
        active ? "text-primary" : "text-muted-foreground",
      )}
    >
      <Icon className="size-5" aria-hidden />
      {item.label}
    </button>
  )
}
