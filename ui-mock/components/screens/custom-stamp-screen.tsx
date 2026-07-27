"use client"

import * as React from "react"
import Image from "next/image"
import { Cake, Check, Crown, Heart, ImageIcon, PawPrint, Shapes, Smile, Sparkles, Star, Sun, type LucideIcon } from "lucide-react"

import { cn } from "@/lib/utils"
import { MEDIA_LIBRARY } from "@/lib/mock-data"
import { myStampToArt, STAMP_SOURCES, type MyStamp } from "@/lib/stamps"
import { CUSTOM_STAMP_LIMIT, useApp } from "@/components/app-provider"
import { PrivacyNote, ScreenHeader } from "@/components/app-bits"
import { StampArtView } from "@/components/stamp-art"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Slider } from "@/components/ui/slider"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"

type Mode = "image" | "icon"
type Shape = "circle" | "rounded"

const ICONS: { id: string; icon: LucideIcon; label: string }[] = [
  { id: "paw", icon: PawPrint, label: "足あと" },
  { id: "heart", icon: Heart, label: "ハート" },
  { id: "star", icon: Star, label: "星" },
  { id: "smile", icon: Smile, label: "笑顔" },
  { id: "sparkles", icon: Sparkles, label: "キラキラ" },
  { id: "crown", icon: Crown, label: "かんむり" },
  { id: "cake", icon: Cake, label: "ケーキ" },
  { id: "sun", icon: Sun, label: "たいよう" },
]

const COLORS: { id: string; label: string; bg: string; fg: string }[] = [
  { id: "primary", label: "ブルー", bg: "bg-primary", fg: "text-primary-foreground" },
  { id: "teal", label: "ミント", bg: "bg-chart-2", fg: "text-background" },
  { id: "amber", label: "イエロー", bg: "bg-chart-3", fg: "text-background" },
  { id: "coral", label: "コーラル", bg: "bg-chart-4", fg: "text-background" },
  { id: "navy", label: "ネイビー", bg: "bg-chart-5", fg: "text-background" },
  { id: "ink", label: "ブラック", bg: "bg-foreground/85", fg: "text-background" },
]

/** 端末のなかにある画像（ファイルアプリのPNG＋写真ライブラリ） */
const IMAGE_SOURCES = [
  ...STAMP_SOURCES,
  ...MEDIA_LIBRARY.map((m) => ({ id: m.id, src: m.src, label: m.title })),
]

export function CustomStampScreen() {
  const { back, addMyStamp, myStamps } = useApp()
  const [mode, setMode] = React.useState<Mode>("image")
  const [name, setName] = React.useState("")
  const [shape, setShape] = React.useState<Shape>("circle")

  // 画像から作る
  const [srcId, setSrcId] = React.useState<string | null>(null)
  const [zoom, setZoom] = React.useState(110)

  // アイコンから作る
  const [iconId, setIconId] = React.useState("paw")
  const [colorId, setColorId] = React.useState("primary")

  const source = IMAGE_SOURCES.find((s) => s.id === srcId) ?? null
  const icon = ICONS.find((i) => i.id === iconId) ?? ICONS[0]
  const color = COLORS.find((c) => c.id === colorId) ?? COLORS[0]

  const fallbackName = mode === "image" ? (source ? source.label : "画像スタンプ") : `${icon.label}スタンプ`

  const draft: MyStamp =
    mode === "image"
      ? { id: "draft", name: name.trim() || fallbackName, shape, src: source?.src, zoom }
      : {
          id: "draft",
          name: name.trim() || fallbackName,
          shape,
          icon: icon.icon,
          bg: color.bg,
          fg: color.fg,
        }

  const canSave = mode === "icon" || source !== null

  const handleSave = () => {
    if (!canSave) return
    addMyStamp({ ...draft, id: `my-${Date.now()}`, name: name.trim() || fallbackName })
    back()
  }

  return (
    <div className="flex min-h-full flex-col">
      <ScreenHeader title="マイスタンプを作る" onBack={back} />

      <div className="flex flex-1 flex-col gap-5 px-4 pb-8 pt-4">
        <div className="grid grid-cols-2 gap-2 rounded-2xl bg-secondary/60 p-1.5">
          <ModeButton
            active={mode === "image"}
            icon={<ImageIcon className="size-4" aria-hidden />}
            label="画像から作る"
            onClick={() => setMode("image")}
          />
          <ModeButton
            active={mode === "icon"}
            icon={<Shapes className="size-4" aria-hidden />}
            label="アイコンから作る"
            onClick={() => setMode("icon")}
          />
        </div>

        <div className="flex flex-col items-center gap-2 rounded-3xl bg-card p-6 ring-1 ring-foreground/10">
          {mode === "image" && !source ? (
            <div className="grid size-28 place-items-center rounded-full bg-secondary text-muted-foreground">
              <ImageIcon className="size-9" aria-hidden />
            </div>
          ) : (
            <StampArtView art={myStampToArt(draft)} className="size-28 shadow-sm" sizes="112px" />
          )}
          <p className="text-xs text-muted-foreground">
            {mode === "image" && !source ? "画像をえらんでください" : name.trim() || "プレビュー"}
          </p>
        </div>

        {mode === "image" ? (
          <FieldGroup>
            <Field>
              <FieldLabel>端末の画像からえらぶ</FieldLabel>
              <div className="grid grid-cols-4 gap-2">
                {IMAGE_SOURCES.map((s) => {
                  const selected = srcId === s.id
                  return (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => setSrcId(s.id)}
                      aria-pressed={selected}
                      className={cn(
                        "relative aspect-square overflow-hidden rounded-2xl bg-muted transition-transform",
                        selected ? "ring-2 ring-primary ring-offset-2" : "active:scale-95",
                      )}
                    >
                      <Image src={s.src || "/placeholder.svg"} alt={s.label} fill sizes="80px" className="object-cover" />
                      {selected ? (
                        <span className="absolute bottom-1 right-1 grid size-5 place-items-center rounded-full bg-primary text-primary-foreground">
                          <Check className="size-3" strokeWidth={3} aria-hidden />
                        </span>
                      ) : null}
                    </button>
                  )
                })}
              </div>
              <FieldDescription>
                写真ライブラリの画像とファイルアプリのPNGから選べます。透過PNGは透明なまま、それ以外は円か角丸で切り抜きます
              </FieldDescription>
            </Field>

            <Field>
              <FieldLabel>切り抜くかたち</FieldLabel>
              <ShapePicker value={shape} onChange={setShape} />
            </Field>

            <Field>
              <FieldLabel htmlFor="stamp-zoom">画像の大きさ</FieldLabel>
              <div className="flex items-center gap-3">
                <Slider
                  id="stamp-zoom"
                  value={[zoom]}
                  min={100}
                  max={200}
                  step={5}
                  onValueChange={(v) => setZoom(Array.isArray(v) ? v[0] : v)}
                  className="flex-1"
                />
                <span className="w-12 text-right text-xs text-muted-foreground">{zoom}%</span>
              </div>
              <FieldDescription>大きくすると、はみ出た部分が切り抜かれます</FieldDescription>
            </Field>
          </FieldGroup>
        ) : (
          <FieldGroup>
            <Field>
              <FieldLabel>かたち</FieldLabel>
              <ShapePicker value={shape} onChange={setShape} />
            </Field>

            <Field>
              <FieldLabel>絵柄</FieldLabel>
              <div className="grid grid-cols-4 gap-2">
                {ICONS.map((i) => {
                  const ItemIcon = i.icon
                  return (
                    <button
                      key={i.id}
                      type="button"
                      onClick={() => setIconId(i.id)}
                      aria-pressed={iconId === i.id}
                      className={cn(
                        "grid aspect-square place-items-center rounded-2xl transition-colors",
                        iconId === i.id
                          ? "bg-primary text-primary-foreground"
                          : "bg-card text-foreground ring-1 ring-foreground/10",
                      )}
                    >
                      <ItemIcon className="size-6" aria-hidden />
                      <span className="sr-only">{i.label}</span>
                    </button>
                  )
                })}
              </div>
            </Field>

            <Field>
              <FieldLabel>色</FieldLabel>
              <div className="grid grid-cols-6 gap-2">
                {COLORS.map((c) => (
                  <button
                    key={c.id}
                    type="button"
                    onClick={() => setColorId(c.id)}
                    aria-pressed={colorId === c.id}
                    className={cn(
                      "aspect-square rounded-full transition-transform",
                      c.bg,
                      colorId === c.id ? "ring-2 ring-foreground ring-offset-2" : "active:scale-95",
                    )}
                  >
                    <span className="sr-only">{c.label}</span>
                  </button>
                ))}
              </div>
            </Field>
          </FieldGroup>
        )}

        <Field>
          <FieldLabel htmlFor="stamp-name">スタンプの名前</FieldLabel>
          <Input
            id="stamp-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={fallbackName}
            className="h-12 rounded-2xl"
          />
          <FieldDescription>あとから探しやすい名前をつけましょう</FieldDescription>
        </Field>

        <div className="flex flex-col gap-1 rounded-2xl bg-secondary px-4 py-3 text-[11px] leading-relaxed text-secondary-foreground">
          <p className="font-bold">登録するときの処理</p>
          <p>・スタンプ用のサイズ（長辺1,024px程度）へ縮小します</p>
          <p>・透過はそのまま保ちます</p>
          <p>・元の画像は変更されません</p>
          <p>・登録できるのは{CUSTOM_STAMP_LIMIT}個までです（現在 {myStamps.length}個）</p>
        </div>

        <PrivacyNote />
      </div>

      <div className="sticky bottom-0 border-t bg-card/95 p-4 backdrop-blur">
        <Button
          size="lg"
          className="h-14 w-full rounded-2xl text-base font-bold"
          disabled={!canSave}
          onClick={handleSave}
        >
          {canSave ? "このスタンプを保存" : "画像をえらんでください"}
        </Button>
      </div>
    </div>
  )
}

function ModeButton({
  active,
  icon,
  label,
  onClick,
}: {
  active: boolean
  icon: React.ReactNode
  label: string
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "flex h-11 items-center justify-center gap-1.5 rounded-xl text-xs font-bold transition-colors",
        active ? "bg-card text-foreground shadow-sm ring-1 ring-foreground/10" : "text-muted-foreground",
      )}
    >
      {icon}
      {label}
    </button>
  )
}

function ShapePicker({ value, onChange }: { value: Shape; onChange: (value: Shape) => void }) {
  return (
    <ToggleGroup
      value={[value]}
      onValueChange={(v) => {
        const next = v[0]
        if (next === "circle" || next === "rounded") onChange(next)
      }}
      className="w-full"
    >
      <ToggleGroupItem value="circle" className="h-12 flex-1 rounded-2xl text-xs font-bold">
        まる
      </ToggleGroupItem>
      <ToggleGroupItem value="rounded" className="h-12 flex-1 rounded-2xl text-xs font-bold">
        かどまる
      </ToggleGroupItem>
    </ToggleGroup>
  )
}
