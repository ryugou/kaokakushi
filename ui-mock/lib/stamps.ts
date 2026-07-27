import {
  Bird,
  Cake,
  Cat,
  Circle,
  Crown,
  Dog,
  Flower,
  Ghost,
  Glasses,
  Heart,
  MessageCircle,
  PawPrint,
  Rabbit,
  Smile,
  Snowflake,
  Sparkles,
  Star,
  Sun,
  type LucideIcon,
} from "lucide-react"

export type StampCategory = "basic" | "cute" | "simple" | "animal" | "season" | "fun" | "mine"

export const STAMP_CATEGORIES: { id: StampCategory; label: string }[] = [
  { id: "basic", label: "ベーシック" },
  { id: "cute", label: "かわいい" },
  { id: "simple", label: "シンプル" },
  { id: "animal", label: "動物" },
  { id: "season", label: "季節" },
  { id: "fun", label: "おもしろ" },
  { id: "mine", label: "マイスタンプ" },
]

export type Stamp = {
  id: string
  name: string
  icon: LucideIcon
  category: StampCategory
  premium?: boolean
  /** スタンプの下地の色 */
  bg: string
  fg: string
}

export const STAMPS: Stamp[] = [
  { id: "circle", name: "丸", icon: Circle, category: "basic", bg: "bg-foreground/85", fg: "text-background" },
  { id: "smile", name: "笑顔", icon: Smile, category: "basic", bg: "bg-chart-2", fg: "text-background" },
  { id: "glasses", name: "サングラス", icon: Glasses, category: "basic", bg: "bg-foreground/85", fg: "text-background" },
  { id: "heart", name: "ハート", icon: Heart, category: "basic", bg: "bg-chart-4", fg: "text-background" },
  { id: "star", name: "星", icon: Star, category: "basic", bg: "bg-chart-3", fg: "text-background" },
  { id: "cat", name: "ねこ", icon: Cat, category: "basic", bg: "bg-chart-5", fg: "text-background" },
  { id: "bubble", name: "吹き出し", icon: MessageCircle, category: "basic", bg: "bg-primary", fg: "text-primary-foreground" },
  { id: "sparkle", name: "キラキラ", icon: Sparkles, category: "basic", bg: "bg-chart-3", fg: "text-background" },

  { id: "flower", name: "お花", icon: Flower, category: "cute", premium: true, bg: "bg-chart-4", fg: "text-background" },
  { id: "cake", name: "ケーキ", icon: Cake, category: "cute", premium: true, bg: "bg-chart-4", fg: "text-background" },
  { id: "crown", name: "かんむり", icon: Crown, category: "cute", premium: true, bg: "bg-chart-3", fg: "text-background" },
  { id: "rabbit", name: "うさぎ", icon: Rabbit, category: "cute", premium: true, bg: "bg-chart-2", fg: "text-background" },

  { id: "dot", name: "ドット", icon: Circle, category: "simple", bg: "bg-muted-foreground", fg: "text-background" },
  { id: "paw", name: "足あと", icon: PawPrint, category: "simple", premium: true, bg: "bg-foreground/85", fg: "text-background" },

  { id: "dog", name: "いぬ", icon: Dog, category: "animal", premium: true, bg: "bg-chart-5", fg: "text-background" },
  { id: "bird", name: "とり", icon: Bird, category: "animal", premium: true, bg: "bg-primary", fg: "text-primary-foreground" },

  { id: "sun", name: "たいよう", icon: Sun, category: "season", premium: true, bg: "bg-chart-3", fg: "text-background" },
  { id: "snow", name: "ゆき", icon: Snowflake, category: "season", premium: true, bg: "bg-primary", fg: "text-primary-foreground" },

  { id: "ghost", name: "おばけ", icon: Ghost, category: "fun", premium: true, bg: "bg-chart-5", fg: "text-background" },
]

export function findStamp(id: string) {
  return STAMPS.find((s) => s.id === id) ?? STAMPS[0]
}

/**
 * 自分で登録したスタンプ。
 * 画像から作った場合は src、アイコンから作った場合は icon が入る。
 */
export type MyStamp = {
  id: string
  name: string
  shape: "circle" | "rounded"
  /** 画像から作ったスタンプの画像パス */
  src?: string
  /** 画像の大きさ（%） */
  zoom?: number
  /** アイコンから作ったスタンプの絵柄 */
  icon?: LucideIcon
  bg?: string
  fg?: string
}

/** 端末のなかにある画像（デモ用の素材） */
export type StampSource = { id: string; src: string; label: string }

export const STAMP_SOURCES: StampSource[] = [
  { id: "src-dog", src: "/stamp-sources/pet-dog.png", label: "いぬの写真" },
  { id: "src-cat", src: "/stamp-sources/pet-cat.png", label: "ねこの写真" },
  { id: "src-mark", src: "/stamp-sources/logo-mark.png", label: "マーク" },
  { id: "src-flower", src: "/stamp-sources/doodle-flower.png", label: "手書きのお花" },
]

export const MY_STAMPS: MyStamp[] = [
  { id: "my1", name: "うちの子", shape: "circle", src: "/stamp-sources/pet-dog.png", zoom: 115 },
  { id: "my2", name: "ロゴ風", shape: "rounded", icon: Sparkles, bg: "bg-primary", fg: "text-primary-foreground" },
]

/** スタンプを描画するために正規化したデータ */
export type StampArt = {
  id: string
  name: string
  shape: "circle" | "rounded"
  src?: string
  zoom?: number
  icon?: LucideIcon
  bg: string
  fg: string
  /** 下地の色だけで塗りつぶすスタンプ */
  plain?: boolean
}

function stampToArt(stamp: Stamp): StampArt {
  return {
    id: stamp.id,
    name: stamp.name,
    shape: "circle",
    icon: stamp.icon,
    bg: stamp.bg,
    fg: stamp.fg,
    plain: stamp.id === "circle" || stamp.id === "dot",
  }
}

export function myStampToArt(stamp: MyStamp): StampArt {
  return {
    id: stamp.id,
    name: stamp.name,
    shape: stamp.shape,
    src: stamp.src,
    zoom: stamp.zoom,
    icon: stamp.icon,
    bg: stamp.bg ?? "bg-secondary",
    fg: stamp.fg ?? "text-secondary-foreground",
  }
}

/** 用意されたスタンプとマイスタンプの両方から探す */
export function resolveStampArt(id: string, myStamps: MyStamp[] = []): StampArt {
  const mine = myStamps.find((s) => s.id === id)
  if (mine) return myStampToArt(mine)
  return stampToArt(findStamp(id))
}
