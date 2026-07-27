"use client"

import * as React from "react"
import Image from "next/image"

import { cn } from "@/lib/utils"
import type { MyStamp, StampArt } from "@/lib/stamps"

/** マイスタンプを画面のどこからでも参照できるようにする */
const MyStampsContext = React.createContext<MyStamp[]>([])

export function MyStampsProvider({
  value,
  children,
}: {
  value: MyStamp[]
  children: React.ReactNode
}) {
  return <MyStampsContext.Provider value={value}>{children}</MyStampsContext.Provider>
}

export function useMyStamps() {
  return React.useContext(MyStampsContext)
}

/** スタンプ1つぶんの見た目 */
export function StampArtView({
  art,
  className,
  style,
  sizes = "160px",
}: {
  art: StampArt
  className?: string
  style?: React.CSSProperties
  sizes?: string
}) {
  const shape = art.shape === "rounded" ? "rounded-[24%]" : "rounded-full"

  if (art.src) {
    return (
      <span className={cn("relative block overflow-hidden bg-muted", shape, className)} style={style}>
        <Image
          src={art.src || "/placeholder.svg"}
          alt=""
          fill
          sizes={sizes}
          className="object-cover"
          style={{ transform: `scale(${(art.zoom ?? 100) / 100})` }}
        />
      </span>
    )
  }

  if (art.plain || !art.icon) {
    return <span className={cn("block", shape, art.bg, className)} style={style} />
  }

  const Icon = art.icon
  return (
    <span className={cn("grid place-items-center", shape, art.bg, className)} style={style}>
      <Icon className={cn("size-[62%]", art.fg)} strokeWidth={2.2} aria-hidden />
    </span>
  )
}
