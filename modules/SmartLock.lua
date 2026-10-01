script_name("SmartVehicleLock")
script_version("2.1")
script_author("Haru Hayashi")
script_description("Chooses /pvl or /gvl for the nearest owned vehicle")

require "moonloader"
local sampev = require "lib.samp.events"

local PREFIX = "{00FFAA}[SmartLock] {FFFFFF}"
local SMART_LOCK_KEY = 0x32 -- 2
local PERSONAL_MAX_DISTANCE = 10.0
local FAMILY_MAX_DISTANCE = 3.0
local RESPONSE_TIMEOUT = 5000
local FALLBACK_DELAY = 60

local PERSONAL_FAILURE =
    "You are not near any vehicle that you own."
local FAMILY_FAILURE =
    "You are not near any vehicle that your family owns."

local ownershipCache = {}
local operation = {
    active = false,
    generation = 0
}

local function notify(message, color)
    sampAddChatMessage(PREFIX .. (color or "") .. message, -1)
end

local function resetOperation()
    operation.active = false
    operation.command = nil
    operation.car = nil
    operation.vehicleId = nil
    operation.model = nil
    operation.triedPersonal = false
    operation.triedFamily = false
end

local function finishOperation(message, color)
    if message then
        notify(message, color)
    end
    resetOperation()
end

local function getVehicleDistance(car)
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local vx, vy, vz = getCarCoordinates(car)
    return getDistanceBetweenCoords3d(px, py, pz, vx, vy, vz)
end

local function getNearestVehicle()
    local car
    if isCharInAnyCar(PLAYER_PED) then
        car = storeCarCharIsInNoSave(PLAYER_PED)
    else
        car = select(1, storeClosestEntities(PLAYER_PED))
    end

    if not car or car == 0 or not doesVehicleExist(car) then
        return nil, "No vehicle is nearby."
    end

    if getVehicleDistance(car) > PERSONAL_MAX_DISTANCE then
        return nil, string.format(
            "No vehicle is within the %.1f metre private lock range.",
            PERSONAL_MAX_DISTANCE
        )
    end

    local mapped, vehicleId = sampGetVehicleIdByCarHandle(car)
    if not mapped or vehicleId == nil then
        return nil, "The nearest vehicle is not a streamed SA-MP vehicle."
    end

    return {
        car = car,
        vehicleId = vehicleId,
        model = getCarModel(car)
    }
end

local function targetIsStillValid()
    if not operation.car or not doesVehicleExist(operation.car) then
        return false
    end

    local mapped, vehicleId = sampGetVehicleIdByCarHandle(operation.car)
    return mapped and vehicleId == operation.vehicleId
end

local function getCommandRange(command)
    if command == "/gvl" then
        return FAMILY_MAX_DISTANCE
    end
    return PERSONAL_MAX_DISTANCE
end

local function confirmSuccess()
    if not operation.active then
        return
    end

    local kind = operation.command == "/gvl" and "family" or "personal"
    ownershipCache[operation.vehicleId] = {
        kind = kind,
        model = operation.model
    }
    finishOperation()
end

local function sendLockCommand(command)
    if not operation.active then
        return
    end

    if not targetIsStillValid() then
        finishOperation("The selected vehicle is no longer nearby.", "{FFAA00}")
        return
    end

    local maxDistance = getCommandRange(command)
    if getVehicleDistance(operation.car) > maxDistance then
        finishOperation(string.format(
            "%s requires the vehicle to be within %.1f metres.",
            command,
            maxDistance
        ), "{FFAA00}")
        return
    end

    operation.command = command
    if command == "/pvl" then
        operation.triedPersonal = true
    else
        operation.triedFamily = true
    end

    operation.generation = operation.generation + 1
    local generation = operation.generation
    sampSendChat(command)

    lua_thread.create(function()
        wait(RESPONSE_TIMEOUT)
        if operation.active and operation.generation == generation then
            finishOperation(
                "The server did not confirm the vehicle lock change.",
                "{FFAA00}"
            )
        end
    end)
end

local function sendFallback(command)
    operation.generation = operation.generation + 1
    local generation = operation.generation
    lua_thread.create(function()
        wait(FALLBACK_DELAY)
        if operation.active and operation.generation == generation then
            sendLockCommand(command)
        end
    end)
end

local function startSmartLock()
    if operation.active then
        notify("A lock request is already in progress.", "{FFAA00}")
        return
    end

    local target, errorMessage = getNearestVehicle()
    if not target then
        notify(errorMessage, "{FFAA00}")
        return
    end

    resetOperation()
    operation.active = true
    operation.car = target.car
    operation.vehicleId = target.vehicleId
    operation.model = target.model

    local cached = ownershipCache[target.vehicleId]
    if cached and cached.model ~= target.model then
        ownershipCache[target.vehicleId] = nil
        cached = nil
    end

    if cached and cached.kind == "family" then
        sendLockCommand("/gvl")
    else
        sendLockCommand("/pvl")
    end
end

function sampev.onServerMessage(color, text)
    if not operation.active then
        return
    end

    local plain = text:gsub("{%x%x%x%x%x%x}", "")
    if operation.command == "/pvl"
        and plain:find(PERSONAL_FAILURE, 1, true) then
        ownershipCache[operation.vehicleId] = nil
        if not operation.triedFamily then
            sendFallback("/gvl")
        else
            finishOperation(
                "This vehicle is not owned by you or your family.",
                "{FF6666}"
            )
        end
        return false
    end

    if operation.command == "/gvl"
        and plain:find(FAMILY_FAILURE, 1, true) then
        ownershipCache[operation.vehicleId] = nil
        if not operation.triedPersonal then
            sendFallback("/pvl")
        else
            finishOperation(
                "This vehicle is not owned by you or your family.",
                "{FF6666}"
            )
        end
        return false
    end
end

local function handleLockTextdraw(text)
    if not operation.active or not text then
        return
    end

    local lower = text:lower()
    if lower:find("unlocked", 1, true) then
        confirmSuccess()
    elseif lower:find("locked", 1, true) then
        confirmSuccess()
    end
end

function sampev.onShowTextDraw(id, data)
    handleLockTextdraw(data and data.text)
end

function sampev.onTextDrawSetString(id, text)
    handleLockTextdraw(text)
end

function sampev.onVehicleStreamOut(vehicleId)
    ownershipCache[vehicleId] = nil
    if operation.active and operation.vehicleId == vehicleId then
        finishOperation()
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then
        return
    end
    while not isSampAvailable() do
        wait(100)
    end

    sampRegisterChatCommand("smartlock", startSmartLock)
    notify("Loaded. Press {FFFF00}2 {FFFFFF}or use {FFFF00}/smartlock{FFFFFF}.")

    while true do
        wait(0)
        if isKeyJustPressed(SMART_LOCK_KEY)
            and not isPauseMenuActive()
            and not sampIsChatInputActive()
            and not sampIsDialogActive()
            and not isSampfuncsConsoleActive()
            and not sampIsScoreboardOpen() then
            startSmartLock()
        end
    end
end
