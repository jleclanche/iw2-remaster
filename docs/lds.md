# LDS: inhibition vs. avoidance

Two different mechanisms that our `main.gd` had merged into one
`_nearest_inhibitor()` that treated every station as a 25 km inhibitor and every
body as a radius-scaled one. Both of those were our invention. Recovered from
`iwar2.dll` (it kept its C++ symbols).

## LDS INHIBITION — what actually STOPS the drive (region-based)

Inhibition is **purely region-based**. It is not a property of a station or a
body; it is a spatial zone the mission scripts author.

- Each ship (`iiThrusterSim`, the base of `icShip`) carries a one-byte inhibit
  **counter** at `+0x251`.
  - `iiThrusterSim::IsLDSInhibited` — `iwar2.dll @ 0x100023c0` — returns
    `this[0x251] != 0`.
  - `iiThrusterSim::EnterLDSInhibitRegion` — `iwar2.dll @ 0x1007e450` — does
    `this[0x251] += 1`; the first bump also logs event 0x2c and stashes the
    region pointer on the player pilot at `icPlayerPilot+0xb8`.
  - `iiThrusterSim::LeaveLDSInhibitRegion` — `iwar2.dll @ 0x1007e4a0` — does
    `this[0x251] -= 1`; back to zero logs event 0x2d and clears `+0xb8`.
- The counter is changed **only** by an `icLDSIRegion`:
  - `icLDSIRegion::OnSimEnter` — `iwar2.dll @ 0x10048680` — calls
    `EnterLDSInhibitRegion`.
  - `icLDSIRegion::OnSimLeave` — `iwar2.dll @ 0x10048690` — calls
    `LeaveLDSInhibitRegion`.
- An `icLDSIRegion` is a **centre + radius sphere**. Its constructor
  `icLDSIRegion(FcGenericVector<double> centre, float radius)` —
  `iwar2.dll @ 0x10048870` — forwards to `iiRegion(centre, radius)`. The centre
  and radius are **authored by the scripts** (`iRegion.CreateLDSI`); there is no
  other construction path. `icPlayerPilot::LDSIRegion` — `0x10005480` — reads
  back the region the player is currently inside.
- The drive enforces it: `icLDSDrive::Simulate` — `iwar2.dll @ 0x10037040` —
  calls `BreakShipOutOfLDS` whenever the owning ship's `+0x251` counter is
  non-zero (the branch at `0x37040` reading `Ship()[0x251]`).

**Traffic-control regions inhibit too.** `icTrafficControlRegion` derives from
`icLDSIRegion` (`icTrafficControlRegion(centre, radius, speed)` @ `0x1004f6e0`
chains the `icLDSIRegion` ctor). Its `OnSimEnter` — `iwar2.dll @ 0x1004f3e0` —
calls **both** `EnterSpeedLimitRegion` (the throttle cap at `+0x48`) **and**
`EnterLDSInhibitRegion`. So an approach lane authored with
`iRegion.CreateTrafficControl` caps speed *and* inhibits LDS in the original.
The remaster currently models `"traffic"` regions as a speed cap only
(`entities.gd::_region_tick`); the fence and inhibition query are scoped to
`kind == "ldsi"`. Promoting traffic regions to inhibitors is a faithful future
refinement, deliberately left out here to keep the fence scoped to the
`CreateLDSI` zones the bug report is about.

**Bodies do NOT inhibit LDS.** There is no intrinsic per-body/per-station LDSI
shell anywhere in the binary — the only thing that touches `+0x251` is an
`icLDSIRegion`, and the only thing that builds one is a script. The prior note
that "body LDSI = thin shell near the surface" was our invention and has been
removed.

## LDS AVOIDANCE — what keeps you from flying INTO a mass (mass-based)

Avoidance is a **separate, mass-derived break-off distance**. It is not a fence
and it does not set the inhibit counter. It is the marker sphere the autopilot /
LDS cruise flies to and stops on, derived from the *target's* mass — which is why
a fighter breaks off at ~300 m, a station at a km or two, a planet thousands of
km out.

- `icAIServices::InnerMarkerRadius` — `iwar2.dll @ 0x100560d0` — the break-off
  sphere. A planet/star stands off at `(m_heat_radius_multiplier + 1.0) x radius`
  with `m_heat_radius_multiplier = 0.5` (`0x1011af58`), i.e. **1.5x** the radius;
  everything else at its own bounds radius; plus ~200 m clear space
  (`0x10119470`), or the avoidance-function radius if larger.
  (Mirrored in `world.gd::inner_marker_radius`.)
- The manual `icLDSDrive` itself has **no** mass-proximity spool gate — the only
  thing it checks is the inhibit counter. Avoidance lives in the AI/autopilot and
  in the cruise brake, not in the drive's engage test.

### The AI route-around — `icAITarget::CheckLDSAvoidance` — is ARMED (#56)

The route-around is real and armed. An earlier revision of this section declared
it inert because `AddLDSObstacle` has no call sites; that inference was WRONG —
the compiler **inlined** the append at every populate site (the identical
grow-and-store on `+0x640/+0x644/+0x648` appears verbatim inside them), which is
why `0x10006770` itself is referenced only by the export table. The corrected
extraction:

- `icAITarget::CheckLDSAvoidance` — `iwar2.dll @ 0x1005bd87` — is called from
  `ComputeLateralLDSControl` (`0x1005d911`) each LDS control tick (when no aux
  avoidance target is already set, flag `0x80`). It walks
  `icSolarSystem::LDSObstacles` — accessor `0x10006730`, a
  `FcCompactArray<icGeography*>` at `this+0x640` — and, for the nearest obstacle
  that is ahead, nearer than the target, and whose 1.6×-radius shell the
  straight path enters, builds an auxiliary target that tangents the shell
  (`operator_new(0x70)` cData, flags `0x400`/`8`/`0x20000000`; the shell is
  `(HeatDistanceAsRadiusMultiplier 0.5 @ 0x1011af58 + 1.1 @ 0x10119e94) ×
  radius`; `IsLDSAvoiding @ 0x100033b0` reports the state).
- The list is populated at map parse, by three appends and nothing else:
  * every **sun** — `ParseSunInfo @ 0x1004e5a0`;
  * every **body of `IeBodyType` 1..6** — `ParseBodyInfo @ 0x1004e040`
    (`1 << type & 0x7e`, excluding the type-0 system-centre/marker records);
  * every **station with scene `0x1c` = 28** — `ParseLocationInfo @ 0x1004e0a0`
    — which in the shipped maps is exactly **Lucrecia's Base** (its three
    per-system instances and nothing else).
  L-points, belts, nebulae and ordinary stations are **not** LDS obstacles.
- The radius the check reads is the LIVE `FiSim::Radius`, and for suns that is
  **1e8 m** — `icSolarSystem::AddSim` (`0x1004cbe0`) forces `SetRadius(1e8)` on
  every sun it admits, discarding the authored map value (docs/geography.md) —
  so a sun's avoidance shell is **1.6e8 m** (160,000 km), not the 2.8e11 m
  Alpha's file radius implies. That is why the original from the Hoffer's Wake
  spawn flies effectively straight to Griffon (Alpha's shell is tiny at system
  scale) yet visibly routes around the sun when the selected destination sits
  behind it.

The remaster matches this: `_load_system` stamps `lds_obstacle` per the three
parse-time appends, `_lds_avoid_waypoint` (main_targeting.gd) walks flagged
records and grazes the 1.6× shell; there is still no mass brake and no mass
dropout. What stops you short of a body is that body being your *destination* —
the approach order's marker sphere (`InnerMarkerRadius`), handled in
`_autopilot_tick`, not here.

## What changed in the remaster

- `main.gd::_nearest_inhibitor()` now returns the nearest **`icLDSIRegion`**
  (queried from `entities.gd::nearest_ldsi`), never stations or bodies. This
  feeds the LDSi **fence** (`_update_ldsi_fence`), the HUD **roundel**
  (`inhibit_charge`), and the LDS-engage inhibition test (`_lds_clearance`), so
  all three agree.
- The **drive** has no mass interaction — no dropout, no brake. `_lds_process`
  brakes only on the DESTINATION distance (`icLDSDrive::Simulate` case 2's
  target-relative cap `this+0x90`) and drops out only on region inhibition or
  arrival (`icLDSDrive::Simulate @ 0x10037040`). Manual LDS near a star
  re-engages cleanly. Two earlier stand-ins are gone: an invented mass
  **dropout** (which wedged the drive into a spool/break loop, since every
  L-point sits inside its planet's shell — Alexander's is 132,000 km deep), and
  an invented mass **brake** plus a route-around keyed to the AUTHORED radii
  (which, against Alpha's file value 1.75e11 — shell 2.8e8 km — crawled the
  drive to a stop and swung the autopilot on a giant detour; reported as
  "rotated around HWA, LDS stuck at 2 km/s"). The real radii story is the 1e8
  AddSim override above.
- The autopilot (`_autopilot_tick`) steers at `_lds_avoid_waypoint(p)` — the
  raw destination unless a flagged obstacle's 1.6×-radius shell blocks the
  corridor — and engages LDS once the nose is on that steer heading.
  `main.gd::_lds_avoidance()` survives only as a diagnostic metric the demo
  autoplay reads; it feeds nothing in the flight path.
- `entities.gd::nearest_ldsi(p)` (new) is the region query helper.

## The render fold at LDS magnitudes (issue #51)

The world fold is **post-integration**. `icClient::Tick @ 0x100b39c0` runs the
sim Thinks first, then `FcClient::Tick` integrates the world and rebases the
render focus — `FcWorld+0x38` is the focus position, and the per-frame rebase
delta is `GraphicsDeltaFocus` (`FcWorld+0x50..0x58`, the same displacement
`iiSimField::Think` tests and `icTeleportDynamics::Update` adds to every dust
mote). So the original renders every frame with the focus at the origin.

The remaster's fold (`main._fold_motion`) originally ran inside
`main._physics_process`, **before** `ShipFlight` integrated — leaving the
rendered ship a full tick's travel from the fold origin. At drive speeds that
is metres; at the LDS ceiling (`lds_class1.ini max_speed = 3e10`, the authored
"frigged" value) it is **5e8 m per 60 Hz tick**, where a float32 ULP is ~32 m:
the ship/camera/world relation quantized per frame (the reported on-screen
teleporting), every `px/py/pz`-anchored draw (grid, fence, impostors, streamed
objects) sat 5e8 m astern of the hull, and dropping out collapsed that offset
in one frame (the reported "snap back"). `px/py/pz` itself always advanced
correctly — measured 1.48e11 m over an 18 s probe cruise, before and after.

The fix moves `_fold_motion` + `_stream_objects` + the grid/fence updates into
`main.late_physics` (the CameraTail hook, after integration, before the
camera), matching the engine's order. `mechcheck` asserts it:
`lds-render-origin` requires the folded ship at the origin during cruise, and
FAILS at `off = v * dt` (measured 2e9 m at 4x time scale) under the old
ordering.

## For original.md

LDS inhibition (`icLDSIRegion`, `iRegion.CreateLDSI`) and LDS avoidance
(`icAIServices::InnerMarkerRadius`) are distinct systems. Inhibition is a
script-authored centre+radius sphere that increments a per-ship counter at
`iiThrusterSim+0x251` on entry (`EnterLDSInhibitRegion @ 0x1007e450`) and
decrements it on exit; `icLDSDrive::Simulate @ 0x10037040` breaks any ship out
of LDS while that counter is non-zero. Stations and bodies do not inhibit LDS.
Traffic-control lanes do (`icTrafficControlRegion::OnSimEnter @ 0x1004f3e0`
chains `EnterLDSInhibitRegion`). Avoidance is the mass-derived break-off marker
(`InnerMarkerRadius @ 0x100560d0`, planets/stars at 1.5x radius + 200 m) the
autopilot and LDS cruise stand off from; the drive has no mass gate of its own.
