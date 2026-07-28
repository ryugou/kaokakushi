import type { EffectConfig } from "@/components/face-mask"

/**
 * v1 は写真専用。動画は扱わない。
 * 内部では media という呼び方を残すが、利用者向けの表記はすべて「写真」に統一する。
 */

/** 顔ひとつぶんの検出結果 */
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
  /**
   * 顔の向き（度）。左右の向き。
   * FaceObservation.yaw を度へ変換した値。iOS 単独のため非 Optional。
   */
  yawDegrees?: number
  /** 顔の向き（度）。上下の向き */
  pitchDegrees?: number
  /**
   * 検出の信頼度（0〜1）。FaceObservation.confidence。
   * iOS 単独になったため、トリアージの判定に使う。
   */
  confidence?: number
  /** 検出用の画像上で小さすぎる顔 */
  small?: boolean
  /** 画像の端に接している顔 */
  atEdge?: boolean
  /** ほかの顔と領域が重なっている（相手の faceId） */
  overlapsWith?: string
}

export type MediaItem = {
  id: string
  src: string
  title: string
  takenAt: string
  /** 元写真のおおよそのファイルサイズ（MB）。容量見積りの表示に使う */
  sizeMb: number
  faces: FaceBox[]
}

export const MEDIA_LIBRARY: MediaItem[] = [
  {
    id: "m1",
    src: "/media/park-family.png",
    title: "公園でのおでかけ",
    takenAt: "7月21日",
    sizeMb: 4.2,
    faces: [
      { id: "f1", x: 40.5, y: 28.5, w: 13, h: 11 },
      { id: "f2", x: 55, y: 46, w: 11, h: 9.5 },
    ],
  },
  {
    id: "m2",
    src: "/media/friends-cafe.png",
    title: "カフェで友人と",
    takenAt: "7月19日",
    sizeMb: 3.8,
    faces: [
      { id: "f1", x: 21.5, y: 27, w: 12.5, h: 10.5 },
      { id: "f2", x: 45, y: 28, w: 12.5, h: 10.5, overlapsWith: "f3" },
      { id: "f3", x: 52, y: 29, w: 12, h: 10.5, overlapsWith: "f2" },
    ],
  },
  {
    id: "m3",
    src: "/media/travel-street.png",
    title: "旅行先の街あるき",
    takenAt: "7月15日",
    sizeMb: 5.1,
    faces: [
      { id: "f1", x: 41, y: 28.5, w: 10, h: 9.5 },
      { id: "f2", x: 49, y: 22.5, w: 10, h: 9.5, confidence: 0.42 },
      { id: "f3", x: 17, y: 39, w: 5.5, h: 5, small: true },
      { id: "f4", x: 71, y: 37, w: 5.5, h: 5, small: true },
      { id: "f5", x: 93, y: 35.5, w: 5.5, h: 5, small: true, atEdge: true },
    ],
  },
  {
    id: "m4",
    src: "/media/sports-day.png",
    title: "運動会のかけっこ",
    takenAt: "7月12日",
    sizeMb: 4.6,
    faces: [
      { id: "f1", x: 18.5, y: 36, w: 10, h: 11.5 },
      { id: "f2", x: 44, y: 35, w: 10.5, h: 11.5 },
      { id: "f3", x: 70.5, y: 36, w: 10.5, h: 11.5 },
    ],
  },
  {
    id: "m5",
    src: "/media/vlog-selfie.png",
    title: "自撮り",
    takenAt: "7月10日",
    sizeMb: 3.2,
    faces: [{ id: "f1", x: 38, y: 24, w: 22, h: 20 }],
  },
  {
    id: "m6",
    src: "/media/birthday-party.png",
    title: "誕生日パーティー",
    takenAt: "7月6日",
    sizeMb: 4.9,
    faces: [
      { id: "f1", x: 15, y: 30, w: 12, h: 11 },
      { id: "f2", x: 36, y: 26, w: 12, h: 11 },
      { id: "f3", x: 55, y: 27, w: 12, h: 11 },
      { id: "f4", x: 74, y: 31, w: 12, h: 11 },
    ],
  },
  {
    id: "m7",
    src: "/media/beach-trip.png",
    title: "海に行った日",
    takenAt: "7月4日",
    sizeMb: 5.4,
    faces: [
      { id: "f1", x: 24, y: 30, w: 12, h: 11 },
      { id: "f2", x: 45, y: 25, w: 12, h: 11 },
      { id: "f3", x: 66, y: 31, w: 12, h: 11 },
    ],
  },
  {
    // 顔が写っているのに1件も検出できなかった写真。要確認のなかで最も危険なケース
    id: "m8",
    src: "/media/festival.png",
    title: "夏祭りの夜",
    takenAt: "6月29日",
    sizeMb: 4.1,
    faces: [],
  },
  {
    id: "m9",
    src: "/media/park-family.png",
    title: "公園でおにごっこ",
    takenAt: "6月22日",
    sizeMb: 4.3,
    faces: [
      { id: "f1", x: 40.5, y: 28.5, w: 13, h: 11 },
      { id: "f2", x: 55, y: 46, w: 11, h: 9.5, yawDegrees: 58 },
    ],
  },
  {
    id: "m10",
    src: "/media/sports-day.png",
    title: "運動会のリレー",
    takenAt: "6月18日",
    sizeMb: 4.7,
    faces: [
      { id: "f1", x: 18.5, y: 36, w: 10, h: 11.5 },
      { id: "f2", x: 92, y: 35, w: 8, h: 11.5, atEdge: true },
    ],
  },
  {
    id: "m11",
    src: "/media/beach-trip.png",
    title: "海辺の夕暮れ",
    takenAt: "6月11日",
    sizeMb: 5.2,
    faces: [
      { id: "f1", x: 24, y: 30, w: 12, h: 11 },
      { id: "f2", x: 45, y: 25, w: 12, h: 11 },
    ],
  },
  {
    id: "m12",
    src: "/media/friends-cafe.png",
    title: "ランチ会",
    takenAt: "6月2日",
    sizeMb: 3.6,
    faces: [
      { id: "f1", x: 21.5, y: 27, w: 12.5, h: 10.5 },
      { id: "f2", x: 66.5, y: 27.5, w: 12, h: 10.5 },
    ],
  },
]

export function findMedia(id: string) {
  return MEDIA_LIBRARY.find((m) => m.id === id) ?? MEDIA_LIBRARY[0]
}

/* ------------------------------------------------------------------ */
/* トリアージ                                                          */
/* ------------------------------------------------------------------ */

/** 写真1枚を「要確認」にする理由 */
export type ReviewReason = "no-face" | "low-confidence" | "small-face" | "extreme-pose" | "edge-face" | "overlap"

export const REVIEW_REASON_LABELS: Record<ReviewReason, string> = {
  "no-face": "顔が検出されませんでした",
  "low-confidence": "検出の確からしさが低い顔があります",
  "small-face": "小さい顔があります",
  "extreme-pose": "大きく横や上下を向いた顔があります",
  "edge-face": "画像の端に顔があります",
  overlap: "顔が重なっています",
}

/** yaw / pitch の絶対値がこれを超えたら要確認にする（度） */
const POSE_THRESHOLD = 40
/** これ未満の信頼度は要確認にする */
const CONFIDENCE_THRESHOLD = 0.6

function hasExtremePose(face: FaceBox) {
  return Math.abs(face.yawDegrees ?? 0) > POSE_THRESHOLD || Math.abs(face.pitchDegrees ?? 0) > POSE_THRESHOLD
}

function hasLowConfidence(face: FaceBox) {
  return face.confidence !== undefined && face.confidence < CONFIDENCE_THRESHOLD
}

/**
 * 警告1件。「理由」ではなく「発生」を表す。
 *
 * 理由ごとに1件へ集約すると、小さい顔が3人いる写真で
 * 1人だけ対応して確認済みにできてしまう。
 */
export type ReviewIssue = {
  /** projectID + revision + reason + 対象の顔 から決まる */
  id: string
  reason: ReviewReason
  /** 対象の顔。no-face では空 */
  faceIds: string[]
  /** 一覧に出す短い説明 */
  label: string
}

function issueId(mediaId: string, revision: number, reason: ReviewReason, faceIds: string[]) {
  // 写真をまたいで衝突しないよう mediaId を含める。
  // no-face は faceIds が空なので、これが無いと同じ revision の別写真と同じ ID になる。
  return `${mediaId}#${revision}#${reason}#${faceIds.join(",")}`
}

/**
 * 検出結果から要確認の「発生」を列挙する。
 *
 * iOS 単独になったため、検出の信頼度も判定に使う。
 *
 * 注意：判定できるのは「検出された顔の状態」だけで、
 * 検出できなかった顔の存在は判定できない。
 * そのため0件でも「安全」ではなく「警告なし」でしかない。
 */
export function triage(media: MediaItem, revision = 0): ReviewIssue[] {
  const make = (reason: ReviewReason, faceIds: string[], label: string): ReviewIssue => ({
    id: issueId(media.id, revision, reason, faceIds),
    reason,
    faceIds,
    label,
  })

  if (media.faces.length === 0) {
    return [make("no-face", [], REVIEW_REASON_LABELS["no-face"])]
  }

  const issues: ReviewIssue[] = []

  media.faces.forEach((f, index) => {
    const nth = `${index + 1}人目`
    if (hasLowConfidence(f)) issues.push(make("low-confidence", [f.id], `${nth}：確からしさが低い`))
    if (f.small) issues.push(make("small-face", [f.id], `${nth}：顔が小さい`))
    if (hasExtremePose(f)) issues.push(make("extreme-pose", [f.id], `${nth}：大きく向いている`))
    if (f.atEdge) issues.push(make("edge-face", [f.id], `${nth}：画像の端にある`))
  })

  // 重なりは「顔の組み合わせ」ごとに1件。順序で別 ID にならないよう辞書順に並べる
  const seenPairs = new Set<string>()
  media.faces.forEach((f) => {
    if (!f.overlapsWith) return
    const pair = [f.id, f.overlapsWith].sort()
    const key = pair.join(",")
    if (seenPairs.has(key)) return
    seenPairs.add(key)
    issues.push(make("overlap", pair, `${pair.join(" と ")} が重なっている`))
  })

  return issues
}

/** 顔ひとつが要確認かどうか（検出画面の警告表示に使う） */
export function faceNeedsReview(face: FaceBox) {
  return Boolean(face.small || face.atEdge || face.overlapsWith || hasExtremePose(face) || hasLowConfidence(face))
}

/* ------------------------------------------------------------------ */
/* 履歴                                                                */
/* ------------------------------------------------------------------ */

/** 有料プランでしか新規に使えない機能。降格後の再書き出し判定に使う */
export type PaidFeature = "premium-stamp" | "custom-stamp"

export type SingleHistoryItem = {
  id: string
  type: "single"
  mediaId: string
  processedAt: string
  method: string
  faceCount: number
  effect: EffectConfig
  /** 有料期間中に有料スタンプを使って作った作品か */
  paidFeature?: PaidFeature
  /** 保存も共有もしていない加工済み写真が残っている */
  unsaved?: boolean
}

export type BatchHistoryItem = {
  id: string
  type: "batch"
  title: string
  mediaIds: string[]
  processedAt: string
  method: string
  effect: EffectConfig
  doneCount: number
  errorCount: number
  unsaved?: boolean
}

export type HistoryItem = SingleHistoryItem | BatchHistoryItem

export const HISTORY: HistoryItem[] = [
  {
    id: "h1",
    type: "single",
    mediaId: "m1",
    processedAt: "7月26日 18:24",
    method: "モザイク",
    faceCount: 2,
    effect: { type: "mosaic", strength: 70, stampId: "circle" },
  },
  {
    id: "h2",
    type: "batch",
    title: "旅行写真",
    mediaIds: ["m3", "m4", "m7", "m10", "m11"],
    processedAt: "7月25日 09:12",
    method: "スタンプ（笑顔）",
    effect: { type: "stamp", strength: 60, stampId: "smile" },
    doneCount: 30,
    errorCount: 2,
  },
  {
    id: "h3",
    type: "single",
    mediaId: "m2",
    processedAt: "7月24日 21:40",
    method: "ぼかし",
    faceCount: 3,
    effect: { type: "blur", strength: 80, stampId: "circle" },
  },
  {
    // 有料期間中に追加スタンプで作った作品。Free へ降格しても、そのまま再書き出しできる
    id: "h4",
    type: "single",
    mediaId: "m6",
    processedAt: "7月22日 12:03",
    method: "スタンプ（うさぎ）",
    faceCount: 4,
    effect: { type: "stamp", strength: 60, stampId: "rabbit" },
    paidFeature: "premium-stamp",
  },
  {
    // 有料期間中にカスタムスタンプで作った作品
    id: "h5",
    type: "single",
    mediaId: "m7",
    processedAt: "7月20日 15:55",
    method: "スタンプ（うちの子）",
    faceCount: 3,
    effect: { type: "stamp", strength: 60, stampId: "my1" },
    paidFeature: "custom-stamp",
  },
]

/* ------------------------------------------------------------------ */
/* 容量の見積り（デモ用のざっくり計算）                                 */
/* ------------------------------------------------------------------ */

/** 端末の空き容量（MB）。デモ用に切り替えられる */
export const DEVICE_FREE_MB = { normal: 8600, low: 180 }

export function estimateBatch(mediaIds: string[]) {
  const items = mediaIds.map(findMedia)
  const input = items.reduce((sum, m) => sum + m.sizeMb, 0)
  const output = Math.round(input * 0.85 * 10) / 10
  const temp = Math.round(input * 0.5 * 10) / 10
  const required = Math.round((output + temp) * 1.2 * 10) / 10
  return { count: items.length, input, output, temp, required }
}

export function formatMb(mb: number) {
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)}GB` : `${Math.round(mb)}MB`
}
