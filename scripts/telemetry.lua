-- ============================================================
--  telemetry.lua
--  Streams island status to the central WebSocket hub and
--  handles commands sent back from the server (SET_ALTITUDE,
--  SHUTDOWN). Call Telemetry.init(controller) once, then
--  Telemetry.tick(state) in a loop (blocks ~1s per call).
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Telemetry = {}

local _ws  = nil
local _pid = nil   -- injected so SET_ALTITUDE can reset it

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

-- ── Command handlers ─────────────────────────────────────────

local _cmdHandlers = {}

_cmdHandlers["SET_ALTITUDE"] = function(msg, state)
    if type(msg.target) ~= "number" then return end
    print(("[TEL] SET_ALTITUDE → %dm"):format(msg.target))
    state.targetAltitude = msg.target
    if _pid then _pid:reset() end
end

_cmdHandlers["SHUTDOWN"] = function(msg, state)
    print("[TEL] SHUTDOWN received from hub.")
    state.running = false
end

local function handleCommand(raw, state)
    local ok, msg = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(msg) ~= "table" or type(msg.cmd) ~= "string" then return end
    local handler = _cmdHandlers[msg.cmd]
    if handler then
        handler(msg, state)
    else
        print(("[TEL] Unknown command: %s"):format(msg.cmd))
    end
end

-- ── Public API ────────────────────────────────────────────────

-- Call once at startup, passing the PID controller so SET_ALTITUDE can reset it.
function Telemetry.init(pidController)
    _pid = pidController
    if Config.HUB_URL then connect() end
end

function Telemetry.isConnected()
    return _ws ~= nil
end

-- Send status and wait up to 1 second for an incoming command.
-- Reconnects automatically on send failure.
function Telemetry.tick(state)
    if not _ws then
        if not connect() then sleep(1); return end
    end

    -- Send status
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
        sleep(1)
        return
    end

    -- Wait up to 1s for a command from the server
    local raw = _ws.receive(1)
    if raw and raw ~= '{"ok":true}' then
        handleCommand(raw, state)
    end
end

function Telemetry.close()
    if _ws then
        pcall(_ws.close)
        _ws = nil
    end
end

return Telemetry
