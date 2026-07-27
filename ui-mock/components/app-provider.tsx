"use client"

import * as React from "react"

import {
  DEVICE_FREE_MB,
  findMedia,
  HISTORY,
  triage,
  type BatchHistoryItem,
  type FaceBox,
  type HistoryItem,
  type MediaItem,
  type ReviewReason,
  type SingleHistoryItem,
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
  | "batch-standard"
  | "batch-credit"
  | "batch-size"
  | "edit-locked"

export type UpgradeState = { reason: UpgradeReason; detail?: string } | null

export type ExportTarget = "ig-post" | "ig-story" | "original"
export type ExportRatio = "1:1" | "4:5" | "9:16" | "original"
export type FitMode = "crop" | "blur" | "contain"

/** メタデータは項目ごとに分ける。撮影日時だけは「保持」が初期値 */
export type MetadataSettings = {
  stripLocation: boolean
  stripDevice: boolean
  stripEditor: boolean
  keepCaptureDate: boolean
}

export type ExportSettings = {
  target: ExportTarget
  ratio: ExportRatio
  fitMode: FitMode
  metadata: MetadataSettings
}

/** 履歴の保存期間 */
export type Retention = "none" | "7d" | "30d" | "unlimited"

export const RETENTION_LABELS: Record<Retention, string> = {
  none: "履歴を保存しない",
  "7d": "7日間",
  "30d": "30日間",
  unlimited: "制限なし",
}

/**
 * 生成が終わった加工済み写真。
 * delivered が false のあいだは、保存も共有もされていない。
 * 受け渡しに成功したあとも、完了画面を開いているあいだは保持する。
 */
export type PendingOutput =
  | { kind: "single"; historyId: string; mediaId: string; usedTrial: false; delivered: boolean }
  | {
      kind: "batch"
      historyId: string
      mediaIds: string[]
      count: number
      usedTrial: boolean
      delivered: boolean
    }

export type BatchStage = "setup" | "detecting" | "review" | "queue" | "summary"
export type BatchMode = "auto" | "one-by-one"

export type BatchItemStatus =
  | "waiting"
  | "detecting"
  | "review"
  | "exporting"
  | "done"
  | "error"
  | "canceled"
  | "paused"

export const BATCH_STATUS_LABELS: Record<BatchItemStatus, string> = {
  waiting: "待機中",
  detecting: "顔を検出中",
  review: "確認が必要",
  exporting: "書き出し中",
  done: "完了",
  error: "エラー",
  canceled: "キャンセル",
  paused: "一時停止",
}

/**
 * 要確認に対するユーザーの判断。
 * 警告そのものは消えない。どう扱うと決めたかを記録する。
 */
export type ReviewResolution = "accepted-as-is" | "manual-region-added" | "unmasked-export-confirmed"

export const RESOLUTION_LABELS: Record<ReviewResolution, string> = {
  "accepted-as-is": "このままでよいと判断",
  "manual-region-added": "手動で範囲を追加",
  "unmasked-export-confirmed": "顔を隠さず保存",
}

export type BatchItem = {
  mediaId: string
  status: BatchItemStatus
  reasons: ReviewReason[]
  /** 要確認をユーザーが確認したか */
  resolved: boolean
  /** 確認した場合、どう扱うと決めたか。reasons は変化しない */
  resolution: ReviewResolution | null
  /** 共通設定とは別に個別編集したか */
  hasOverride: boolean
  /** 加工後サムネイルの生成が終わったか */
  thumbReady: boolean
  /** 書き出しで失敗させるデモ用のフラグ */
  willFail: boolean
}

/** 未保存出力が残っているときに保留する操作 */
type PendingIntent = { label: string; run: () => void } | null

/** 無料プランの月あたりの書き出し上限（枚） */
export const FREE_MONTHLY_LIMIT = 5
/** Proの一括処理で1バッチに選べる最大枚数 */
export const BATCH_MAX_ITEMS = 50
/** 一括処理のお試しクレジット（枚） */
export const TRIAL_CREDITS = 5
/** カスタムスタンプの登録上限（Standard / Pro 共通） */
export const CUSTOM_STAMP_LIMIT = 100

export const PLAN_LABELS: Record<Plan, string> = {
  free: "Free",
  standard: "Standard",
  pro: "Pro",
}

export const PLAN_PRICE_LABELS: Record<Plan, string> = {
  free: "無料",
  standard: "月300円",
  pro: "月980円",
}

const DEFAULT_METADATA: MetadataSettings = {
  stripLocation: true,
  stripDevice: true,
  stripEditor: true,
  keepCaptureDate: true,
}

const DEFAULT_EXPORT: ExportSettings = {
  target: "ig-post",
  ratio: "1:1",
  fitMode: "crop",
  metadata: DEFAULT_METADATA,
}

const DEMO_ERROR_IDS = ["m6", "m11"]

type AppContextValue = {
  screen: Screen
  go: (screen: Screen) => void
  back: () => void

  plan: Plan
  setPlan: (plan: Plan) => void
  remainingFree: number
  setRemainingFree: (n: number) => void
  trialCredits: number
  setTrialCredits: (n: number) => void

  canUsePremiumStamps: boolean
  canUseCustomStamps: boolean
  /** Proの通常の一括処理 */
  canBatchFull: boolean
  /** お試しクレジットで一括処理を試せる */
  canBatchTrial: boolean
  hasAds: boolean
  batchMaxSelectable: number

  media: MediaItem | null
  faces: FaceBox[]
  hidden: string[]
  effect: EffectConfig
  setEffect: React.Dispatch<React.SetStateAction<EffectConfig>>
  effectLabel: string
  exportSettings: ExportSettings
  updateExport: (patch: Partial<ExportSettings>) => void
  updateMetadata: (patch: Partial<MetadataSettings>) => void

  startEditing: (mediaId: string) => void
  toggleFace: (id: string) => void
  hideAll: () => void
  showAll: () => void
  addManualFace: () => void
  /** 顔検出なしで書き出しへ進む（顔0件のとき） */
  skipFaces: boolean
  canExportSingle: boolean
  completeSingleExport: () => void

  /** 変更せず再書き出しするモード（降格後の既存作品） */
  reexportOf: SingleHistoryItem | null
  startReexport: (item: SingleHistoryItem) => void
  startLockedView: (item: SingleHistoryItem) => void
  /** 閲覧はできるが変更にはStandardが必要な状態 */
  lockedEdit: boolean

  upgrade: UpgradeState
  requestUpgrade: (reason: UpgradeReason, detail?: string) => void
  closeUpgrade: () => void

  history: HistoryItem[]
  removeHistory: (id: string) => void
  retention: Retention
  setRetention: (value: Retention) => void

  myStamps: MyStamp[]
  addMyStamp: (stamp: MyStamp) => void
  removeMyStamp: (id: string) => void
  /** 履歴から参照されているスタンプか（削除時の説明に使う） */
  isStampReferenced: (id: string) => boolean
  /** 登録中のマイスタンプが使っている容量 */
  stampStorageActiveMb: number
  /** 一覧からは消えたが、過去の加工履歴が使っている容量 */
  stampStorageRetainedMb: number
  retiredStampCount: number
  clearMyStamps: () => void

  /** 写真ピッカー */
  pickerOpen: boolean
  pickerMulti: boolean
  openPicker: () => void
  openBatchPicker: () => void
  closePicker: () => void
  selectMedia: (id: string) => void

  /** 未保存の加工済み写真 */
  pendingOutput: PendingOutput | null
  unsavedPromptOpen: boolean
  discardPromptOpen: boolean
  recoveryOpen: boolean
  openUnsavedPrompt: () => void
  closeUnsavedPrompt: () => void
  askDiscard: () => void
  closeDiscard: () => void
  savePending: () => void
  sharePending: () => void
  discardPending: () => void
  keepPendingForLater: () => void
  closeRecovery: () => void
  simulateCrash: () => void
  /** 未保存があるときは確認をはさんでから実行する */
  guardNewWork: (label: string, run: () => void) => void

  /** 一括処理 */
  batchStage: BatchStage
  batchMode: BatchMode
  setBatchMode: (mode: BatchMode) => void
  batchSelection: string[]
  toggleBatchSelection: (id: string) => void
  clearBatchSelection: () => void
  batchItems: BatchItem[]
  batchRunning: boolean
  batchTrialUsed: boolean
  gridConfirmed: boolean
  reachedEnd: boolean
  markReachedEnd: () => void
  confirmGrid: () => void
  canConfirmGrid: boolean
  allThumbsReady: boolean
  unresolvedCount: number
  reviewCount: number
  /** 「1枚ずつ確認」で個別に確認を終えた写真 */
  reviewedIds: string[]
  markReviewed: (mediaId: string) => void
  resolveItem: (mediaId: string, resolution?: ReviewResolution) => void
  resolveGroup: (reason: ReviewReason) => void
  markOverride: (mediaId: string) => void
  startBatchDetection: () => void
  startBatchExport: () => void
  pauseBatch: () => void
  resumeBatch: () => void
  cancelBatch: () => void
  retryBatchErrors: () => void
  resetBatch: () => void
  overrideCount: number
  applyCommonSettings: (mode: "keep" | "overwrite") => void
  /** 共通の見た目設定を変えたときに呼ぶ */
  onCommonVisualChanged: () => void

  /** 端末の空き容量（デモ用） */
  freeSpaceMb: number
  lowStorage: boolean
  setLowStorage: (value: boolean) => void
}

const AppContext = React.createContext<AppContextValue | null>(null)

export function useApp() {
  const ctx = React.useContext(AppContext)
  if (!ctx) throw new Error("useApp は AppProvider の中で使ってください")
  return ctx
}

export function AppProvider({ children }: { children: React.ReactNode }) {
  const [stack, setStack] = React.useState<Screen[]>(["home"])
  const [plan, setPlanState] = React.useState<Plan>("free")
  const [remainingFree, setRemainingFree] = React.useState(3)
  const [trialCredits, setTrialCredits] = React.useState(TRIAL_CREDITS)
  const [retention, setRetention] = React.useState<Retention>("30d")
  const [lowStorage, setLowStorage] = React.useState(false)

  const [mediaId, setMediaId] = React.useState<string | null>(null)
  const [manualFaces, setManualFaces] = React.useState<FaceBox[]>([])
  const [hidden, setHidden] = React.useState<string[]>([])
  const [effect, setEffect] = React.useState<EffectConfig>(DEFAULT_EFFECT)
  const [exportSettings, setExportSettings] = React.useState<ExportSettings>(DEFAULT_EXPORT)
  const [reexportOf, setReexportOf] = React.useState<SingleHistoryItem | null>(null)

  const [upgrade, setUpgrade] = React.useState<UpgradeState>(null)
  const [history, setHistory] = React.useState<HistoryItem[]>(HISTORY)
  const [myStamps, setMyStamps] = React.useState<MyStamp[]>(MY_STAMPS)
  /** 一覧からは消えたが、過去プロジェクトが参照しているスタンプ */
  const [retiredStamps, setRetiredStamps] = React.useState<MyStamp[]>([])

  const [pickerOpen, setPickerOpen] = React.useState(false)
  const [pickerMulti, setPickerMulti] = React.useState(false)

  const [pendingOutput, setPendingOutput] = React.useState<PendingOutput | null>(null)
  const [unsavedPromptOpen, setUnsavedPromptOpen] = React.useState(false)
  const [discardPromptOpen, setDiscardPromptOpen] = React.useState(false)
  const [recoveryOpen, setRecoveryOpen] = React.useState(false)
  const intentRef = React.useRef<PendingIntent>(null)

  const [batchStage, setBatchStage] = React.useState<BatchStage>("setup")
  const [batchMode, setBatchMode] = React.useState<BatchMode>("auto")
  const [batchSelection, setBatchSelection] = React.useState<string[]>([])
  const [batchItems, setBatchItems] = React.useState<BatchItem[]>([])
  const [batchRunning, setBatchRunning] = React.useState(false)
  const [batchTrialUsed, setBatchTrialUsed] = React.useState(false)
  const [gridConfirmed, setGridConfirmed] = React.useState(false)
  const [reachedEnd, setReachedEnd] = React.useState(false)
  const [reviewedIds, setReviewedIds] = React.useState<string[]>([])
  /** すでに枠を消費した元写真。同じ写真の再書き出しでは二重に消費しない */
  const [chargedIds, setChargedIds] = React.useState<string[]>([])
  const [trialChargedIds, setTrialChargedIds] = React.useState<string[]>([])

  const media = mediaId ? findMedia(mediaId) : null
  const faces = React.useMemo(
    () => (media ? [...media.faces, ...manualFaces] : []),
    [media, manualFaces],
  )
  const screen = stack[stack.length - 1]

  /* -------------------------------------------------------------- */
  /* プラン権限                                                      */
  /* -------------------------------------------------------------- */

  const canUsePremiumStamps = plan === "standard" || plan === "pro"
  const canUseCustomStamps = plan === "standard" || plan === "pro"
  const canBatchFull = plan === "pro"
  const canBatchTrial = trialCredits > 0
  const hasAds = plan === "free"
  // トライアルは「総枚数5枚まで」「新規写真は残クレジットまで」の2条件。
  // 総枚数だけで絞ると、残0枚のとき消費済みの写真すら選べなくなる。
  const batchMaxSelectable = canBatchFull ? BATCH_MAX_ITEMS : TRIAL_CREDITS
  const canExportSingle = plan !== "free" || remainingFree > 0
  // 有料スタンプで作った既存作品は、Freeでも閲覧と再書き出しはできるが変更はできない
  const lockedEdit = plan === "free" && reexportOf?.paidFeature !== undefined
  const freeSpaceMb = lowStorage ? DEVICE_FREE_MB.low : DEVICE_FREE_MB.normal

  const allStamps = React.useMemo(() => [...myStamps, ...retiredStamps], [myStamps, retiredStamps])

  const effectLabel =
    effect.type === "stamp"
      ? `スタンプ（${resolveStampArt(effect.stampId, allStamps).name}）`
      : EFFECT_LABELS[effect.type]

  /* -------------------------------------------------------------- */
  /* 画面遷移                                                        */
  /* -------------------------------------------------------------- */

  const go = React.useCallback((next: Screen) => {
    setStack((prev) => (prev[prev.length - 1] === next ? prev : [...prev, next]))
  }, [])

  const back = React.useCallback(() => {
    setStack((prev) => (prev.length > 1 ? prev.slice(0, -1) : prev))
  }, [])

  const setPlan = React.useCallback((next: Plan) => {
    setPlanState(next)
    // Proの契約が終わったら、走っているバッチは一時停止する
    if (next !== "pro") {
      setBatchRunning(false)
      setBatchItems((prev) =>
        prev.map((item) =>
          ["waiting", "detecting", "exporting"].includes(item.status) ? { ...item, status: "paused" } : item,
        ),
      )
    }
  }, [])

  /* -------------------------------------------------------------- */
  /* 単体処理                                                        */
  /* -------------------------------------------------------------- */

  const startEditing = React.useCallback((id: string) => {
    const item = findMedia(id)
    setMediaId(id)
    setManualFaces([])
    // 検出した顔はすべて「隠す」で初期化する
    setHidden(item.faces.map((f) => f.id))
    setReexportOf(null)
    setStack((prev) => [...prev, "detect"])
  }, [])

  const openProject = React.useCallback((item: SingleHistoryItem, target: Screen) => {
    const source = findMedia(item.mediaId)
    setMediaId(item.mediaId)
    setManualFaces([])
    setHidden(source.faces.map((f) => f.id))
    setEffect(item.effect)
    setReexportOf(item)
    setStack((prev) => [...prev, target])
  }, [])

  /** 変更せずそのまま書き出す */
  const startReexport = React.useCallback(
    (item: SingleHistoryItem) => openProject(item, "export"),
    [openProject],
  )

  /** 内容の確認だけを許す。変更しようとした時点でStandardを案内する */
  const startLockedView = React.useCallback(
    (item: SingleHistoryItem) => openProject(item, "effect"),
    [openProject],
  )

  const toggleFace = React.useCallback((id: string) => {
    setHidden((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))
  }, [])

  const hideAll = React.useCallback(() => setHidden(faces.map((f) => f.id)), [faces])
  const showAll = React.useCallback(() => setHidden([]), [])

  const addManualFace = React.useCallback(() => {
    setManualFaces((prev) => {
      const index = prev.length
      const id = `manual-${index + 1}`
      const offset = index * 7
      const next: FaceBox = { id, x: 22 + offset, y: 62 - offset, w: 16, h: 14, manual: true }
      setHidden((h) => [...h, id])
      return [...prev, next]
    })
  }, [])

  const updateExport = React.useCallback((patch: Partial<ExportSettings>) => {
    setExportSettings((prev) => ({ ...prev, ...patch }))
  }, [])

  const updateMetadata = React.useCallback((patch: Partial<MetadataSettings>) => {
    setExportSettings((prev) => ({ ...prev, metadata: { ...prev.metadata, ...patch } }))
  }, [])

  const skipFaces = faces.length === 0

  /**
   * 加工済み出力の生成が完了した時点で1枚ぶん消費する。
   * 同じ元写真を24時間以内に再書き出しても追加消費しない（仕様 14.3）。
   */
  const completeSingleExport = React.useCallback(() => {
    if (!media) return
    if (plan === "free" && !chargedIds.includes(media.id)) {
      setRemainingFree((n) => Math.max(0, n - 1))
      setChargedIds((prev) => [...prev, media.id])
    }

    const label =
      effect.type === "stamp"
        ? `スタンプ（${resolveStampArt(effect.stampId, allStamps).name}）`
        : EFFECT_LABELS[effect.type]

    const historyId = `h-${history.length + 1}-${label}`
    const entry: SingleHistoryItem = {
      id: historyId,
      type: "single",
      mediaId: media.id,
      processedAt: "たったいま",
      method: label,
      faceCount: hidden.length,
      effect: { ...effect },
      paidFeature: reexportOf?.paidFeature,
      unsaved: true,
    }

    if (retention !== "none") setHistory((prev) => [entry, ...prev])
    setPendingOutput({ kind: "single", historyId, mediaId: media.id, usedTrial: false, delivered: false })
  }, [allStamps, chargedIds, effect, hidden.length, history.length, media, plan, reexportOf, retention])

  /* -------------------------------------------------------------- */
  /* 未保存の加工済み写真                                             */
  /* -------------------------------------------------------------- */

  /**
   * 受け渡しが成功しても、その場でファイルは消さない。
   * 完了画面を開いているあいだは保持し、画面を離れた時点で破棄する。
   * これにより「共有したあとに保存もする」ができる。
   */
  const markDelivered = React.useCallback(() => {
    setPendingOutput((current) => {
      if (!current) return current
      setHistory((prev) =>
        prev.map((h) => (h.id === current.historyId ? ({ ...h, unsaved: false } as HistoryItem) : h)),
      )
      return { ...current, delivered: true }
    })
    setUnsavedPromptOpen(false)
    setDiscardPromptOpen(false)
    setRecoveryOpen(false)
    const intent = intentRef.current
    intentRef.current = null
    if (intent) intent.run()
  }, [])

  const savePending = React.useCallback(() => markDelivered(), [markDelivered])
  const sharePending = React.useCallback(() => markDelivered(), [markDelivered])

  const discardPending = React.useCallback(() => {
    setPendingOutput((current) => {
      if (current && retention !== "none") {
        setHistory((prev) => prev.filter((h) => h.id !== current.historyId))
      }
      return null
    })
    setUnsavedPromptOpen(false)
    setDiscardPromptOpen(false)
    setRecoveryOpen(false)
    const intent = intentRef.current
    intentRef.current = null
    if (intent) intent.run()
  }, [retention])

  /** 「あとで保存」。履歴に未保存として残す */
  const keepPendingForLater = React.useCallback(() => {
    setUnsavedPromptOpen(false)
    const intent = intentRef.current
    intentRef.current = null
    if (intent) intent.run()
  }, [])

  const openUnsavedPrompt = React.useCallback(() => setUnsavedPromptOpen(true), [])
  const closeUnsavedPrompt = React.useCallback(() => {
    intentRef.current = null
    setUnsavedPromptOpen(false)
  }, [])
  const askDiscard = React.useCallback(() => setDiscardPromptOpen(true), [])
  const closeDiscard = React.useCallback(() => setDiscardPromptOpen(false), [])
  const closeRecovery = React.useCallback(() => setRecoveryOpen(false), [])

  /**
   * 異常終了後の起動を再現する。
   * 受け渡し済みの出力は一時ファイルを消すだけで、復旧案内は出さない。
   * すでに保存できているのに「保存していない」と伝えるのは事実と異なるため。
   */
  const simulateCrash = React.useCallback(() => {
    setStack(["home"])
    setPendingOutput((current) => {
      if (current && current.delivered) return null
      if (current) setRecoveryOpen(true)
      return current
    })
  }, [])

  /**
   * 未保存があるときは確認をはさむ。単体・一括を問わず同時に1件まで。
   * 受け渡し済みの出力は、画面を離れる時点で静かに破棄する。
   */
  const guardNewWork = React.useCallback(
    (label: string, run: () => void) => {
      if (pendingOutput && !pendingOutput.delivered) {
        intentRef.current = { label, run }
        setUnsavedPromptOpen(true)
        return
      }
      setPendingOutput(null)
      run()
    },
    [pendingOutput],
  )

  /* -------------------------------------------------------------- */
  /* 写真ピッカー                                                    */
  /* -------------------------------------------------------------- */

  const openPicker = React.useCallback(() => {
    guardNewWork("写真を選ぶ", () => {
      setPickerMulti(false)
      setPickerOpen(true)
    })
  }, [guardNewWork])

  const openBatchPicker = React.useCallback(() => {
    setPickerMulti(true)
    setPickerOpen(true)
  }, [])

  const closePicker = React.useCallback(() => setPickerOpen(false), [])

  const selectMedia = React.useCallback(
    (id: string) => {
      setPickerOpen(false)
      startEditing(id)
    },
    [startEditing],
  )

  /* -------------------------------------------------------------- */
  /* 課金訴求                                                        */
  /* -------------------------------------------------------------- */

  const requestUpgrade = React.useCallback((reason: UpgradeReason, detail?: string) => {
    setUpgrade({ reason, detail })
  }, [])
  const closeUpgrade = React.useCallback(() => setUpgrade(null), [])

  /* -------------------------------------------------------------- */
  /* 履歴とスタンプ                                                  */
  /* -------------------------------------------------------------- */

  const isStampReferenced = React.useCallback(
    (id: string) => history.some((h) => h.effect.type === "stamp" && h.effect.stampId === id),
    [history],
  )

  const removeHistory = React.useCallback((id: string) => {
    setHistory((prev) => {
      const next = prev.filter((h) => h.id !== id)
      // 参照がなくなったスタンプの参照用コピーを破棄する
      setRetiredStamps((stamps) =>
        stamps.filter((s) => next.some((h) => h.effect.type === "stamp" && h.effect.stampId === s.id)),
      )
      return next
    })
  }, [])

  const addMyStamp = React.useCallback((stamp: MyStamp) => {
    setMyStamps((prev) => (prev.length >= CUSTOM_STAMP_LIMIT ? prev : [stamp, ...prev]))
  }, [])

  /** 一覧からは消すが、過去プロジェクトが使っていれば参照用コピーを残す */
  const removeMyStamp = React.useCallback(
    (id: string) => {
      setMyStamps((prev) => {
        const target = prev.find((s) => s.id === id)
        if (target && isStampReferenced(id)) {
          setRetiredStamps((stamps) => (stamps.some((s) => s.id === id) ? stamps : [...stamps, target]))
        }
        return prev.filter((s) => s.id !== id)
      })
    },
    [isStampReferenced],
  )

  const clearMyStamps = React.useCallback(() => {
    setMyStamps((prev) => {
      const kept = prev.filter((s) => isStampReferenced(s.id))
      setRetiredStamps((stamps) => [...stamps, ...kept.filter((k) => !stamps.some((s) => s.id === k.id))])
      return []
    })
  }, [isStampReferenced])

  // 1個あたり 0.18MB としてざっくり見積もる（長辺1024pxの圧縮画像の目安）
  const stampStorageActiveMb = Math.round(myStamps.length * 0.18 * 10) / 10
  const stampStorageRetainedMb = Math.round(retiredStamps.length * 0.18 * 10) / 10
  const retiredStampCount = retiredStamps.length

  /* -------------------------------------------------------------- */
  /* 一括処理                                                        */
  /* -------------------------------------------------------------- */

  /**
   * 確認状態の解除は、変更が見た目へ影響する写真だけに限定する。
   * 一律に全解除すると、50枚のうち1枚直しただけで残り49枚も再確認になる。
   */
  const dropOverview = React.useCallback(() => {
    setGridConfirmed(false)
    setReachedEnd(false)
  }, [])

  /** 個別写真の見た目を変えた */
  const onItemVisualChanged = React.useCallback(
    (id: string) => {
      setReviewedIds((prev) => prev.filter((x) => x !== id))
      setBatchItems((prev) =>
        prev.map((item) => (item.mediaId === id ? { ...item, resolved: false, resolution: null } : item)),
      )
      dropOverview()
    },
    [dropOverview],
  )

  /** 共通設定を変えた。個別設定を持つ写真は影響を受けない */
  const onCommonVisualChanged = React.useCallback(() => {
    setBatchItems((prev) => {
      const affected = prev.filter((i) => !i.hasOverride).map((i) => i.mediaId)
      setReviewedIds((ids) => ids.filter((x) => !affected.includes(x)))
      return prev.map((item) =>
        item.hasOverride ? item : { ...item, resolved: false, resolution: null },
      )
    })
    dropOverview()
  }, [dropOverview])

  /** 写真を追加した。追加分だけ未確認 */
  const onSelectionAdded = React.useCallback(
    (id: string) => {
      setReviewedIds((prev) => prev.filter((x) => x !== id))
      dropOverview()
    },
    [dropOverview],
  )

  /** 写真を削除した。残りの確認状態は維持する */
  const onSelectionRemoved = React.useCallback(() => {
    dropOverview()
  }, [dropOverview])

  const toggleBatchSelection = React.useCallback(
    (id: string) => {
      setBatchSelection((prev) => {
        if (prev.includes(id)) {
          onSelectionRemoved()
          return prev.filter((x) => x !== id)
        }
        // 条件1: 1バッチの総枚数
        if (prev.length >= batchMaxSelectable) {
          setUpgrade(
            canBatchFull
              ? { reason: "batch-size", detail: `1回の一括処理では最大${BATCH_MAX_ITEMS}枚まで選べます。` }
              : { reason: "batch-size" },
          )
          return prev
        }
        // 条件2: 消費済み台帳にない写真の枚数が残クレジットを超えないこと
        if (!canBatchFull && !trialChargedIds.includes(id)) {
          const freshSelected = prev.filter((x) => !trialChargedIds.includes(x)).length
          if (freshSelected >= trialCredits) {
            setUpgrade({ reason: "batch-size" })
            return prev
          }
        }
        onSelectionAdded(id)
        return [...prev, id]
      })
    },
    [batchMaxSelectable, canBatchFull, onSelectionAdded, onSelectionRemoved, trialChargedIds, trialCredits],
  )

  const clearBatchSelection = React.useCallback(() => {
    setBatchSelection([])
    setReviewedIds([])
    dropOverview()
  }, [dropOverview])

  const startBatchDetection = React.useCallback(() => {
    setBatchItems(
      batchSelection.map((id) => ({
        mediaId: id,
        status: "detecting" as BatchItemStatus,
        reasons: triage(findMedia(id)),
        resolved: false,
        resolution: null,
        hasOverride: false,
        thumbReady: false,
        willFail: DEMO_ERROR_IDS.includes(id),
      })),
    )
    setBatchStage("detecting")
    setGridConfirmed(false)
    setReachedEnd(false)
  }, [batchSelection])

  // 検出とサムネイル生成を順に終わらせる
  React.useEffect(() => {
    if (batchStage !== "detecting") return
    const pending = batchItems.findIndex((item) => !item.thumbReady)
    if (pending === -1) {
      setBatchStage("review")
      return
    }
    const timer = window.setTimeout(() => {
      setBatchItems((prev) => {
        const next = [...prev]
        const item = next[pending]
        next[pending] = {
          ...item,
          thumbReady: true,
          status: item.reasons.length > 0 ? "review" : "waiting",
        }
        return next
      })
    }, 260)
    return () => window.clearTimeout(timer)
  }, [batchStage, batchItems])

  const allThumbsReady = batchItems.length > 0 && batchItems.every((i) => i.thumbReady)
  const unresolvedCount = batchItems.filter((i) => i.reasons.length > 0 && !i.resolved).length
  const reviewCount = batchItems.filter((i) => i.reasons.length > 0).length
  const overrideCount = batchItems.filter((i) => i.hasOverride).length

  const markReachedEnd = React.useCallback(() => setReachedEnd(true), [])
  const markReviewed = React.useCallback((id: string) => {
    setReviewedIds((prev) => (prev.includes(id) ? prev : [...prev, id]))
  }, [])

  /**
   * 確認の成立条件はモードで異なる。
   * おまかせ一括は一覧の末尾到達と確認ボタン、
   * 1枚ずつ確認は全写真の個別確認をもって成立とし、一覧スクロールは求めない。
   */
  const canConfirmGrid =
    allThumbsReady &&
    unresolvedCount === 0 &&
    (batchMode === "auto" ? reachedEnd : batchItems.every((i) => reviewedIds.includes(i.mediaId)))

  const confirmGrid = React.useCallback(() => {
    if (!canConfirmGrid) return
    setGridConfirmed(true)
  }, [canConfirmGrid])

  /** 警告は消さず、どう扱うと決めたかを記録する */
  const resolveItem = React.useCallback((id: string, resolution: ReviewResolution = "accepted-as-is") => {
    setBatchItems((prev) =>
      prev.map((item) =>
        item.mediaId === id
          ? { ...item, resolved: true, resolution, status: "waiting" as BatchItemStatus }
          : item,
      ),
    )
  }, [])

  /** 理由ごとの一括確認。「顔が検出されませんでした」は対象外 */
  const resolveGroup = React.useCallback((reason: ReviewReason) => {
    if (reason === "no-face") return
    setBatchItems((prev) =>
      prev.map((item) =>
        item.reasons.includes(reason) && !item.reasons.includes("no-face")
          ? {
              ...item,
              resolved: true,
              resolution: "accepted-as-is" as ReviewResolution,
              status: "waiting" as BatchItemStatus,
            }
          : item,
      ),
    )
  }, [])

  const markOverride = React.useCallback(
    (id: string) => {
      setBatchItems((prev) => prev.map((item) => (item.mediaId === id ? { ...item, hasOverride: true } : item)))
      onItemVisualChanged(id)
    },
    [onItemVisualChanged],
  )

  /** 共通設定を変えたときの扱い。個別設定を残すか、すべて上書きするか */
  const applyCommonSettings = React.useCallback(
    (mode: "keep" | "overwrite") => {
      if (mode === "overwrite") {
        setBatchItems((prev) => prev.map((item) => ({ ...item, hasOverride: false })))
      }
      onCommonVisualChanged()
    },
    [onCommonVisualChanged],
  )

  const startBatchExport = React.useCallback(() => {
    if (unresolvedCount > 0 || !gridConfirmed) return
    setBatchItems((prev) =>
      prev.map((item) => ({ ...item, status: "waiting" as BatchItemStatus })),
    )
    setBatchStage("queue")
    setBatchRunning(true)
  }, [gridConfirmed, unresolvedCount])

  // 書き出しキューを1件ずつ進める
  React.useEffect(() => {
    if (batchStage !== "queue" || !batchRunning) return
    const index = batchItems.findIndex((i) => i.status === "waiting" || i.status === "exporting")
    if (index === -1) {
      setBatchRunning(false)
      setBatchStage("summary")
      return
    }
    const timer = window.setTimeout(() => {
      setBatchItems((prev) => {
        const next = [...prev]
        const item = next[index]
        next[index] =
          item.status === "waiting"
            ? { ...item, status: "exporting" }
            : { ...item, status: item.willFail ? "error" : "done" }
        return next
      })
    }, 420)
    return () => window.clearTimeout(timer)
  }, [batchStage, batchRunning, batchItems])

  // 書き出しが終わったら、成功枚数ぶんを消費して未保存出力にする
  const summaryHandled = React.useRef(false)
  React.useEffect(() => {
    if (batchStage !== "summary" || summaryHandled.current) return
    summaryHandled.current = true

    const doneItems = batchItems.filter((i) => i.status === "done")
    const errorCount = batchItems.filter((i) => i.status === "error").length
    if (doneItems.length === 0) return

    const usedTrial = !canBatchFull
    if (usedTrial) {
      // 同じ元写真を再書き出ししてもクレジットは二重に消費しない
      const fresh = doneItems.filter((i) => !trialChargedIds.includes(i.mediaId))
      if (fresh.length > 0) {
        setTrialCredits((n) => Math.max(0, n - fresh.length))
        setTrialChargedIds((prev) => [...prev, ...fresh.map((i) => i.mediaId)])
      }
      setBatchTrialUsed(true)
    }
    // 通常の一括処理はProのみ。Proは書き出し無制限なので枠を消費しない

    const historyId = `batch-${doneItems.length}-${errorCount}`
    const entry: BatchHistoryItem = {
      id: historyId,
      type: "batch",
      title: "まとめて加工",
      mediaIds: doneItems.map((i) => i.mediaId),
      processedAt: "たったいま",
      method: EFFECT_LABELS[effect.type],
      effect: { ...effect },
      doneCount: doneItems.length,
      errorCount,
      unsaved: true,
    }
    if (retention !== "none") setHistory((prev) => [entry, ...prev])
    setPendingOutput({
      kind: "batch",
      historyId,
      mediaIds: doneItems.map((i) => i.mediaId),
      count: doneItems.length,
      usedTrial,
      delivered: false,
    })
  }, [batchItems, batchStage, canBatchFull, chargedIds, effect, plan, retention, trialChargedIds])

  const pauseBatch = React.useCallback(() => setBatchRunning(false), [])
  const resumeBatch = React.useCallback(() => setBatchRunning(true), [])

  const cancelBatch = React.useCallback(() => {
    setBatchRunning(false)
    setBatchItems((prev) =>
      prev.map((item) =>
        ["done", "error"].includes(item.status) ? item : { ...item, status: "canceled" as BatchItemStatus },
      ),
    )
    setBatchStage("summary")
  }, [])

  const retryBatchErrors = React.useCallback(() => {
    summaryHandled.current = false
    setBatchItems((prev) =>
      prev.map((item) =>
        item.status === "error" ? { ...item, status: "waiting" as BatchItemStatus, willFail: false } : item,
      ),
    )
    setBatchStage("queue")
    setBatchRunning(true)
  }, [])

  const resetBatch = React.useCallback(() => {
    summaryHandled.current = false
    setBatchItems([])
    setBatchSelection([])
    setBatchRunning(false)
    setBatchStage("setup")
    setGridConfirmed(false)
    setReachedEnd(false)
    setReviewedIds([])
  }, [])

  const value: AppContextValue = {
    screen,
    go,
    back,
    plan,
    setPlan,
    remainingFree,
    setRemainingFree,
    trialCredits,
    setTrialCredits,
    canUsePremiumStamps,
    canUseCustomStamps,
    canBatchFull,
    canBatchTrial,
    hasAds,
    batchMaxSelectable,
    media,
    faces,
    hidden,
    effect,
    setEffect,
    effectLabel,
    exportSettings,
    updateExport,
    updateMetadata,
    startEditing,
    toggleFace,
    hideAll,
    showAll,
    addManualFace,
    skipFaces,
    canExportSingle,
    completeSingleExport,
    reexportOf,
    startReexport,
    startLockedView,
    lockedEdit,
    upgrade,
    requestUpgrade,
    closeUpgrade,
    history,
    removeHistory,
    retention,
    setRetention,
    myStamps,
    addMyStamp,
    removeMyStamp,
    isStampReferenced,
    stampStorageActiveMb,
    stampStorageRetainedMb,
    retiredStampCount,
    clearMyStamps,
    pickerOpen,
    pickerMulti,
    openPicker,
    openBatchPicker,
    closePicker,
    selectMedia,
    pendingOutput,
    unsavedPromptOpen,
    discardPromptOpen,
    recoveryOpen,
    openUnsavedPrompt,
    closeUnsavedPrompt,
    askDiscard,
    closeDiscard,
    savePending,
    sharePending,
    discardPending,
    keepPendingForLater,
    closeRecovery,
    simulateCrash,
    guardNewWork,
    batchStage,
    batchMode,
    setBatchMode,
    batchSelection,
    toggleBatchSelection,
    clearBatchSelection,
    batchItems,
    batchRunning,
    batchTrialUsed,
    gridConfirmed,
    reachedEnd,
    markReachedEnd,
    confirmGrid,
    canConfirmGrid,
    allThumbsReady,
    unresolvedCount,
    reviewCount,
    reviewedIds,
    markReviewed,
    resolveItem,
    resolveGroup,
    markOverride,
    startBatchDetection,
    startBatchExport,
    pauseBatch,
    resumeBatch,
    cancelBatch,
    retryBatchErrors,
    resetBatch,
    overrideCount,
    applyCommonSettings,
    onCommonVisualChanged,
    freeSpaceMb,
    lowStorage,
    setLowStorage,
  }

  return (
    <AppContext.Provider value={value}>
      <MyStampsProvider value={allStamps}>{children}</MyStampsProvider>
    </AppContext.Provider>
  )
}
