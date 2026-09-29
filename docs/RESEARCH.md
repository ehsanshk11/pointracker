# Prior art

Reference product: [Glance Switch](https://glanceswitch.com/), a macOS 14+ menu
bar app that moves keyboard focus to the screen, window or split pane you face.
It uses the camera and Vision, with a ~300 ms dwell, holds focus while you type
or use the mouse (and 1.5 s after), learns from clicks, and pauses with ⇧⌘G.

We read the code of every open-source project we could find that does
something similar. We only read it: nothing was run. No project is a good base
to fork, but several have algorithms worth porting.

| Project | Stack | License | Score | Worth taking |
|---|---|---|---|---|
| [Rakesh-Raushan/loveye](https://github.com/Rakesh-Raushan/loveye) | Electron + MediaPipe, macOS | MIT | 6.5 | Challenger/dwell/hysteresis state machine, confidence gating, ridge-regression calibration with a fit-quality gate, camera release on sleep/lock |
| [Maxiatef/HeadFocus](https://github.com/Maxiatef/HeadFocus) | Python, Windows | MIT | 6 | Head + eye fusion, hysteresis relative to the gap between screens, per-screen pointer restore |
| [tschallacka/fancy-tracker](https://github.com/tschallacka/fancy-tracker) | Python + OpenCV, macOS | MIT | 4.5 | Per-monitor linear pose map, rejecting looks into the gap between monitors, calibration quality checks, warp + re-associate |
| [AquiGorka/eye-focus](https://github.com/AquiGorka/eye-focus) | Swift menu bar app | **none** | 4 | Ideas only: camera picker, activate + AX raise, permissions flow |
| [pranavkarthik10/miru](https://github.com/pranavkarthik10/miru) | Rust, Windows | none | 4 | Ideas only: midpoint + margin hysteresis, confirm then cooldown |
| [naolnegassa/gazectl](https://github.com/naolnegassa/gazectl) (fork of jnsahaj/gazectl) | Swift CLI, macOS | MIT | 3 | Vision rev3 yaw/pitch read-out. Avoid its warp-and-click focus switching |
| [UtkarshBagaria/AutoFocus](https://github.com/UtkarshBagaria/AutoFocus) | Python, Windows | none | 2 | Does not run (syntax errors) |
| [jlopez/deer-mouse](https://github.com/jlopez/deer-mouse) | Swift, macOS | none | 2 | Ideas only: k-NN gaze mapping |

Projects with no license are all-rights-reserved: we took ideas from them,
not code.

**Warning:** `Mamtamahe3975/gazectl` is a copy of gazectl whose README
download button points to an added `Software_v3.5.zip`. That is a common
malware pattern. Do not use it.

## Not covered by any project

These are what set Glance Switch apart, and we build them ourselves:

1. Focus on a window or split pane within one screen.
2. Adaptive calibration from clicks.
3. Holding focus while typing, and for 1.5 s after mouse use.
4. A global pause hotkey, with the camera stopped while paused.
