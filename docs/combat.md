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

## 10. Missiles

The whole secondary-weapon system. Class map (registrations in `iwar2.dll`):

```
iiWeapon
  icMissileLauncher   0x10031450   an INERT rack: magazines slave to it
  icMagazine          0x10037fe0   the weapon that actually fires
    icMissileMagazine          0x1000ff80   fires icMissile subclasses
    icCounterMeasureMagazine   FUN_1002d470 (vtable 0x10119320)
iiThrusterSim
  icMissile           0x1006c020   powered, guided, 0x488 bytes
    icSimTrackingMissile  ctor FUN_1007d140, vtable 0x1011c038
    icLDSIMissile         ctor FUN_1006b740, vtable 0x1011b3b0
    icMine                ctor FUN_1006baf0, vtable 0x1011b4e0
iiProjectile (0x1006ee70)   unpowered, 0x1dc owner / 0x1e4 age / 0x1f0 lifetime
  icRocket            ctor FUN_1006fc90, vtable 0x1011bb98
  icCounterMeasure    ctor FUN_10064050, vtable 0x1011a714
icShip
  icRemoteMissile     0x1006f330   a player-flyable drone SHIP
```

`icSimTrackingMissile`, `icLDSIMissile`, `icMine`, `icRocket` and
`icCounterMeasure` are not DLL-exported; their bodies were recovered by
dumping the vtables from the PE and raw-disassembling the slots
(`tools/ghidra/disasm.py`).

### 10.1 The launcher is not the weapon

`icMissileLauncher::Fire` (`0x1004ad80`) is an **empty function** (COMDAT-
folded with a dozen other no-ops), its `ComputeFiringSolution` (`0x100310c0`)
returns false, its `IsReadyToFire` (`0x100bc470`) returns 0xd ("recharging")
unconditionally, and its `Range` is 0. It exists to hold `missile_capacity`
magazines (`AddMagazine 0x10030ee0`) and to donate its fire position:
`icMagazine::SetLauncher` (`0x100387e0`) copies the launcher's mount position,
orientation and muzzle offset (`+0x88..+0xa0`) onto the magazine. Everything
else -- readiness, solution, firing -- is the magazine.

### 10.2 The magazine fire cycle

`icMagazine` INI keys (property map at `0x10037db0`): `max_ammo_count` `+0xac`,
`ammo_count` `+0xb0`, `refire_delay` `+0xb4`, `launch_speed` `+0xb8`,
`salvo_fire` `+0xbc` (ctor default ON), `projectile_template` `+0xc4`.

- **Reload clock**: `icMagazine::Simulate` (`0x10038210`) accumulates
  `clock += efficiency * dt` -- a damaged or under-powered magazine reloads
  slower.
- **Ready** (`IsReadyToFire 0x10038350`): `efficiency * clock > refire_delay`,
  `ammo > 0`, plus the ship-wide overheat flag 0x200 from `iiWeapon::Simulate`
  (`0x1003cc00`). In AUTO mode (`+0x7c == 2`) a non-countermeasure magazine
  additionally rolls `rand() <= ammo_fraction *
  rocket_launch_likelihood_per_ammo_fraction` (flux.ini `[icMagazine]`: 0.1)
  every ready check -- the AI's rocket rate limiter.
- **Trigger** (`iiWeapon::AttemptToActivateWeapon 0x1003ccb0`): in player mode
  (`+0x7c == 1`) only the magazine matching the pilot's current weapon
  selection fires -- with one exception: an LDSI magazine (flagged at `+0x6c`,
  set in `Load 0x10038240` when the projectile template is an `icLDSIMissile`)
  fires on the dedicated LDSI trigger (`icPlayerPilot+0x82`,
  `LDSIQuickFire` = `I` in `configs/default.ini`), bypassing selection.
  In AUTO mode the target comes from the fire-request slot `+0x84` or the
  ship's contact-list target.
- **Fire** (`icMissileMagazine::Fire 0x100399c0` / `icMagazine::Fire
  0x10038440`): `clock = 0`, `ammo -= 1`, create the projectile template,
  set aggressor = `StrongRoot(ship).id` and `SetTarget(current target)`,
  velocity = ship velocity + muzzle forward x `launch_speed`, orientation =
  muzzle quat -- unless the muzzle is within `cos > 0.95` (`0x10119c3c`) of
  the ship's facing, in which case the SHIP's orientation is used (angled
  tubes straighten out). CM/rocket fire also calls the projectile's OnLaunch
  slot (+0x100): a CM starts its engage timer there (`0x10064130`).
- The AI ballistic solution for rockets (`icMagazine::ComputeFiringSolution`
  `0x10038660`): an unguided round at `launch_speed` must pass within
  `target_radius + 15` m (`squared_radius_firing_tolerance`, used linearly),
  lead time 0..30 s (`0x10119c18`).
- AI missile launches (`icMissileMagazine::ComputeFiringSolution 0x10039d50`):
  each ready frame rolls `rand() <= ammo_fraction *
  missile_launch_likelihood_per_ammo_fraction` (flux.ini: 0.005; 0.01 under a
  missile-boat order, goal id 4 at `pilot+0xa4`). **An LDSI magazine only
  auto-fires at a target whose LDS drive is currently engaged**
  (`target+0x25c` drive state `+0x84 == 2`).

### 10.3 icMissile -- the state machine

Property map (`FUN_1006bcf0`): `arm_time +0x260`, `lifetime +0x264`,
`penetration +0x268`, `damage +0x26c`, `explode_radius +0x270`,
`blast_radius +0x274`, `disable_attenuation +0x278`, `sensor_radius +0x27c`,
`disruptor_time +0x280`, `full_disruption +0x284`, `antimatter_radius +0x288`,
`ldsi +0x28c`, `field_radius +0x290`, `field_life_time +0x294`. Runtime:
`eMissileType +0x298` (ctor default 2; `icMine` sets 0), `eState +0x29c`,
embedded `icAITarget` brain at `+0x2a0`, aggressor `+0x458`, target `+0x45c`,
age `+0x460`, seek timer `+0x47c`.

States (`Simulate 0x1006c550` / `Think 0x1006c350`):

1. **EJECT** -- coast until `age > arm_time`, then: type 0/1 -> SEEK,
   type 2 (everything a magazine fires) -> TRACK + `OnTracking()`. A type-2
   with no lock is a dud: `Think` finds no target instance and sets state 6.
2. **SEEK** -- every `m_active_seek_update_time` (1.0 s, `0x1011b60c`)
   `FindTarget` (`0x1006c3f0`) scans every ship-type sim within
   `sensor_radius` and takes the nearest -- hostile-faction only
   (`FeelingType < 2`), except a player-launched missile may take anything on
   the player's contact list. Only **type 0** (mines) thrusts in this state.
3. **TRACK** -- the embedded `icAITarget` brain flies the missile through
   `iiThrusterSim::ComputeForceAndTorque`: the missile IS a ship, flying the
   INI `speed`/`acceleration`/`yaw_rate` flight model. Each frame
   `TargetInRange` (`0x1006c980`: brain range < `explode_radius` +
   target radius) triggers `OnExplodeRadiusEntry` + `OnExplode` + destroy.
4. **HOLD** -- `icMine` with `proximity=1` (`icMine::Simulate 0x1006bc20`):
   brake to zero and wait for `TargetInRange`.
5. **EXPLODED**, 6. **DEAD** -- state 6 coasts inert, engine flame still on
   (the `lz` avatar channel is `state >= 2`), until lifetime.

Lifetime expiry **explodes** a missile (`OnExplode` then destroy); an
`iiProjectile` (rocket, CM) just vanishes (`0x1006ef90`).
`CanCollideWith` (`0x1006cf90`): never another missile, and never the
launcher (or its subsims / docked parent) during the first **4 s**
(`0x101190b4`). `OnTracking` (`0x1000f8c0`) -> `icShip::OnIncomingMissile`
(`0x10074f20`): the player pilot gets the HUD warning
(`icPlayerPilot::OnIncomingMissile 0x100b0fc0` appends the missile id to the
pilot's `+0xa8` list -- one HUD pip per entry -- and folds the range into
`+0xb4` with the octagonal norm `max + 0.34375*mid + 0.25*min`,
`0x101191f0`/`0x101191ec`; log event 0x30), and any ship scans its subsims
for a ready `icCounterMeasureMagazine` and drops the missile id in its
fire-request slot `+0x84` -- **NPCs auto-launch countermeasures**.

### 10.4 Warheads

`icMissile::OnCollision` (`0x1006cc30`): only a warhead with
`|explode_radius| < 1e-6` applies contact damage --
`ApplyWeaponDamage(damage, penetration, ..., src=2)` on the struck sim.
**eDamageSource 2 skips the LDA loop** (`icShip::ApplyWeaponDamage 0x10073e2e`
only scans LDAs for source 0): missiles and rockets cannot be
shield-deflected. Armour and subsim criticals still apply on this path.
Then director cue 9, `CheckForDisruption`, `OnExplode`, score, destroy.

`icMissile::OnExplode` (`0x1006d1a0`), in priority order:

- **LDSI** (`+0x28c`): spawn `ini:/sims/explosions/ldsi_missile_explosion`
  (an `icShockwave`) with radius = `field_radius`. The teeth are in
  `OnExplodeRadiusEntry` (`0x1006c9e0`): snap the missile to the target's
  position, **zero the target's velocity** (yanks it out of LDS), then
  `ScrambleLDSDrives(field_radius, field_life_time)` (`0x1006d7c0`): every
  thruster sim in the field with an ENGAGED LDS drive is stopped dead
  (the player also gets `Reset` + autopilot removed) and its drive
  `icLDSDrive::Scramble`d for `field_life_time`. It also plants an
  `icTimedWaypoint` (localised `ldsi_waypoint_name`) visible only to the
  aggressor's side.
- **Antimatter** (`antimatter_radius != 0`): spawn
  `ini:/sims/explosions/missile_antimatter_explosion` (`icShockwave`) with
  that radius; the shockwave sim does the damage (not recovered here).
- **Blast** (`explode_radius != 0`): every sim within
  `blast_radius + sim_radius` takes `(1 - dist/reach) * damage` -- or flat
  `damage` with `disable_attenuation` (all shipped seekers set it) --
  through **`iiSim::ApplyDamage` (vtable +0xd0): raw hull, no armour, no
  LDA, no subsim criticals**; plus `CheckForDisruption` each.
- Visuals: a `harmless_shockwave` when `max(blast, explode, radius) > 100`
  (`0x101192c0`, capped at 3000 `0x1011a194`) and an `icExplosion` fireball
  of `min(that, 100)`.

`CheckForDisruption` (`0x1006d0b0`): if `disruptor_time > 0` and the victim
is a ship, `icShip::Disrupt(clamp(150 / victim_radius * disruptor_time,
2, 30), shields_only = !full_disruption)` -- 150 = `m_destroyer_radius`
(300, `0x1011b618`) x 0.5. Disruption raises subsim flag 0x10 (efficiency 0;
`iiWeapon::IsReadyToFire 0x1003cb80` returns "locked out").

### 10.5 icSimTrackingMissile -- level and decoys

Its `Think`/`Simulate` are **pure thunks** to `icMissile` (`0x1007d3d0` /
`0x1007d3e0`). All it adds is `level` (`+0x484`, ctor default 1.0) and the
decoy dance, called from `icCounterMeasure::Simulate` (`0x10064140`):

- The CM coasts ballistically (`Integrate 0x100642d0`). The frame its engage
  timer expires (`engage_time`, INI, started at launch), every tracking
  missile whose target is the CM's OWNER runs **`Decoy`** (`FUN_1007d240`):
  seduced iff the CM is within `(1 - level) * 500` m **of the victim**
  (`max_range_for_decoying_level_zero_missile`, flux.ini). The original
  target id is parked in `+0x480`. One chance, no rand. A `level=1`
  missile can never be seduced; a Deadshot (0.9) needs the flare within 50 m.
- When the CM dies, **`OnDecoyExpired`** (`FUN_1007d2d0`): a missile further
  than `level * 5000` m from the dead CM
  (`min_range_for_stopping_level_one_missile_reacquisition`) loses lock for
  good (`SetTarget(0)` -> state 6); otherwise it reacquires the parked
  target and re-warns it (`OnIncomingMissile` again).
- `icCounterMeasure::OnCollision` (`0x10064340`): a projectile-type sim
  (`+0x190 == 1`, i.e. a missile) that flies into the CM is destroyed with it.

### 10.6 icMine, icRocket, icRemoteMissile

**icMine** -- `eMissileType 0`, `proximity` at `+0x480` (default true).
`Think` (`0x1006bbb0`): while tracking, the lock is dropped past
`sensor_radius * 5` (`0x1011b4dc`), back to SEEK. `Simulate` (`0x1006bc20`):
a proximity mine that starts tracking goes to HOLD (brake to zero) instead of
chasing; a seeker mine (`proximity=0`) chases. `lifetime=-1` = forever.

**icRocket** -- an `iiProjectile` with one key, `acceleration` (`+0x200`).
`Simulate` (`0x1006fde0`): the motor lights at a fixed **0.6 s**
(`0x1011bb94`), switching the `lz` channel on; `Integrate` (`0x1006fe30`):
`velocity += facing * acceleration * dt`, no speed cap, no guidance.
`OnCollision` (`0x1006ff50`): contact `ApplyWeaponDamage(damage, penetration,
..., src=2)` (armour applies, LDA does not), director cue 8, `OnExplode`.
The iiProjectile keys (`FUN_1006ecc0`): `damage +0x1e8`, `penetration +0x1ec`,
`lifetime +0x1f0`, `speed +0x1f4`, `antimatter_based +0x1f8`. `arm_time` in
the rocket/CM INIs matches no key in either map -- dead data.

**icRemoteMissile** -- an `icShip` subclass (hull, subsims, sensors), keys
`penetration +0x300 / damage +0x304 / blast_radius +0x308 /
antimatter_radius +0x30c / lifetime +0x310`. `Think` (`0x1006f490`): after
`m_arm_time` (1.5 s, `0x1011ba60`) it hands itself to
`icPlayerPilot::RemoteLink` -- the player flies it. It self-destructs
(ApplyDamage(2 x max hull, src=5)) on any collision (`0x1006f610`), at
`arm_time + lifetime` (`0x1006f530`), or when the pilot aborts. `OnExplode`
(`0x1006f630`) is the icMissile blast with linear attenuation over the
octagonal-norm distance, aggressor = owner (`+0x314`).

### 10.7 Trail avatars

`icMissileTrailAvatar` / `icRocketTrailAvatar` (registrations `0x100c7...`;
property map `FUN_100c7980`: `texture +0xbc`, `lifetime +0xc0`,
`min_radius +0xc4`, `max_radius +0xc8`, `tint +0xcc`, `channel +0xd8`,
`stay_on +0xdc`). The authored data (`data/ini/avatars/*/trail.ini`):
`redtrail` (seeker/harrower/deadshot 5 s), `bluetrail` (pulsar/disruptor 5 s),
`greentrail` (LDSI 2 s), `orangetrail` (rockets 2-3 s, hammer 3 s),
`min_radius 1.5 / max_radius 10`, keyed to the `lz` engine channel.
The ribbon draw itself was NOT disassembled; the remaster spawns its
additive-billboard machinery with exactly these parameters.

### 10.8 Player controls (configs/default.ini)

`CurrentWeaponFire` Space/Joy1 fires the SELECTED weapon;
`NextPrimaryWeapon` Return, `NextSecondaryWeapon` Backspace cycle the
selection rings; `LDSIQuickFire` I fires the LDSI magazine directly;
`RemotePilot` Shift+R. The prefitted tug carries `seeker_missile_magazine`
(5), `ldsi_missile_magazine` (4) and `decoy_magazine` (8).

### 10.9 Missile constants

| address | value | what |
|---|---|---|
| `0x1011b60c` | 1.0 | `m_active_seek_update_time` (FindTarget cadence) |
| `0x1011b610` | 2.0 | `m_min_disruptor_time` |
| `0x1011b614` | 30.0 | `m_max_disruptor_time` |
| `0x1011b618` | 300.0 | `m_destroyer_radius` (x0.5 in the disrupt scale) |
| `0x101190b4` | 4.0 | launch grace: no self-collision for 4 s |
| `0x1011b4dc` | 5.0 | mine lock-drop hysteresis on sensor_radius |
| `0x10119fcc` | 500.0 | LDSI proximity fuse range |
| `0x1011bb94` | 0.6 | rocket motor ignition delay |
| `0x101192c0` | 100.0 | explosion visual floor / fireball cap |
| `0x1011a194` | 3000.0 | missile harmless-shockwave radius cap |
| `0x1011bb90` | 2000.0 | remote-missile shockwave radius cap |
| `0x10119c3c` | 0.95 | muzzle-vs-ship facing dot for launch orientation |
| `0x10119c18` | 30.0 | max ballistic lead time (rocket solution) |
| `0x1015dd5c` | 500.0 | decoy range, level 0 (flux.ini same) |
| `0x1015dd60` | 5000.0 | reacquisition stop range, level 1 (flux.ini same) |
| `0x1015ba80` | 0.02 | missile launch likelihood default (flux.ini 0.005) |
| `0x1015ba7c` | 0.08 | missile-boat likelihood default (flux.ini 0.01) |
| `0x1015ba00` | 0.1 | rocket launch likelihood (flux.ini same) |
| `0x1015b9fc` | 15.0 | firing tolerance (metres, despite the name) |
| `0x1011ba60` | 1.5 | `icRemoteMissile::m_arm_time` |
| `0x10119b9c` | 0.1 | `icMagazine::m_background_power_usage` |
| `0x101191f0` | 0.34375 | octagonal-norm mid coefficient |
| `0x101191ec` | 0.25 | octagonal-norm min coefficient |

### 10.10 Missile unknowns

Not recovered. **Do not fill these in with plausible values.**

- **The `icAITarget::Think` intercept law.** The missile flies the same AI
  brain NPC ships use; its exact steering (lead law, roll policy) was not
  extracted. The remaster flies turn-rate-limited lead pursuit at full
  thrust through the same INI limits -- the flight-model shape is right, the
  steering law is an approximation.
- **`icShockwave`** -- the antimatter and LDSI explosion carrier. Radius and
  the INI it is built from are recovered; its damage application is not.
- **The LDSI missile's in-LDS fuse.** `icLDSIMissile::Think` (`0x1006b830`)
  has a second detonation branch used while the missile's OWN LDS drive
  (subsim `nps_lds_missile`) is engaged, testing two brain fields
  (`+0x34c >= 0 && +0x36c > 0.4`) whose meaning was not pinned down. The
  500 m proximity branch is recovered and implemented; LDS-chase is not
  built (the remaster's missiles do not fly LDS).
- **`eMissileType 1`.** Constructed nowhere in the shipped code paths we
  read; behaves like type 0 in `Think`, thrust-less in SEEK.
- **The turret-fighter path** (`icMissileMagazine::Fire` with an `icShip`
  template: attach `icAIPilot`, sim flag 0x40000, `GiveEscortOrder`
  `0x10039840` = DefaultFormate on the launcher).
- **`speed=` in rocket INIs** (`iiProjectile+0x1f4`): no rocket code reads
  it (`icBullet` does); rockets get velocity from `launch_speed` + thrust.

---

## 11. Turrets and guns

Class map (registrations in `iwar2.dll`):

```
iiWeapon                 (property map 0x1003c6d0: fire_position_translation
  |                       +0x88, fire_position_rotation +0x94; ctor 0x1003c860:
  |                       fire MODE +0x7c default 1 = player trigger)
  iiGun         reg 0x10034ba0, ctor 0x10034ea0, 0xd0 bytes  the ballistic gun
    icCannon    the fixed cannon (weapons.gd's PBC; +0xd0 capacity/+0xd4 cost)
    icSlugThrower  ctor 0x10032660: iiGun + max_ammo_count +0xd0 / ammo_count
                +0xd4 (ints); Fire 0x100327f0 decrements, IsReadyToFire
                0x10032750 returns 8 on empty. Simulate 0x10032730 pins usage 1.
    icTurret    reg 0x10032c50, ctor 0x10032d80, 0x114 bytes  the slewing gun
icShip
  icTurretShip  reg 0x10033ea0, ctor 0x10034080, 0x330 bytes  a HULL that yaws
                itself at its target (the player turret fighter)
```

### 11.1 iiGun -- the shared fire solution

Property map (`0x10034c20`): `horizontal_fire_arc +0xac`,
`vertical_fire_arc +0xb0` (degrees, full angle), `projectile_template +0xb4`,
`refire_delay +0xb8`, `no_jitter +0xc4`, `sniper_zoom +0xc5`; statics
`m_min_travel_time`, `m_min_speed_fraction`, `m_max_jitter_angle`,
`m_max_jitter_radius` (`flux.ini [iiGun]`: 0.4 / 0.75 / 0.75 / 1.5).

- **Load** (`0x10035060`): resolves the projectile prototype (must derive from
  `icBullet`, class ptr `0x1016631c`); muzzle speed `+0xbc` = the bullet INI's
  `speed` (`proto+0x1f4`), range `+0xc0` = `speed * lifetime` (`proto+0x1f0`).
- **Simulate** (`0x10035030`): the refire clock `+0xc8` accumulates
  `efficiency * dt` -- a damaged gun cycles slower.
- **IsReadyToFire** (`0x10035120`): ready when
  `TRIWeight * clock >= refire_delay` (0xd "recharging" otherwise; the ship
  overheat check at vtable `+0x5c` returns 9 first).
- **FindAimPoint** (`0x10035170`, static): `travel = dist / muzzle_speed`
  floored at `m_min_travel_time` (0.4 s); the SOLVED speed `dist / travel` is
  floored at `0.75 * muzzle_speed` (`0x10117d8c` -- the compiled-in value; the
  registered `m_min_speed_fraction` static carries the same 0.75 from
  flux.ini). `aim = target_pos + target_vel * travel`. The bolt then launches
  at the solved speed, and `Fire` (`0x100357e0`, the tail at `0x10035ad0`)
  scales its `lifetime` and `half_time` by `muzzle_speed / solved` (times
  TRIWeight on lifetime and damage) -- range in metres is preserved; a
  close-in shot flies a slower, longer-lived bolt.
- **IsInFireArc** (`0x10035270`): the solution direction (muzzle-local) must
  satisfy `atan(|x|/z) <= horizontal_fire_arc/2` and `atan(|y|/z) <=
  vertical_fire_arc/2` (degrees x 57.2958 `0x10119924`; a negative atan gets
  +pi `0x10119464`, so a target behind always fails).
- **ComputeFiringSolution** (`0x10035310`): player guns with auto-aim off
  (`pilot+0x9c == 0`) fire straight ahead, always true. Otherwise:
  `FindLocalTarget` (`0x1003d7d0`) -> range gate (`+0xc0`) -> **the AI miss
  model**: unless `no_jitter`, for a target of radius >= 40 m (`0x1011849c`),
  roll `FcRandom::Int(0, 4 - pilot_skill)`; on > 0 push the aim point
  `sin(rand(0..1)^2 * m_max_jitter_angle * 2deg)` (`2deg = 0.0349066 @
  0x10119adc`) times the octagonal-norm ship-to-target distance
  (`0x101191f0/0x101191ec`), capped at `target_radius * m_max_jitter_radius`,
  in a random unit direction. A pilotless gun (station, gunstar) rolls 0..4:
  **80% of its shots are jittered**. Then FindAimPoint + IsInFireArc.
- **Fire** (`0x100357e0`): clock = 0; clone the bullet prototype, owner
  `+0x1dc` = strong-root id, position = world muzzle + solution direction x
  `bullet_length * +0x20c`, velocity = ship velocity + solution x solved
  speed, orientation = the solution direction.

### 11.2 icTurret -- the slewing mount

Property map (`0x10032960`, parent `iiGun`): `capacity +0xd0`,
`shot_energy_cost +0xd4`, `reacquire_time +0xd8` (ctor default FLT_MAX),
`turret_mode +0xdc` (int, default 0), `min_heading +0xe0` (-45),
`max_heading +0xe4` (45), `min_elevation +0xe8` (0), `max_elevation +0xec`
(45), `stow_heading +0xf0`, `stow_elevation +0xf4`,
`max_heading_velocity +0xf8`, `max_elevation_velocity +0xfc` (deg/s, ctor 0).
Runtime: reacquire clock `+0x100`, elevation `+0x104`, heading `+0x108`,
locked target `+0x10c`, energy `+0x110` (ctor 0).

The ctor (`0x10032d80`) sets subsim flags `|0x20` (switchable), `&~2` (on) and
**`|0x100` (destroy-on-death)** -- a turret shot below 0 hp is removed from
the ship outright (this resolves part of the section-6 "flag 0x100" unknown).

`turret_mode` (the INI comments in `nps_turret_*.ini` match the code):
`0` full control (self-targeting), `1` designated target, `2` point defence.
`SetMode` (`0x10033800`) always forces fire mode `+0x7c = 2` (AUTO); mode 1
parks the fire request in `+0x10c`; modes 0/2 set the reacquire clock to
`reacquire_time + 1` so the next Simulate retargets immediately.

**Simulate** (`0x10033570`, recovered by raw disassembly -- Ghidra dropped it):

```
iiGun::Simulate(dt)                          ; refire clock
if (!IsWorking() or ship overheat) -> skip aiming
mode 0/2:  reacq += dt; if reacq > reacquire_time { FindNewTarget; reacq = 0 }
mode 1:    if fire request != locked target: reacq += dt;
           if reacq > reacquire_time { fire request = locked; reacq = 0 }
target = FindInstance(fire request +0x84)
if target:
    ComputeAnglesToTarget (0x10033180: FindLocalTarget -> iiGun::FindAimPoint
        lead -> heading/elevation degrees, 0x10033000)
    if within min/max heading+elevation (0x10033420): Slew(h, el, dt)
    else if (mode 1 && locked): FindNewTarget       ; designated out of reach
    else: slew to stow
else: slew to stow (0x10033470: step by max_*_velocity * dt, no shortest-path)
energy: if energy < capacity { energy += TRIWeight * efficiency * power * dt,
        clamp; SetUsage(1) } else SetUsage(0)
```

**The shot energy bank only exists on powered turrets**: `IsReadyToFire`
(`0x10033790`) returns 4 ("no energy") only when `power > 0` and
`energy < shot_energy_cost`; every `nps_turret_*.ini` has no `power` key, so
NPC turrets never gate on energy (the player point-defence/dock-on turrets,
`power=50`, do). `Fire` (`0x100337d0`) is `energy -= shot_energy_cost` then
`iiGun::Fire`. GetHUDInfo (`0x10033db0`) reports `energy/capacity * 100`.

**FindNewTarget** (`0x10033890`): scans every world sim within **25 km**
(6.25e8 m^2), skipping `icGeography`. Mode 2 takes only missiles (sim type
`+0x194 == 8`) whose **aggressor** is hostile; other modes take ships (type >
10). Hostile = faction FeelingType 0, OR anything on the player's contact
list when the turret is on the player's own ship (`0x10033de0`). It prefers
the nearest candidate inside the slew limits (`0x10033270` -> `0x10033420`)
and falls back to the last hostile seen even out of arc.

**The muzzle follows the slew**: `InternalOrientation` (`0x10033af0`) builds
the quaternion from `heading * 0.0174533` (`0x10119930`) and `-elevation`
(`0x10119934`); SetAngles (`0x10033bd0`) drives the avatar's `heading`
channel (`h / 360`, `0x1011993c`) and `elevation` channel (`0.5 - el / 180`,
`0x10119938`) -- that is what visibly turns the turret model.

**Fire cycle summary**: `iiWeapon::Simulate` (`0x1003cc00`) calls
`AttemptToActivateWeapon` (`0x1003ccb0`) every frame; in AUTO mode the target
comes from the fire request `+0x84` (or the ship's contact-list target, only
if hostile when the ship has no AI pilot); mode 0 returns 0xc; an LDS-engaged
ship returns 0xb; CFS failure in AUTO is silent (9). So a turret fires the
moment its slewed muzzle brings the (possibly jittered) lead point inside its
1-degree fire arc, at most once per `refire_delay`.

### 11.3 What mounts turrets

- **Gunstars** are ordinary `icShip`s (`sims/ships/navy/gunstar*.ini`,
  6000 hp / armour 90) with 4 icTurrets on `hardpoint_gun_1..4` nulls
  authored in `sims/ships/common_setups/gunstar.lws` -- the nulls sit on the
  hull faces with their +Y outward, so each turret covers one hemisphere
  face and the four together cover the sphere. The map's "gunstar" habitat
  category (kind 6) is such a ship parked as a station.
- **Stations** (`sims/stations/*.ini`) mount `nps_pseudo_turret.ini` -- an
  **icCannon** with 90-degree fire arcs, i.e. a fixed gun pretending
  (the custom gunstar station, `sims/stations/custom/gunstar.ini`, uses 4).
- Warships: `heavy_destroyer_turret.ini`, `old_destroyer_turreted.ini`,
  `corp_cruiser_turrets.ini` mount `nps_turret_cannon_*` icTurrets.

### 11.4 ihabitat.SetArmed -- iiSim::ConfigureWeapons

The POG natives live in their own wrapper DLL. `ihabitat.dll @ 0x10002840`
(SetArmed) / `@ 0x10002910` (SetArmedWithTarget) resolve the habitat (must be
`icStation`-derived) and call virtual `+0xfc`:

```
SetArmed(hab, true)          ConfigureWeapons(1, 0, 0)
SetArmed(hab, false)         ConfigureWeapons(0, 0, 1)   = LockDownWeapons
SetArmedWithTarget(hab, t)   ConfigureWeapons(1, t, 0)
```

`iiSim::ConfigureWeapons(bool armed, iiSim* target, bool lockdown)`
(`0x1007b8a0`), for every `iiWeapon` subsim:

- lockdown -> fire mode 0 (off; turrets slew to stow);
- on the player's true ship, magazines and slug throwers stay manual (mode 0
  here means "the pilot's trigger");
- otherwise AUTO (mode 2) if the weapon's muzzle points backwards (muzzle
  forward . ship forward <= 0), or it is an `icCounterMeasureMagazine`, or an
  `icTurret`; anything else gets `armed + 1`;
- with a target: fire request `+0x84` = target id, icTurrets `SetMode(1)`;
  without: `+0x84 = 0`, icTurrets keep their authored mode (2 stays point
  defence, else 0). `ConfigureWeaponsForAI` (`0x10001590`) is the same call
  with the AI pilot's victim -- an engaging AI warship arms its turrets this
  way.

The shipped scripts (`istation.pog`) arm stations exclusively through
`SetArmedWithTarget` when a hostile closes within **15 000 m** (the
station-protection handler) and disarm with `SetArmed(x, 0)` when the player
leaves the area.

### 11.5 icTurretShip (the turret fighter) -- NOT BUILT

`0x330`-byte icShip subclass; props `max_heading_velocity +0x300` and static
`sensor_update_time` (`flux.ini [icTurretShip]` = 1). `Think` (`0x10034700`,
raw-disassembled): when enabled (`+0x318`), mode 2 tracks the contact-list
target (refreshed every `sensor_update_time`), mode 3 a designated id
(`+0x324`); `FUN_10034200` lead-solves at a **hardcoded 6000 m/s** and
`FUN_10034190` yaws the whole hull at `max_heading_velocity`. Only
`sims/ships/player/turret_fighter*.ini` use it; the loadout system that
launches turret fighters is not built (see the icMissileMagazine unknown in
10.10), so the remaster stubs the class.

---

## 12. Beam weapons

```
iiWeapon
  icBeamProjector  reg 0x1002f980, ctor 0x1002fc50, 0xd4 bytes   the mount
iiSim
  icBeam           reg near 0x10064f20 (map), ctor 0x100650a0, 0x228 bytes
                   the BEAM ITSELF IS A SIM riding the muzzle
```

### 12.1 icBeamProjector

Property map (`0x1002fa20`): `beam_template +0xac`, `capacity +0xb0`,
`beam_power_drain +0xb4`, `min_fire_energy +0xb8`, `ai_charge_per_second
+0xbc`, static `heat_scale` (`flux.ini [icBeamProjector]` = 5; compiled
default 1.0 `0x1015b2c4`). Runtime: range `+0xc0`, energy `+0xc4`, live beam
sim id `+0xc8`, firing flag `+0xcc`, live-last-frame flag `+0xcd`, scripted
fire timer `+0xd0`.

- **Load** (`0x10030370`, raw-disassembled): creates the icBeam from
  `beam_template`, keeps its id at `+0xc8`, and range `+0xc0` = the beam's
  `length` (`beam+0x1d8`). `Range` (`0x100302b0`) returns the live beam's
  length, or **1500** (`0x1011961c`) with none.
- **Simulate** (`0x1002fee0`, raw-disassembled): the scripted-fire timer
  `+0xd0` counts down, holding the trigger (`+0xa8`) while it runs. Then
  `prev = firing(+0xcc); firing = 0; live(+0xcd) = prev`. **While not live**:
  recharge `energy += TRIWeight * efficiency * power * dt` up to capacity
  (usage 1 while charging, else 0); in AUTO mode additionally the free NPC
  charge `energy += ai_charge_per_second * dt` -- and **only at FULL capacity
  with a fire-request target does an AUTO beam light up** (`+0xcc = 1`).
  Then `iiWeapon::Simulate`, the avatar's fire channel, force feedback.
- **IsReadyToFire** (`0x10030480`): with `power > 0`, needs
  `energy > min_fire_energy` to start; **once live it fires down to zero**
  (`+0xcd` switches the test). A drawless NPC projector (power=0) skips the
  gate entirely.
- **The fire path** (`0x100300c0`, the vtable `+0x54` trigger): on activation,
  if the beam is not yet live: `energy <= min_fire_energy` -> stop (result
  4), else start the beam -- owner `beam+0x1ec` = strong-root id, target
  `beam+0x1f0` = fire request, ramp reset (`0x10065830`: `+0x224 = 0.01`),
  add the beam sim to the world. Every firing frame: pin the beam to the
  world muzzle (position + orientation); **if `|ai_charge_per_second| <
  1e-6`** (`0x101178fc`) add ship internal heat
  `sqrt(beam.damage_rate) * heat_scale * dt` (so the self-charging NPC beams
  run cold, the player's don't -- section 6); drain
  `energy -= beam_power_drain * dt`, at <= 0 clamp to 0 and stop.
- **CFS** (`0x100304e0`): the target must sit in the muzzle **cylinder**:
  ahead (`z > 0` in muzzle frame), `dist^2 <= range^2`, and `|x|` and `|y|`
  each within the target's radius. `SetFireRequest` (`0x100305e0`) also
  scales the live beam's damage rate by TRIWeight (`beam+0x1e0 =
  TRIWeight * beam+0x1e4`).

### 12.2 icBeam -- the damage

Property map (`0x10064f20`): `length +0x1d8`, `penetration +0x1dc`,
`damage_rate +0x1e0`, `antimatter_based +0x1e8`. Runtime: INI damage rate
copy `+0x1e4`, owner `+0x1ec`, target `+0x1f0`, nearest-hit distance
`+0x1f8` (reset to FLT_MAX every frame), hit sim `+0x1f4`, hit position
`+0x200`, hit normal `+0x218`, ramp `+0x224` (ctor 0.01). The ctor also sets
`SetRadius(length)` -- the whole beam is one sim for the collision system.

- **OnCollision** (`0x10065840`): records the CLOSEST contact along the beam
  axis (`dot(forward, contact - muzzle)`), its position and normal.
- **Think** (`0x100652c0`, raw-disassembled): the ramp grows `+= dt / 0.75`
  (`0x1011ab30`) to 1 -- the beam VISUAL extends to full length over 0.75 s
  (`avatar z-scale = length * ramp * 0.5`, also `Integrate 0x100656f0`). If a
  contact was recorded: the visual shortens to the hit
  (`ramp = hit_dist / length`), an impact effect spawns at the hit point
  (effect type 4 through the manager at `0x10173908`), and

  ```
  victim->ApplyWeaponDamage(damage_rate * dt,          ; CONTINUOUS
                            penetration * 7.5,         ; 0x1011ac34
                            hit_pos, hit_dir, this, owner, src=1)
  ```

  **eDamageSource 1 skips the LDA loop** (`icShip::ApplyWeaponDamage
  0x10073e2e` only scans LDAs for source 0): a beam cannot be
  shield-deflected. Armour still divides it -- but at `penetration * 7.5`
  (antimatter beam: 70 -> 525 effective) **no shipped hull's armour reduces a
  beam**. Subsim criticals apply every frame, which is why beams shred
  subsystems. There is no ramp gate on the damage: the sweep hits at full
  authored length from the first frame.

### 12.3 The authored beams

| beam INI (`sims/weapons/`) | length | pen | damage_rate | projector (`subsims/systems/`) | capacity | drain | min_fire | ai_charge | power |
|---|---|---|---|---|---|---|---|---|---|
| `antimatter_beam` | 3000 | 70 | 4000 | `player/antimatter_beam` | 1800 | 300 | 300 | -- | 250 |
| `capital_ship_beam` | 10000 | 70 | 6000 | `nonplayer/nps_capital_beam_weapon` | 100 | 0 | 1 | 100 | 0 |
| `cutting_beam` | 2500 | 60 | 1500 | `player/cutting_beam` | 1500 | 250 | 250 | -- | 150 |
| `nps_cutting_beam` | 2500 | 60 | 1000 | `nonplayer/nps_beam_weapon` | 1800 | 500 | 10 | 300 | 0 |
| `mining_beam` | 1500 | 55 | 1000 | `player/mining_laser` (also `nonplayer/nps_mining_laser`) | 1200 | 200/300 | 100/200 | -- | 100/0 |
| `comms_laser_beam` | 2500 | 20 | 300 | `player/comms_laser` | 900 | 150 | 100 | -- | 75 |

So the NPC cutting beam burns `capacity/drain = 3.6 s` for 3600 total damage,
then recharges 6 s; the capital beam (drain 0) simply never stops while it
has a solution. `antimatter_based` marks the beam for the antimatter-immunity
checks (`IsAntimatterBasedWeapon`, vtable `+0xdc` reads `+0x1e8`).

The visual is an `icBeamAvatar` axial billboard (docs/effects.md): half-width
= the avatar's authored x-scale (`beam_antimatter` 1.8 m, `beam_capital`
10 m), length driven by the engine, u scrolling along the beam; glow colours
from the avatar lights (antimatter/capital purple 149,1,211; mining/comms
cyan 62,220,255; cutting orange 253,165,0). The exact LWS texture bindings
did not survive the avatar extract; the remaster matches by name
(`am_beam`, `beam_blue`, `cutting_beam` under `images/sfx`).

### 12.4 Turret and beam constants

| address | value | what |
|---|---|---|
| `0x10033890` (imm) | 6.25e8 | FindNewTarget scan range^2 (25 km) |
| `0x1011849c` | 40.0 | min target radius for the jitter roll |
| `0x10119adc` | 0.0349066 | 2 deg in rad, the jitter angle unit |
| `0x10117d8c` | 0.75 | solved-speed floor fraction (= flux.ini min_speed_fraction) |
| `0x10119924` | 57.2958 | rad->deg in every angle path |
| `0x10119930` | 0.0174533 | heading deg->rad (InternalOrientation) |
| `0x10119934` | -0.0174533 | elevation deg->rad (negated) |
| `0x1011993c` | 0.00277778 | 1/360, avatar heading channel |
| `0x10119938` | 0.00555556 | 1/180, avatar elevation channel |
| `0x1011ab30` | 0.75 | beam ramp time (s to full length) |
| `0x1011ac34` | 7.5 | beam penetration multiplier |
| `0x1011961c` | 1500.0 | icBeamProjector::Range fallback |
| `0x1011a70c` | 0.01 | beam avatar z-scale factor (x0.5) |
| `0x1015b2c4` | 1.0 | icBeamProjector::m_heat_scale default (flux.ini 5) |
| `0x101178fc` | 1e-06 | the epsilon on the ai_charge heat gate |
| `flux.ini [iiGun]` | 0.4 / 0.75 / 0.75 / 1.5 | min_travel_time / min_speed_fraction / max_jitter_angle / max_jitter_radius |
| `flux.ini [icTurretShip]` | 1.0 | sensor_update_time |

### 12.5 Turret/beam unknowns

Not recovered. **Do not fill these in with plausible values.**

- **The heading fold.** `0x10033000` folds heading into [0, 360) and mirrors
  elevation past +/-90, yet the authored limits are signed
  (`min_heading = -160`). How the limit test (`0x10033420`, a plain
  `min <= x <= max`) meets the folded angle was not reconciled; the remaster
  keeps heading signed in (-180, 180], which makes the authored limits test
  directly and matches the arcs the INIs describe.
- **The mount null convention.** The engine composes the muzzle from the
  setup-scene null's orientation x the turret's slew quaternion. Our LWS
  hpb -> basis conversion (`ExplosionFx._hpb_basis`, the repo's established
  reading of the same scene data) puts the gunstar turret's azimuth axis on
  the null's +Y (outward), which is geometrically coherent, but the axis
  convention was not verified against the renderer.
- **`FUN_1002f900`** (`0x1002f900`): an AI utility on the beam projector
  returning `TRIWeight * (x/min_fire)^2 * ai_charge` clamped to 0.25..5
  (`0x1015b214/0x1015b210`) times the ship's max hull -- a target-priority
  weight, caller not traced.
- **The icBeamAvatar textures and scroll speed** for the weapon beams (the
  `speed` property of each beam avatar's LWS node): the setup.gltf extract
  keeps class + lights + scale but not the texture/speed bindings.
- **`icTurretShip` beyond Think** (`0x100348d0` Simulate, the `+0x2b0`
  contact refresh via `0x1003ab00`): partially read, class stubbed.
- **The impact-effect table** behind `0x100d3210` (beam sparks, effect
  type 4).

---

## Player devices (task #51)

### icAggressorShield (+ icAggressorAvatar)

Not a shield in the LDA sense at all: it is registered with base **`iiWeapon`**
(`iwar2 @ 0x1002efa0`, `operator_new(0xcc)`, ctor `0x1002f290`), and it is a
**ram**. You charge it, fire it, and whatever you hit head-on takes a multiple of
*your own hull* in damage while you take a fraction of that back.

Fitted at the type-2048 mountpoint (`subsims/mountpoints/aggressor_shield.ini`),
which the tug carries as an *empty socket*; `heavy_corvette_prefitted.ini` and
`fast_attack_prefitted.ini` come with `subsims/systems/player/aggressor` fitted.
Two devices ship: `aggressor.ini` (Cargo_AggressorShieldUpgrade) and
`military_aggressors.ini` (Cargo_MilitaryAggressorShields).

Property map `0x1002f040`:

| INI key | field | aggressor | military |
|---|---|---:|---:|
| `duration` | +0xac | 3.0 | 5.0 |
| `capacity` | +0xb0 | 1000 | 1500 |
| `coverage` | +0xb4 | 90 | 140 |
| `sweet_speed` | +0xb8 | 800 | 1200 |
| `damage_factor` | +0xbc | 1.0 | 1.5 |
| `self_damage_factor` | +0xc0 | 0.1 | 0.05 |

Runtime: `energy` +0xc4, `active` +0xc8. Class statics: `min_damage_factor`
**0.25** (`0x1015b214`), `max_damage_factor` **5.0** (`0x1015b210`), and
`penetration_armour_factor` **0.7** (`0x1015b20c`) -- which is registered in the
property map and **never read anywhere in iwar2.dll**: UNKNOWN what it scaled.
The ctor's `sweet_speed` default is 2000.0 (both shipped INIs override it).

The methods:

* **Fire** (vtable slot 28, `0x1002f6a0`) is one instruction -- `mov byte
  [ecx+0xc8], 1`. That is the whole of it.
* **IsReadyToFire** (slot 22, `0x1002f5c0`) refuses while it is already up
  (result 0xd) and refuses unless the bank is **completely full** --
  `abs(energy - capacity) < 1e-6` (`0x101178fc`), else result 4. There is no
  partial discharge. (The `Mode() == 2` branch at `0x1002f5e5` is the AI's: an
  AI-piloted aggressor only fires while its `icAITarget` is `IsAvoiding`.)
* **Simulate** (slot 19, `0x1002f410`) sets the avatar's **`"fire"` channel**
  (`0x1015b22c`) to the active flag, then:
  * active: `energy -= dt * capacity / duration`, so the bank empties over
    exactly `duration` seconds; it drops at empty, and it drops the instant the
    **LDS drive engages** (`0x1002f52a`: `icShip+0x25c`, the `icLDSDrive`, state
    `+0x84 == 2`).
  * idle: `energy += TRIWeight() * efficiency * power`, clamped to `capacity`.
    **There is no `dt` in that expression.** At `0x1002f579` the compiler reuses
    the now-dead `dt` argument slot as scratch for the efficiency, so the
    multiply chain at `0x1002f582` picks up efficiency and power and nothing
    else. `icPlayerLDA::Simulate` does the identical three multiplies at
    `0x100acb7e` **and then an `fmul [esp+0x14]` for dt** -- the aggressor simply
    has no such instruction. It recharges per *frame*. This is presumably why the
    thing is called an *instant* shield (the control program's cargo name is
    `Cargo_InstantShieldControl`). We keep the per-call form, exactly as we
    already do for the heat-damage tick.
* **DamageAtSpeed** (`0x1002f900`) is the curve:

      d = clamp((speed / sweet_speed)^2 * damage_factor * TRIWeight(), 0.25, 5.0)
      damage = ship.hit_points (icShip+0x1b0) * d

  Quadratic, and floored -- so even a stationary ram lands 0.25 of your hull. The
  INI's comment ("in multiples of ship's hit points") is exact.
* **OnCollision** (`0x1002f6b0`) has two halves.
  * *Auto-fire* (`0x1002f6b7`-`0x1002f77e`): gated on the CPU being fitted, being
    **working**, and carrying **program bit 0x1000** (`test ch, 0x10` @
    `0x1002f6fd` -- the aggressor-shield control program). It then fires the
    shield at anything about to hit you that is not friendly
    (`icShip::IsFriendly`) and is not one of the excluded sim types 7/8/9/12/31
    (`0x1002f721`).
  * *Effect* (`0x1002f792`): the other ship must lie inside the coverage cone
    dead ahead -- `dot(normalize(other.pos - ship.pos), ship.forward) >=
    cos(coverage * pi/360)`, the same half-arc idiom as the LDA hood
    (`0x101195a0` = pi/360). Inside it: the victim takes
    `DamageAtSpeed(abs(ship.velocity))` on the raw hull path (**source 5**,
    `0x1002f8b0`), the shield's own ship takes that **same number** times
    `self_damage_factor` (**source 4**, `0x1002f8d0` -- `fld [esp+0x24]; fmul
    [esi+0xc0]`), and the collision is reported **handled**, which is what makes
    `iiSim::OnCollision` skip the ordinary collision damage for both ships.

**icAggressorAvatar** (registered `0x100b9050`, ctor `0x100b9280`, Prepare
`0x100b9460`, Draw `0x100b94e0`) is the **same cone fan as `icLDAAvatar`** --
Draw's only geometry call is `FUN_100c9f40` @ `0x100b95e1`. It is textured
`texture:/images/sfx/aggressor` (`0x101615b8`), additive, rim radius +0xbc (ctor
default 0.1), and its texture's `v` scrolls at **1 unit/s** (`0x1011c824`) off the
node's own clock (+0xc0, accumulated in Prepare). UNKNOWN: the LWS node's world
scale -- we size the shell to the player's collision radius instead.

### icWeaponLink

A weapon link is a **fire group**, and the player never builds one -- the loadout
does it automatically whenever a hull carries **more than one of the same weapon**.

`icLoadout::CreateWeaponLinks` (`0x10096940`) walks the ship's subsims, keeps the
`iiWeapon`-derived ones and buckets them **by the INI `name=`** (FcObject +0xc):

| class | bucket | eLinkType | eFireChannel |
|---|---|---:|---:|
| `icCounterMeasureMagazine` | **excluded outright** (tested first, `0x10096a4c`, because it derives from icMagazine) | -- | -- |
| `icCannon` (base `iiGun`), `icSlugThrower` | A | 0 | 1 |
| `icBeamProjector` | B | 1 | 2 |
| `icMagazine` | C | 2 | 2 |

`icLoadout::RemoveSingleInstancesOfWeapon` (`0x10096cd0`) then throws away every
bucket with fewer than two members -- one gun is not a group.
`icLoadout::DoLinkWeapons` (`0x10096e40`) makes one `icWeaponLink`
(`operator_new(0xa0)`, vtable `0x10119e40`) per surviving bucket: fire channel at
+0x88 = `(linktype != 0) + 1`, eLinkType at +0x90, the member array at
+0x7c/+0x80/+0x84, and `FiSim::AddSubsim`s the link onto the ship as a subsim of
its own. The link's property map is `iiShipSystem`'s -- it has **no INI
properties**.

What the link *does* is in `iiWeapon::AttemptToActivateWeapon` (`0x1003ccb0`): a
player-mode weapon fires only when the pilot's selected object id (the id at
`pilot+0x98[pilot+0x8c]`) matches -- and the id it matches against is the weapon's
own (`0x1003cd3e`) when it has no link, but **the link's** (`0x1003cd4b` /
`0x1003cd5c`) when it has one. So one entry in the cycle selects the whole group
and every member fires on the same trigger. `icPlayerPilot::GetNextWeapon`
(`0x100b0590`) cycles that id list, which holds bare weapons *and* links side by
side, filtered by fire channel.

On `tug_prefitted.ini` this comes out as the game always presented it: the two
`pbc` subsims share an INI name, so they are the hull's **one** link (type 0,
channel 1, two members) and fire as a pair; the assault cannon, quad light PBC,
mining laser and the magazines are singles. The decoy magazine
(icCounterMeasureMagazine) is correctly excluded.

**Two things are UNKNOWN and stay that way.** `icShip::WeaponLinkingMode` (+0x2f4)
/ `WeaponLinkingHardware` (+0x2f8) and `icPlayerPilot::ToggleWeaponLinking`
(`0x100b0f60`, log events 0x29/0x2a/0x2b) are a *separate* player toggle gated on
`Cargo_WeaponLinkHardware` being fitted -- but **nothing in iwar2.dll reads +0x2f4
other than the accessor**, so what the toggle switches was not recovered; and the
hardware's template, `ini:/subsims/systems/player/subsystems/weapon_link` (cargo
type 555, `icargoscript.gd:5477`), **does not ship** -- the file is absent from
the game's data, exactly like `Cargo_Autopilots`' missing `autopilot_program`.

### icProgram -- the software subsims

`icProgram` (registered `0x10031d30`, base `FcSubsim`, `operator_new(0x44)`) has
**exactly one property**: `program_id` at +0x40 (map `0x10031e80`). Everything
else in the ten shipped INIs (`subsims/systems/player/programs/*.ini`, all
identical but for `name` and `program_id`) belongs to the `FcSubsim` parent map.

`icLoadout::LoadComputerPrograms` (`0x10095ea0`) is the fitting rule, and it is
not what you would guess: the loadout INI's `[Priority] program=` list is a
**priority order**, not a fit list. For each entry in order, while the CPU's
`memory_slots` (+0x7c) budget lasts, the program is fitted **only if the player
actually owns the cargo** (`icInventory::NumberOfCargoType` @ `0x100a59b0`); its
`program_id` is then OR-ed into the mask (`or ebp, esi` @ `0x1009609c`), which is
written through the icCPU property map's `programs` key to **icCPU +0x80**.
`icShip::HasProgram` (`0x10002a70`) is the accessor.

| program | bit | what the bit gates in the engine |
|---|---:|---|
| `autopilot_matchvel` | 4 | Case 4 of the autopilot switch. Without it `EngageAutopilotMatchVelocity` (`0x100aff10`) is never called -- the pilot just logs a refusal. Formate/Approach/Dock are ungated. |
| `engine_manage_program` | 32 | `icReactor::Simulate` (`0x1003a2a0`, test @ `0x1003a3e4`): final power output *= `cpu.engine_management_power_multiplier` (+0x84). No heat cost, no CPU-working check. |
| `mil_tracking_program` | 64 | `iiGun::ComputeFiringSolution` (`0x10035310`, test @ `0x100354b6`): the gunnery aim-error ceiling drops from **4** to **1**. (`military_tracking_accuracy_multiplier` at icCPU+0x88 is **never read** -- a dead INI key.) |
| `occlusion_program` | 128 | `icSensor`'s detection sweep (`FUN_1003ae90`, test @ `0x1003b3b4`): detect-brightness *= cpu+0x90, detect-range *= cpu+0x8c. |
| `repair_control_program` | 256 | `icAutorepair::Simulate` (`0x1002c7a0`, test @ `0x1002c7dc`): repair output *= `repair_output_multiplier` (+0x94). |
| `self_defense_program` | 512 | `icPlayerPilot::RemoteLink` (`0x100b1110`): the ship you leave behind when you remote-link gets an `icAIPilot` instead of sitting inert. Fires nowhere else. |
| `stealth_program` | 1024 | `icShip::Brightness` (`0x10075420`): `b -= cpu.stealth_brightness_modifier` (+0x98). Demands a working CPU. |
| `hyperspace_tracker` | 2048 | `icCapsuleSpace::RegisterJump` (already in act3.md) **plus**, newly found, `icPlayerContactList::PostProcess` (`0x100aada0`): the current target is *retained* in the contact list when it drops off sensors instead of being dropped. |
| `aggressor_shield_control` | 4096 | The aggressor auto-fire above (`0x1002f6fd`). |
| `imaging_module` | 8192 | `icPlayerPilot::Think` (`0x100ad8f0`, test @ `0x100ae191`) and `EnableZoom` (`0x100b0e80`): **zoom without a sniper weapon fitted**. |

Bits 0x1 / 0x2 / 0x8 / 0x10 are used by no shipped INI and tested nowhere.

**What single player actually fits.** Fitting is never scripted. The campaign
*gives* the player exactly **two** programs: `Cargo_StealthProgram` (194) at
`iact1mission08.gd:287`, on one dialogue branch, and `Cargo_HyperspaceTracker`
(312) at `iact2mission05.gd:110` / `iacttwo.gd:538`. Everything else must be
bought as cargo. (`Cargo_MatchVelocityAutopilot` is added only by
`igivepursuit.gd`, whose one export has **no caller** in any ported package --
dead in the shipped game.) All four loadouts list all ten programs and differ only
in their priority order.

## icShip::Brightness and the reactor gauge (task #53)

Both are in `ship_systems.gd`; both correct things the docs previously had wrong.

**`icShip::Brightness()` (`0x10075420`, vtable slot +0xc8)** is the ship's 0..1
EM/visual signature -- the number the whole stealth system runs on, because
`icSensor`'s scan (`FUN_1003ae90`) scores a contact as
`efficiency * Brightness * (1 - dist/range)`.

    b  = min_brightness                       (icShip +0x2fc, ship INI min_brightness)
    b *= reactor.charge / reactor.max_charge  (+0x7c / +0x98; 1.0 if no reactor)
    b  = (m_brightness - b) * ThrusterRatio() + b        <-- DEAD, see below
    b += (heat + heat_external) * 0.4 / heat_damage_threshold   (0.4 @ 0x10117558)
    b += sensor_disruptor.brightness_mod       when ON (+0x7c; negative, -0.15)
    b += active_sensor.efficiency * active_sensor.brightness_mod  (+0x78 * +0x80)
    b -= cpu.stealth_brightness_modifier       when CPU working AND program 0x400
    b *= 0.1                                   when docked at an icStation (0x101184b0)
    return clamp(b, 0, 1)

Two corrections:

* **`ThrusterRatio()` is a stub.** `icShip::ThrusterRatio` (`0x10075600`) is seven
  bytes -- `fld dword [0x10117178]; ret` -- and `0x10117178` is `0.0`. The lerp at
  `0x10075499` therefore collapses to `b`, and the ship INI's `brightness`
  (icShip +0x1b8) is **never reached** on the local path; only `min_brightness` is.
  (+0x1b8 is the network-replicated value, returned early for proxies.)
* The terms are **not** "heat / LDS / weapon capacitor". The four subsims icShip
  caches are `icCPU` (+0x29c), `icReactor` (+0x2a0), `icActiveSensor` (+0x2a4) and
  `icSensorDisruptor` (+0x2a8), and those are what Brightness reads. Consequently
  `cold_thrusters.ini`'s `brightness_mod = -0.1` looks **dead** -- its class is
  `icThrusters` (+0x290), which Brightness never touches.

**The reactor gauge is a misnomer.** `icReactor::Simulate` (`0x1003a2a0`) stores
nothing and drains nothing:

    ramp(+0x9c) chases ramp_target(+0xa0) at 1/ramp_up_time per second
    out   = base_output(+0x94)  [* pod_power_factor when a pod is fitted and on]
    +0x98 = out                              <- the gauge's DENOMINATOR (rated output)
    +0x7c = efficiency * out * ramp          <- the gauge's NUMERATOR  (this frame's output)
    +0x7c *= cpu.engine_management_power_multiplier   when program bit 0x20
    icShip::AddPower(+0x7c)

So the gauge reads `efficiency * ramp`, its **equilibrium is `efficiency`** (1.0
for a healthy, cool, powered reactor -- verified in a harness), and it goes red
below 0.25 (`0x101191ec`) only when the reactor is damaged, overheated, or
throttled down. The only thing that moves the target is the HUD throttle
(`FUN_10108240`), which drags +0xa0 at **0.35/s** (`_DAT_10163f14`). Property map
`0x10039f40`: `output_power` +0x7c, `has_power_pod` +0x80, `pod_power_factor`
+0x84, `pod_heat_factor` +0x88, `ramp_up_time` +0x8c (ctor default **20.0**; only
`powerplant_multiplayer.ini` overrides it, to 2.0). The HUD feed
(`FUN_100e07f0`) defaults the gauge to **1.0**, not 0, when no reactor is fitted.

We start the ramp settled rather than at the ctor's 0, because our ships are
constructed at the moment they enter play rather than at level load; the 20 s
cold-start transient is the one part of this we do not reproduce.
