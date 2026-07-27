"use client"

import Image from "next/image"

import { cn } from "@/lib/utils"
import type { FaceBox, MediaItem } from "@/lib/mock-data"
import { FaceFrame, FaceMask, type EffectConfig } from "@/components/face-mask"

export function MediaCanvas({
  media,
  faces,
  hidden,
  effect,
  selectable = false,
  onToggleFace,
  className,
  fit = "cover",
  children,
}: {
  media: MediaItem
  faces: FaceBox[]
  hidden: string[]
  effect?: EffectConfig | null
  selectable?: boolean
  onToggleFace?: (id: string) => void
  className?: string
  fit?: "cover" | "contain"
  children?: React.ReactNode
}) {
  return (
    <div className={cn("relative w-full overflow-hidden rounded-3xl bg-muted", className)}>
      <Image
        src={media.src || "/placeholder.svg"}
        alt={`${media.title}のプレビュー`}
        fill
        sizes="480px"
        className={fit === "cover" ? "object-cover" : "object-contain"}
        priority
      />
      {effect
        ? faces
            .filter((f) => hidden.includes(f.id))
            .map((f) => <FaceMask key={f.id} face={f} effect={effect} />)
        : null}
      {selectable
        ? faces.map((f, i) => (
            <FaceFrame
              key={f.id}
              face={f}
              index={i}
              selected={hidden.includes(f.id)}
              onToggle={() => onToggleFace?.(f.id)}
            />
          ))
        : null}
      {children}
    </div>
  )
}

export function MediaThumb({
  media,
  effect,
  hidden,
  className,
  priority,
}: {
  media: MediaItem
  effect?: EffectConfig | null
  hidden?: string[]
  className?: string
  priority?: boolean
}) {
  return (
    <div className={cn("relative overflow-hidden rounded-2xl bg-muted", className)}>
      <Image
        src={media.src || "/placeholder.svg"}
        alt={media.title}
        fill
        sizes="160px"
        className="object-cover"
        priority={priority}
      />
      {effect
        ? media.faces
            .filter((f) => (hidden ? hidden.includes(f.id) : true))
            .map((f) => <FaceMask key={f.id} face={f} effect={effect} />)
        : null}
    </div>
  )
}
