# The controls

The original's keymap, recovered from the game's own configuration, and the
yoke behind it, recovered from `iwar2.dll`. Same rules as `original.md`:
nothing here without a source.

The action names are the engine's, because the scripts use them: POG calls
`input.KeyCombinations("icPlayerPilot.CycleContactUp")` to render a key into a
tutorial prompt. `docs/original.md` used to carry "the original keymap" as an
open question. It is not one: the keymap ships with the game.

---

## Where it comes from

The install has **two** binding sets, and they are complete:

| file | `[Properties] name` | what it is |
|---|---|---|
| `configs/default.ini` | `options_default` | "I-War II **recommended** input bindings" -- assumes a joystick |
| `configs/keyboard_only.ini` | `options_keysonly` | "bindings for users **without joysticks**" |

`default.ini` binds **no keyboard key to yaw, pitch or roll at all** -- it
expects a stick. Every keyboard flight binding below therefore comes from
`keyboard_only.ini`, which is the one a modern player is actually flying.

A binding line is `Device, Control[, inverse][, SHIFT|ALT]`. `inverse` is the
negative half of an axis: `[icPlayerPilot.ThrottleDelta] Equals` / `Minus,
inverse` is "`=` speeds up, `-` slows down".

---

## Flight

|  | keyboard (`keyboard_only.ini`) | joystick (`default.ini`) |
|---|---|---|
| `icPlayerPilot.Yaw` | **NumPad4** / **NumPad6** | JoyXAxis |
| `icPlayerPilot.Pitch` | **NumPad2** / **NumPad8** | JoyYAxis, `inverse` |
| `icPlayerPilot.Roll` | **NumPad1** / **NumPad3** | JoyRZAxis (twist) |
| `icPlayerPilot.RollYawToggleHold` | -- (unbound) | JoyButton2 |
| `icPlayerPilot.LateralX` | **A** / **D** | JoyXAxis + ALT |
| `icPlayerPilot.LateralY` | -- (unbound) | JoyYAxis + ALT |
| `icPlayerPilot.LateralZ` | **S** / **W** | JoyButton8 / JoyButton7 |
| `icPlayerPilot.Throttle` | -- | JoyZAxis / JoyUAxis, `inverse` |
| `icPlayerPilot.ThrottleDelta` | **-** / **=** (and NumPad) | -- |
| `icPlayerPilot.FreeHold` | **LeftControl**, **NumPad5** | -- |
| `icPlayerPilot.FreeToggle` | **N** | -- |

**WASD is the thrusters, not the stick.** That is the single biggest thing
about IW2's controls and the thing a modern port gets wrong: you *steer* on the
numpad and *strafe* on WASD. `LateralZ` (W/S) is fore-aft **thrust**, which is
not the same as the throttle: the throttle is a set-speed wheel the flight
computer flies to, and W/S push directly.

**Vertical strafe has no keyboard binding.** `LateralY` is joystick-only in both
shipped configs. We leave it unbound rather than invent a key.

### The yoke

`icPlayerPilot::RegisterInputs` (`iwar2 @ 0x100aea00`) gives the axes their
message ids -- Roll 0, Pitch 1, Yaw 2, Throttle 3, ThrottleDelta 4, LateralX 5,
LateralY 6, LateralZ 7 -- and `icPlayerPilot::HandleLinearMessage`
(`0x100ae2b0`) is what they do:

```
scale = (zoom <= 0) ? 1 : 1/zoom          ; zoom is icPlayerPilot+0xa0

Roll  (0): swapped ? yoke.yaw  = scale*v : yoke.roll = v
Pitch (1):            yoke.pitch = scale*v
Yaw   (2): swapped ? yoke.roll = v       : yoke.yaw  = scale*v
Throttle      (3): throttle = (v + 1) * 0.5           ; absolute axis -> 0..1
ThrottleDelta (4): throttle += v * dt * 0.3333, clamped [0,1]
LateralX/Y/Z (5,6,7): straight through
```

Three things fall out of that:

- **`RollYawToggleHold` swaps yaw and roll.** Hold it and the stick's X axis
  rolls the ship instead of yawing it. `swapped` is
  `m_toggle_roll_yaw || button_held`, and `flux.ini [icPlayerPilot]
  toggle_roll_yaw = 0` -- so out of the box it is a **hold**, not a permanent
  swap. This is the "different controls for rolls and yaw" the game is
  remembered for.
- **The throttle is a FRACTION of top speed, and it is rate-limited.** `+-1/3`
  per second (the float at `0x10119454`), so a full sweep takes **three
  seconds**.
- **Zoom divides yaw and pitch but not roll**, which is what makes a zoomed-in
  shot aimable. `flux.ini [icPlayerPilot] max_zoom_factor = 10, zoom_time =
  0.5`, and `icPlayerPilot::Simulate` ramps the factor at `max/time` per second.

`icEuler` is **(yaw, pitch, roll)** -- `icAITarget::AngularVelocityToEuler`
(`0x1005df5c`) is literally `icEuler(w.y, w.x, -w.z)`. That is how the three
yoke slots above are identified.

---

## Cameras

`icDirector::RegisterCommands` (`0x100d8cc0`) registers InternalCamera 0,
TacticalCamera 1, ExternalCamera 2, DropCamera 3, DevCycleAllCameras 4.

| key | action |
|---|---|
| **F1** | `icDirector.InternalCamera` |
| **F2** | `icDirector.TacticalCamera` |
| **F3** | `icDirector.ExternalCamera` |
| **F4** | `icDirector.DropCamera` |
| **F11** | `icDirector.AutoMode` |
| **F12** | `fcGraphicsDeviceD3D.TakeScreenShot` |

### F1 really does cycle the cockpit away

The director's constructor (`0x100d5e20`) builds **five camera groups**, and
`icDirector::OnMessage` (`0x100d6920`) cycles them: pressing a camera key while
you are **outside** its group jumps to that group's **first** camera; pressing it
while you are **inside** the group steps to the **next** camera in it, wrapping.

The groups, by `icDirector::eCamera` index (the name table is at `0x101621e0`):

```
0  cam_none              8  cam_tactical            16 cam_contact
1  cam_internal_cockpit  9  cam_inverse_tactical    17 cam_bridge_shot
2  cam_internal_no_cockpit  10 cam_flyby            18 cam_target_bridge_shot
3  cam_internal_no_hud   11 cam_drop                19 cam_dolly
4  cam_chase             12 cam_distantdrop         20 cam_tactical_no_hud
5  cam_arcade            13 cam_two_shot            21 cam_distant_bridge_shot
6  cam_external          14 cam_inverse_two_shot    22 cam_orbit
7  cam_target_external   15 cam_conversation        23 cam_wide_angle_orbit
```

| key | group |
|---|---|
| F1 | `cam_internal_cockpit` -> `cam_internal_no_cockpit` -> `cam_arcade` |
| F2 | `cam_tactical` -> `cam_inverse_tactical` |
| F3 | `cam_external` -> `cam_target_external` |
| F4 | `cam_drop` |

So **F1 is the "turn the cockpit off" key** -- it was never a separate option.
`cam_internal_no_hud` exists but sits only in the developers'
`DevCycleAllCameras` group, which ships bound to nothing.

FOVs (`flux.ini` / `defaults.ini`, radians): internal 1.1, tactical 1.2, arcade
1.2, external 1.25, drop 1.1, chase 1.2.

**Every external camera range is authored in SHIP RADII**, against
`iiSim::CalculateRadius` (`0x1007ccf0`, sqrt((w²+h²+l²)·0.25)):
`[icArcadeCamera] range = 4`, `[icChaseCamera]`/`[icDollyCamera]`
`initial_range = 4` (min 2, max 10), `[icExternalCamera]` `initial_zoom = 3`
(zoom 1..150). The tug (radius 80.2 m) frames at 320 m where the turret
fighter (12.9 m) frames at 52 m. `_chase_camera` scales its offsets by
`ship.radius` accordingly -- fixed-metre offsets put the camera inside the
tug's silhouette.

### Pressing a camera key again -- and why F4 "resets"

`OnMessage`'s cycle always hands the chosen camera to `icDirector::ChangeCamera`
(`0x100d7350`), **even when it is the camera you are already on**. `ChangeCamera`
guards against that with a same-id branch at `0x100d7358`:

```
0x100d7358  cmp [esi+0x2b0], edi    ; already on this camera?
0x100d735e  jne commit
0x100d7360  cmp edi, 0xb            ; SAME id -- is it cam_drop (0xb)?
0x100d7363  jne return              ; SAME and != 0xb  -> no-op
                                    ; SAME and == 0xb  -> fall through, re-commit
0x100d739c  mov [esi+0x2b8], 2      ; CameraChanged = 2  (force re-frame)
```

So re-pressing a camera key is a **no-op for every camera except the drop camera
(`0xb`)**, which alone re-commits and raises `CameraChanged = 2`, making the drop
camera re-establish its default framing from the ship's transform. In practice
only **F4** ever lands back on itself -- its group has one member -- so **F4 is
the one key whose repeat press does something: it re-drops the camera** (a
recentre). F1/F2/F3 always step to a *different* camera in their group, so every
one of their presses is already a real change and never hits the no-op path.

The remaster mirrors this in `main._set_camera`: a repeat F4 re-anchors
`drop_cam_pos` behind the ship instead of leaving the frozen drop camera where it
was. (`configs/default.ini` binds F1..F4 to
`icDirector.InternalCamera/TacticalCamera/ExternalCamera/DropCamera`; there is no
per-camera recentre tunable -- the reset is code-driven.)

---

## Everything else, verbatim from `default.ini`

| action | key |
|---|---|
| `CurrentWeaponFire` | Space (JoyButton1) |
| `NextWeapon` / `NextPrimaryWeapon` / `NextSecondaryWeapon` | `]` / Return / Backspace |
| `ToggleWeaponLinkingMode` | F |
| `ToggleAimAssist` | X |
| `ToggleZoom` | Z |
| `LDSIQuickFire` | I |
| `ToggleLDS` | L |
| `Undock` | U |
| `CycleContactUp` / `CycleContactDown` | `,` / `.` |
| `CycleContactTop` / `CycleContactBottom` | Home / End |
| `TargetNearestEnemy` | R |
| `TargetNearestShipToDirection` | T |
| `TargetLastAggressor` | Q |
| `SubTarget` | Y |
| `CycleEnemy` | E |
| `CycleCritical` | C |
| `RemotePilot` | Shift+R |
| `AutopilotOff` / `Approach` / `Formate` / `Dock` / `MatchVelocity` | **F5 / F6 / F7 / F8 / F9** |
| `PowerToOffensive` / `Defensive` / `Drive` / `Balance` | Shift + Left / Right / Down / Up |
| `HUD.Objectives` / `Starmap` / `Log` / `Engineering` / `Statistics` | Shift + O / M / L / E / S |
| `HUD.Menu*` | arrows, Return, Backspace |
| `SpaceFlight.PDA` | Escape |
| `SpaceFlight.Pause` / `Game.PauseSimulation` | Pause, P |
| `Game.MovieSkip` | Space, Escape, Return |
| `ScriptKeys.SkipCutscene` | Space |
| `ScriptKeys.Wingmen*` | 1..6 |
| `ScriptKeys.TFighter*` | 0, 7, 8, 9 |
| `icComms.PrevResponse` / `NextResponse` / `SayResponse` / `SkipPhrase` | Up / Down / Space or Return / Delete |

The autopilot mode enum is confirmed by `icPlayerPilot::SetAutopilot`
(`0x100af930`): **0 Off, 1 Formate, 2 Approach, 3 Dock, 4 MatchVelocity, 6
RemotePilot**. Note it is *not* the F5..F9 order.

---

## Where we differ, and why

| we do | the original did | why |
|---|---|---|
| The mouse is a yoke: X yaws, Y pitches, right button is `RollYawToggleHold`, and the zoom factor divides it | Bound **no** mouse axis to the pilot at all -- the mouse is the director's camera, and flight is stick or numpad | A 2001 game could assume a joystick. The mouse carries the real yoke's two behaviours (the zoom divisor and the roll/yaw swap) so it is the same control, on a different device. |
| `LateralY` unbound on the keyboard | the same | Neither shipped config binds it. We will not invent a key. |
| No `RollYawToggleHold` key | Joystick button 2 only | Same reason; it is on the right mouse button instead. |

---

## What the engineering, zoom and weapon keys actually do

All three are implemented now (tasks #60 / #62 / #63). The mechanics are in
`docs/combat.md`; this is the player-facing half.

### Shift + arrows: the TRI

`icPlayerPilot::DistributePower` (`0x100b00d0`) is a straight
`iiShipSystem::SetTRIPosition` plus a log line, and the four corners line up with
the triangle on the engineering screen:

| key | corner | log line |
|---|---|---|
| **Shift+Left** | full OFFENSIVE (top-left node) | "TRI: FULL POWER TO WEAPONS" |
| **Shift+Right** | full DEFENSIVE (top-right node) | "TRI: FULL POWER TO SHIELDS" |
| **Shift+Down** | full DRIVE (bottom apex) | "TRI: FULL POWER TO ENGINES" |
| **Shift+Up** | balanced (centre) | "TRI: POWER BALANCED" |

The weight an axis hands its subsims runs **0.5 (empty) -> 1.0 (balanced) -> 1.5
(full)**, so the swing between corners is real:

- **offensive** -- 1.5x bolt damage, 1.5x range, refire delay divided by 1.5
  (a 2.25x DPS swing end to end)
- **drive** -- 1.5x linear *and* angular acceleration, and the LDS spools in 2/3
  the time
- **defensive** -- the aggressor shield recharges 1.5x as fast and rams 1.5x as
  hard. (It is the *only* thing on that axis: the LDA deflection shields are not
  on the TRI at all -- see `combat.md`.)

The engineering screen (Shift+E, then Left/Right on rows 1-3, Enter on RESET TRI)
writes the same live value; the bars and the four keys are two views of one
number. The TRI is **player-only**: every AI ship flies at a flat weight of 1.0.

### Z: the zoom is gated on hardware

`icPlayerPilot::EnableZoom` (`0x100b0e80`) will only engage the zoom if the ship
has **a working CPU carrying the imaging module** (program bit 8192) **or a
sniper weapon selected** (the `sniper_zoom` INI flag -- only the long-range
'Sniper' PBC has it). Otherwise it refuses and says why, on the HUD:

| refusal | when |
|---|---|
| `ERROR: IMAGING MODULE NOT INSTALLED` | CPU fitted, no imaging module (**the stock tug**) |
| `ERROR: COMPUTER OFFLINE` | the CPU is destroyed or unpowered |
| `ERROR: NO COMPUTER FITTED` | no CPU at all |
| `WEAPON DAMAGED` | you have the sniper gun, but it is dead |

`icPlayerPilot::Think` re-tests this **every frame**: shoot a zoomed pilot's CPU
out and the view snaps back on its own. Zooming in ramps to 10x over ~0.45 s;
zooming out is instantaneous. While zoomed, pitch and yaw are divided by the zoom
factor (roll is not) -- that is the point of it.

**On the stock tug this means Z does nothing but complain**, which is exactly
what the original does to a fresh pilot: you *buy* the zoom in IW2. We have not
ported the cargo/fitting screen, so `main.gd`'s `GRANT_IMAGING_MODULE` (default
`false`) is the one switch that hands it to you.

### Return / Backspace / `]`: weapon cycling

- **Return** = `NextPrimaryWeapon`. If you are holding a *secondary*, it just
  drops you back to your primary; if you already hold a primary, it advances to
  the next one. With **one** primary and nothing to switch to it does nothing --
  because that is what the engine's loop does (it wraps onto the entry it started
  from and accepts it).
- **Backspace** = `NextSecondaryWeapon`, the ring of fitted magazines.
- **`]`** = `NextWeapon`, which ignores the channel: primaries first, then
  secondaries.

A weapon **link** is one entry in the cycle, not one per gun -- the tug's two
PBCs are a single "PBC x2" selection that fires as a pair.

**Sound.** The original plays *nothing at all* here (`icPlayerPilot` contains no
sound call). We used to play the pause menu's click, which is why it sounded like
clicking Resume. It now plays the engine's own HUD cues -- `audio/hud/valid_input`
when the selection really moves, `audio/hud/invalid_input` when there is nowhere
to move to -- which is the idiom the HUD itself uses everywhere else.
