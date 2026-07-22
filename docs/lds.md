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

### The AI route-around — `icAITarget::CheckLDSAvoidance` — is INERT (#56)

There **is** a route-around subsystem in the binary, but the shipped game never
arms it, so it does nothing at runtime. The player's LDS — and the AI's — flies
**straight** past a mass, never around it. Verified conclusively:

- `icAITarget::CheckLDSAvoidance` — `iwar2.dll @ 0x1005bd87` — IS called (from
  the icAITarget flight code). Each tick it walks `icSolarSystem::LDSObstacles`
  — `0x10006730`, a `FcCompactArray<icGeography*>` at `this+0x640` — and, for the
  nearest obstacle that is ahead, nearer than the target, and whose 1.6×-radius
  shell the straight path enters, would build an auxiliary target that tangents
  the shell (`operator_new(0x70)` cData, flags `0x400`/`8`/`0x20000000`; the
  shell is `(HeatDistanceAsRadiusMultiplier 0.5 @ 0x1011af58 + 1.1 @ 0x10119e94)
  × radius`; `IsLDSAvoiding @ 0x100033b0` reports the state).
- **But that list is only ever written by `AddLDSObstacle` — `0x10006770` — and
  `AddLDSObstacle` has ZERO callers.** The 4-byte value `0x10006770` appears
  nowhere in `iwar2.dll`, `EdgeOfChaos.exe`, or any POG package — not as a
  `call`, not as a `mov`/`push` immediate, not in any vtable or data table. The
  only reference is the DLL export table (RVA `0x6770`), i.e. it is a public API
  the shipped campaign never invokes (editor/tooling, presumably). Nothing else
  touches `+0x640`, and the ctor zeroes it.
- So `LDSObstacles` is **always empty**, `CheckLDSAvoidance` iterates zero
  obstacles, and no auxiliary avoidance target is ever created. Confirmed by
  observation: from the Hoffer's Wake spawn the original autopilots **straight**
  to Griffon, never routing around the primary star.

The remaster must match this: no route-around, no mass brake, no mass dropout.
A star in the corridor is flown straight past. The only thing that stops you
short of a body is that body being your *destination* — the approach order's own
marker sphere (`InnerMarkerRadius`), handled in `_autopilot_tick`, not here.

## What changed in the remaster

- `main.gd::_nearest_inhibitor()` now returns the nearest **`icLDSIRegion`**
  (queried from `entities.gd::nearest_ldsi`), never stations or bodies. This
  feeds the LDSi **fence** (`_update_ldsi_fence`), the HUD **roundel**
  (`inhibit_charge`), and the LDS-engage inhibition test (`_lds_clearance`), so
  all three agree.
- The drive has **no mass interaction at all** — no dropout, no brake, no
  steer. `_lds_process` brakes only on the DESTINATION distance (`icLDSDrive::
  Simulate` case 2's target-relative cap `this+0x90`) and drops out only on
  region inhibition or arrival (`icLDSDrive::Simulate @ 0x10037040`). Manual LDS
  near a star re-engages cleanly and flies straight past it. Two earlier
  stand-ins are gone: an invented mass **dropout** (which wedged the drive into
  a spool/break loop, since every L-point sits inside its planet's shell —
  Alexander's is 132,000 km deep), and an invented mass **brake + route-around**
  (which, near a huge primary like Hoffer's Wake Alpha, shell 2.8e8 km, crawled
  the drive to a stop and swung the autopilot on a giant detour — reported as
  "rotated around HWA, LDS stuck at 2 km/s"). Both were absent from the original.
- The autopilot (`_autopilot_tick`) faces the destination directly and engages
  LDS once the nose is on it — no waypoint steering. `main.gd::_lds_avoidance()`
  survives only as a diagnostic metric the demo autoplay reads; it feeds nothing
  in the flight path.
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
