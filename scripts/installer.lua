-- installer.lua — run this on the CC computer to install or update.
-- • Only writes files that have changed (config.lua is never overwritten).
-- • Self-updates: rewrites itself and restarts if the remote version differs.
-- • First install: interactive wizard pre-filled with detected peripherals.

local REPO_API   = "https://api.github.com/repos/NaVAWU/Flight-Controller/contents/scripts"
local CONFIG_FILE = "config.lua"
local SIDES       = { "top", "bottom", "left", "right", "front", "back" }

-- ── Helpers ──────────────────────────────────────────────────

local function fmtBytes(n)
    if n >= 1024 * 1024 then return ("%.1f MB"):format(n / (1024 * 1024))
    elseif n >= 1024    then return ("%.1f KB"):format(n / 1024)
    else                     return (n .. " B")
    end
end

local function readLocal(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local c = f.readAll(); f.close()
    return c
end

local function writeFile(path, content)
    local f = fs.open(path, "w")
    f.write(content); f.close()
end

-- Replace  Config.KEY = <anything up to EOL>  in a config file string.
local function patchConfig(src, key, luaValue)
    return (src:gsub("Config%." .. key .. "%s*=[^\n]*",
                     "Config." .. key .. " = " .. luaValue))
end

-- Prompt with an optional bracketed default; returns default on empty input.
local function ask(label, default)
    write(label)
    if default ~= nil then write(" [" .. tostring(default) .. "]") end
    write(": ")
    local v = read()
    return (v == "" and default or v)
end

local function askSide(label, default)
    local valid = {}
    for _, s in ipairs(SIDES) do valid[s] = true end
    while true do
        local v = ask(label, default)
        if valid[v] then return v end
        print("  Must be one of: " .. table.concat(SIDES, " / "))
    end
end

local function askSideOrNone(label, default)
    local valid = { none = true }
    for _, s in ipairs(SIDES) do valid[s] = true end
    while true do
        local v = ask(label, default)
        if valid[v] then return v end
        print("  Must be a side or 'none': " .. table.concat(SIDES, " / "))
    end
end

-- ── Fetch file list from GitHub ──────────────────────────────

print("Fetching file list from GitHub...")
local res = http.get(REPO_API)
assert(res, "Failed to reach GitHub API. Check your connection.")

local data = textutils.unserialiseJSON(res.readAll())
res.close()
assert(type(data) == "table", "Unexpected response from GitHub API.")

-- ── Self-update (runs before everything else) ─────────────────

local selfPath = shell.getRunningProgram()
local selfName = fs.getName(selfPath)

for _, entry in ipairs(data) do
    if entry.name == selfName then
        local r = http.get(entry.download_url)
        if r then
            local rc = r.readAll(); r.close()
            if rc ~= readLocal(selfPath) then
                writeFile(selfPath, rc)
                print("Installer updated — restarting...")
                print("")
                shell.run(selfPath)
                return
            end
        end
        break
    end
end

-- ── Peripheral scan (used later as wizard defaults) ───────────

local detected = {}   -- side → peripheral type
for _, side in ipairs(SIDES) do
    local t = peripheral.getType(side)
    if t then detected[side] = t end
end

-- Returns the first side whose peripheral type contains the substring.
local function findSide(sub)
    for side, t in pairs(detected) do
        if t:lower():find(sub, 1, true) then return side end
    end
end

-- ── Main update loop (skips installer + config) ───────────────

local configIsNew    = not fs.exists(CONFIG_FILE)
local configTemplate = nil   -- populated if config.lua is new
local freeStart      = fs.getFreeSpace("/")
local updated, unchanged, failed = 0, 0, 0

for _, entry in ipairs(data) do
    if entry.type == "file" and entry.name:match("%.lua$") then

        if entry.name == selfName then
            -- already handled above

        elseif entry.name == CONFIG_FILE then
            if configIsNew then
                -- Download template for the wizard to patch; don't write yet.
                local r = http.get(entry.download_url)
                if r then configTemplate = r.readAll(); r.close() end
            end
            -- Existing config is never touched.

        else
            local r = http.get(entry.download_url)
            if not r then
                print("  FAIL  " .. entry.name)
                failed = failed + 1
            else
                local rc = r.readAll(); r.close()
                local lc = readLocal(entry.name)
                if rc == lc then
                    unchanged = unchanged + 1
                else
                    writeFile(entry.name, rc)
                    print((lc == nil and "  NEW   " or "  UPDATE") .. " " .. entry.name)
                    updated = updated + 1
                end
            end
        end
    end
end

-- ── First-time setup wizard ───────────────────────────────────

if configIsNew and configTemplate then
    print("")
    print("============================================")
    print("          First-time Island Setup           ")
    print("============================================")

    if next(detected) then
        print("Peripherals detected:")
        for side, ptype in pairs(detected) do
            print(("  %-8s  %s"):format(side, ptype))
        end
    else
        print("(No peripherals detected — enter sides manually.)")
    end

    print("")
    print("Press Enter to accept the value shown in [brackets].")
    print("")

    -- Island identity
    local islandId = ask("Island ID", "island_1")
    configTemplate = patchConfig(configTemplate, "ISLAND_ID", '"' .. islandId .. '"')

    -- Peripheral sides
    print("")
    local motorSide  = askSide("Motor side   (electric_motor)",  findSide("motor")    or "left")
    local sensorSide = askSide("Sensor side  (altitude_sensor)", findSide("altitude") or "back")
    local modemSide  = askSideOrNone("Modem side   (modem, or 'none')", findSide("modem") or "top")

    configTemplate = patchConfig(configTemplate, "SIDE_MOTOR",  '"' .. motorSide  .. '"')
    configTemplate = patchConfig(configTemplate, "SIDE_SENSOR", '"' .. sensorSide .. '"')
    configTemplate = patchConfig(configTemplate, "SIDE_MODEM",
        modemSide == "none" and "nil" or ('"' .. modemSide .. '"'))

    -- Rednet channel
    print("")
    local channel = ask("Rednet channel", 1234)
    configTemplate = patchConfig(configTemplate, "REDNET_CHANNEL", tostring(tonumber(channel) or 1234))

    -- Hub telemetry (optional)
    print("")
    local hubUrl = ask("Hub WebSocket URL (or 'none')", "none")
    if hubUrl ~= "none" and hubUrl ~= "" then
        write("Hub token: ")
        local hubToken = read()
        configTemplate = patchConfig(configTemplate, "HUB_URL",   '"' .. hubUrl   .. '"')
        configTemplate = patchConfig(configTemplate, "HUB_TOKEN", '"' .. hubToken .. '"')
    else
        configTemplate = patchConfig(configTemplate, "HUB_URL", "nil")
    end

    writeFile(CONFIG_FILE, configTemplate)
    print("")
    print("Config saved.")
    updated = updated + 1

    -- Offer to set up auto-start
    print("")
    write("Create startup.lua so main runs on boot? [y/n]: ")
    if read():lower() == "y" then
        writeFile("startup.lua", 'shell.run("main")\n')
        print("startup.lua created.")
    end
end

-- ── Summary ──────────────────────────────────────────────────

local freeEnd   = fs.getFreeSpace("/")
local diskDelta = freeStart - freeEnd

print("")
print(("Files: %d updated, %d unchanged, %d failed"):format(updated, unchanged, failed))

if diskDelta > 0 then
    print(("Disk:  +%s used"):format(fmtBytes(diskDelta)))
elseif diskDelta < 0 then
    print(("Disk:  %s freed"):format(fmtBytes(-diskDelta)))
else
    print("Disk:  no change")
end
print(("Free:  %s"):format(fmtBytes(freeEnd)))

if failed == 0 then
    if configIsNew then
        print("\nRun: main")
    elseif updated > 0 then
        print("\nUpdated. Restart main if it is running.")
    end
end
