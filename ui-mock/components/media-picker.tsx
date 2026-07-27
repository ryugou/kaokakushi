"use client"

import Image from "next/image"
import { Check } from "lucide-react"

import { cn } from "@/lib/utils"
import { MEDIA_LIBRARY } from "@/lib/mock-data"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { PrivacyNote } from "@/components/app-bits"
import { BATCH_MAX_ITEMS, useApp } from "@/components/app-provider"
import { Button } from "@/components/ui/button"

/** v1 は写真だけを扱う。OS標準の写真ピッカーに相当する画面 */
export function MediaPicker() {
  const {
    pickerOpen,
    pickerMulti,
    closePicker,
    selectMedia,
    batchSelection,
    toggleBatchSelection,
    batchMaxSelectable,
    canBatchFull,
  } = useApp()

  return (
    <Dialog open={pickerOpen} onOpenChange={(open) => (!open ? closePicker() : undefined)}>
      <DialogContent className="max-w-[340px] rounded-3xl">
        <DialogHeader>
          <DialogTitle className="font-rounded">写真を選ぶ</DialogTitle>
          <DialogDescription>
            {pickerMulti
              ? canBatchFull
                ? `端末のライブラリから選びます・最大${BATCH_MAX_ITEMS}枚`
                : `お試しでは最大${batchMaxSelectable}枚まで選べます`
              : "端末のライブラリから選びます"}
          </DialogDescription>
        </DialogHeader>

        <div className="grid max-h-[46vh] grid-cols-3 gap-2 overflow-y-auto">
          {MEDIA_LIBRARY.map((item) => {
            const selected = batchSelection.includes(item.id)
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => (pickerMulti ? toggleBatchSelection(item.id) : selectMedia(item.id))}
                aria-pressed={pickerMulti ? selected : undefined}
                className={cn(
                  "relative aspect-square overflow-hidden rounded-2xl bg-muted transition-transform active:scale-95",
                  pickerMulti && selected ? "ring-2 ring-primary" : "ring-1 ring-foreground/10",
                )}
              >
                <Image
                  src={item.src || "/placeholder.svg"}
                  alt={item.title}
                  fill
                  sizes="120px"
                  className="object-cover"
                />
                {pickerMulti ? (
                  <span
                    className={cn(
                      "absolute right-1 top-1 grid size-5 place-items-center rounded-full text-[10px] font-bold",
                      selected ? "bg-primary text-primary-foreground" : "bg-card/90 text-muted-foreground",
                    )}
                    aria-hidden
                  >
                    {selected ? <Check className="size-3" strokeWidth={3} /> : ""}
                  </span>
                ) : null}
              </button>
            )
          })}
        </div>

        {pickerMulti ? (
          <Button
            size="lg"
            className="h-12 rounded-2xl text-sm font-bold"
            disabled={batchSelection.length === 0}
            onClick={closePicker}
          >
            {batchSelection.length}枚を選んだ
          </Button>
        ) : null}

        <PrivacyNote />
      </DialogContent>
    </Dialog>
  )
}
