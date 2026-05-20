# Hover Calibration Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the constant altitude offset caused by HOVER_RSC being calibrated too high, by replacing the single-pass ramp with a two-phase binary-search calibration, raising the integral cap, and adding in-flight trim learning.

**Architecture:** Phase 1 calibration is tightened (lower velocity threshold + altitude guard) to stop the ramp before the island gains momentum. Phase 2 binary-searches between `liftoff_rsc` and `liftoff_rsc - 25` until steady-state velocity ≈ 0. The flight loop gains a 20-second steady-state window that folds the accumulated I-term into `HOVER_RSC` and resets the integral, self-correcting any residual offset across flights.

**Tech Stack:** Lua (ComputerCraft / CC: Tweaked), Minecraft ATM10 modpack, `sublevel` API for velocity, `altitude_sensor` peripheral for height.

---

### Task 1: Raise PID_INTEGRAL_MAX in config.lua

**Files:**
- Modify: `scripts/config.lua`

- [ ] **Step 1: Change PID_INTEGRAL_MAX from 10.0 to 40.0**

In `scripts/config.lua`, find and replace:

```lua
-- Before:
Config.PID_INTEGRAL_MAX = 10.0            -- anti-windup clamp

-- After:
Config.PID_INTEGRAL_MAX = 40.0            -- anti-windup clamp
```

With `KI = 0.05`, this raises the maximum I-term RSC contribution from 0.5 to 2.0, enough to absorb small calibration imprecision.

- [ ] **Step 2: Confirm the file**

Open `scripts/config.lua` and confirm `Config.PID_INTEGRAL_MAX = 40.0`.

- [ ] **Step 3: Commit**

```bash
git add scripts/config.lua
git commit -m "config: raise PID_INTEGRAL_MAX to 40 for better steady-state correction"
```

---

### Task 2: Rewrite Phase 1 liftoff detection in calibrate.lua

**Files:**
- Modify: `scripts/calibrate.lua`

- [ ] **Step 1: Update the calibration constants block**

In `scripts/calibrate.lua`, replace the four constants at the top of the file (lines 9–12):

```lua
-- Before:
local RAMP_INTERVAL    = 0.35  -- seconds per RSC step during ramp
local SAMPLES_PER_STEP = 5     -- velocity readings averaged per ramp step
local LIFT_THRESHOLD   = 0.5   -- m/s average velocity = confirmed liftoff
local SUSTAIN_NEEDED   = 4     -- consecutive steps that must stay above threshold

-- After:
local RAMP_INTERVAL    = 0.35  -- seconds per RSC step during ramp
local SAMPLES_PER_STEP = 5     -- velocity readings averaged per ramp step
local LIFT_THRESHOLD   = 0.05  -- m/s: catch first movement, not sustained climb
local SUSTAIN_NEEDED   = 2     -- consecutive steps above threshold to confirm liftoff
local ALTITUDE_GUARD   = 3     -- blocks: force liftoff detection if island rises this far
```

- [ ] **Step 2: Capture starting altitude before the Phase 1 ramp loop**

In `scripts/calibrate.lua`, find the block that reads:

```lua
local hoverRSC    = nil
local sustainCount = 0
local peakRSC     = 0
```

Replace it with:

```lua
local startAlt    = Sensors.getHeight()
local hoverRSC    = nil
local sustainCount = 0
local peakRSC     = 0
```

- [ ] **Step 3: Add altitude guard to the Phase 1 loop**

In `scripts/calibrate.lua`, replace the entire `for speed = 0, 256 do` loop:

```lua
-- Before:
for speed = 0, 256 do
    rsc.setTargetSpeed(speed)
    sleep(RAMP_INTERVAL)
    peakRSC = speed

    local vel = avgVel(SAMPLES_PER_STEP)
    statusLine(statusRow, "  RSC: %3d  vel: %+.3f  [%d/%d]",
               speed, vel, sustainCount, SUSTAIN_NEEDED)

    if vel >= LIFT_THRESHOLD then
        sustainCount = sustainCount + 1
        if sustainCount >= SUSTAIN_NEEDED then
            hoverRSC = math.max(0, speed - SUSTAIN_NEEDED + 1)
            break
        end
    else
        sustainCount = 0
    end
end

-- After:
for speed = 0, 256 do
    rsc.setTargetSpeed(speed)
    sleep(RAMP_INTERVAL)
    peakRSC = speed

    local vel   = avgVel(SAMPLES_PER_STEP)
    local risen = Sensors.getHeight() - startAlt
    statusLine(statusRow, "  RSC: %3d  vel: %+.3f  risen: %.1fm  [%d/%d]",
               speed, vel, risen, sustainCount, SUSTAIN_NEEDED)

    if vel >= LIFT_THRESHOLD or risen >= ALTITUDE_GUARD then
        sustainCount = sustainCount + 1
        if sustainCount >= SUSTAIN_NEEDED then
            hoverRSC = math.max(0, speed - SUSTAIN_NEEDED + 1)
            break
        end
    else
        sustainCount = 0
    end
end
```

- [ ] **Step 4: Confirm the loop**

Read through the loop and verify:
- `startAlt` is referenced before the loop
- `risen` is computed each iteration
- Both `vel >= LIFT_THRESHOLD` and `risen >= ALTITUDE_GUARD` can trigger `sustainCount`
- `hoverRSC` assignment is unchanged

- [ ] **Step 5: Commit**

```bash
git add scripts/calibrate.lua
git commit -m "calibrate: tighten Phase 1 threshold to 0.05 m/s and add altitude guard"
```

---

### Task 3: Add Phase 2 binary search to calibrate.lua

**Files:**
- Modify: `scripts/calibrate.lua`

- [ ] **Step 1: Add binary search constants**

In `scripts/calibrate.lua`, add these six constants immediately after the `ALTITUDE_GUARD` line:

```lua
local BINARY_ITER     = 7     -- iterations (gives 25/2^7 ≈ 0.2 RSC precision)
local BINARY_LO_RANGE = 25    -- RSC units below liftoff_rsc to start search
local BINARY_SETTLE   = 1.5   -- seconds to let velocity settle per iteration
local BINARY_SAMPLES  = 8     -- velocity readings per iteration
local BINARY_DEADBAND = 0.08  -- m/s: island is hovering if |vel| is within this
local BINARY_RECOVER  = 1.5   -- seconds to re-lift if island lands during search
```

- [ ] **Step 2: Add the binarySearchHover function**

In `scripts/calibrate.lua`, add the following function immediately after the `rampDown` function (after its closing `end`):

```lua
local function binarySearchHover(liftoffRSC, rsc, binaryRow)
    local lo             = math.max(0, liftoffRSC - BINARY_LO_RANGE)
    local hi             = liftoffRSC
    local searchStartAlt = Sensors.getHeight()
    local result         = math.floor((lo + hi) / 2)

    -- Validate lower bound: if island lands immediately raise it by 5
    rsc.setTargetSpeed(lo)
    sleep(BINARY_SETTLE)
    if Sensors.getHeight() < searchStartAlt - 0.5 then
        lo = lo + 5
        rsc.setTargetSpeed(hi)
        sleep(BINARY_RECOVER)
        searchStartAlt = Sensors.getHeight()
    end

    for i = 1, BINARY_ITER do
        local mid = math.floor((lo + hi) / 2)
        rsc.setTargetSpeed(mid)
        sleep(BINARY_SETTLE)

        local vel        = avgVel(BINARY_SAMPLES)
        local currentAlt = Sensors.getHeight()
        statusLine(binaryRow, "  Binary [%d/%d] RSC=%3d  vel=%+.3f",
                   i, BINARY_ITER, mid, vel)

        if math.abs(vel) <= BINARY_DEADBAND then
            result = mid
            break
        elseif vel > BINARY_DEADBAND then
            hi = mid        -- island rising: RSC too high
        else
            lo = mid        -- island falling: RSC too low
            if currentAlt < searchStartAlt - 0.5 then
                -- Island landed; re-lift before continuing
                rsc.setTargetSpeed(hi)
                sleep(BINARY_RECOVER)
                searchStartAlt = Sensors.getHeight()
            end
        end
        result = math.floor((lo + hi) / 2)
    end

    return result
end
```

- [ ] **Step 3: Wire Phase 2 into the Phase 1 result block**

In `scripts/calibrate.lua`, find the block that runs after the Phase 1 loop ends (currently around lines 115–129). Replace it:

```lua
-- Before:
print("")
print("Stopping engines...")
rampDown(peakRSC, rsc)
print("Engines stopped.")
print("")

if not hoverRSC then
    print("ERROR: No liftoff detected up to RSC 256.")
    print("Check that the RSC peripheral is connected and the island can move freely.")
    return
end

print(("Hover point: RSC = %d"):format(hoverRSC))
saveConfig({ HOVER_RSC = tostring(hoverRSC) })
print("Saved HOVER_RSC to config.lua.")

-- After:
print("")

if not hoverRSC then
    print("Stopping engines...")
    rampDown(peakRSC, rsc)
    print("Engines stopped.")
    print("ERROR: No liftoff detected up to RSC 256.")
    print("Check that the RSC peripheral is connected and the island can move freely.")
    return
end

print(("Rough liftoff RSC = %d — refining with binary search..."):format(hoverRSC))
print("")
write(("  Binary [0/%d] ..."):format(BINARY_ITER))
local _, binaryRow = term.getCursorPos()

local roughRSC   = hoverRSC
local refinedRSC = binarySearchHover(roughRSC, rsc, binaryRow)

print("")
print("Stopping engines...")
rampDown(peakRSC, rsc)
print("Engines stopped.")
print("")

print(("Hover point: RSC = %d  (rough liftoff was %d)"):format(refinedRSC, roughRSC))
hoverRSC = refinedRSC
saveConfig({ HOVER_RSC = tostring(hoverRSC) })
print("Saved HOVER_RSC to config.lua.")
```

- [ ] **Step 4: Verify the full Phase 1 → Phase 2 flow end-to-end**

Read `scripts/calibrate.lua` from the start of the Phase 1 ramp through to the Phase 2 PID tuning prompt and confirm:
- If Phase 1 finds no liftoff → engines ramp down, script returns early, Phase 2 is never called
- If Phase 1 finds liftoff → `roughRSC` captured, `binarySearchHover` called with `roughRSC`
- After binary search → engines ramp down via `rampDown(peakRSC, rsc)`
- `hoverRSC` is set to `refinedRSC` before it is used by Phase 2 PID step-tests

- [ ] **Step 5: Commit**

```bash
git add scripts/calibrate.lua
git commit -m "calibrate: add Phase 2 binary search to converge on true hover RSC"
```

---

### Task 4: Add in-flight HOVER_RSC trim learning to main.lua

**Files:**
- Modify: `scripts/main.lua`

- [ ] **Step 1: Add saveHoverRSC helper after the clamp function**

In `scripts/main.lua`, add the following function immediately after the `clamp` function (after line ~43):

```lua
local function saveHoverRSC(value)
    local f = fs.open("config.lua", "r")
    if not f then return end
    local src = f.readAll(); f.close()
    local result, n = src:gsub(
        "Config%.HOVER_RSC%s*=[^\n]*",
        "Config.HOVER_RSC = " .. tostring(value))
    if n == 0 then
        result = result:gsub(
            "return Config",
            "Config.HOVER_RSC = " .. tostring(value) .. "\nreturn Config")
    end
    local g = fs.open("config.lua", "w")
    g.write(result); g.close()
end
```

- [ ] **Step 2: Add trim state variables before the flightLoop function**

In `scripts/main.lua`, add these five lines immediately before `local function flightLoop()`:

```lua
local _steadyStart = nil
local TRIM_WINDOW  = 20                      -- seconds of steady state before trimming
local TRIM_MAX     = 15                      -- RSC: sanity cap on trim delta
local TRIM_VEL     = 0.1                     -- m/s: max velocity to qualify as steady
local TRIM_ERR     = Config.HOLD_DEADBAND * 2  -- metres: max error to qualify as steady
```

- [ ] **Step 3: Insert the trim learning block inside the flight loop**

In `scripts/main.lua`, find the `logStatus()` call inside `flightLoop` (around line 94). Insert the following block immediately before it:

```lua
        -- Trim learning: once the island has been steady for TRIM_WINDOW seconds,
        -- fold the I-term into HOVER_RSC so the integral starts fresh next flight.
        local trimEligible = absErr < TRIM_ERR
                          and math.abs(State.currentVelocity) < TRIM_VEL
        if trimEligible then
            if not _steadyStart then _steadyStart = now end
            if now - _steadyStart >= TRIM_WINDOW then
                local delta = Config.PID_KI * controller._integral
                if math.abs(delta) > TRIM_MAX then
                    print(("[TRIM] delta %.2f exceeds limit — skipping"):format(delta))
                else
                    Config.HOVER_RSC = Config.HOVER_RSC + delta
                    controller:reset()
                    local saved = math.floor(Config.HOVER_RSC + 0.5)
                    saveHoverRSC(saved)
                    print(("[TRIM] HOVER_RSC updated to %d (delta %+.2f)"):format(saved, delta))
                end
                _steadyStart = nil
            end
        else
            _steadyStart = nil
        end
```

- [ ] **Step 4: Confirm variable availability**

Check that in the flight loop at the point of insertion:
- `now` is defined: `local now = os.clock()` — yes, line ~67
- `absErr` is defined: `local absErr = math.abs(error)` — yes, line ~73
- `controller` is in scope: defined before `flightLoop` is called — yes, line ~27
- `Config.PID_KI` is available: loaded at top of file — yes

- [ ] **Step 5: Commit**

```bash
git add scripts/main.lua
git commit -m "main: add in-flight HOVER_RSC trim learning to self-correct residual calibration error"
```

---

### Task 5: In-game verification

ComputerCraft has no automated test runner. Verification is done by observation in-game.

- [ ] **Step 1: Test Phase 1 — island should stop rising quickly**

Run `calibrate` on a test island. Observe the Phase 1 status line:
- `risen` should stay at `0.0–2.0m` when liftoff is triggered
- Previously the island would climb many blocks before detection

- [ ] **Step 2: Test Phase 2 — binary search prints and converges**

Still in the calibration run, observe Phase 2:
- Seven lines of `Binary [N/7] RSC=XXX vel=±Y.YYY` should appear
- The final `HOVER_RSC` should be lower than the rough liftoff RSC
- Compare the printed `rough liftoff was N` vs `Hover point: RSC = M`; M should be smaller

- [ ] **Step 3: Test altitude accuracy in main**

Run `main`. Island should reach target altitude within ≈1 block (vs. previous 6-block overshoot).

- [ ] **Step 4: Test trim learning**

With `main` running and the island holding at target, wait 20+ seconds without moving the island or changing target:
- A `[TRIM] HOVER_RSC updated to N (delta ±X.XX)` line should appear
- If calibration was accurate, delta will be near 0 and nothing meaningful changes
- If there was residual error, delta corrects it

- [ ] **Step 5: Test trim convergence across flights**

Stop `main` and restart it. The updated `HOVER_RSC` in `config.lua` should now be the trimmed value. Island should reach target with ≤1 block error without needing to wait for trim to fire again.
