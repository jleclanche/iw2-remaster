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

## What changed in the remaster

- `main.gd::_nearest_inhibitor()` now returns the nearest **`icLDSIRegion`**
  (queried from `entities.gd::nearest_ldsi`), never stations or bodies. This
  feeds the LDSi **fence** (`_update_ldsi_fence`), the HUD **roundel**
  (`inhibit_charge`), and the LDS-engage inhibition test (`_lds_clearance`), so
  all three agree.
- `main.gd::_lds_avoidance()` (new) is the mass break-off distance, used only in
  `_lds_process` to brake/drop the drive near a mass. It is kept out of the fence
  and the roundel. Near a planet you still cannot LDS straight in, but that is
  avoidance, not an inhibition fence.
- `entities.gd::nearest_ldsi(p)` (new) is the region query helper.

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
