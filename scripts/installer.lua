-- installer.lua — run this once on the CC computer
local files = {
    ["config.lua"]  = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/config.lua",
    ["main.lua"]    = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/main.lua",
    ["motor.lua"]   = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/motor.lua",
    ["network.lua"] = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/network.lua",
    ["pid.lua"]     = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/pid.lua",
    ["sensors.lua"] = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/sensors.lua",
    ["state.lua"]   = "https://raw.githubusercontent.com/NaVAWU/Flight-Controller/refs/heads/main/scripts/state.lua",
}

for filename, url in pairs(files) do
    print("Downloading " .. filename)
    local res = http.get(url)
    if res then
        local f = fs.open(filename, "w")
        f.write(res.readAll())
        f.close()
        res.close()
        print("  OK")
    else
        print("  FAILED: " .. url)
    end
end

print("Done. Run: main")