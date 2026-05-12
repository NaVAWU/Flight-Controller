-- ============================================================
--  network.lua
--  Rednet for inter-island communication.
--
--  Protocol (all messages are Lua tables):
--
--  Inbound commands (sent TO this island):
--    { cmd="SET_ALTITUDE",    target=<number>, from=<string> }
--    { cmd="STATUS_REQUEST",  from=<string> }
--    { cmd="SHUTDOWN",        from=<string> }
--
--  Outbound replies (sent FROM this island):
--    { cmd="STATUS_REPLY", from=<string>, altitude=<n>,
--      target=<n>, mode=<string>, pressure=<n> }
-- ============================================================

local Config  = require("config")
local Sensors = require("sensors")

local Network = {}

local _available = false
local _pid       = nil   -- injected reference so network can reset it

-- ── COMMAND HANDLERS ────────────────────────────────────────

local _handlers = {}

_handlers["SET_ALTITUDE"] = function(senderId, msg, state)
    if type(msg.target) ~= "number" then return end
    print(("[NET] %s → SET_ALTITUDE %d"):format(msg.from or senderId, msg.target))
    state.targetAltitude = msg.target
    if _pid then _pid:reset() end
end

_handlers["STATUS_REQUEST"] = function(senderId, msg, state)
    rednet.send(senderId, {
        cmd      = "STATUS_REPLY",
        from     = Config.ISLAND_ID,
        altitude = state.currentAltitude,
        target   = state.targetAltitude,
        mode     = state.mode,
        pressure = Sensors.getAirPressure(),
    })
    print(("[NET] STATUS_REPLY sent to %s"):format(msg.from or senderId))
end

_handlers["SHUTDOWN"] = function(senderId, msg, state)
    print(("[NET] Shutdown command received from %s."):format(msg.from or senderId))
    state.running = false
end

-- ── PUBLIC API ───────────────────────────────────────────────

-- Attempt to open the modem. Safe to call even if no modem is present.
function Network.init(pidController)
    _pid = pidController

    if not Config.SIDE_MODEM then
        print("[NET] Networking disabled (SIDE_MODEM is nil).")
        return
    end

    local ok = pcall(function()
        rednet.open(Config.SIDE_MODEM)
    end)

    if ok then
        _available = true
        print(("[NET] Rednet online on '%s', channel %d."):format(
            Config.SIDE_MODEM, Config.REDNET_CHANNEL))
    else
        print("[NET] No modem found — running standalone.")
    end
end

-- Returns true if networking is available
function Network.isAvailable()
    return _available
end

-- Non-blocking poll; dispatches one message per call if one is waiting.
-- Designed to be called inside a parallel coroutine that yields with sleep(0).
function Network.poll(state)
    if not _available then return end

    local evt = table.pack(os.pullEvent("rednet_message"))
    local senderId = evt[2]
    local msg      = evt[3]

    if type(msg) ~= "table" or type(msg.cmd) ~= "string" then return end

    local handler = _handlers[msg.cmd]
    if handler then
        handler(senderId, msg, state)
    else
        print(("[NET] Unknown command '%s' from %s"):format(msg.cmd, senderId))
    end
end

return Network
