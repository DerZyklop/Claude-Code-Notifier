# Plan: "Outputs" tab in the setup window

## Context
Today the mapping of signals to keyboard LEDs is hard-coded in `KeyboardLight.Zone`. Each change needs a chat and a code edit. The menu also gets crowded. The user wants a new tab in the setup window. In it, they turn each output on or off, choose the LED areas and the brightness of each keyboard signal, and preview each signal with a simulate toggle. The values must stay after a rebuild and a restart.

Note: the working tree has uncommitted changes (KeyboardLight, NuPhyKeyboard, Report, SessionStore, tests). The plan builds on top of them.

## Decisions (from the user)
- Simulate toggles only on the 4 keyboard signals. They show on the blink(1) and on the keyboard. Push gets "Send Test", sound gets "Play".
- Overlap: fixed order per LED. Red ring > waiting > summary not opened > work state. A lower signal shows again when a higher one has no frame.
- Move "Show Notifications", "When It Is Your Turn" and "Play Sounds" out of the menu. "Send Test" also moves (the tab has it). The menu keeps the cards, the reports, Launch at Login, "Setup …" and Quit.

## Settings (UserDefaults, bundle ID `local.claude-code-notifier.app` stays fixed, so values survive rebuild and restart)
| Key | Type | Default |
|---|---|---|
| `usesBlink1` (new) | Bool | true |
| `muted` (existing, shown inverted as "Push Notifications") | Bool | false |
| `notifyOnDone` (existing, sub-toggle under push) | Bool | true |
| `playsSound` (existing) | Bool | true |
| `usesKeyboard` (new) | Bool | true |
| `keyboard.<signal>.areas` | [String] | see below |
| `keyboard.<signal>.brightness` | Double 0…1 | see below |

Only non-default values are stored, like `StatusMenu.toggleSetting`. Add the new Bool keys to `SettingsKey.defaultValues` in [SessionStore.swift](Sources/SessionStore.swift).

Defaults reproduce today's look:
| Signal | Areas | Brightness |
|---|---|---|
| work state (wave) | First two rows | 0.6 segment, dim = 0.2 × segment |
| waiting (orange) | Top-right 3 keys | full |
| red ring | Left + Right side LED | full |
| summary not opened (purple) | Left side LED + Top-right 3 keys | full |

## Code changes

1. **New file `Sources/KeyboardMapping.swift`**
   - `enum KeyArea: String, CaseIterable` — `firstTwoRows`, `topRightThree`, `leftSide`, `rightSide`, `allKeys`, `rightColumn`. Each has a title and `leds: [Int]`.
   - `enum KeySignal: CaseIterable` — `work`, `waiting`, `ring`, `unread`, in priority order (`ring` first). Each has title, default areas, default brightness, settings keys.
   - `struct KeyboardMapping` — reads/writes areas and brightness for each signal from a `UserDefaults` (testable with `MemoryDefaults`).
2. **[NuPhyKeyboard.swift](Sources/NuPhyKeyboard.swift)**: add the full key layout. Fetch `rgb_matrix.layout` of `nuphy/air75_v2/ansi/keyboard.json` from qmk_firmware. From it, derive `keyCount` (key LEDs), the first LED of each row, the right-most LED of each row, and `keyX` for all keys (scaled to today's 0…160 units). Side LEDs get x = 0 (left bar) and x = right end (right bar).
3. **[KeyboardLight.swift](Sources/KeyboardLight.swift)**:
   - Replace `Zone` with the mapping. `Scene` gets `wave`, `isWaiting`, `hasUnread` (separate, no longer one `Badge`), `ringStart`.
   - Per LED: walk `KeySignal` in priority order. Use the first signal that covers the LED and has a frame now.
   - Brightness = signal value × `fullBrightness`. Cap at 1.0 (NuPhy limit) for a signal that covers more than 12 LEDs, because all keys at full power need too much USB current.
   - `ring()` keeps working while waiting is on. Re-render when the mapping changes (observe `UserDefaults.didChangeNotification` or a call from the tab).
   - Skip all output and call `clear()` while `usesKeyboard` is off.
4. **[Blink1.swift](Sources/Blink1.swift)**: while `usesBlink1` is off, `turnOff()` and ignore `show`, `ring`, `pulse`. Turned on again → show the current state.
5. **New `LightSimulation` (ObservableObject, in memory only)** — `work: Blink1.Wave` (Off/Work/Summary), `waiting`, `ring`, `unread`. 
   - [StatusMenu.swift](Sources/StatusMenu.swift) `updateIcon()` merges it with the real state before it calls `Blink1.shared.show` and `KeyboardLight.shared.show`: sim wave wins if not `.off`; waiting and unread are OR.
   - `ring` runs its own timer at `AttentionBubble.ringInterval` and calls `Blink1.shared.ring()` + `KeyboardLight.shared.ring()`. Simulated ring also sets waiting for the blink(1), so its LED 1 has the orange rest color.
   - `stopAll()` resets everything and triggers an icon update.
6. **[HookSetup.swift](Sources/HookSetup.swift) `SetupWindow` / `SetupView`**:
   - Wrap in a `TabView` with tabs "Hooks" (today's content) and "Outputs" (new `OutputsView`).
   - `SetupWindow.show(tab:)`. Rename the window title to "Claude Code Pulse Setup" (keep).
   - Stop the simulation on tab change (`onChange` of the selection) and on close (window delegate `windowWillClose` + `.onDisappear`).
   - Move the "Send a test notification" row to the Outputs tab.
7. **New `OutputsView`** (own file `Sources/OutputsView.swift`), a `Form`:
   - blink(1) [toggle]
   - Push Notifications [toggle] [Send Test ▾] — sub-toggle "When It Is Your Turn"
   - Sound [toggle] [Play] (plays the chime through `AttentionBubble`'s sound code, made static/internal)
   - Keyboard [toggle] — then for each of the 4 signals: title, simulate toggle (work state: segmented Off/Work/Summary), multi-select menu of `KeyArea` (a `Menu` with a checkmark `Toggle` per area, label lists the chosen areas), brightness `Slider`. Disabled while Keyboard is off.
8. **[StatusMenu.swift](Sources/StatusMenu.swift)**: remove the Notifications and Sounds sections. Rename "Hook Setup …" to "Setup …".

## Tests
- Update [KeyboardLightTests.swift](Tests/KeyboardLightTests.swift): replace the `Zone` tests with area LED tests (no overlap inside one area, `allKeys` = all key LEDs, `rightColumn` has one LED per row) and priority tests (ring over waiting over unread over wave; lower signal shows when ring rests).
- New `KeyboardMappingTests`: defaults, stored only when changed, round trip through `MemoryDefaults`.
- Brightness cap test for `allKeys`.
- `StatusMenuTests`: adjust if they count menu items.

## Verification
- `npm run test`.
- `npm start`, open "Setup …" → Outputs tab. Toggle each simulation; watch the keyboard and the blink(1). Change areas and brightness; the keyboard follows at once.
- Switch to the Hooks tab and close the window: the simulation stops.
- `npm run restart` and a rebuild: the chosen values stay.
- Lint: no ESLint in this Swift project, so not needed.


## Additinoal notes for this plan after it was created

Besides the option to turn sounds on and off, there should be a third option that says, off as long as an led device is connected.
