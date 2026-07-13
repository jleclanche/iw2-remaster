# The combat and damage model

Recovered from `iwar2.dll` (GOG build, image base `0x10000000`) and from the
shipped INI tree. Every number below is either a float read out of the PE or a
value in a data file; where the original could not be recovered it says so.

Companion to `original.md`, which carries the one-paragraph summary. This is the
long version, with the disassembly.

---

## 1. The chain

A weapon impact runs five stages. Nothing else in the game damages a ship
except the raw hull path in stage 4 (collisions, heat, script damage).

```
icBullet::OnCollision       0x100630c0   bolt ages out its damage
  |
icShip::ApplyWeaponDamage   0x10073cf0   LDA may deflect the whole bolt
  |
iiSim::ApplyWeaponDamage    0x100796a0   armour divides what is left
  |
iiSim::ApplyDamage          0x10079920   the hull takes it; 0 hp -> Kill()
  |
icShip::ApplyWeaponDamage   0x10074100   N subsims take a cut of what landed
```

`icShip::ApplyWeaponDamage`'s signature (from the mangled name at `0x73cf0`,
ordinal 519):

```cpp
virtual float const icShip::ApplyWeaponDamage(
    float damage, float penetration,
    FcGenericVector<double> const& hit_pos,   // world
    FcGenericVector<float>  const& hit_dir,
    iiSim const& projectile,
    unsigned int aggressor_id,
    iiSim::eDamageSource src)
```

It returns the damage that actually reached the hull.

---

## 2. Damage falloff over the bolt's flight (`half_time`)

`icBullet::OnCollision`, `0x100630e8`:

```asm
fld  dword [ebx+0x1e4]        ; age
fcomp dword [ebx+0x204]       ; half_time
jne  .full                    ; age <= half_time -> factor 1.0
fld  qword [0x1011a5e0]       ; 2.0
fld  dword [ebx+0x1e4]        ; age
fdiv dword [ebx+0x204]        ; age / half_time
fsub dword [0x101171f0]       ; - 1.0
call _CIpow                   ; 2 ^ (age/half_time - 1)
.full:
fld  dword [ebx+0x1e8]        ; damage
fdiv st(1)                    ; damage / factor
```

So

```
effective = damage,                                  age <= half_time
effective = damage / 2^(age/half_time - 1),          age >  half_time
```

**The damage halves for every further `half_time` of flight.** For the standard
PBC bolt (`sims/weapons/pbc_bolt.ini`: `damage=160`, `half_time=0.35`,
`speed=6000`, `lifetime=1.6`):

| flight time | range | damage |
|---|---|---|
| 0.35 s | 2.1 km | 160 |
| 0.70 s | 4.2 km | 80 |
| 1.05 s | 6.3 km | 40 |
| 1.60 s | 9.6 km | 13.5 (then it expires) |

That is the whole reason PBC range matters: the bolt still hits at 9 km, it just
does nothing. `half_time` is an `icBullet` property (`+0x204`, registered at
`0x100629c0` alongside `length` `+0x200` and `bypass_shields` `+0x208`); its
constructor default is 2.0.

`bypass_shields` is passed to `ApplyWeaponDamage` as the `eDamageSource`
argument (`setne cl` at `0x100631da`), which is exactly what the LDA loop tests.

---

## 3. Armour vs penetration

`iiSim::ApplyWeaponDamage`, `0x100796e1`:

```asm
fld  dword [edi+0x1b4]        ; armour
fcomp dword [esp+0x60]        ; penetration
jne  .no_reduction            ; armour <= penetration -> full damage
fld  qword [0x1011a5e0]       ; 2.0
fld  dword [edi+0x1b4]        ; armour
fdiv dword [esp+0x60]         ; armour / penetration
fsub dword [0x101171f0]       ; - 1.0
call _CIpow                   ; 2 ^ (armour/penetration - 1)
fdivr dword [esp+0x5c]        ; damage / that
```

```
applied = damage,                                    penetration >= armour
applied = damage / 2^(armour/penetration - 1),       penetration <  armour
```

**Penetration at or above the armour rating does full damage; there is no bonus
for exceeding it.** Below it, the damage halves for every whole multiple of the
armour/penetration ratio. This is the same `2^(x-1)` curve as the bolt falloff --
the two are literally the same code shape, reading the same `2.0` at
`0x1011a5e0`.

`armour` is `iiSim+0x1b4`, and it is the ship INI's `armour=` key. Hull is
`+0x1ac` (current) / `+0x1b0` (max) = `hit_points`.

What that produces with the shipped stats:

| ship | hp | armour | standard PBC 160/50 | light PBC 130/35 | heavy PBC 250/70 |
|---|---|---|---|---|---|
| player tug | 1000 | 65 | 130.0 (13.0%, 8 hits) | 71.8 (7.2%, 14) | 250 (25%, 4) |
| patcom | 700 | 50 | 160.0 (22.9%, 5) | 96.6 (13.8%, 8) | 250 (35.7%, 3) |
| marauder cutter | 1500 | 55 | 149.3 (10.0%, 11) | 87.5 (5.8%, 18) | 250 (16.7%, 6) |
| heavy corvette | 1500 | 65 | 130.0 (8.7%, 12) | 71.8 (4.8%, 21) | 250 (16.7%, 6) |
| corp cruiser | 5000 | 62 | 135.5 (2.7%, 37) | 76.2 (1.5%, 66) | 250 (5.0%, 20) |
| navy heavy cruiser | 16500 | 80 | 105.6 (0.64%, 157) | 53.3 (0.32%, 310) | 226.4 (1.4%, 73) |

A light PBC does **0.32%** of a heavy cruiser per bolt, and that is before the
range falloff. Penetration -- not hit points -- is what makes capital ships
immune to light weapons.

**Note the light PBC does not fire `pbc_bolt`.** `subsims/systems/player/light_pbc.ini`
names `projectile_template=ini:/sims/weapons/light_pbc_bolt` -- `damage=130`,
`penetration=35`, `half_time=0.3`, `speed=4500`. `pbc_bolt` (160/50) is what the
*standard* `pbc.ini` cannon fires.

---

## 4. The hull

`iiSim::ApplyDamage`, `0x10079920`:

```
if (killed) return
hull -= damage
if (invulnerable)  hull = max(hull, max_hull * 0.2)      ; 0x101184ac
else if (hull < 0) hull = 0
if (|hull| < 1e-6) Kill()                                ; vtable +0xd4
```

It also logs three damage-warning events as the hull crosses **0.75 / 0.5 /
0.25** of max (`0x10117d8c`, `0x10117738`, `0x101191ec`; log events 0x50/0x51/0x52).
Those are the same three thresholds the HUD damage ramp uses.

`Kill()` -> `iiSim::OnKilled` (`0x10079b80`): credits the score table, sets the
killed flag (`+0x19b`), runs the ship's **death script** (a POG task name at
`+0x1c4`), calls `Explode()` (vtable `+0xfc`, with `(0,0,1)`), logs, cues the
director with event `0xc`, and removes the sim from its group.

Explosions are a two-part affair: `iiSim::StartExplosion` (`0x1007c950`) just
sets an explosion timer to `FLT_MAX` (`+0x1a4`) and a counter to 0 (`+0x1a8`) --
the ship burns until something stops it -- and `StopExplosion` (`0x1007c970`)
zeroes the timer and calls `DoFinalExplosion(eExplosion, bool)` (`0x1007c990`).
The visual composition of `DoFinalExplosion` has **not** been worked out.

---

## 5. Subsim criticals

The tail of `icShip::ApplyWeaponDamage`, `0x100740f9` onward. This is the part
that is not obvious from the decompiler output and had to be read as assembly.

```asm
fild qword [esp+0x2c]         ; (unsigned)subsim_count  -- MSVC's u32->float
fmul dword [0x1015d5cc]       ; * m_criticals_per_impact (0.2)
call _ftol
cmp  eax, 2
jae  .go
mov  dword [esp+0x24], 2      ; floor of 2
```

so

```
N = max(2, int(subsim_count * criticals_per_impact))
```

Then a loop of N iterations:

- **the first** scans every subsim for the one whose mount position
  (`iiShipSystem+0x20..0x28`, the TRI position, i.e. the model null it is
  attached to) is nearest the impact point transformed into ship-local space,
  and damages it at weight **1.0**;
- **each of the rest** picks a uniformly random subsim and damages it at weight
  **0.4** (`0x3ecccccd` at `0x1007427b`).

In every case

```
InflictDamage(subsim, m_critical_damage_scale * weight * hull_damage_applied)
```

with `m_critical_damage_scale = 0.2`. So the nearest subsim takes **20%** of
whatever got through to the hull, and each splash subsim takes **8%**.

**The RNG gate on the splash hits is a no-op.** The code computes
`chance = m_critical_chance_scale * damage / current_hull` (12 x damage / hull)
and rolls `rand()/32767 <= chance` -- but on a *failed* roll it jumps to
`0x100742e6`, which re-tests the loop counter **without decrementing it**
(`dec dword [esp+0x24]` sits at `0x100742e2`, on the *taken* path only). The
loop therefore just re-rolls until the hit lands. Every impact damages exactly N
subsims; the roll only changes how many times the loop spins. Likewise the
`ceil((1 - hull/max_hull) * 3.0)` at `0x10074254` has its result popped off the
FPU stack and discarded (`fstp st(0)` at `0x10074263`) -- dead code in the
shipped binary.

A subsim is skipped if it is already at 0 hp, or if the ship is invulnerable
(`+0x19a`).

`iiShipSystem::InflictDamage` (`0x1003bed0`) is a bare subtract:

```
if (max_hit_points != 0 && !suppress) {
    hit_points -= amount
    if (amount > max_hit_points * 0.25) log "system damaged"
}
```

It does not clamp and it does not destroy. **A subsim with `hit_points=0` in its
INI cannot be damaged at all** -- which is exactly what the empty mountpoint
templates (`subsims/mountpoints/*.ini`) are.

---

## 6. What damage does to a subsim: `iiShipSystem::Simulate` (`0x1003bbd0`)

This is the whole subsystem model, per frame:

```
if (destroyed) { efficiency = 0; usage = 0; return }
usage = clamp(usage, 0, 1)
clear the "underpowered" and "hp<0" flags

--- health ---
if (max_hp <= 0) health = 1                     ; indestructible (empty mounts)
else {
    if (hp < max_hp) {
        if (hp < 0) {
            set flag 8 (not working)
            hp = max(hp, -max_hp)
            if (flag 0x100) { Destroy(); return } ; removed from the ship
        }
        hp += icShip::UseRepairRate(repair_rate) * dt
        hp = min(hp, max_hp)
    }
    health = clamp(hp / max_hp, 0, 1)
}

--- power ---
if (power > 0) {
    drain   = (usage * 0.75 + 0.25) * power
    granted = icShip::UsePower(drain)
    ratio   = granted / drain
    if (ratio <= 0.25) set flag 4 (underpowered)
    ratio = clamp(ratio, 0, 1)
} else ratio = 1

if (heat_rate > 0) icShip::AddHeatRate(HeatRate() * ratio)

efficiency = ratio * health                      ; <-- the whole point

if (ship heat >= heat_damage_threshold && this is not a heatsink)
    efficiency = min(efficiency, 0.75)
if (!IsWorking())                efficiency = 0
if (efficiency < minimum_efficiency) efficiency = 0
```

**Damage degrades a subsim linearly**: `efficiency = hp/max_hp` (times the power
it actually got). It does not step, and there is no "destroyed" threshold for a
normal ship system -- but each device declares a `minimum_efficiency` in its INI
below which it **snaps to zero**. `cpu2.ini` has `minimum_efficiency=0.1`,
`light_pbc.ini` `0.3`, `nps_pbc.ini` `0.5`, `ships_drive.ini` `0`. That is the
authored "at what damage does this thing quit" knob, and it is per device.

Hit points can go **negative** (down to `-max_hp`): the subsim is dead but still
repairable. `IsWorking()` (`0x100019b0`) is `!(flags & 0x21f)` -- not destroyed,
not switched off, not underpowered, not below 0 hp, not disrupted.

### Auto-repair

Two pools on `icShip`, both **reset to zero every frame** before the subsims
tick (`0x10075f80`):

- **power** `+0x27c` -- filled by `icReactor::Simulate` with
  `efficiency * output_power`; if the ship has no powerplant at all the pool is
  set to `100000` (`0x47c35000`), i.e. free power.
- **repair** `+0x280` -- filled by `icAutorepair` with its `autorepair_rate`.

Each damaged subsim then draws `repair_rate` points per second out of the repair
pool, first come first served (`icShip::UseRepairRate`, `0x10075100`, hands out
what is left and no more).

So `autorepair2.ini`'s `autorepair_rate` is a **budget in hit points per second
shared across the whole ship**, and each device's own `repair_rate` caps how
fast it personally can take from it. No autorepair fitted -> the pool is 0 ->
**nothing ever repairs**.

There is also a separate straight hull regen at `0x10076028`: if `icShip+0x2ac`
is set, `hull += rate * dt` clamped to max.

### Heat

`flux.ini [icShip]`: `heat_gain_factor=1`, `heat_loss_factor=0.5`,
`heat_damage_threshold=500`, `heat_damage_rate=0.08` (the PE's compiled-in
defaults, overridden by that INI, are gain 1.0 `0x1015d5b4`, loss 1.0
`0x1015d5b8`, threshold 500 `0x1015d5bc`, rate 0.1 `0x1015d5c0`).

Heat is **not** a normalized temperature: it is a raw accumulator in the same
units as the subsims' `heat_rate` (points per second), living in two stores on
`icShip` -- **internal** `+0x288` (`InternalHeat`, fed by the ship's own
subsims and beam fire) and **external** `+0x28c` (`ExternalHeat`, fed only by
sun/planet proximity). `TotalHeat` (`0x10002b30`) is their sum. There is no
authored "rest value": the rest value is the *equilibrium* where the
heatsink's ramped cooling matches the fitted subsims' output (below).

**Sources.** Each frame `iiShipSystem::Simulate` (`0x1003bbd0`, the block at
`0x1003bda6`) makes every live subsim with `heat_rate > 0` call
`icShip::AddHeatRate(HeatRate() * power_ratio)` -- the same 0..1 power ratio
that scales its efficiency, so a browned-out device also runs cooler. On top
of that a firing beam projector adds internal heat directly:
`icBeamProjector`'s fire path (`0x100300c0`, the beam-drain block) does
`ship.internal += sqrt(beam.damage_rate) * heat_scale * dt` while the beam is
on (`heat_scale=5`, `flux.ini [icBeamProjector]`; the static's compiled-in
default is 1.0 at `0x1015b2c4`; `damage_rate` is the `icBeam` field at
`+0x1e0`, property map at `0x10064f20`). `icCannon` registers the same
`heat_scale` property (static at `0x1015b09c`, `flux.ini [icCannon]` sets 5)
but **no code reads it** -- PBC fire adds no heat beyond the mount's own
`heat_rate`.

**Sun and planet proximity** feed the *external* store, and only for the
player's ship -- both Thinks go through `icPlayerPilot::m_p_instance`:

```
icPlanet::Think 0x10068380 / icSun::Think 0x1006ab90, every frame:
d = max(distance_to_centre - radius, 0)
if (d < radius * heat_radius_multiplier)                ; 0.5, 0x1011af58
    t = 1 - d / (radius * heat_radius_multiplier)
    external += t^2 * heat_multiplier * dt              ; planet: 10000, 0x1011af54
    external += t^2 * heat_multiplier * 10 * dt         ; sun: the same * 10, 0x101190c0
```

`m_heat_radius_multiplier` / `m_heat_multiplier` are **exported const floats**
(`?m_heat_radius_multiplier@icPlanet@@1MB`), not INI-tunable in the shipped
build.

**Dissipation.** `icHeatSink::Simulate` (`0x1002ee90`) is what cools: it calls
`AddHeatRate(-heat_loss_rate * ramp)`, where the ramp is

```
knee = heat_damage_threshold * 0.9              ; 450, 0x1011951c
ramp = 1 - (total - knee)^2 / knee^2   , total < knee, floored at 0.2 (0x101184ac)
ramp = 1                               , total >= knee
```

so a heatsink loafs at 20% of its rated `heat_loss_rate` on a cold ship and only
works flat out as the ship approaches its damage threshold. Note `0x1002ee90`
has **no destroyed/off gate** -- the base `Simulate` bails out for a dead
subsim, but the cooling call after it still runs, so a shot-out heatsink keeps
radiating.

**Integration** (`icShip::SimulateSystems 0x10075f60`, the tail at
`0x10076060`): the per-frame net `heat_rate` accumulator (`+0x284`, reset to 0
at the top of every frame) is applied as

```
if (rate <= 0)                             ; cooling
    d = heat_loss_factor * dt * rate       ; <= 0
    if (external >= -d)  external += d     ; external drains FIRST
    else { internal += d + external; external = 0 }   ; spillover
else                                       ; heating
    internal += heat_gain_factor * dt * rate
internal = clamp(internal, 0, threshold)
external = clamp(external, 0, threshold)   ; so total caps at 1000
```

**Damage** (same tail): with `total = internal + external`,

```
if (total > 500 && external >= total * 0.5)         ; 0.5 at 0x10117738
    if (LastAggressor() == 0) SetLastAggressor(self)
    ApplyDamage((total - 500) * 0.08, src=3)        ; NO dt term
```

The damage call has **no dt factor** -- it is applied once per frame, so heat
damage in the original engine is frame-rate dependent. Because the condition
needs `external >= total/2`, a ship can never burn itself: internal-only heat
pegs at the threshold and merely degrades it (below). Only sun/planet heat
kills, which is what makes sun-diving lethal.

**Overheat.** Once `total >= threshold`, every non-heatsink subsim is capped at
0.75 efficiency (`0x10117d8c`), and `iiWeapon::Simulate` (`0x1003cc00`) sets
flag `0x200` on every weapon, which blocks fire.

**HUD normalization.** The HUD's player feed (`0x10108890`) computes the
thermometer as `TotalHeat / heat_damage_threshold * 0.8` clamped to 1 -- the
0.8 lives at `0x10163efc`. Internal-only overheat therefore pegs the needle at
0.8; it hits 1.0 at `total = 625`, which requires external heat. The
base-screen status panels (`0x100e07f0`) use `* 0.75` instead and flag
"overheat" at `frac >= 0.75`, i.e. exactly at the threshold. Total heat also
leaks into the ship's sensor brightness: `icShip::Brightness` (`0x10075420`)
adds `total * 0.4 / threshold` (`0x10117558`).

**Rest value.** With the above, a fitted ship idles where
`sum(heat_rate) = heat_loss_rate * ramp(total)`. The prefitted comsec
(`comsec_prefitted.ini`: 100 powerplant + 250 thrusters + 10 sensors + 30
autorepair + 300 LDS + 60 PBC + 10 CPU = 760/s against `heatsink1`'s 2000)
settles at `total = 450 * (1 - sqrt(1 - 760/2000)) = 95.7`, i.e. 0.153 on the
HUD gauge; the prefitted tug (2190/s against `heatsink5`'s 4500) at
`total = 127.6`, gauge 0.204.

---

## 7. LDA -- the shields

The `lda` mountpoints named `shield_upper` and `shield_lower` in `tug.ini` are
the HUD's two SHIELD STATUS bars. What fills them is an `icPlayerLDA`
(`lda_light`, `lda_defence`, `lda_military`, ...) or, on an NPC, an `icAILDA`
(`nps_lda.ini`). Both derive from the abstract `iiLDA` (registered at
`0x10035f10`; the deflect method is a pure virtual at vtable slot `+0x54`).

`icShip::ApplyWeaponDamage` (`0x10073e2e`) walks the subsim list **before** any
damage is computed, and for each subsim that `IsKindOf(iiLDA)` calls that
`+0x54`. If it returns true the shot is gone: `CheckForReactives`, `return 0.0`.

**An LDA either eats the entire bolt or does nothing.** It does not absorb part
of the damage, and it has no hit-point pool that soaks damage. The whole loop is
skipped when the damage source is nonzero, i.e. when the bolt has
`bypass_shields`.

### `icPlayerLDA` (`0x100acda0`)

```
if (min_energy(0.2) * capacity > energy)  return false   ; 0x101607e0
if (shield_energy_cost > energy)          return false
chance = min(TRIWeight() * reliability * efficiency, 0.98)   ; 0x1011c664
if (rand()/32767 > chance)                return false
if (cos(coverage/2) > dot(-bolt_dir, lda_forward))  return false   ; hood arc
... second arc test against the threat the LDA is currently tracking ...
energy -= shield_energy_cost
spawn the field effect
return true
```

`icPlayerLDA::Simulate` (`0x100acb00`) recharges it:

```
energy += TRIWeight() * efficiency * power * dt      , capped at capacity
usage   = (charging ? 0.75 : 0) + (has a threat ? 0.25 : 0)
```

`lda_light.ini`: `capacity=500`, `shield_energy_cost=180`, `power=100`,
`reliability=0.3`, `coverage=180`, `hit_points=500`. So it recharges 100/s,
each deflection costs 180, and it will not fire below 100 energy -- roughly one
deflection every 1.8 s, at a 30% success rate when undamaged.
`lda_military.ini` is `capacity=1200`, `cost=230`, `power=220`,
`reliability=0.7`.

`TRIWeight()` (`0x1003c170`) returns **1.0 for every non-player ship**; for the
player it indexes `iiShipSystem::m_tri_weights` by the system's TRI position.
The TRI is IW2's three-way power-priority allocator. **The weight table is not
recovered** -- see Unknowns.

### `icAILDA` (`0x1002b940`)

Simpler, and much stronger:

```
if (!IsWorking())                       return false
if (rand()/32767 > efficiency * reliability) return false
if (defends < 1)                        return false
... the same arc tests ...
defends -= 1
```

and `Simulate` regenerates `defends += dt * defend_count / recharge_time`.

`nps_lda.ini` is `defend_count=1`, `recharge_time=0.1`, `reliability=0.5`: a
50% chance to eat *any* bolt, recharging in a tenth of a second. That is why NPC
warships feel spongy.

---

## 8. Constants

`flux.ini [icShip]` (identical in `defaults.ini`) -- these are `icShip` static
class properties, registered at `0x10070760`:

```
heat_gain_factor      = 1
heat_loss_factor      = 0.5
heat_damage_threshold = 500
heat_damage_rate      = 0.08
critical_chance_scale = 12
critical_damage_scale = 0.2
criticals_per_impact  = 0.2
```

(mirrored in the PE at `icShip::m_critical_chance_scale` `0x1015d5c4`,
`m_critical_damage_scale` `0x1015d5c8`, `m_criticals_per_impact` `0x1015d5cc`.)

Immediates read out of the PE with `tools/ghidra/readconst.py`:

| address | value | what |
|---|---|---|
| `0x1011a5e0` | 2.0 (double) | the base of **both** `2^(x-1)` curves |
| `0x1015d5cc` | 0.2 | criticals per impact |
| `0x1015d5c8` | 0.2 | critical damage scale |
| `0x1015d5c4` | 12.0 | critical chance scale (a no-op, see 5) |
| `0x1007427b` | 0.4 | splash weight for the non-nearest criticals |
| `0x101607e0` | 0.2 | `icPlayerLDA::m_min_energy` |
| `0x1011c664` | 0.98 | LDA deflect chance cap |
| `0x101184ac` | 0.2 | invulnerable hull floor; also the heatsink ramp floor |
| `0x1011951c` | 0.9 | heatsink knee, as a fraction of the heat threshold |
| `0x10117d8c` | 0.75 | overheat efficiency cap; power drain usage term; the base-screens' heat panel scale |
| `0x101191ec` | 0.25 | power drain base term; underpower threshold |
| `0x10118494` | 3.0518e-05 | 1/32767, the `rand()` normaliser |
| `0x10117738` | 0.5 | external share of total heat needed before heat damage |
| `0x10163efc` | 0.8 | HUD thermometer scale on `total/threshold` (`0x10108890`) |
| `0x10117558` | 0.4 | heat's contribution to sensor brightness (`0x10075420`) |
| `0x101190c0` | 10.0 | the sun's extra factor on planet proximity heat |
| `0x1011af54` | 10000.0 | `icPlanet::m_heat_multiplier` (exported const) |
| `0x1011af58` | 0.5 | `icPlanet::m_heat_radius_multiplier` (exported const) |
| `0x1015b09c` | 1.0 | `icCannon::m_heat_scale` default (flux.ini sets 5; **unused by any code**) |
| `0x1015b2c4` | 1.0 | `icBeamProjector::m_heat_scale` default (flux.ini sets 5) |

### `iiShipSystem` layout

| offset | field | INI key |
|---|---|---|
| `+0x0c` | name | `name` |
| `+0x20..0x2c` | TRI position (ship-local) | from the attach null |
| `+0x44` | power | `power` |
| `+0x48` | heat rate | `heat_rate` |
| `+0x4c` | repair rate | `repair_rate` |
| `+0x50` | minimum efficiency | `minimum_efficiency` |
| `+0x54` | hit points | `hit_points` |
| `+0x58` | max hit points | copied from `+0x54` at Load (`0x1003bb30`) |
| `+0x60` | type | |
| `+0x64` | TRI position index | |
| `+0x68` | flags | 1 destroyed, 2 off, 4 underpowered, 8 hp<0, 0x10 disrupted, 0x20 switchable, 0x100 destroy-on-death |
| `+0x70` | power drain (actual) | |
| `+0x74` | usage | |
| `+0x78` | efficiency | |

### Mountpoint types (`subsims/mountpoints/*.ini`, `type=`)

```
1 heatsink   2 reactor   4 eps    8 thrusters   16 active_sensors
32 passive_sensors  64 lds  128 lda  256 drive  512 capsule_drive
1024 auto_repair  2048 aggressor_shield  4096 (all weapon mounts)
16384 sensor_disruptor  32768 cpu  65536 point_defence_turret
131072 dock_on_turret
```

which is what the HUD's `DRV THR LDS CAP WEP SEN EPS CPU` strip is reading.

---

## 9. Unknowns

Not recovered. **Do not fill these in with plausible values.**

- **The TRI weight table.** `iiShipSystem::m_tri_weights` is indexed by the
  system's TRI position (`+0x64`) and multiplies the LDA's deflect chance and
  recharge, for the player only. `iiShipSystem::m_min_tri_weight` /
  `m_max_tri_weight` exist as symbols; the table's values were not read out. Our
  implementation uses 1.0 (the non-player value) throughout, which is exactly
  what a ship with a neutral TRI would get.
- **The LDA's second arc test.** After the hood-coverage test, `icPlayerLDA`
  transforms the direction to the sim whose id it holds at `+0xa0` -- set by
  `0x100ad000`, which scans the contact list for the nearest hostile inside the
  hood -- and tests `field_coverage` against it. The exact geometric predicate
  (and how `field_hold_time` gates it) is only half read. We implement the hood
  test and skip the second one, so our LDAs are slightly more permissive than
  the original's.
- **`DoFinalExplosion` (`0x1007c990`)** -- what the explosion actually spawns.
- **The `eDamageSource` enum** beyond 0 (weapon), 1 (shield-bypassing weapon)
  and 3 (heat). There is a log-event table at `DAT_1011bf14` indexed by it.
- **`icShip+0x2ac`** -- the subsystem that drives the straight hull regen at
  `0x10076028`. Its `+0x80` is a hit-points-per-second rate.
- **Flag `0x100`** (destroy-on-death) -- which subsims set it, and therefore
  which ones are permanently removed rather than merely knocked to 0 hp.
- **The reactor's spin-up factor** (`icReactor+0x9c`) and its boost mode
  (`+0x84`/`+0x88`), which scale `output_power`.

---
