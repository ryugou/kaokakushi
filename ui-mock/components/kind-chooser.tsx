"use client"

import { ChevronRight, ImageIcon, Video } from "lucide-react"

import { useApp } from "@/components/app-provider"
import { PrivacyNote } from "@/components/app-bits"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"

/** 「加工する」を押したときに、写真か動画かをえらぶシート */
export function KindChooser() {
  const { kindChooserOpen, closeKindChooser, openPicker, videoLimitLabel } = useApp()

  return (
    <Dialog open={kindChooserOpen} onOpenChange={(open) => (!open ? closeKindChooser() : undefined)}>
      <DialogContent className="max-w-[330px] rounded-3xl">
        <DialogHeader>
          <DialogTitle className="font-rounded">なにを加工しますか？</DialogTitle>
          <DialogDescription>写真と動画のどちらでも加工できます</DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-2">
          <ChooserRow
            icon={ImageIcon}
            label="写真を選ぶ"
            hint="1件ずつ加工します"
            onClick={() => openPicker("photo")}
          />
          <ChooserRow
            icon={Video}
            label="動画を選ぶ"
            hint={`顔を追いかけます・最大${videoLimitLabel}`}
            onClick={() => openPicker("video")}
          />
        </div>
        <PrivacyNote />
      </DialogContent>
    </Dialog>
  )
}

function ChooserRow({
  icon: Icon,
  label,
  hint,
  onClick,
}: {
  icon: typeof ImageIcon
  label: string
  hint: string
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-center gap-3 rounded-2xl bg-card p-3 text-left ring-1 ring-foreground/10 transition-transform active:scale-[0.99]"
    >
      <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-secondary text-primary">
        <Icon className="size-5" aria-hidden />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate font-rounded text-sm font-bold">{label}</span>
        <span className="block truncate text-[11px] text-muted-foreground">{hint}</span>
      </span>
      <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden />
    </button>
  )
}
