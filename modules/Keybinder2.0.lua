require "lib.sampfuncs"
require "lib.samp.events"
local sampev = require "lib.samp.events"
local FBI_COLOR_ID = 9276927
local IN_A_VEHICLE = false
local badge_active = false

local toggler
local json = require "dkjson"
-- local fakeStat = false

local jsonFile = "moonloader/config/Keybinder2.0.json"

local function saveConfig()
    local file = io.open(jsonFile, "w+")
    if file then
        local data = { toggler = toggler }
        file:write(json.encode(data, { indent = true }))
        file:close()
    end
end

local function loadConfig()
    local file = io.open(jsonFile, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local data, _, err = json.decode(content, 1, nil)
        if data and data.toggler ~= nil then
            toggler = data.toggler
        end
    end
end

local function isPlayerAiming()
    -- 25 is the virtual key for RMB (right mouse button)
    return isKeyDown(0x02)
end

function getMyTagColor()
    local myPlayerId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
    return sampGetPlayerColor(myPlayerId)
end


-- Key bindings table
-- Key: Virtual key code
-- Value: Function or command string
local binds = {
    -- [4] = "/park",
    -- [6] = function()
    --     local currentColor = getMyTagColor()

    --     if currentColor == FBI_COLOR_ID and not isCharInAnyCar(PLAYER_PED) then
    --         sampSendChat("/tazer")
    --     elseif badge_active == false and  not isCharInAnyCar(PLAYER_PED) then
    --         sampSendChat("/badge")
    --         badge_active = true
    --         sampSendChat("/tazer")
    --     end
    --     badge_active = false
    -- end,
    -- [5] = function()
    --     if isPlayerAiming() then
        
    --     else
    --         sampSendChat("/gate")
    --     end
    -- end,            
    --[107] = "/capture",                 -- Numpad +
    -- [49] = function ()
    --     if isKeyDown(18) then
    --         sampSendChat("/tazer")
    --         wait(10)
    --         sampSendChat("/s This is the Sheriff's Department, Put your hands up in the air right this instant ((/hu))!")
    --     else
    --         sampSendChat("/s This is the Sheriff's Department, Put your hands up in the air right this instant ((/hu))!")
    --     end
    -- end,            -- Middle mouse
    -- [50]  = "/lock",                     -- 2
    [51]  = "/accept bodyguard",         -- 3
    [52]  = "/accept dicebet",           -- 4
    [53]  = "/cancel dicebet",           -- 5
    [54]  = function()                   -- 6 (special sequence)
        
        setVirtualKeyDown(0x54, true) -- Press T
        wait(100)
        setVirtualKeyDown(0x54, false)
        sampSetChatInputText("/.settime 20")
        setVirtualKeyDown(0x0D, true) -- Press Enter
        wait(100)
        setVirtualKeyDown(0x0D, false)
        wait(100)
        setVirtualKeyDown(0x54, true) -- Press T
        wait(100)
        setVirtualKeyDown(0x54, false)
        sampSetChatInputText("/.setweather 39")
        setVirtualKeyDown(0x0D, true) -- Press Enter
        wait(100)
        setVirtualKeyDown(0x0D, false)
    end,
    [55]  = function()                   -- 7 (special sequence)
        sampSendChat("/kcp")
        wait(50)
        sampSendChat("/farm")
    end,
    [56]  = "/getcrack 10",               -- 8
    [57]  = function ()
        sampSendChat("/m **Flashing Lights And Loud Sirens**")
        wait(100)
        sampSendChat("/m This is the Federal Bureau, PULL OVER to the side of the road this instant...")
        wait(100)
        sampSendChat("/m ...and turn your ENGINE OFF! ((/car engine))")
    end,
    [189] = "/quithelp",
    [48] = "/helprequests",
    [111] = "/nos",
    -- [103] = "/me reaches for their pocket as he takes out a pair of Latex Gloves, and slips it into their hand", -- Num 7
    -- [104] = "/me walks forward and lean towards the person infront of them as they attempt to frisk him/her",     -- Num 8
    -- [105] = "/do Would i Succed? ((Yes/no))"                                                                     -- Num 9
}

local function isGameFree()
    return not sampIsChatInputActive() and not sampIsDialogActive()
end

function main()
    while not isSampAvailable() do wait(0) end

    sampRegisterChatCommand("cchat", function()
        lua_thread.create(function()
            for i = 1, 100 do -- 20 lines is usually enough to push everything up
                sampAddChatMessage(" ", -1)
                wait(10) -- tiny delay so it doesn’t skip
            end
        end)
    end)

    sampAddChatMessage("{FFFFFF}{FF00FF}Keybinder has been loaded {FFFFFF}- {FF0000}by Haru Hayashi {808080}[/abind]", -1)
    wait(1000)
    loadConfig()
    if toggler then
        sampAddChatMessage("{FF00FF}Hayashi's Binds {00FF00}activated.", 0x1e81b0)
    else
        sampAddChatMessage("{FF00FF}Hayashi's Binds {FF0000}deactivated.", 0x1e81b0)
    end
    
    sampRegisterChatCommand("abind", function()
        toggler = not toggler
        if toggler then
            sampAddChatMessage("{FF00FF}Hayashi's Binds {00FF00}activated.", 0x1e81b0)
        else
            sampAddChatMessage("{FF00FF}Hayashi's Binds {FF0000}deactivated.", 0x1e81b0)
        end
        saveConfig()
    end)

    sampRegisterChatCommand("exitveh", function()
        local vehicle = sampGetPlayerVehicle()
        if vehicle and vehicle ~= 0 then
            lua_thread.create(function()
                setVirtualKeyDown(0x46, true)
                wait(100)
                setVirtualKeyDown(0x46, false)
            end)
        else
            sampAddChatMessage("{FF6666}[Vehicle] You are not in a vehicle.", -1)
        end
    end)

    -- sampRegisterChatCommand("fakestat", function()
    --     fakeStat = not fakeStat
    -- end)

    sampRegisterChatCommand("levcal", function(args)
        local startLvl, endLvl = args:match("^(%d+)%s+(%d+)$")
        startLvl, endLvl = tonumber(startLvl), tonumber(endLvl)

        if not startLvl or not endLvl or startLvl < 1 or endLvl <= startLvl then
            sampAddChatMessage("{FFFF00}Usage: {FFFFFF}/levcal [startLevel] [endLevel]", -1)
            return
        end

        local totalRP, totalCash = 0, 0

        -- loop from startLvl+1 (next level) to endLvl
        for lvl = startLvl + 1, endLvl do
            local respect = 8 + (lvl - 2) * 4   -- base 8, +4 each level after
            local cash = 5000 + (lvl - 2) * 2500 -- base 7500, +2500 each level after
            totalRP = totalRP + respect
            totalCash = totalCash + cash
        end

        sampAddChatMessage(
            string.format(
                "{00FF00}[LevelCalc] {FFFFFF}From level %d to %d, you need a total of {FFFF00}%d respect points {FFFFFF}and {FFFF00}$%s.",
                startLvl, endLvl, totalRP, totalCash
            ),
            -1
        )
    end)

    while true do
        wait(0)
        if toggler and isGameFree() then
            for key, action in pairs(binds) do
                if  isKeyJustPressed(key) then
                    if (key == 49 or key == 50) and isKeyDown(17)  then
                        
                    else
                        if type(action) == "string" then
                            sampSendChat(action)
                        elseif type(action) == "function" then
                            action()
                        end
                    end
                end
            end

            if isKeyJustPressed(0x05) then
                -- Define the target position
                local targetX1, targetY1, targetZ1 = 623, -601, 17 -- enter garage
                local targetX2, targetY2, targetZ2 = 2230,  2465,  791 -- exit garage
                local targetX3, targetY3, targetZ3 = 1600,  -1609,  13 -- impound lspd
                local targetX4, targetY4, targetZ4 = 614,  -598,  17 -- impound sasd
                local targetX5, targetY5, targetZ5 = 619,  -554,  5 -- sasd locker
                local targetX6, targetY6, targetZ6 =  2908,  -4970,  9331 --P3 locker
                local targetX7, targetY7, targetZ7 =  94,  1727,  405 -- P13 locker
                local targetX8, targetY8, targetZ8 =  94,  1727,  405 -- P14 locker
                local targetX9, targetY9, targetZ9 =  94,  1727,  405 -- P47 locker
                local targetX10, targetY10, targetZ10 =  94,  1727,  405 -- P16 locker
                local targetX11, targetY11, targetZ11 =  1552,  -1685,  5052 -- P19 locker

                local radius = 3.0
                

                -- Get player coordinates
                local px, py, pz = getCharCoordinates(PLAYER_PED)

                -- Calculate distance
                local dist1 = getDistanceBetweenCoords3d(px, py, pz, targetX1, targetY1, targetZ1)
                local dist2 = getDistanceBetweenCoords3d(px, py, pz, targetX2, targetY2, targetZ2)
                local dist3 = getDistanceBetweenCoords3d(px, py, pz, targetX3, targetY3, targetZ3)
                local dist4 = getDistanceBetweenCoords3d(px, py, pz, targetX4, targetY4, targetZ4)
                local dist5 = getDistanceBetweenCoords3d(px, py, pz, targetX5, targetY5, targetZ5)
                local dist6 = getDistanceBetweenCoords3d(px, py, pz, targetX6, targetY6, targetZ6)
                local dist7 = getDistanceBetweenCoords3d(px, py, pz, targetX7, targetY7, targetZ7)
                local dist8 = getDistanceBetweenCoords3d(px, py, pz, targetX8, targetY8, targetZ8)
                local dist9 = getDistanceBetweenCoords3d(px, py, pz, targetX9, targetY9, targetZ9)
                local dist10 = getDistanceBetweenCoords3d(px, py, pz, targetX10, targetY10, targetZ10)
                local dist11 = getDistanceBetweenCoords3d(px, py, pz, targetX11, targetY11, targetZ11)

                -- Only trigger Y if within radius
                if dist1 <= radius or dist2 <= radius then
                    setVirtualKeyDown(0x59, true)   -- Press Y
                    wait(100)
                    setVirtualKeyDown(0x59, false)  -- Release Y
                end

                if dist3 <= radius or dist4 <= radius then
                    sampSendChat("/impound")
                end

                if dist5 <= radius or dist6 <= radius or dist7 <= radius or dist8 <= radius or dist9 <= radius or dist10 <= radius or dist11 <= radius then
                    setVirtualKeyDown(0x12, true) 
                    wait(500)
                    setVirtualKeyDown(0x4C, true)
                    wait(500)
                    setVirtualKeyDown(0x12, false)
                    setVirtualKeyDown(0x4C, false)
                end
            end
        end
    end
end

-- function getLocalMoney()
--     return readMemory(0xB7CE50, 4, false)
-- end

-- function fakeStats()
--     lua_thread.create(function()

--         -- get cash from memory
--         local cash = getLocalMoney()
--         if type(cash) ~= "number" then cash = 0 end

--         -- set total wealth
--         local totalWealth = 225000000

--         -- calculate bank balance dynamically
--         local bank = totalWealth - cash
--         if bank < 0 then bank = 0 end

--         -- formatting function
--         local function formatMoney(n)
--             local str = tostring(n)
--             str = str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
--             return str
--         end

--         local cashFormatted = formatMoney(cash)
--         -- local bankFormatted = formatMoney(bank)
--         local bankFormatted = formatMoney(0)
--         local totalFormatted = formatMoney(totalWealth + cashFormatted)

--         wait(300)
--         sampAddChatMessage("{FFB900}___________________________________________________________________________________________________", -1)
--         sampAddChatMessage("{FFFFFF}Haru Hayashi - (Level: 30) - (Playing hours: 3807) - (Gender: Male) - (Age: 21) - (Phone number: -256) - (Warnings: 0)", -1)
--         sampAddChatMessage("{FFFF92}(Family: House of Mercy) - (Rank: Grand Shepherd [5]) - (Crew: None) - (Job: Detective [lvl: 5]) - (Job 2: Car Mechanic [lvl: 5])", -1)
--         sampAddChatMessage("{FFFFFF}(Total wealth: $"..totalFormatted..") - (Cash: $"..cashFormatted..") - (Bank balance: $"..bankFormatted..") - (Insurance: All Saints) - (Married to: Nobody)", -1)
--         sampAddChatMessage("{FFFF92}(Respect points: 2453/124 [$77,500]) - (Upgrades: 42) - (Spawn armor: 0.0) - (Health: 100.0) - (Armor: 100.0) - (Radio: 2231", -1)
--         sampAddChatMessage("{FFFFFF}(Crimes: 614) - (Arrests: 107) - (Wanted Level: 0) - (Materials: 350) - (Pot: 36) - (Crack: 18) - (Packages: 0) - (Crates: 0)", -1)
--         sampAddChatMessage("{FFFF92}(Rope: 8) - (Cigars: 20) - (Sprunk: 4) - (Spray: 0) - (Seeds: 0) -  (Blindfolds: 3) - (Ref Tokens: 0) - (Donator: No)", -1)
--         sampAddChatMessage("{FFB900}___________________________________________________________________________________________________", -1)
--     end)
-- end

-- function sampev.onSendCommand(cmd)
--     if cmd:lower():match("^/stats") and fakeStat then
--         fakeStats()
--         return false
--     end
-- end

-- function sampev.onServerMessage(colorid, text)
--     if text:find("Haru Hayashi says: (( test ))") then
--         sampAddChatMessage("{FF00FF}Keybinder: {FFFFFF}Test message received, checking for vehicle status...", -1)
--         IN_A_VEHICLE = true
--     end
-- end

function onScriptLoad()
    sampRegisterChatCommand("/tstop1", cmd_tstop1)
end

function cmd_tstop1()
    sampSendChat("/me knocks on the vehicle windows.")
    wait(500)
    sampSendChat("/me clears throat.")
    wait(500)
    sampSendChat("/do Window Status?")
end


--========================================================--
--                KEYCODES REFERENCE LIST                 --
--     Use these keycodes in your Lua scripts (SP, etc.)  --
--========================================================--

-- Numbers
-- 0 - 9
--========================================================--
-- 0 : 48
-- 1 : 49
-- 2 : 50
-- 3 : 51
-- 4 : 52
-- 5 : 53
-- 6 : 54
-- 7 : 55
-- 8 : 56
-- 9 : 57

-- Letters
--========================================================--
-- A : 65
-- B : 66
-- C : 67
-- D : 68
-- E : 69
-- F : 70
-- G : 71
-- H : 72
-- I : 73
-- J : 74
-- K : 75
-- L : 76
-- M : 77
-- N : 78
-- O : 79
-- P : 80
-- Q : 81
-- R : 82
-- S : 83
-- T : 84
-- U : 85
-- V : 86
-- W : 87
-- X : 88
-- Y : 89
-- Z : 90

-- Function Keys
--========================================================--
-- F1  : 112
-- F2  : 113
-- F3  : 114
-- F4  : 115
-- F5  : 116
-- F6  : 117
-- F7  : 118
-- F8  : 119
-- F9  : 120
-- F10 : 121
-- F11 : 122
-- F12 : 123

-- Control Keys
--========================================================--
-- Backspace : 8
-- Tab       : 9
-- Enter     : 13
-- Shift     : 16
-- Ctrl      : 17
-- Alt       : 18
-- Pause     : 19
-- CapsLock  : 20
-- Esc       : 27
-- Space     : 32
-- PageUp    : 33
-- PageDown  : 34
-- End       : 35
-- Home      : 36
-- LeftArrow : 37
-- UpArrow   : 38
-- RightArrow: 39
-- DownArrow : 40
-- Insert    : 45
-- Delete    : 46

-- Numpad Keys
--========================================================--
-- Num0 : 96
-- Num1 : 97
-- Num2 : 98
-- Num3 : 99
-- Num4 : 100
-- Num5 : 101
-- Num6 : 102
-- Num7 : 103
-- Num8 : 104
-- Num9 : 105
-- Num* : 106
-- Num+ : 107
-- Num- : 109
-- Num. : 110
-- Num/ : 111

-- Symbols
--========================================================--
-- ; : 186
-- = : 187
-- , : 188
-- - : 189
-- . : 190
-- / : 191
-- ` : 192
-- [ : 219
-- \ : 220
-- ] : 221
-- ' : 222
