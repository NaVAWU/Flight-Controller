-- calibrate.lua
-- Phase 1: Find HOVER_RSC — the RSC value that just lifts the island.
-- Phase 2: Auto-tune PID gains via step-response tests.

local Config  = require("config")
local Sensors = require("sensors")

-- ── Constants ────────────────────────────────────────────────
local RAMP_INTERVAL    = 0.35  -- seconds per RSC step during ramp
local SAMPLES_PER_STEP = 5     -- velocity readings averaged per ramp step
local LIFT_THRESHOLD   = 0.05  -- m/s: catch first movement, not sustained climb
local SUSTAIN_NEEDED   = 2     -- consecutive steps above threshold to confirm liftoff
local ALTITUDE_GUARD   = 3     -- blocks: force liftoff detection if island rises this far

local BINARY_ITER     = 7     -- iterations (gives 25/2^7 ≈ 0.2 RSC precision)
local BINARY_LO_RANGE = 25    -- RSC units below liftoff_rsc to start search
local BINARY_SETTLE   = 1.5   -- seconds to let velocity settle per iteration
local BINARY_SAMPLES  = 8     -- velocity readings per iteration
local BINARY_DEADBAND = 0.08  -- m/s: island is hovering if |vel| is within this
local BINARY_RECOVER  = 1.5   -- seconds to re-lift if island lands during search

local STEP_METRES      = 8     -- altitude change for each PID test
local TEST_TIMEOUT     = 22    -- seconds allowed for island to reach step target
local RETURN_TIMEOUT   = 18    -- seconds allowed to return to base altitude
local DT               = 0.1   -- loop interval during tests (seconds)
local MAX_OVERSHOOT    = 1.2   -- acceptable overshoot in metres

-- ── Helpers ──────────────────────────────────────────────────

local function patchConfig(src, key, val)
    local result, n = src:gsub(
        "Config%." .. key .. "%s*=[^\n]*",
        "Config." .. key .. " = " .. val)
    if n == 0 then
        -- Key missing — insert before "return Config"
        result = result:gsub(
            "return Config",
            "Config." .. key .. " = " .. val .. "\nreturn Config")
    end
    return result
end

local function saveConfig(patches)
    local f = fs.open("config.lua", "r")
    local src = f.readAll(); f.close()
    for k, v in pairs(patches) do src = patchConfig(src, k, v) end
    local g = fs.open("config.lua", "w")
    g.write(src); g.close()
end

-- Average N velocity readings spread over ~0.2 s to reduce noise.
local function avgVel(n)
    local sum = 0
    for i = 1, n do
        sum = sum + Sensors.getVerticalVelocity()
        if i < n then sleep(0.04) end
    end
    return sum / n
end

local function statusLine(row, fmt, ...)
    term.setCursorPos(1, row)
    term.clearLine()
    write(fmt:format(...))
end

local function rampDown(fromRSC, rsc)
    for s = fromRSC, 0, -3 do
        rsc.setTargetSpeed(s)
        sleep(0.04)
    end
    rsc.setTargetSpeed(0)
end

-- groundAlt is the pre-ramp ground level so we can distinguish
-- "hovering at vel≈0" from "sitting on the ground at vel≈0".
local function binarySearchHover(liftoffRSC, rsc, binaryRow, groundAlt)
    local lo             = math.max(0, liftoffRSC - BINARY_LO_RANGE)
    local hi             = liftoffRSC
    local searchStartAlt = Sensors.getHeight()
    local result         = math.floor((lo + hi) / 2)
    local AIRBORNE_MIN   = groundAlt + 0.5  -- below this = grounded

    -- Validate lower bound: if island is on or near ground, raise lo
    rsc.setTargetSpeed(lo)
    sleep(BINARY_SETTLE)
    if Sensors.getHeight() <= AIRBORNE_MIN then
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

        if currentAlt <= AIRBORNE_MIN then
            -- Island grounded: RSC is too low regardless of velocity reading
            lo = mid
            rsc.setTargetSpeed(hi)
            sleep(BINARY_RECOVER)
            searchStartAlt = Sensors.getHeight()
        elseif math.abs(vel) <= BINARY_DEADBAND then
            result = mid
            break
        elseif vel > BINARY_DEADBAND then
            hi = mid        -- island rising: RSC too high
        else
            lo = mid        -- island falling: RSC too low
            if currentAlt < searchStartAlt - 0.5 then
                rsc.setTargetSpeed(hi)
                sleep(BINARY_RECOVER)
                searchStartAlt = Sensors.getHeight()
            end
        end
        result = math.floor((lo + hi) / 2)
    end

    print("")   -- advance cursor past binary status line
    return result
end

-- ── Init ─────────────────────────────────────────────────────

print("=== Island Calibration ===")
print("")

local state = { seaLevelPressure = nil }
Sensors.init()

-- ── Phase 1: Hover point ──────────────────────────────────────

print("Phase 1 - Hover point detection")
print("Place the island on a flat surface, then press Enter.")
read()

Sensors.calibrate(state)

local rsc = peripheral.wrap(Config.RSC)
assert(rsc, "No RSC on side: " .. Config.RSC)

print("Ramping RSC slowly — do not move the island.")
print("")
write(("  RSC:   0  vel: +0.000  [0/%d]"):format(SUSTAIN_NEEDED))
local _, statusRow = term.getCursorPos()

local startAlt    = Sensors.getHeight()
local hoverRSC    = nil
local sustainCount = 0
local peakRSC     = 0

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
local refinedRSC = binarySearchHover(roughRSC, rsc, binaryRow, startAlt)

print("")
print("Stopping engines...")
rampDown(peakRSC, rsc)
print("Engines stopped.")
print("")

print(("Hover point: RSC = %d  (rough liftoff was %d)"):format(refinedRSC, roughRSC))
hoverRSC = refinedRSC
saveConfig({ HOVER_RSC = tostring(hoverRSC) })
print("Saved HOVER_RSC to config.lua.")

-- ── Phase 2: PID tuning ───────────────────────────────────────

print("")
print("Phase 2 - PID auto-tuning (optional)")
print("Move the island to open air (20+ m clearance above).")
print("Press Enter to begin tuning, or type 'skip'.")
if read():lower() == "skip" then
    print("Skipped. Run 'main' to start the flight controller.")
    return
end

Sensors.calibrate(state)

-- Run the island toward (currentAlt + stepM) for TEST_TIMEOUT seconds.
-- Then return it to baseAlt. Returns response characteristics.
local function stepTest(kp, kd, ki, imax)
    local baseAlt   = Sensors.getHeight()
    local targetAlt = baseAlt + STEP_METRES

    local integral  = 0
    local prevErr   = nil
    local prevTime  = os.clock()
    local startTime = prevTime

    local maxAlt    = baseAlt
    local reached   = false
    local above     = false
    local crossings = 0

    -- Ascent phase
    while os.clock() - startTime < TEST_TIMEOUT do
        local now = os.clock()
        local dt  = math.max(0.001, now - prevTime)
        prevTime  = now

        local alt = Sensors.getHeight()
        local err = targetAlt - alt
        if alt > maxAlt then maxAlt = alt end

        if not above and alt >= targetAlt then
            above = true; reached = true
        elseif above and alt < targetAlt - 0.5 then
            above = false; crossings = crossings + 1
        end

        integral = math.max(-imax, math.min(imax, integral + err * dt))
        local deriv = prevErr and (err - prevErr) / dt or 0
        prevErr = err

        local comp = Sensors.pressureCompensation(state)
        local out  = (kp * err + ki * integral + kd * deriv + hoverRSC) * comp
        rsc.setTargetSpeed(math.max(-Config.MAX_RSC_SPEED, math.min(Config.MAX_RSC_SPEED, out)))
        sleep(DT)
    end

    -- Return phase (P-only, back to base)
    local retStart = os.clock()
    while os.clock() - retStart < RETURN_TIMEOUT do
        local alt = Sensors.getHeight()
        if math.abs(alt - baseAlt) < 0.8 then break end
        local comp = Sensors.pressureCompensation(state)
        local out  = (kp * (baseAlt - alt) + hoverRSC) * comp
        rsc.setTargetSpeed(math.max(-Config.MAX_RSC_SPEED, math.min(Config.MAX_RSC_SPEED, out)))
        sleep(DT)
    end
    rsc.setTargetSpeed(hoverRSC)
    sleep(1.5)

    return {
        reached     = reached,
        overshoot   = math.max(0, maxAlt - targetAlt),
        oscillating = crossings >= 2,
    }
end

-- Find KP ─────────────────────────────────────────────────────
print("")
print("Finding KP (KI=0, KD=0)...")

local lo_kp  = 0.2
local hi_kp  = 5.0
local bestKP = 0.5

for _ = 1, 8 do
    local kp = (lo_kp + hi_kp) / 2
    write(("  KP=%.3f ... "):format(kp))
    local r = stepTest(kp, 0, 0, 50)

    if r.oscillating then
        print(("oscillating (overshoot %.1fm) — too high"):format(r.overshoot))
        hi_kp = kp
    elseif r.reached then
        print(("reached  overshoot %.2fm"):format(r.overshoot))
        bestKP = kp
        hi_kp  = kp  -- try to find smaller working KP
    else
        print("did not reach target — too low")
        lo_kp = kp
    end
end

print(("KP = %.3f"):format(bestKP))

-- Find KD ─────────────────────────────────────────────────────
print("")
print(("Finding KD (KP=%.3f, KI=0)..."):format(bestKP))

local bestKD = 0

local r0 = stepTest(bestKP, 0, 0, 50)
if r0.overshoot <= MAX_OVERSHOOT and not r0.oscillating then
    print(("KD=0 already acceptable (overshoot %.2fm)."):format(r0.overshoot))
else
    local kd = 0.05
    for _ = 1, 10 do
        write(("  KD=%.3f ... "):format(kd))
        local r = stepTest(bestKP, kd, 0, 50)

        if not r.reached then
            print("lost target — KD too high, backing off")
            bestKD = kd * 0.6
            break
        elseif r.overshoot <= MAX_OVERSHOOT and not r.oscillating then
            print(("OK  overshoot %.2fm"):format(r.overshoot))
            bestKD = kd
            break
        else
            print(("overshoot %.2fm — increasing"):format(r.overshoot))
            kd = kd * 1.6
            if kd > 4 then print("KD limit reached."); bestKD = kd * 0.6; break end
        end
    end
end

print(("KD = %.3f"):format(bestKD))

-- KI and INTEGRAL_MAX (conservative — I-term only trims residual drift)
local bestKI   = 0.05
local bestIMax = math.max(20, math.floor(Config.MAX_RSC_SPEED * 0.25))

-- Graceful shutdown after tuning
print("")
print("Tuning complete. Stopping engines...")
rampDown(hoverRSC, rsc)
print("Engines stopped.")

-- Summary ─────────────────────────────────────────────────────
print("")
print("=== Results ===")
print(("HOVER_RSC        = %d"):format(hoverRSC))
print(("PID_KP           = %.3f"):format(bestKP))
print(("PID_KI           = %.3f"):format(bestKI))
print(("PID_KD           = %.3f"):format(bestKD))
print(("PID_INTEGRAL_MAX = %d"):format(bestIMax))
print("")
write("Save to config.lua? [y/n]: ")
if read():lower() ~= "n" then
    saveConfig({
        HOVER_RSC        = tostring(hoverRSC),
        PID_KP           = ("%.3f"):format(bestKP),
        PID_KI           = ("%.3f"):format(bestKI),
        PID_KD           = ("%.3f"):format(bestKD),
        PID_INTEGRAL_MAX = tostring(bestIMax),
    })
    print("Config saved. Run 'main' to start the flight controller.")
else
    print("Not saved.")
end
