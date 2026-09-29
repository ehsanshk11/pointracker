# Pointracker

A macOS menu bar app that moves keyboard focus to the screen you are facing.
It uses the Mac's camera and Apple's Vision framework to read your head pose,
and switches focus once you have faced another screen for a moment. You don't
need to click first.

The open-source projects this design draws on are reviewed in [docs/RESEARCH.md](docs/RESEARCH.md).

## Status

This is an early version. It switches focus between screens; focusing a
window or split pane within one screen is still to do (see [Roadmap](#roadmap)).

- [x] Menu bar app, with a choice of camera (built-in, external or Continuity).
- [x] Head yaw and pitch from Vision, plus nose and pupil cues from face landmarks.
- [x] Guided calibration: 5 dots per screen and a report on how well the screens can be told apart.
- [x] Learns from clicks: each click on a calibrated screen becomes a training sample.
- [x] A 300 ms dwell, a clear lead over the current screen, and a cooldown between switches.
- [x] No switching while typing (0.6 s) or using the mouse (1.5 s).
- [x] Focuses the last-used window on the target screen through Accessibility; it never clicks.
- [x] Can bring the pointer along, back to where it last was on that screen.
- [x] **Pauses while running on battery** (on by default).
- [x] Pauses on sleep, display sleep, screen lock and user switching.
- [x] Pause or resume with **⇧⌘G** or from the menu.

## Build and run

This needs macOS 14 or later and Xcode 15 or later (or the Swift 5.9+ toolchain).

```sh
swift test               # decision-logic unit tests
scripts/bundle.sh        # builds build/Pointracker.app
open build/Pointracker.app
```

On first launch, grant:

1. **Camera**: macOS asks for this automatically.
2. **Accessibility**, under System Settings → Privacy & Security → Accessibility.
   It is needed to raise windows and to notice typing.

Then choose **Calibrate…** from the eye icon and follow the red dot with your
head, as you naturally would.

Builds signed ad-hoc get a new identity each time, so macOS may ask for
Accessibility again after a rebuild. To avoid that, build with
`SIGN_IDENTITY="Apple Development: …"`.

## How it works

```
Camera (640×480, ≤15 fps)
  → FaceTracker        Vision: yaw, pitch, face position/size, nose & pupil offsets
  → ScreenClassifier   Gaussian-weighted k-NN over calibration + click samples
  → FocusDecider       dwell, lead margin, cooldown, typing/mouse holds, face-loss grace
  → FocusController    CGWindowList (front-to-back) + AX raise/main/frontmost
```

- `Sources/PointrackerCore` holds the pure decision logic, with no AppKit or
  Vision, and is covered by unit tests.
- `Sources/Pointracker` is the app: camera, Vision, Accessibility, the power,
  lock and sleep monitors, the hotkey, calibration and the menu.

### The camera can sit anywhere

Nothing assumes the camera is centred. Calibration records how each screen
looks *from where the camera is*, so a laptop off to one side works: its
camera sees you at about 0° when you face the laptop and about 35° when you
face a monitor ahead. That gap is large and easy to classify. Face position
and size are features too, so shifting in your seat or leaning in is handled,
and clicks keep refining the model.

If a far turn takes your face out of the camera's view, a switch that was
already under way still completes (`faceLossGrace`).

### CPU and battery

- Frames are small, and Vision runs largely on the Neural Engine and GPU.
- Frames are processed at 12 fps only when a switch could happen. While you
  type or use the mouse this drops to 4 fps, just enough to learn from clicks.
- The camera is stopped entirely when paused, on battery (if enabled), when
  locked or asleep, and when fewer than two displays are connected.
- The camera light stays on while tracking. That is the nature of the
  feature, so pausing is one keystroke away.

### Privacy

Frames are analysed in memory and dropped. The only thing saved is the
calibration file,
`~/Library/Application Support/Pointracker/samples.json` (mode 0600). It holds
head angles and face positions, never images. Nothing is sent over the network.

## Roadmap

1. Check accuracy on real desks, including a side camera, three monitors and glasses.
2. **Window and split-pane focus within one screen.** This needs finer gaze
   (pupil features plus per-screen x/y regression) and per-app pane geometry
   read through Accessibility (iTerm2, Terminal, Ghostty, VS Code, Cursor,
   Xcode, JetBrains, Zed).
3. Single-display mode, once item 2 exists.
4. Settings window with dwell, holds and frame rate, plus a login item and a
   live camera preview during calibration.
