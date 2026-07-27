"use client"

import * as React from "react"

import {
  findMedia,
  formatDuration,
  HISTORY,
  type FaceBox,
  type HistoryItem,
  type MediaItem,
  type MediaKind,
} from "@/lib/mock-data"
import { DEFAULT_EFFECT, EFFECT_LABELS, type EffectConfig } from "@/components/face-mask"
import { MY_STAMPS, resolveStampArt, type MyStamp } from "@/lib/stamps"
import { MyStampsProvider } from "@/components/stamp-art"

export type Screen =
  | "home"
  | "history"
  | "stamps"
  | "settings"
  | "detect"
  | "effect"
  | "export"
  | "processing"
  | "done"
  | "pricing"
  | "batch"
  | "custom-stamp"

export type Plan = "free" | "standard" | "pro"

export type UpgradeReason =
  | "export-limit"
  | "premium-stamp"
  | "custom-stamp"
  | "batch"
  | "long-video"
  | "export-4k"

export type UpgradeState = { reason: UpgradeReason; detail?: string } | null

export type ExportTarget = "ig-post" | "ig-story" | "tiktok" | "original"
export type ExportRatio = "1:1" | "4:5" | "9:16" | "original"
export type ExportQuality = "standard" | "1080p" | "4k"

export type ExportSettings = {
  target: ExportTarget
  ratio: ExportRatio
  quality: ExportQuality
  keepAudio: boolean
  verticalBlur: boolean
  stripMetadata: boolean
}

/** 無料プランの月あたりの書き出し上限（件） */
export const FREE_MONTHLY_LIMIT = 5
/** 1回の一括処理で扱える最大素材数 */
export const BATCH_MAX_ITEMS = 50

export const VIDEO_LIMIT_SEC: Record<Plan, number> = {
  free: 60,
  standard: 300,
  pro: 1800,
}

export const VIDEO_LIMIT_LABEL: Record<Plan, string> = {
  free: "60秒",
  standard: "5分",
  pro: "30分",
}

export const PLAN_LABELS: Record<Plan, string> = {
  free: "Free",
  standard: "Standard",
  pro: "Pro",
}

export const PLAN_LABELS_JA: Record<Plan, string> = {
  free: "無料",
  standard: "スタンダード",
  pro: "Pro",
}

export const PLAN_PRICE_LABELS: Record<Plan, string> = {
  free: "無料",
  standard: "月300円",
  pro: "月980円",
}

const DEFAULT_EXPORT: ExportSettings = {
  target: "ig-post",
  ratio: "1:1",
  quality: "standard",
  keepAudio: true,
  verticalBlur: false,
  stripMetadata: true,
}

type AppContextValue = {
  screen: Screen
  go: (screen: Screen) => void
  back: () => void
  plan: Plan
  setPlan: (plan: Plan) => void
  remainingFree: number
  setRemainingFree: (n: number) => void
  /** 端末が4K書き出しに対応しているか（モック切り替え用） */
  deviceSupports4K: boolean
  setDeviceSupports4K: (value: boolean) => void
  canUsePremiumStamps: boolean
  canUseCustomStamps: boolean
  canBatch: boolean
  canUseQueue: boolean
  canExport4K: boolean
  hasAds: boolean
  videoLimitSec: number
  videoLimitLabel: string
  media: MediaItem | null
  faces: FaceBox[]
  hidden: string[]
  effect: EffectConfig
  setEffect: React.Dispatch<React.SetStateAction<EffectConfig>>
  exportSettings: ExportSettings
  updateExport: (patch: Partial<ExportSettings>) => void
  startEditing: (mediaId: string) => void
  toggleFace: (id: string) => void
  hideAll: () => void
  showAll: () => void
  addManualFace: () => void
  upgrade: UpgradeState
  requestUpgrade: (reason: UpgradeReason, detail?: string) => void
  closeUpgrade: () => void
  canExport: boolean
  completeExport: () => void
  history: HistoryItem[]
  removeHistory: (id: string) => void
  myStamps: MyStamp[]
  addMyStamp: (stamp: MyStamp) => void
  removeMyStamp: (id: string) => void
  effectLabel: string
  /** 素材の種類をえらぶシート */
  kindChooserOpen: boolean
  openKindChooser: () => void
  closeKindChooser: () => void
  /** ライブラリ選択シート */
  pickerKind: MediaKind | null
  openPicker: (kind: MediaKind) => void
  closePicker: () => void
  selectMedia: (id: string) => void
}

const AppContext = React.createContext<AppContextValue | null>(null)

export function useApp() {
  const ctx = React.useContext(AppContext)
  if (!ctx) throw new Error("useApp は AppProvider の中で使ってください")
  return ctx
}

export function AppProvider({ children }: { children: React.ReactNode }) {
  const [stack, setStack] = React.useState<Screen[]>(["home"])
  const [plan, setPlan] = React.useState<Plan>("free")
  const [remainingFree, setRemainingFree] = React.useState(3)
  const [deviceSupports4K, setDeviceSupports4K] = React.useState(true)
  const [mediaId, setMediaId] = React.useState<string | null>(null)
  const [manualFaces, setManualFaces] = React.useState<FaceBox[]>([])
  const [hidden, setHidden] = React.useState<string[]>([])
  const [effect, setEffect] = React.useState<EffectConfig>(DEFAULT_EFFECT)
  const [exportSettings, setExportSettings] = React.useState<ExportSettings>(DEFAULT_EXPORT)
  const [upgrade, setUpgrade] = React.useState<UpgradeState>(null)
  const [history, setHistory] = React.useState<HistoryItem[]>(HISTORY)
  const [myStamps, setMyStamps] = React.useState<MyStamp[]>(MY_STAMPS)
  const [kindChooserOpen, setKindChooserOpen] = React.useState(false)
  const [pickerKind, setPickerKind] = React.useState<MediaKind | null>(null)

  const media = mediaId ? findMedia(mediaId) : null
  const faces = React.useMemo(
    () => (media ? [...media.faces, ...manualFaces] : []),
    [media, manualFaces],
  )

  const screen = stack[stack.length - 1]

  // 権限判定
  const canUsePremiumStamps = plan === "standard" || plan === "pro"
  const canUseCustomStamps = plan === "standard" || plan === "pro"
  const canBatch = plan === "pro"
  const canUseQueue = plan === "pro"
  const canExport4K = plan === "pro"
  const hasAds = plan === "free"
  const videoLimitSec = VIDEO_LIMIT_SEC[plan]
  const videoLimitLabel = VIDEO_LIMIT_LABEL[plan]

  const go = React.useCallback((next: Screen) => {
    setStack((prev) => (prev[prev.length - 1] === next ? prev : [...prev, next]))
  }, [])

  const back = React.useCallback(() => {
    setStack((prev) => (prev.length > 1 ? prev.slice(0, -1) : prev))
  }, [])

  const startEditing = React.useCallback((id: string) => {
    const item = findMedia(id)
    setMediaId(id)
    setManualFaces([])
    setHidden(item.faces.map((f) => f.id))
    setEffect(DEFAULT_EFFECT)
    setExportSettings({
      ...DEFAULT_EXPORT,
      target: item.kind === "video" ? "tiktok" : "ig-post",
      ratio: item.kind === "video" ? "9:16" : "1:1",
    })
    setStack((prev) => [...prev, "detect"])
  }, [])

  const toggleFace = React.useCallback((id: string) => {
    setHidden((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))
  }, [])

  const hideAll = React.useCallback(() => {
    setHidden(faces.map((f) => f.id))
  }, [faces])

  const showAll = React.useCallback(() => setHidden([]), [])

  const addManualFace = React.useCallback(() => {
    const index = manualFaces.length
    const id = `manual-${index + 1}`
    const offset = index * 7
    const next: FaceBox = { id, x: 22 + offset, y: 62 - offset, w: 16, h: 14, manual: true }
    setManualFaces((prev) => [...prev, next])
    setHidden((prev) => [...prev, id])
  }, [manualFaces.length])

  const updateExport = React.useCallback((patch: Partial<ExportSettings>) => {
    setExportSettings((prev) => ({ ...prev, ...patch }))
  }, [])

  const requestUpgrade = React.useCallback((reason: UpgradeReason, detail?: string) => {
    setUpgrade({ reason, detail })
  }, [])

  const closeUpgrade = React.useCallback(() => setUpgrade(null), [])

  const openKindChooser = React.useCallback(() => setKindChooserOpen(true), [])
  const closeKindChooser = React.useCallback(() => setKindChooserOpen(false), [])

  const openPicker = React.useCallback((kind: MediaKind) => {
    setKindChooserOpen(false)
    setPickerKind(kind)
  }, [])

  const closePicker = React.useCallback(() => setPickerKind(null), [])

  const selectMedia = React.useCallback(
    (id: string) => {
      const item = findMedia(id)
      setPickerKind(null)
      if (item.kind === "video" && (item.duration ?? 0) > videoLimitSec) {
        requestUpgrade("long-video", `この動画は${formatDuration(item.duration ?? 0)}あります。`)
        return
      }
      startEditing(id)
    },
    [requestUpgrade, startEditing, videoLimitSec],
  )

  const canExport = plan !== "free" || remainingFree > 0

  const effectLabel =
    effect.type === "stamp"
      ? `スタンプ（${resolveStampArt(effect.stampId, myStamps).name}）`
      : EFFECT_LABELS[effect.type]

  const completeExport = React.useCallback(() => {
    if (!media) return
    if (plan === "free") setRemainingFree((n) => Math.max(0, n - 1))
    const label =
      effect.type === "stamp"
        ? `スタンプ（${resolveStampArt(effect.stampId, myStamps).name}）`
        : EFFECT_LABELS[effect.type]
    setHistory((prev) => [
      {
        id: `h-${Date.now()}`,
        mediaId: media.id,
        kind: media.kind,
        processedAt: "たったいま",
        method: label,
        faceCount: hidden.length,
        effect: { ...effect },
      },
      ...prev,
    ])
  }, [effect, hidden.length, media, myStamps, plan])

  const removeHistory = React.useCallback((id: string) => {
    setHistory((prev) => prev.filter((h) => h.id !== id))
  }, [])

  const addMyStamp = React.useCallback((stamp: MyStamp) => {
    setMyStamps((prev) => [stamp, ...prev])
  }, [])

  const removeMyStamp = React.useCallback((id: string) => {
    setMyStamps((prev) => prev.filter((s) => s.id !== id))
  }, [])

  const value: AppContextValue = {
    screen,
    go,
    back,
    plan,
    setPlan,
    remainingFree,
    setRemainingFree,
    deviceSupports4K,
    setDeviceSupports4K,
    canUsePremiumStamps,
    canUseCustomStamps,
    canBatch,
    canUseQueue,
    canExport4K,
    hasAds,
    videoLimitSec,
    videoLimitLabel,
    media,
    faces,
    hidden,
    effect,
    setEffect,
    exportSettings,
    updateExport,
    startEditing,
    toggleFace,
    hideAll,
    showAll,
    addManualFace,
    upgrade,
    requestUpgrade,
    closeUpgrade,
    canExport,
    completeExport,
    history,
    removeHistory,
    myStamps,
    addMyStamp,
    removeMyStamp,
    effectLabel,
    kindChooserOpen,
    openKindChooser,
    closeKindChooser,
    pickerKind,
    openPicker,
    closePicker,
    selectMedia,
  }

  return (
    <AppContext.Provider value={value}>
      <MyStampsProvider value={myStamps}>{children}</MyStampsProvider>
    </AppContext.Provider>
  )
}
