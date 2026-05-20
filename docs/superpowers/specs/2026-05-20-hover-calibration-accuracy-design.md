# Hover Calibration Accuracy — Design Spec
**Date:** 2026-05-20

## Problem

After calibration, every island floats a constant number of blocks above its target altitude (observed: 6 blocks), regardless of target. Manually reducing `HOVER_RSC` by a small amount corrects this. The constant offset means the calibrated `HOVER_RSC` is systematically too high.

**Root cause:** Phase 1 calibration ramps RSC upward and declares liftoff when vertical velocity exceeds `0.5 m/s` for 4 consecutive steps. By the time that threshold is consistently met, the island has already built up momentum and risen several blocks. The RSC at that point is well above the true static hover point (net thrust = gravity). The PID I-term cannot correct the residual error because `PID_INTEGRAL_MAX = 10` limits the I-term's RSC contribution to `0.5 units` — far too small to compensate a multi-unit HOVER_RSC error.

**Secondary concern:** During calibration the island keeps rising, meaning the detected RSC is biased by the altitude it has drifted to by detection time.

---

## Solution Overview

1. Replace the single-pass ramp with a **two-phase calibration**: a fast rough liftoff detection followed by a binary search that converges on the RSC where steady-state velocity ≈ 0.
2. Raise `PID_INTEGRAL_MAX` from `10` to `40` so residual calibration error can be absorbed.
3. Add **in-flight HOVER_RSC trim learning** (option C): after the island reaches steady state, fold the accumulated I-term into `HOVER_RSC` and reset the integral.

---

## Section 1 — Calibration Algorithm Redesign (`calibrate.lua`)

### Phase 1 — Rough liftoff detection

Same upward ramp as today, but with tighter parameters to stop before the island gains momentum:

| Constant | Old | New | Reason |
|---|---|---|---|
| `LIFT_THRESHOLD` | `0.5 m/s` | `0.05 m/s` | Catch first movement, not sustained climb |
| `SUSTAIN_NEEDED` | `4` | `2` | Stop sooner |
| `ALTITUDE_GUARD` | — | `3 blocks` | Hard cap: if island has risen 3 blocks from start, treat as liftoff regardless |

Result: `liftoff_rsc`. Island is only 1–2 blocks above starting position at this point.

### Phase 2 — Binary search refinement

With the island airborne, binary search for the RSC where steady-state vertical velocity ≈ 0.

**Bounds:**
- Upper: `liftoff_rsc` (known to cause upward motion)
- Lower: `liftoff_rsc - 25` (below true hover for any expected island weight)

**Per-iteration procedure:**
1. Set RSC to midpoint
2. Wait `1.5 s` for velocity to settle
3. Sample velocity `8` times over `~0.4 s`, compute average
4. Decision:
   - avg vel `> +0.08 m/s` → too high → search lower half
   - avg vel `< -0.08 m/s` OR island altitude < search-start altitude → too low (falling/landed) → search upper half
   - `|avg vel| ≤ 0.08 m/s` → converged, record as `HOVER_RSC`

**Iterations:** 7 (precision: `25 / 2^7 ≈ 0.2 RSC units`)

**Altitude floor recovery:** If the lower bound causes the island to land on the first iteration, raise the lower bound by `5` and restart the search. Prevents an overly aggressive lower bound from corrupting the result.

After convergence: ramp down, save `HOVER_RSC` to `config.lua`.

---

## Section 2 — PID Integral Cap (`config.lua`)

Raise `PID_INTEGRAL_MAX` default from `10.0` to `40.0`.

With `KI = 0.05`, this allows up to `2.0 RSC` of steady-state I-term correction — enough to absorb small calibration imprecision without risking windup.

---

## Section 3 — In-Flight HOVER_RSC Trim Learning (`main.lua`)

After the island has been in steady state for `20 consecutive seconds`, fold the accumulated I-term into `HOVER_RSC`:

**Steady-state condition:** `|error| < 2 × HOLD_DEADBAND` AND `|velocity| < 0.1 m/s`, both true for the full window.

**Trim step:**
```
delta = KI × integral
if |delta| > 15:  -- sanity guard against sensor glitch
    print warning, skip
else:
    Config.HOVER_RSC += delta
    integral = 0
    save Config.HOVER_RSC to config.lua
```

**Properties:**
- Fires at most once per steady-state window, no file thrashing
- If calibration is accurate, `delta ≈ 0` and nothing changes
- Converges across flights: by the second flight, `HOVER_RSC` is dialled in
- Sanity guard (`|delta| > 15`) prevents a sensor glitch from corrupting config

---

## Files Changed

| File | Change |
|---|---|
| `calibrate.lua` | Replace Phase 1 ramp logic; add Phase 2 binary search |
| `config.lua` | Raise `PID_INTEGRAL_MAX` to `40`; add new calibration constants as comments |
| `main.lua` | Add steady-state trim learning block inside flight loop |

---

## Error Handling

| Scenario | Behaviour |
|---|---|
| Phase 1 never detects liftoff by RSC 256 | Existing `ERROR: No liftoff detected` message, abort |
| Phase 2 lower bound causes immediate landing on first try | Raise lower bound by 5, restart search |
| Binary search does not converge in 7 iterations | Use midpoint of final bracket as best estimate, print warning |
| Trim delta exceeds 15 RSC | Skip write, print warning |

---

## What Is Not Changed

- PID Phase 2 auto-tuning logic (runs after improved `HOVER_RSC`, so gains are tuned against an accurate baseline automatically)
- Pressure compensation logic
- Motor, Sensors, Network, Telemetry modules
