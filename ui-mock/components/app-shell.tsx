"use client"

import * as React from "react"

import { AppProvider, useApp } from "@/components/app-provider"
import { PhoneShell } from "@/components/phone-shell"
import { BottomNav } from "@/components/bottom-nav"
import { MediaPicker } from "@/components/media-picker"
import { KindChooser } from "@/components/kind-chooser"
import { UpgradeModal } from "@/components/upgrade-modal"
import { HomeScreen } from "@/components/screens/home-screen"
import { DetectScreen } from "@/components/screens/detect-screen"
import { EffectScreen } from "@/components/screens/effect-screen"
import { ExportScreen } from "@/components/screens/export-screen"
import { ProcessingScreen } from "@/components/screens/processing-screen"
import { DoneScreen } from "@/components/screens/done-screen"
import { HistoryScreen } from "@/components/screens/history-screen"
import { StampsScreen } from "@/components/screens/stamps-screen"
import { SettingsScreen } from "@/components/screens/settings-screen"
import { PricingScreen } from "@/components/screens/pricing-screen"
import { BatchScreen } from "@/components/screens/batch-screen"
import { CustomStampScreen } from "@/components/screens/custom-stamp-screen"

const TAB_SCREENS = ["home", "history", "stamps", "settings"]

export function AppShell() {
  return (
    <AppProvider>
      <AppShellInner />
    </AppProvider>
  )
}

function AppShellInner() {
  const { screen, pickerKind, closePicker, selectMedia, openKindChooser } = useApp()
  const scrollRef = React.useRef<HTMLDivElement>(null)

  React.useEffect(() => {
    scrollRef.current?.scrollTo({ top: 0 })
  }, [screen])

  return (
    <PhoneShell>
      <main ref={scrollRef} className="flex-1 overflow-y-auto overscroll-contain">
        {screen === "home" ? <HomeScreen /> : null}
        {screen === "detect" ? <DetectScreen /> : null}
        {screen === "effect" ? <EffectScreen /> : null}
        {screen === "export" ? <ExportScreen /> : null}
        {screen === "processing" ? <ProcessingScreen /> : null}
        {screen === "done" ? <DoneScreen /> : null}
        {screen === "history" ? <HistoryScreen /> : null}
        {screen === "stamps" ? <StampsScreen /> : null}
        {screen === "settings" ? <SettingsScreen /> : null}
        {screen === "pricing" ? <PricingScreen /> : null}
        {screen === "batch" ? <BatchScreen /> : null}
        {screen === "custom-stamp" ? <CustomStampScreen /> : null}
      </main>

      {TAB_SCREENS.includes(screen) ? <BottomNav onNew={openKindChooser} /> : null}

      <KindChooser />
      <MediaPicker kind={pickerKind} onClose={closePicker} onSelect={selectMedia} />
      <UpgradeModal />
    </PhoneShell>
  )
}
