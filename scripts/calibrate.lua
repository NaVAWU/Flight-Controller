-- calibrate.lua
-- Run on a flat surface to find the RSC value that just lifts the island.
-- Saves the result as HOVER_RSC in config.lua for use as a gravity feedforward.

local Config  = require("config")
local Sensors = require("sensors")

local STEP_INTERVAL  = 0.3    -- seconds per RSC step
local LIFT_THRESHOLD = 0.2    -- m/s upward velocity = liftoff detected
local SUSTAIN_STEPS  = 3      -- must stay above threshold for this many consecutive steps

local function patchConfig(src, key, val)
    return (src:gsub("Config%." .. key .. "%s*=[^\n]*", "Config." .. key .. " = " .. val))
end

-- ── Setup ────────────────────────────────────────────────────

print("=== RSC Hover Calibration ===")
print("Place the island on a flat surface.")
print("Press Enter to begin.")
read()

local state = { seaLevelPressure = nil }
Sensors.init()
Sensors.calibrate(state)

local rsc = peripheral.wrap(Config.RSC)
assert(rsc, "No RSC found on side: " .. Config.RSC)

-- ── Ramp ─────────────────────────────────────────────────────

print("Ramping RSC slowly. Do not move the island.")
print("")
write("  RSC:   0  vel: +0.000 m/s")
local _, displayRow = term.getCursorPos()

local hoverRSC    = nil
local sustainCount = 0

for speed = 0, 256 do
    rsc.setTargetSpeed(speed)
    sleep(STEP_INTERVAL)

    local vel = Sensors.getVerticalVelocity()

    term.setCursorPos(1, displayRow)
    term.clearLine()
    write(("  RSC: %3d  vel: %+.3f m/s  [%d/%d]"):format(speed, vel, sustainCount, SUSTAIN_STEPS))

    if vel >= LIFT_THRESHOLD then
        sustainCount = sustainCount + 1
        if sustainCount >= SUSTAIN_STEPS then
            hoverRSC = speed - SUSTAIN_STEPS + 1  -- first step that triggered
            break
        end
    else
        sustainCount = 0  -- reset on any dip below threshold
    end
end

rsc.setTargetSpeed(0)
print("")

-- ── Result ───────────────────────────────────────────────────

if not hoverRSC then
    print("ERROR: No liftoff detected up to RSC 256.")
    print("Check that the RSC peripheral is connected and the island is not anchored.")
    return
end

print(("Liftoff detected at RSC = %d"):format(hoverRSC))

local f = fs.open("config.lua", "r")
local src = f.readAll()
f.close()

if src:find("Config%.HOVER_RSC") then
    src = patchConfig(src, "HOVER_RSC", tostring(hoverRSC))
else
    src = src:gsub("return Config", "Config.HOVER_RSC = " .. tostring(hoverRSC) .. "\nreturn Config")
end

local g = fs.open("config.lua", "w")
g.write(src)
g.close()

print("Saved HOVER_RSC = " .. hoverRSC .. " to config.lua.")
print("Run 'main' to start the flight controller.")
