-- installer.lua — run this once on the CC computer
-- Fetches the file list from GitHub and only writes files that have changed.
-- Self-updates: if this file changed remotely it rewrites itself and restarts.

local REPO_API = "https://api.github.com/repos/NaVAWU/Flight-Controller/contents/scripts"

local function fmtBytes(n)
    if n >= 1024 * 1024 then return ("%.1f MB"):format(n / (1024 * 1024))
    elseif n >= 1024    then return ("%.1f KB"):format(n / 1024)
    else                     return (n .. " B")
    end
end

local function readLocal(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local content = f.readAll()
    f.close()
    return content
end

-- ── Fetch file list ──────────────────────────────────────────

print("Fetching file list from GitHub...")
local res = http.get(REPO_API)
assert(res, "Failed to reach GitHub API. Check your internet connection.")

local data = textutils.unserialiseJSON(res.readAll())
res.close()
assert(type(data) == "table", "Unexpected response from GitHub API.")

-- ── Self-update check (runs before anything else) ────────────

local selfPath = shell.getRunningProgram()
local selfName = fs.getName(selfPath)

for _, entry in ipairs(data) do
    if entry.name == selfName then
        local remote = http.get(entry.download_url)
        if remote then
            local remoteContent = remote.readAll()
            remote.close()
            if remoteContent ~= readLocal(selfPath) then
                local f = fs.open(selfPath, "w")
                f.write(remoteContent)
                f.close()
                print("Installer updated — restarting...")
                print("")
                shell.run(selfPath)
                return
            end
        end
        break
    end
end

-- ── Download and diff all other files ───────────────────────

local freeStart = fs.getFreeSpace("/")

local updated, unchanged, failed = 0, 0, 0

for _, entry in ipairs(data) do
    if entry.type == "file" and entry.name:match("%.lua$")
    and entry.name ~= selfName then
        local remote = http.get(entry.download_url)
        if not remote then
            print("  FAIL  " .. entry.name)
            failed = failed + 1
        else
            local remoteContent = remote.readAll()
            remote.close()

            local localContent = readLocal(entry.name)

            if remoteContent == localContent then
                unchanged = unchanged + 1
            else
                local label = localContent == nil and "  NEW   " or "  UPDATE"
                local f = fs.open(entry.name, "w")
                f.write(remoteContent)
                f.close()
                print(label .. " " .. entry.name)
                updated = updated + 1
            end
        end
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

if updated > 0 and failed == 0 then
    print("\nRun: main")
end
