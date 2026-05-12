-- ============================================================
--  telemetry.lua
--  Streams island status to the central WebSocket hub.
--  Call Telemetry.send(state) once per second from a loop.
--  Reconnects automatically if the connection drops.
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Telemetry = {}

local _ws = nil

local function connect()
    local ws, err = http.websocket(Config.HUB_URL, {
        ["Authorization"] = "Bearer " .. Config.HUB_TOKEN,
    })
    if ws then
        _ws = ws
        print("[TEL] Connected to hub.")
        return true
    end
    print("[TEL] Connection failed: " .. tostring(err))
    return false
end

function Telemetry.isConnected()
    return _ws ~= nil
end

-- Send current state to the hub. Reconnects on failure.
function Telemetry.send(state)
    if not _ws then
        if not connect() then return end
    end

    local payload = textutils.serialiseJSON({
        type     = "status",
        island   = Config.ISLAND_ID,
        altitude = state.currentAltitude,
        target   = state.targetAltitude,
        velocity = state.currentVelocity,
        mode     = state.mode,
        pressure = Sensors.getAirPressure(),
    })

    local ok, err = pcall(_ws.send, payload)
    if not ok then
        print("[TEL] Send error: " .. tostring(err))
        pcall(_ws.close)
        _ws = nil
    end
end

function Telemetry.close()
    if _ws then
        pcall(_ws.close)
        _ws = nil
    end
end

return Telemetry
