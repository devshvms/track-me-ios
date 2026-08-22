# Onboarding Rebuild — iOS

*Platform slice. Cross-platform source of truth: `.ai/context/ONBOARDING_REBUILD_SPEC.md` in the workspace root, with cards in `.ai/tasks/ONBOARDING_REBUILD_TASKS.md` and ownership in `.ai/tasks/active_tasks.md`. Claim work there, not here. This file is the iOS detail, kept in-repo so it travels with the code.*

Baseline: `d0070fc`, level with `origin/master`. Deployment target 26.2.

---

## The decision

Four Remotion clips were produced for the walkthrough (`assets/onboarding_videos/` in the workspace). **None can ship as rendered** — nine measured blockers, four of them properties of the files rather than the animation. Rather than fix all four:

| `OnboardingPage` | Today | Becomes |
|---|---|---|
| `.welcome` | `WelcomeOnboardingArt` | Rebuilt clip — persona hook |
| `.ride` | `RideGestureOnboardingArt` | **4-step guided demo** |
| `.history` | `HistoryOnboardingArt` | **4-step guided demo** |
| `.together` | `TogetherOnboardingArt` | Rebuilt clip — group creation → proximity alert |

Video where the user cannot act; interaction everywhere else.

**Do not delete the art structs.** On `.welcome` and `.together` they become the reduced-motion path and the decode-failure fallback for the clip view.

---

## Prerequisite: the controls are private

This is the one blocking difference from Android. Every control the demos need already exists and is properly state-driven — but all four are `private struct` inside `HomeView.swift` and unreachable from `OnboardingView.swift`:

| Struct | Line | Init |
|---|---|---|
| `RadialStartTrackingControl` | 1344 | `@Binding var launchState: RideStartLaunchState`, `var onCommit: (RidePersona) -> Void` |
| `LiveShareActionDrawer` | 1201 | `isActive`, `isStarting`, `isAuthenticated`, `onStart`, `onStop`, `onShare`, `onCopy`, `onAuthRequired` |
| `UnifiedPauseStopSlider` | 1094 | `isPaused`, `onPauseToggle`, `onStop` |
| `ActiveRideHUD` | 853 | — |

Drop `private` (same target, so `internal` suffices) or move them to `Views/Components/RideControls/`. Mechanical, no behaviour change, but it blocks every iOS demo step. ⚠️ **`HomeView.swift` is also TASK-153's file — coordinate before claiming.**

Second extraction: `combinedChart` is a computed property inside `RideDetailView` (`Views/RideDetailView.swift:360`, Swift Charts, ~40 lines). Lift it to a standalone view taking points plus a `scrubIndex`, matching Android's `CombinedMetricLineChart` which already accepts one.

---

## Do not embed the screens

`HomeView` is 1,535 lines bound to the tracking, auth and live-share managers; `RideDetailView` loads by id. Rendering either in onboarding would boot the real system before the user has granted anything. Re-compose the controls above instead, against fabricated state.

| Step | Component |
|---|---|
| p1 1/4 pick persona | `RadialStartTrackingControl` |
| p1 2/4 start live share | `LiveShareActionDrawer` |
| p1 3/4 copy link | same, `onCopy` |
| p1 4/4 slide to stop | `UnifiedPauseStopSlider` |
| p2 1/4 open demo ride | the row from `HistoryView.swift` |
| p2 2/4 scrub | the chart extracted from `RideDetailView:360` + a `Slider` |
| p2 map surface | `RoutePreviewThumbnail(points:)` — already non-private, `Views/RoutePreviewThumbnail.swift` |
| p2 3–4/4 share + save | `ExportPreviewView(ride:snapshotImage:)` |

### Never use MapKit `Map` in onboarding

`RideDetailView:318` uses `Map(initialPosition:)`. In the walkthrough that means tile fetches on first launch, before location permission exists. `RoutePreviewThumbnail` is a pure `Canvas` route renderer with no tiles — use it for every map surface and draw the scrub marker on top.

---

## The SwiftData trap

`Ride` and `GPSPoint` are `@Model` classes (`Models/Ride.swift`, `Models/GPSPoint.swift`). They can be constructed and used entirely in memory — but **an inserted object drags its relationships in with it**. If the demo fixture ever touches the live `ModelContext`, directly or by being referenced from something that is inserted, it becomes a real ride in the user's History.

Build the fixture detached, or stand up a separate in-memory `ModelContainer` for it. **Write a test asserting the fixture never appears in a History fetch** — this is the single highest-risk item in the iOS slice, and it fails silently.

Android has no equivalent risk: `RideWithPoints` is a plain data class.

---

## Constraints that will bite

- **No callback may reach `TrackingManager` or the live-share service.** Assert it in a test.
- **Copy-link is a no-op with an explanatory toast** (spec decision D1). The user is not authenticated and there is no backend call, so a real `onCopy` writes a dead URL to the actual pasteboard. An "example" URL is no better — people paste before reading.
- **4 s inactivity auto-advance per step** (D2), plus an explicit per-step skip. Eight forced interactions across two pages is a gate, not a tour.
- **Every new string goes into `Localizable.xcstrings` for all seven languages**, in step with the Android `AppStrings.kt` additions so the platforms cannot drift.
- **Open decision D3:** `ExportPreviewView` takes a pre-rendered `snapshotImage: UIImage`. Either bundle a static preview or render `RoutePreviewThumbnail` through `ImageRenderer` at runtime. Runtime is preferred — no asset to drift from the fixture — but the cost call is the implementor's. Record the outcome in the task's discussion file.
- **HUD stats come from the fixture, not zeros.** The current clip shows a ride that has achieved nothing.

---

## The clip view (`.welcome`, `.together`)

Cheaper than Android — AVKit is on the system and the target is 26.2.

- `AVQueuePlayer` + `AVPlayerLooper` for a seamless loop.
- Wrap `AVPlayerLayer` in a `UIViewRepresentable`. **Not `VideoPlayer`** — it brings playback chrome you do not want in an onboarding card.
- Files in `Resources/`, named `onboarding_{welcome,together}_{dark,light}.mp4`.
- Select on `@Environment(\.colorScheme)`.
- Fall back to the existing art struct when `UIAccessibility.isReduceMotionEnabled`, and on any player error.
- Keep `.accessibilityHidden(true)` — meaning is carried by the localized `PageCopy` beneath, which is why stripping the burned-in text from the clips costs nothing in accessibility terms.
- The art slot must match the render's 2:1 aspect rather than a fixed height.

---

## Tasks

| ID | Title | Depends on |
|---|---|---|
| TASK-183 | Demo fixture + control extraction (**iOS-heavy**) | — |
| TASK-184 | Page 1 guided ride demo | 183 |
| TASK-185 | Page 2 guided history demo | 183 |
| TASK-186 | Re-render clips 0 and 3 (`remotion-videos`) | — |
| TASK-187 | Clip view, fallback, slot aspect | 186 |
| TASK-188 | Seed a sample ride into History on first run | 183 |
| TASK-189 | Per-page dwell + finish on an action | 184/185 |

Full acceptance criteria and verification steps are in `.ai/tasks/ONBOARDING_REBUILD_TASKS.md`.

Note for TASK-189: `OnboardingView.swift` already supports `-TrackMeOnboardingPage=N` in DEBUG to jump straight to a page — use it when iterating on the demo steps.
