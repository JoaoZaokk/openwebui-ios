# Roadmap — OpenWebUI for macOS (native)

Mirror of the proven **Odysseus-macOS** approach ([odysseus-ios](https://github.com/JoaoZaokk/odysseus-ios),
now at **1.4 (8)** — 35 UI languages incl. zh-HK, macOS target shipping):
**one shared SwiftUI source tree, a second xcodegen target** — 100% native AppKit-backed
SwiftUI, no Catalyst, no WebView, and zero breakage of the iOS app (macOS-only code is
fenced behind `#if os(macOS)`; iOS keeps compiling the exact same files).

Target: **macOS 14+ (Apple Silicon)**, sandboxed, same PolyForm license, same bundle id
family (`com.zao.openwebui`) so it can ship as the Mac version of the same App Store listing.

---

## Phase 0 — Target scaffolding (½ day)
*Mirror: Odysseus `project.yml` lines 93–131.*

- [ ] `project.yml`: add **OpenWebUI-macOS** target — `platform: macOS`, same `sources: App`
      with per-platform excludes (`Info.plist` ↔ `Info-macOS.plist`, entitlements).
- [ ] `App/Resources/Info-macOS.plist` via xcodegen `info.properties`:
      `LSApplicationCategoryType: public.app-category.productivity`,
      `CFBundleShortVersionString/CFBundleVersion` from build settings,
      `ITSAppUsesNonExemptEncryption: false`, `NSAppTransportSecurity` (LAN-only exception),
      mic + speech usage strings, PolyForm copyright.
- [ ] `App/Resources/OpenWebUI-macOS.entitlements` (copy Odysseus):
      `app-sandbox`, `network.client`, `device.audio-input`, `files.user-selected.read-write`.
- [ ] Build settings: `ENABLE_HARDENED_RUNTIME: YES`, `COMBINE_HIDPI_IMAGES: YES`,
      `CODE_SIGN_ENTITLEMENTS`, macOS `MARKETING_VERSION: "1.0"`.
- [ ] Root scene (`OpenWebUIApp`): `#if os(macOS)` → global `.buttonStyle(.plain)`,
      `.textFieldStyle(.plain)`, `.frame(minWidth: 900, minHeight: 560)`,
      `.defaultSize(width: 1180, height: 760)`, `.windowResizability(.contentMinSize)`.

## Phase 1 — Compile pass: platform shims (1–2 days)
*Mirror: Odysseus `Config/PlatformCompat.swift` (57 lines) — OpenWebUI already ships a
fork-era `App/Config/PlatformCompat.swift` + `ScreenChrome.swift`; extend, don't reinvent.*

- [ ] Sync `ScreenChrome.swift` with Odysseus 1.4's version first — it gained
      `themedNavBar(_:)` (themed nav bars on iOS sheets) and `LocalizedStringKey`
      routing for titles/search/prompts (OpenWebUI still has the older fork copy;
      PlatformCompat is already byte-identical ✓).
- [ ] Extend PlatformCompat for every iOS-only call site until the macOS target compiles:
      `navigationBarTitleDisplayMode`, `keyboardType`, `textInputAutocapitalization`,
      `ToolbarItemPlacement` shims, haptics no-op.
- [ ] `UIImage` → platform image alias (`NSImage` on macOS) where the **App** layer touches
      images (`ImageGenView`, `Attachments`); `OpenWebUIKit` is already platform-neutral ✓.
- [ ] `UIPasteboard` → `NSPasteboard` shim; share sheet → `NSSharingServicePicker`.
- [ ] `AVAudioSession` (iOS-only) → fence with `#if os(iOS)`; macOS uses the plain
      `AVAudioEngine` input node path (Odysseus `VoiceInputManager` pattern: fresh engine per
      recording — reusing one hangs the macOS audio HAL).
- [ ] `AppIconManager` (alternate icons are iOS-only) → no-op on macOS.

**Hotspots (from survey):** `Attachments.swift` (27 UIKit hits — PhotosPicker/camera/UIImage),
`ImageGenView` (8), `VoiceInputManager` (5), `SettingsView`/`ChatScreen` (5), `SpeechManager` (4).
Camera capture: iOS-only — hide the camera button on macOS, keep file-picker attachment
(`.fileImporter` works on both).

## Phase 2 — Mac-quality UX pass (2–3 days)
*Mirror: Odysseus `ScreenChrome.swift` + macOS conventions from its CLAUDE.md.*

- [ ] Custom themed headers via ScreenChrome (macOS `Form`/`.toolbar` overflow issues —
      Odysseus renders its own header row instead).
- [ ] Full-row hit areas: `.frame(maxWidth: .infinity).contentShape(Rectangle())`.
- [ ] `NavigationSplitView` sidebar tuned for desktop (min/ideal widths, keyboard focus).
- [ ] Keyboard: ⌘N new chat, ⌘F search, ⌘, settings (`Settings` scene), Esc closes sheets.
- [ ] Sheets sized for desktop (`.frame(minWidth:minHeight:)` — Companion `.macWindow()` trick).
- [ ] Transparency/backdrop: `VisualEffectBackground` (NSVisualEffectView) behind themes.
- [ ] Voice mode on Mac: mic input via AVAudioEngine ✓, TTS native `AVSpeechSynthesizer` ✓;
      PocketTTS/CoreML — verify FluidAudio macOS support, else hide neural option.

## Phase 3 — Parity QA vs iOS (1 day)
- [ ] Full manual pass: login gate, chat streaming, markdown/code, attachments (file picker),
      image generation + save panel (`NSSavePanel`), notes, workspace, voice, 34 languages
      (`.lproj` are target-agnostic — they ship automatically), RTL layout on macOS.
- [ ] iOS regression build: `xcodebuild -scheme OpenWebUI` must stay green after every phase
      (shared files; any `#if` mistake breaks iOS first).

## Phase 4 — Ship (½ day)
- [ ] Archive OpenWebUI-macOS → App Store Connect (adds macOS platform to the same app id,
      like Odysseus "App para macOS").
- [ ] Store assets: mac screenshots (2880×1800 or 2560×1600) — reuse the framing pipeline
      (`build_deliver.py` palette/typography) with a desktop canvas.
- [ ] `fastlane deliver --platform osx` with the same 27-locale metadata folder.
- [ ] README badge: platform `iOS 17+ · iPadOS · macOS 14+`.

---

## Ground rules (from Odysseus, non-negotiable)
1. **One source tree.** No forked files per platform; differences live behind `#if os(macOS)`
   or in PlatformCompat.
2. **iOS never breaks.** iOS scheme built after every macOS change.
3. **No Catalyst, no WebView.** AppKit-backed SwiftUI only.
4. **Sandboxed** with the minimal entitlement set above (App Store requirement).
5. Kit (`OpenWebUIKit`) stays UIKit-free — enforced today, keep it that way.

**Estimate:** ~5–7 working days to a submittable macOS build.

## Already ported from Odysseus 1.4 (done)
- ✅ Long-transfer session fix (Odysseus `9fe0712`): dedicated `longSession`
  (idle 300s / resource 7200s) for SSE chat streams, image generation, uploads,
  TTS/STT — the default 30s `timeoutIntervalForResource` was killing any
  transfer past 30s wall-clock (streams cut mid-reply, generations at 600s
  timeout could never finish).

## Follow-ups worth copying from Odysseus 1.4 later
- zh-HK as a 3rd Chinese variant (36th language).
- MultipartForm header-smuggling guard + its unit tests.
