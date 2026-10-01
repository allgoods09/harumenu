script_name("SmartFix")
script_version("1.0")
script_author("Haru Hayashi")
script_description("Automates the safe mechanic repair flow with vehicle state restoration")

require "moonloader"
local sampev = require "lib.samp.events"

local PREFIX = "{39C5FF}[SmartFix] {FFFFFF}"

local DUTY_TIMEOUT = 8000
local HOOD_TIMEOUT = 8000
local EXIT_TIMEOUT = 12000
local FIX_START_TIMEOUT = 8000
local FIX_FINISH_TIMEOUT = 15000
local LOCK_TIMEOUT = 6000
local ENTER_TIMEOUT = 15000

local DUTY_ON_MESSAGE =
    "You are now on duty with your Car Mechanic job"
local DUTY_OFF_MESSAGE =
    "You are now off duty from your Car Mechanic job"
local NOT_MECHANIC_MESSAGE = "You are not a mechanic!"
local FIXING_MESSAGE = "You are now fixing this vehicle."
local PERSONAL_VEHICLE_FAILURE =
    "You are not near any vehicle that you own."
local FAMILY_VEHICLE_FAILURE =
    "You are not near any vehicle that your family owns."
local HOOD_OPEN_MESSAGE = "Vehicle hood successfully opened"
local HOOD_CLOSED_MESSAGE = "Vehicle hood successfully closed"

local LOCKED_DOOR_STATES = {
    [2] = true,
    [4] = true,
    [5] = true,
    [7] = true,
    [8] = true
}

local vehicleLockStates = {}
local vehicleBonnetStates = {}

local session = {
    active = false,
    state = "idle"
}

local function notify(message, color)
    sampAddChatMessage(PREFIX .. (color or "") .. message, -1)
end

local function flagIsEnabled(value)
    return value == true or tonumber(value) == 1
end

local function targetVehicleExists()
    return session.targetCar ~= nil
        and doesVehicleExist(session.targetCar)
end

local function getTargetVehicleHandle()
    if targetVehicleExists() then
        local mapped, vehicleId = sampGetVehicleIdByCarHandle(
            session.targetCar
        )
        if mapped and vehicleId == session.targetVehicleId then
            return session.targetCar
        end
        session.targetCar = nil
    end
    if session.targetVehicleId == nil then
        return nil
    end

    local found, handle = sampGetCarHandleBySampVehicleId(
        session.targetVehicleId
    )
    if found and doesVehicleExist(handle) then
        session.targetCar = handle
        return handle
    end
    return nil
end

local function readVehicleLocked(car, vehicleId)
    if car and doesVehicleExist(car) then
        local ok, status = pcall(getCarDoorLockStatus, car)
        if ok and status ~= nil then
            return LOCKED_DOOR_STATES[tonumber(status)] == true
        end
    end
    return vehicleLockStates[vehicleId]
end

local function readHoodOpen(vehicleId)
    return vehicleBonnetStates[vehicleId]
end

local function waitUntil(predicate, timeout)
    local started = getGameTimer()
    while session.active do
        if predicate() then
            return true
        end
        if timeout and getGameTimer() - started >= timeout then
            return false
        end
        wait(50)
    end
    return false
end

local function resetSession()
    session = {
        active = false,
        state = "idle"
    }
end

local function abortSession(reason)
    notify(reason, "{FF6666}")
    resetSession()
end

local function completeSession()
    notify("Repair sequence completed.", "{66FF66}")
    resetSession()
end

local function setLocalPlayerNames()
    local found, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not found or id == nil then
        return false
    end

    local nickname = sampGetPlayerNickname(id) or ""
    if nickname == "" then
        return false
    end

    session.nickname = nickname
    session.displayName = nickname:gsub("_", " ")
    return true
end

local function ownRepairMessage(text, suffix)
    if not session.displayName or session.displayName == "" then
        return false
    end
    return text:find(
        session.displayName .. " " .. suffix,
        1,
        true
    ) ~= nil
end

local function waitForLockResult(expected)
    return waitUntil(function()
        if session.lockFeedback == expected then
            return true
        end

        local car = getTargetVehicleHandle()
        local locked = readVehicleLocked(car, session.targetVehicleId)
        if locked ~= nil then
            if expected == "locked" then
                return locked
            end
            return not locked
        end
        return false
    end, LOCK_TIMEOUT)
end

local function sendVehicleLockCommand(command, expected)
    session.currentLockCommand = command
    session.lockFeedback = nil
    session.lockFailure = nil
    session.expectedLockState = expected
    session.state = expected == "unlocked"
        and "unlocking_vehicle"
        or "locking_vehicle"
    sampSendChat(command)

    local answered = waitUntil(function()
        return session.lockFeedback == expected
            or session.lockFailure ~= nil
    end, LOCK_TIMEOUT)

    if not answered then
        -- Some servers update the GTA lock state without a textdraw.
        return waitForLockResult(expected)
    end
    return session.lockFeedback == expected
end

local function unlockTargetVehicle()
    if sendVehicleLockCommand("/pvl", "unlocked") then
        session.lockCommand = "/pvl"
        return true
    end

    if session.lockFailure ~= "personal" then
        return false
    end

    if sendVehicleLockCommand("/gvl", "unlocked") then
        session.lockCommand = "/gvl"
        return true
    end
    return false
end

local function enterTargetVehicle()
    local car = getTargetVehicleHandle()
    if not car then
        return false, "The repair vehicle is no longer available."
    end

    session.state = "entering_vehicle"
    session.vehicleSyncSeen = false
    taskEnterCarAsDriver(PLAYER_PED, car, ENTER_TIMEOUT)

    local entered = waitUntil(function()
        if not isCharInAnyCar(PLAYER_PED) then
            return false
        end
        local currentCar = storeCarCharIsInNoSave(PLAYER_PED)
        return currentCar == car
            and getDriverOfCar(car) == PLAYER_PED
            and session.vehicleSyncSeen
    end, ENTER_TIMEOUT)

    if not entered then
        return false, "Could not enter the repair vehicle."
    end
    return true
end

local function toggleHoodAndWait(expected)
    session.hoodFeedback = nil
    sampSendChat("/car hood")

    local replied = waitUntil(function()
        return session.hoodFeedback ~= nil
    end, HOOD_TIMEOUT)

    if not replied then
        return false, nil
    end
    return session.hoodFeedback == expected, session.hoodFeedback
end

local function ensureHoodOpen()
    if session.hoodWasOpen == true then
        return true
    end

    session.state = "opening_hood"
    local opened, result = toggleHoodAndWait("open")
    if opened then
        session.openedHood = true
        session.hoodWasOpen = false
        return true
    end

    if result ~= "closed" then
        return false
    end

    -- The server says the toggle closed it, so it was already open.
    session.hoodWasOpen = true
    session.openedHood = false
    local reopened = toggleHoodAndWait("open")
    return reopened
end

local function closeHoodAfterFailedFix()
    if not session.openedHood or session.repairSucceeded then
        return true
    end

    if not getTargetVehicleHandle() then
        return false
    end

    session.state = "closing_hood"
    return toggleHoodAndWait("closed")
end

local function returnToOriginalVehicle()
    if not session.startedInVehicle then
        return true
    end
    if not getTargetVehicleHandle() then
        return false, "The repair vehicle is no longer available."
    end

    if session.wasLocked then
        if not unlockTargetVehicle() then
            return false, "Could not unlock the repair vehicle with /pvl or /gvl."
        end
    end

    local entered, enterError = enterTargetVehicle()
    if not entered then
        return false, enterError
    end

    if not closeHoodAfterFailedFix() then
        return false, "Could not restore the vehicle hood."
    end

    if session.wasLocked then
        if not session.lockCommand
            or not sendVehicleLockCommand(session.lockCommand, "locked") then
            return false, "Could not restore the vehicle lock."
        end
    end
    return true
end

local function runFixSession()
    session.state = "checking_mechanic"
    session.mechanicResult = nil
    sampSendChat("/mechduty")

    if not waitUntil(function()
        return session.mechanicResult ~= nil
    end, DUTY_TIMEOUT) then
        abortSession("No response was received from /mechduty.")
        return
    end

    if session.mechanicResult == "not_mechanic" then
        abortSession("Your character does not have the Car Mechanic job.")
        return
    end

    if session.startedInVehicle then
        local car = getTargetVehicleHandle()
        if not car then
            abortSession("The selected vehicle is no longer available.")
            return
        end

        if not ensureHoodOpen() then
            abortSession("The server did not confirm that the hood opened.")
            return
        end

        session.state = "exiting_vehicle"
        session.onFootSyncSeen = false
        taskLeaveCar(PLAYER_PED, car)
        if not waitUntil(function()
            return not isCharInAnyCar(PLAYER_PED)
                and session.onFootSyncSeen
        end, EXIT_TIMEOUT) then
            abortSession("Could not exit the vehicle normally.")
            return
        end
    end

    session.state = "starting_fix"
    session.repairStarted = false
    session.repairFinished = false
    session.cooldownSeconds = nil
    sampSendChat("/fix")

    if not waitUntil(function()
        return session.repairStarted
            or session.repairFinished
            or session.cooldownSeconds ~= nil
    end, FIX_START_TIMEOUT) then
        local restored, restoreError = returnToOriginalVehicle()
        if not restored then
            abortSession("Repair did not start. " .. restoreError)
        else
            abortSession("The server did not start the repair.")
        end
        return
    end

    if session.cooldownSeconds then
        local seconds = session.cooldownSeconds
        local restored, restoreError = returnToOriginalVehicle()
        if not restored then
            abortSession(string.format(
                "Fix cooldown: %d seconds. %s",
                seconds,
                restoreError
            ))
        else
            abortSession(string.format(
                "Fix is on cooldown for %d seconds.",
                seconds
            ))
        end
        return
    end

    session.state = "fixing"
    if not session.repairFinished
        and not waitUntil(function()
            return session.repairFinished
        end, FIX_FINISH_TIMEOUT) then
        local restored, restoreError = returnToOriginalVehicle()
        if not restored then
            abortSession("Repair completion was not received. " .. restoreError)
        else
            abortSession("Repair completion was not received.")
        end
        return
    end

    session.repairSucceeded = true
    local restored, restoreError = returnToOriginalVehicle()
    if not restored then
        abortSession(restoreError)
        return
    end

    completeSession()
end

local function startSmartFix()
    if session.active then
        notify("A repair sequence is already running.", "{FFAA00}")
        return
    end

    resetSession()
    session.active = true
    session.state = "starting"
    session.startedInVehicle = isCharInAnyCar(PLAYER_PED)
    session.repairSucceeded = false
    session.openedHood = false
    if not setLocalPlayerNames() then
        abortSession("Could not identify the local SA-MP player.")
        return
    end

    if session.startedInVehicle then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        if getDriverOfCar(car) ~= PLAYER_PED then
            abortSession("SmartFix currently supports the driver seat only.")
            return
        end
        if not isThisModelACar(getCarModel(car)) then
            abortSession("This vehicle does not support the SmartFix hood flow.")
            return
        end

        local mapped, vehicleId = sampGetVehicleIdByCarHandle(car)
        if not mapped then
            abortSession("Could not identify the current SA-MP vehicle.")
            return
        end

        session.targetCar = car
        session.targetVehicleId = vehicleId
        session.wasLocked = readVehicleLocked(car, vehicleId)
        session.hoodWasOpen = readHoodOpen(vehicleId)
        if session.wasLocked == nil then
            abortSession("Could not determine whether the vehicle is locked.")
            return
        end
    end

    notify("Repair sequence started.", "{BBDDFF}")
    lua_thread.create(runFixSession)
end

function sampev.onServerMessage(color, text)
    if not session.active then
        return
    end

    local plain = text:gsub("{%x%x%x%x%x%x}", "")

    if plain:find(HOOD_OPEN_MESSAGE, 1, true) then
        if session.targetVehicleId ~= nil then
            vehicleBonnetStates[session.targetVehicleId] = true
        end
        if session.state == "opening_hood"
            or session.state == "closing_hood" then
            session.hoodFeedback = "open"
            return false
        end
    elseif plain:find(HOOD_CLOSED_MESSAGE, 1, true) then
        if session.targetVehicleId ~= nil then
            vehicleBonnetStates[session.targetVehicleId] = false
        end
        if session.state == "opening_hood"
            or session.state == "closing_hood" then
            session.hoodFeedback = "closed"
            return false
        end
    end

    if ownRepairMessage(plain, "opens the vehicles hood.")
        or ownRepairMessage(plain, "closes the vehicles hood.")
        or ownRepairMessage(plain, "closed the vehicles hood.") then
        return false
    end

    if session.state == "checking_mechanic" then
        if plain:find(NOT_MECHANIC_MESSAGE, 1, true) then
            session.mechanicResult = "not_mechanic"
            return false
        elseif plain:find(DUTY_ON_MESSAGE, 1, true)
            or plain:find(DUTY_OFF_MESSAGE, 1, true) then
            session.mechanicResult = "mechanic"
            return false
        end
    end

    if session.state == "starting_fix" or session.state == "fixing" then
        if plain:find(FIXING_MESSAGE, 1, true)
            or ownRepairMessage(
                plain,
                "has started repairing the vehicle."
            ) then
            session.repairStarted = true
        end

        if ownRepairMessage(plain, "has repaired the vehicle.") then
            session.repairFinished = true
        end

        local seconds = plain:match("You must wait (%d+) seconds?!")
        if seconds then
            session.cooldownSeconds = tonumber(seconds)
        end
    end

    if session.state == "unlocking_vehicle"
        or session.state == "locking_vehicle" then
        if plain:find(PERSONAL_VEHICLE_FAILURE, 1, true)
            and session.currentLockCommand == "/pvl" then
            session.lockFailure = "personal"
            return false
        end
        if plain:find(FAMILY_VEHICLE_FAILURE, 1, true)
            and session.currentLockCommand == "/gvl" then
            session.lockFailure = "family"
            return false
        end
    end
end

function sampev.onShowTextDraw(id, data)
    if not session.active or not data or not data.text then
        return
    end
    if session.state ~= "unlocking_vehicle"
        and session.state ~= "locking_vehicle" then
        return
    end

    local lower = data.text:lower()
    if lower:find("unlocked", 1, true) then
        session.lockFeedback = "unlocked"
    elseif lower:find("locked", 1, true) then
        session.lockFeedback = "locked"
    end
end

function sampev.onSetVehicleParams(vehicleId, objective, doorsLocked)
    local locked = flagIsEnabled(doorsLocked)
    vehicleLockStates[vehicleId] = locked

    if session.active and vehicleId == session.targetVehicleId then
        if session.state == "unlocking_vehicle" and not locked then
            session.lockFeedback = "unlocked"
        elseif session.state == "locking_vehicle" and locked then
            session.lockFeedback = "locked"
        end
    end
end

function sampev.onSetVehicleParamsEx(vehicleId, params, doors, windows)
    if not params then
        return
    end

    local lockValue = tonumber(params.doors)
    if lockValue and lockValue >= 0 then
        local locked = lockValue == 1
        vehicleLockStates[vehicleId] = locked
        if session.active and vehicleId == session.targetVehicleId then
            if session.state == "unlocking_vehicle" and not locked then
                session.lockFeedback = "unlocked"
            elseif session.state == "locking_vehicle" and locked then
                session.lockFeedback = "locked"
            end
        end
    end

    local bonnetValue = tonumber(params.bonnet)
    if bonnetValue and bonnetValue >= 0 then
        vehicleBonnetStates[vehicleId] = bonnetValue == 1
    end
end

function sampev.onSendPlayerSync(data)
    if session.active and session.state == "exiting_vehicle"
        and not isCharInAnyCar(PLAYER_PED) then
        session.onFootSyncSeen = true
    end
end

function sampev.onSendVehicleSync(data)
    if not session.active or session.state ~= "entering_vehicle" then
        return
    end
    if isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        if car == getTargetVehicleHandle()
            and getDriverOfCar(car) == PLAYER_PED then
            session.vehicleSyncSeen = true
        end
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then
        return
    end
    while not isSampAvailable() do
        wait(100)
    end

    sampRegisterChatCommand("sf", startSmartFix)
    notify("Loaded. Use {39C5FF}/sf {FFFFFF}to start.")

    wait(-1)
end
