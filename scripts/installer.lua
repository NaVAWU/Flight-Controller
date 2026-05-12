-- installer.lua — run this once on the CC computer
-- Fetches the file list from the GitHub repo automatically,
-- so new scripts are picked up without updating this installer.

local REPO_API = "https://api.github.com/repos/NaVAWU/Flight-Controller/contents/scripts"

print("Fetching file list from GitHub...")
local res = http.get(REPO_API)
assert(res, "Failed to reach GitHub API. Check your internet connection.")

local data = textutils.unserialiseJSON(res.readAll())
res.close()
assert(type(data) == "table", "Unexpected response from GitHub API.")

local downloaded, failed = 0, 0

for _, entry in ipairs(data) do
    if entry.type == "file" and entry.name:match("%.lua$") then
        print("Downloading " .. entry.name)
        local file = http.get(entry.download_url)
        if file then
            local f = fs.open(entry.name, "w")
            f.write(file.readAll())
            f.close()
            file.close()
            downloaded = downloaded + 1
            print("  OK")
        else
            print("  FAILED: " .. entry.download_url)
            failed = failed + 1
        end
    end
end

print(("Done. %d file(s) downloaded, %d failed."):format(downloaded, failed))
if downloaded > 0 and failed == 0 then
    print("Run: main")
end
