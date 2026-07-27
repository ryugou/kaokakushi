import { BatteryFull, Signal, Wifi } from "lucide-react"

export function PhoneShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-svh justify-center bg-secondary sm:items-center sm:p-6">
      <div className="relative flex h-svh w-full max-w-[393px] flex-col overflow-hidden bg-background sm:h-[844px] sm:rounded-[2.75rem] sm:shadow-2xl sm:ring-[10px] sm:ring-foreground">
        <div className="flex shrink-0 items-center justify-between px-6 pt-3 pb-1 text-[11px] font-semibold text-foreground">
          <span>9:41</span>
          <span className="flex items-center gap-1" aria-hidden>
            <Signal className="size-3.5" />
            <Wifi className="size-3.5" />
            <BatteryFull className="size-3.5" />
          </span>
        </div>
        {children}
      </div>
    </div>
  )
}
