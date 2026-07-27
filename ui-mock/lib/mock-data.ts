import type { EffectConfig } from "@/components/face-mask"

export type MediaKind = "photo" | "video"

export type FaceBox = {
  id: string
  /** 左上のX座標（%） */
  x: number
  /** 左上のY座標（%） */
  y: number
  /** 幅（%） */
  w: number
  /** 高さ（%） */
  h: number
  /** 手動で追加した範囲かどうか */
  manual?: boolean
}

export type MediaItem = {
  id: string
  kind: MediaKind
  src: string
  title: string
  takenAt: string
  /** 動画の長さ（秒） */
  duration?: number
  faces: FaceBox[]
}

export const MEDIA_LIBRARY: MediaItem[] = [
  {
    id: "m1",
    kind: "photo",
    src: "/media/park-family.png",
    title: "公園でのおでかけ",
    takenAt: "7月21日",
    faces: [
      { id: "f1", x: 40.5, y: 28.5, w: 13, h: 11 },
      { id: "f2", x: 55, y: 46, w: 11, h: 9.5 },
    ],
  },
  {
    id: "m2",
    kind: "photo",
    src: "/media/friends-cafe.png",
    title: "カフェで友人と",
    takenAt: "7月19日",
    faces: [
      { id: "f1", x: 21.5, y: 27, w: 12.5, h: 10.5 },
      { id: "f2", x: 45, y: 28, w: 12.5, h: 10.5 },
      { id: "f3", x: 66.5, y: 27.5, w: 12, h: 10.5 },
    ],
  },
  {
    id: "m3",
    kind: "video",
    src: "/media/travel-street.png",
    title: "旅行先の街あるき",
    takenAt: "7月15日",
    duration: 24,
    faces: [
      { id: "f1", x: 41, y: 28.5, w: 10, h: 9.5 },
      { id: "f2", x: 49, y: 22.5, w: 10, h: 9.5 },
      { id: "f3", x: 17, y: 39, w: 5.5, h: 5 },
      { id: "f4", x: 71, y: 37, w: 5.5, h: 5 },
      { id: "f5", x: 82.5, y: 35.5, w: 5.5, h: 5 },
    ],
  },
  {
    id: "m4",
    kind: "video",
    src: "/media/sports-day.png",
    title: "運動会のかけっこ",
    takenAt: "7月12日",
    duration: 46,
    faces: [
      { id: "f1", x: 18.5, y: 36, w: 10, h: 11.5 },
      { id: "f2", x: 44, y: 35, w: 10.5, h: 11.5 },
      { id: "f3", x: 70.5, y: 36, w: 10.5, h: 11.5 },
    ],
  },
  {
    id: "m5",
    kind: "video",
    src: "/media/vlog-selfie.png",
    title: "Vlog用の自撮り",
    takenAt: "7月10日",
    duration: 312,
    faces: [{ id: "f1", x: 38, y: 24, w: 22, h: 20 }],
  },
  {
    id: "m6",
    kind: "photo",
    src: "/media/birthday-party.png",
    title: "誕生日パーティー",
    takenAt: "7月6日",
    faces: [
      { id: "f1", x: 15, y: 30, w: 12, h: 11 },
      { id: "f2", x: 36, y: 26, w: 12, h: 11 },
      { id: "f3", x: 55, y: 27, w: 12, h: 11 },
      { id: "f4", x: 74, y: 31, w: 12, h: 11 },
    ],
  },
  {
    id: "m7",
    kind: "photo",
    src: "/media/beach-trip.png",
    title: "海に行った日",
    takenAt: "7月4日",
    faces: [
      { id: "f1", x: 24, y: 30, w: 12, h: 11 },
      { id: "f2", x: 45, y: 25, w: 12, h: 11 },
      { id: "f3", x: 66, y: 31, w: 12, h: 11 },
    ],
  },
  {
    id: "m8",
    kind: "photo",
    src: "/media/festival.png",
    title: "夏祭りの夜",
    takenAt: "6月29日",
    faces: [
      { id: "f1", x: 33, y: 27, w: 13, h: 11 },
      { id: "f2", x: 55, y: 26, w: 13, h: 11 },
    ],
  },
]

export function findMedia(id: string) {
  return MEDIA_LIBRARY.find((m) => m.id === id) ?? MEDIA_LIBRARY[0]
}

export type HistoryItem = {
  id: string
  mediaId: string
  kind: MediaKind
  processedAt: string
  method: string
  faceCount: number
  /** サムネイルに反映する加工内容 */
  effect: EffectConfig
}

export const HISTORY: HistoryItem[] = [
  {
    id: "h1",
    mediaId: "m1",
    kind: "photo",
    processedAt: "7月26日 18:24",
    method: "モザイク",
    faceCount: 2,
    effect: { type: "mosaic", strength: 70, stampId: "circle" },
  },
  {
    id: "h2",
    mediaId: "m4",
    kind: "video",
    processedAt: "7月25日 09:12",
    method: "スタンプ（笑顔）",
    faceCount: 3,
    effect: { type: "stamp", strength: 60, stampId: "smile" },
  },
  {
    id: "h3",
    mediaId: "m2",
    kind: "photo",
    processedAt: "7月24日 21:40",
    method: "ぼかし",
    faceCount: 3,
    effect: { type: "blur", strength: 80, stampId: "circle" },
  },
  {
    id: "h4",
    mediaId: "m8",
    kind: "photo",
    processedAt: "7月22日 12:03",
    method: "黒塗り",
    faceCount: 2,
    effect: { type: "black", strength: 60, stampId: "circle" },
  },
  {
    id: "h5",
    mediaId: "m3",
    kind: "video",
    processedAt: "7月20日 15:55",
    method: "スタンプ（ハート）",
    faceCount: 5,
    effect: { type: "stamp", strength: 60, stampId: "heart" },
  },
]

export function formatDuration(sec: number) {
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${m}:${String(s).padStart(2, "0")}`
}
