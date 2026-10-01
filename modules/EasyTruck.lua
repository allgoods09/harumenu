script_name('EasyTruck')
script_author('Chatty')

require 'moonloader'
local sampev = require 'lib.samp.events'
local ffi = require 'ffi'
local memory = require 'memory'
local imgui = require 'mimgui'
local new = imgui.new

ffi.cdef[[
typedef struct {
    float x;
    float y;
    float z;
} ET_CVector;

typedef struct {
    unsigned short region;
    unsigned short index;
} ET_CNodeAddress;

typedef struct {
    void* next;
    void* previous;
    short x;
    short y;
    short z;
    short distanceToTarget;
    short indexAdjacentNodes;
    ET_CNodeAddress address;
    unsigned char width;
    unsigned char group;
    unsigned char flags[4];
} ET_CPathNode;

typedef struct {
    float x;
    float y;
} ET_CVector2D;

typedef void* (__cdecl *ET_PlaceMarker)(
    unsigned int, unsigned short, ET_CVector*, float,
    unsigned char, unsigned char, unsigned char, unsigned char,
    unsigned short, float, short, float, float, float, bool
);

typedef void (__thiscall *ET_DoPathSearch)(
    void*, unsigned char, ET_CVector, ET_CNodeAddress, ET_CVector,
    ET_CNodeAddress*, short*, int, float*, float, ET_CNodeAddress*,
    float, bool, ET_CNodeAddress, bool, bool
);

typedef void (__cdecl *ET_TransformRadarPoint)(ET_CVector2D*, const ET_CVector2D*);

int ETGPS_Initialize(void);
void ETGPS_ClearRoute(void);
void ETGPS_SetRoute(const float* packedXY, int count);
int ETGPS_IsInstalled(void);
void ETGPS_Shutdown(void);
]]

-- Persistent settings and runtime state
local easytruck_enabled = false
local targetPos = {x = 0, y = 0, z = 0}
local saveFile = "moonloader/config/easytruck.json"
local lastDeliver = 0
local hasCheckpoint = false
local settings = {
    gpsEnabled = true,
    smartInitialLoad = true,
    autoReloadAfterDelivery = true,
    docksRadius = 25.0
}

local menuOpen = new.bool(false)
local guiEasytruckEnabled = new.bool(false)
local guiGpsEnabled = new.bool(true)
local guiSmartInitialLoad = new.bool(true)
local guiAutoReload = new.bool(true)
local guiDocksRadius = new.float(25.0)

-- Delivery destination marker
local DELIVERY_RADIUS = 3.0
local DELIVERY_MARKER_COLOR = 0x6E00FDFF -- RGBA, #6e00fd
local DELIVERY_MARKER_LAYERS = {
    {zOffset = 0.0, radius = DELIVERY_RADIUS},
    {zOffset = 2.0, radius = DELIVERY_RADIUS * 0.82},
    {zOffset = 4.0, radius = DELIVERY_RADIUS * 0.64}
}
local DELIVERY_MARKER_RED = 145
local DELIVERY_MARKER_GREEN = 0
local DELIVERY_MARKER_BLUE = 12
local DELIVERY_MARKER_ALPHA = 165
local deliveryActive = false
local returnTripActive = false
local positionSaved = false
local deliveryBlip = nil
local deliveryMarkerRendererAvailable = false
local deliveryMarkerNative = {}
local OCEAN_DOCKS_POS = {
    x = 2225.203369,
    y = -2635.973144,
    z = 13.441310
}
local OCEAN_DOCKS_LOAD_POS = {
    x = 2198.0,
    y = -2662.0,
    z = 13.0
}
local TRUCK_MODELS = {
    [414] = "Mule",
    [456] = "Yankee",
    [499] = "Benson"
}

local STATS_CAPTURE_TIMEOUT = 2500
local CURRENT_CHECKPOINT_WARNING =
    "Please ensure that your current checkpoint is destroyed first"
local LOADTRUCK_ACCEPTED_MESSAGE =
    "Pick up some goods to transport with your Truck at Ocean Docks"
local TRUCK_LOADING_MESSAGE =
    "Please wait a moment while the truck is being loaded"
local TRUCK_FILLED_MESSAGE = "Your Truck was filled with"

local automationStatus = "Idle"
local jobStatus = "unknown"
local statsCaptureActive = false
local statsCaptureStarted = 0
local statsDividerCount = 0
local statsDetectedTrucker = false
local jobCheckFailedThisVisit = false
local loadInProgress = false
local loadStage = "idle"
local automaticCancelPending = false
local retryLoadAfterVehicleSync = false
local loadAttemptedThisVisit = false
local checkpointBlocked = false
local reloadPending = false
local manualLoadPending = false
local wasEligibleAtDocks = false

-- Live road GPS. These addresses belong to GTA SA 1.0 US, which SA-MP uses.
local GPS_MAX_NODES = 1200
local GPS_UPDATE_INTERVAL = 1250
local GPS_LINE_WIDTH = 6.0
local GPS_ROUTE_COLOR = 0xFF6E00FD -- ARGB, #6e00fd
local GPS_RADAR_RADIUS = 0.97
local GPS_SMOOTHING_PASSES = 2
local GPS_ROUND_JOIN_CORNERS = 16
local gpsEnabled = true
local gpsAvailable = false
local gpsRoute = {}
local gpsDistance = 0.0
local lastGpsUpdate = 0
local gpsNative = {}
local gpsRadarRenderer = nil
local gpsRadarRendererActive = false

local DELIVERY_TIP = "TIP: Deliver the goods to the specified location (see checkpoint on radar)."
local HIJACK_WARNING = "WARNING: Watch out for truck hijackers, they can hijack your truck and get away with the goods."
local DELIVERY_SUCCESS_PREFIX = "* You delivered the "
local DELIVERY_SUCCESS_SUFFIX = ", return the truck to the Ocean Docks to collect your pay."
local RETURN_TIP = "TIP: Return to the Ocean Docks (see checkpoint on radar)."
local TRUCK_CANCELLED = "* You have cancelled: truck."
local CHECKPOINTS_RESET = "All current checkpoints, trackers and accepted fares have been reset."

local function clearGpsRoute()
    gpsRoute = {}
    gpsDistance = 0.0
    lastGpsUpdate = 0
    if gpsRadarRendererActive then
        gpsRadarRenderer.ETGPS_ClearRoute()
    end
end

local function initializeGpsRadarRenderer()
    local rendererPath = getGameDirectory() .. "\\EasyTruckGPS.asi"
    local loaded, renderer = pcall(ffi.load, rendererPath)
    if not loaded or renderer == nil then
        return false
    end

    local called, ready = pcall(function()
        return renderer.ETGPS_Initialize() ~= 0
            and renderer.ETGPS_IsInstalled() ~= 0
    end)
    if not called or not ready then
        pcall(function()
            renderer.ETGPS_Shutdown()
        end)
        return false
    end

    gpsRadarRenderer = renderer
    gpsRadarRendererActive = true
    return true
end

local function submitGpsRouteToRadar()
    if not gpsRadarRendererActive then
        return
    end

    local count = math.min(#gpsRoute, 5000)
    if count == 0 then
        gpsRadarRenderer.ETGPS_ClearRoute()
        return
    end

    local packedRoute = ffi.new('float[?]', count * 2)
    for i = 1, count do
        local point = gpsRoute[i]
        local offset = (i - 1) * 2
        packedRoute[offset] = point.x
        packedRoute[offset + 1] = point.y
    end
    gpsRadarRenderer.ETGPS_SetRoute(packedRoute, count)
end

local function initializeGps()
    -- Refuse to call fixed game addresses if this is not the expected executable.
    if memory.getuint8(0x4515D0, true) ~= 0x51
        or memory.getuint8(0x420AC0, true) ~= 0x8B
        or memory.getuint8(0x583530, true) ~= 0x83 then
        return false
    end

    if ffi.sizeof('ET_CPathNode') ~= 0x1C then
        return false
    end

    gpsNative.doPathSearch = ffi.cast('ET_DoPathSearch', 0x4515D0)
    gpsNative.transformWorldToRadar = ffi.cast('ET_TransformRadarPoint', 0x583530)
    gpsNative.transformRadarToScreen = ffi.cast('ET_TransformRadarPoint', 0x583480)

    -- The immediate operand at this instruction points to ThePaths. Reading it
    -- also keeps compatibility with path limit adjusters that relocate it.
    gpsNative.thePaths = ffi.cast('void**', 0x40CA27)[0]
    if gpsNative.thePaths == nil or gpsNative.thePaths == ffi.NULL then
        return false
    end

    gpsNative.worldPoint = ffi.new('ET_CVector2D')
    gpsNative.radarPoint = ffi.new('ET_CVector2D')
    gpsNative.screenInput = ffi.new('ET_CVector2D')
    gpsNative.screenPoint = ffi.new('ET_CVector2D')
    return true
end

local function getPathNodePosition(address)
    if address.region >= 72 or address.index == 0xFFFF then
        return nil
    end

    local pathNodeArrays = ffi.cast(
        'ET_CPathNode**',
        ffi.cast('unsigned char*', gpsNative.thePaths) + 0x804
    )
    local areaNodes = pathNodeArrays[address.region]
    if areaNodes == nil or areaNodes == ffi.NULL then
        return nil
    end

    local node = areaNodes[address.index]
    return tonumber(node.x) / 8.0, tonumber(node.y) / 8.0, tonumber(node.z) / 8.0
end

-- Chaikin corner cutting rounds the road-node polyline without overshooting
-- sharp corners. Keeping the first and last points anchors the route ends.
local function smoothGpsRoute(points)
    if #points < 3 then
        return points
    end

    local smoothed = points
    for _ = 1, GPS_SMOOTHING_PASSES do
        local nextPass = {smoothed[1]}

        for i = 1, #smoothed - 1 do
            local first = smoothed[i]
            local second = smoothed[i + 1]

            nextPass[#nextPass + 1] = {
                x = first.x * 0.75 + second.x * 0.25,
                y = first.y * 0.75 + second.y * 0.25,
                z = first.z * 0.75 + second.z * 0.25
            }
            nextPass[#nextPass + 1] = {
                x = first.x * 0.25 + second.x * 0.75,
                y = first.y * 0.25 + second.y * 0.75,
                z = first.z * 0.25 + second.z * 0.75
            }
        end

        nextPass[#nextPass + 1] = smoothed[#smoothed]
        smoothed = nextPass
    end

    return smoothed
end

local function updateGpsRoute()
    local navigationActive = returnTripActive or (deliveryActive and positionSaved)
    if not gpsAvailable or not gpsEnabled or not easytruck_enabled
        or not navigationActive then
        clearGpsRoute()
        return
    end

    local now = getGameTimer()
    if lastGpsUpdate ~= 0 and now - lastGpsUpdate < GPS_UPDATE_INTERVAL then
        return
    end
    lastGpsUpdate = now

    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local destination = returnTripActive and OCEAN_DOCKS_POS or targetPos
    local origin = ffi.new('ET_CVector', {px, py, pz})
    local target = ffi.new('ET_CVector', {destination.x, destination.y, destination.z})
    local invalidAddress = ffi.new('ET_CNodeAddress', {0xFFFF, 0xFFFF})
    local resultNodes = ffi.new('ET_CNodeAddress[?]', GPS_MAX_NODES)
    local resultCount = ffi.new('short[1]')
    local resultDistance = ffi.new('float[1]')

    local function searchRoads(respectLaneDirection)
        resultCount[0] = 0
        resultDistance[0] = 0.0
        gpsNative.doPathSearch(
            gpsNative.thePaths,
            0, -- vehicle road nodes
            origin,
            invalidAddress,
            target,
            resultNodes,
            resultCount,
            GPS_MAX_NODES,
            resultDistance,
            1000000.0,
            nil,
            1000000.0,
            respectLaneDirection,
            invalidAddress,
            false,
            false
        )
    end

    -- Prefer legal traffic flow. Some GTA road links have incomplete lane
    -- metadata, so retry without that restriction instead of hiding the GPS.
    searchRoads(true)
    if tonumber(resultCount[0]) <= 0 then
        searchRoads(false)
    end

    local newRoute = {}
    local count = math.max(0, math.min(tonumber(resultCount[0]), GPS_MAX_NODES))
    for i = 0, count - 1 do
        local x, y, z = getPathNodePosition(resultNodes[i])
        if x then
            newRoute[#newRoute + 1] = {x = x, y = y, z = z}
        end
    end

    -- When both positions share one road node, GTA returns zero nodes. A short
    -- direct final segment is still useful. A failed long search stays hidden.
    local directDistance = getDistanceBetweenCoords3d(
        px, py, pz,
        destination.x, destination.y, destination.z
    )
    if #newRoute > 0 or directDistance < 60.0 then
        newRoute[#newRoute + 1] = {
            x = destination.x,
            y = destination.y,
            z = destination.z
        }
    end

    gpsRoute = smoothGpsRoute(newRoute)
    gpsDistance = tonumber(resultDistance[0])
    submitGpsRouteToRadar()
end

local function worldToRadar(x, y)
    gpsNative.worldPoint.x = x
    gpsNative.worldPoint.y = y
    gpsNative.transformWorldToRadar(gpsNative.radarPoint, gpsNative.worldPoint)
    return tonumber(gpsNative.radarPoint.x), tonumber(gpsNative.radarPoint.y)
end

local function radarToScreen(x, y)
    gpsNative.screenInput.x = x
    gpsNative.screenInput.y = y
    gpsNative.transformRadarToScreen(gpsNative.screenPoint, gpsNative.screenInput)
    return tonumber(gpsNative.screenPoint.x), tonumber(gpsNative.screenPoint.y)
end

local function clipLineToRadar(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local a = dx * dx + dy * dy
    local radiusSquared = GPS_RADAR_RADIUS * GPS_RADAR_RADIUS

    if a < 0.0000001 then
        if x1 * x1 + y1 * y1 <= radiusSquared then
            return x1, y1, x2, y2
        end
        return nil
    end

    local b = 2.0 * (x1 * dx + y1 * dy)
    local c = x1 * x1 + y1 * y1 - radiusSquared
    local discriminant = b * b - 4.0 * a * c
    if discriminant < 0.0 then
        return nil
    end

    local root = math.sqrt(discriminant)
    local enter = (-b - root) / (2.0 * a)
    local leave = (-b + root) / (2.0 * a)
    local startT = math.max(0.0, enter)
    local endT = math.min(1.0, leave)
    if startT > endT then
        return nil
    end

    return x1 + dx * startT, y1 + dy * startT,
        x1 + dx * endT, y1 + dy * endT
end

local function drawGpsRoute()
    if not gpsAvailable or not gpsEnabled or not easytruck_enabled
        or (not deliveryActive and not returnTripActive)
        or #gpsRoute == 0 or isPauseMenuActive() then
        return
    end

    local px, py = getCharCoordinates(PLAYER_PED)
    local previousX, previousY = worldToRadar(px, py)
    local previousWasVisible = false

    for i = 1, #gpsRoute do
        local point = gpsRoute[i]
        local currentX, currentY = worldToRadar(point.x, point.y)
        local x1, y1, x2, y2 = clipLineToRadar(
            previousX, previousY,
            currentX, currentY
        )

        if x1 then
            local screenX1, screenY1 = radarToScreen(x1, y1)
            local screenX2, screenY2 = radarToScreen(x2, y2)
            renderDrawLine(
                screenX1, screenY1,
                screenX2, screenY2,
                GPS_LINE_WIDTH,
                GPS_ROUTE_COLOR
            )

            -- Filling each segment end produces continuous round caps and
            -- removes the small gaps that thick D3D lines leave at bends.
            if not previousWasVisible then
                renderDrawPolygon(
                    screenX1, screenY1,
                    GPS_LINE_WIDTH, GPS_LINE_WIDTH,
                    GPS_ROUND_JOIN_CORNERS,
                    0.0,
                    GPS_ROUTE_COLOR
                )
            end
            renderDrawPolygon(
                screenX2, screenY2,
                GPS_LINE_WIDTH, GPS_LINE_WIDTH,
                GPS_ROUND_JOIN_CORNERS,
                0.0,
                GPS_ROUTE_COLOR
            )
            previousWasVisible = true
        else
            previousWasVisible = false
        end

        previousX, previousY = currentX, currentY
    end
end

-- ========= Configuration =========
local function syncGuiSettings()
    guiEasytruckEnabled[0] = easytruck_enabled
    guiGpsEnabled[0] = gpsEnabled
    guiSmartInitialLoad[0] = settings.smartInitialLoad
    guiAutoReload[0] = settings.autoReloadAfterDelivery
    guiDocksRadius[0] = settings.docksRadius
end

local function saveConfig()
    local data = {
        version = 2,
        destination = {
            x = targetPos.x,
            y = targetPos.y,
            z = targetPos.z,
            saved = positionSaved
        },
        settings = {
            enabled = easytruck_enabled,
            gps = gpsEnabled,
            smartInitialLoad = settings.smartInitialLoad,
            autoReloadAfterDelivery = settings.autoReloadAfterDelivery,
            docksRadius = settings.docksRadius
        }
    }

    local f = io.open(saveFile, "w")
    if not f then
        return false
    end
    f:write(encodeJson(data))
    f:close()
    return true
end

local function loadConfig()
    local f = io.open(saveFile, "r")
    if not f then
        syncGuiSettings()
        return
    end

    local raw = f:read("*a")
    f:close()
    local migrated = false
    local decoded = nil
    if raw:match("^%s*{") then
        local decodedOk, decodedValue = pcall(decodeJson, raw)
        if decodedOk and type(decodedValue) == "table" then
            decoded = decodedValue
        end
    end

    if decoded then
        local destination = decoded.destination
        local savedSettings = decoded.settings
        if type(destination) == "table"
            and tonumber(destination.x)
            and tonumber(destination.y)
            and tonumber(destination.z) then
            targetPos.x = tonumber(destination.x)
            targetPos.y = tonumber(destination.y)
            targetPos.z = tonumber(destination.z)
            positionSaved = destination.saved ~= false
        end
        if type(savedSettings) == "table" then
            easytruck_enabled = savedSettings.enabled == true
            if type(savedSettings.gps) == "boolean" then
                gpsEnabled = savedSettings.gps
            end
            if type(savedSettings.smartInitialLoad) == "boolean" then
                settings.smartInitialLoad = savedSettings.smartInitialLoad
            end
            if type(savedSettings.autoReloadAfterDelivery) == "boolean" then
                settings.autoReloadAfterDelivery = savedSettings.autoReloadAfterDelivery
            end
            local radius = tonumber(savedSettings.docksRadius)
            if radius then
                settings.docksRadius = math.max(5.0, math.min(radius, 100.0))
            end
        end
    else
        -- Migrate the original x,y,z text format without losing the destination.
        local x, y, z = raw:match(
            "(-?%d+%.?%d*),(-?%d+%.?%d*),(-?%d+%.?%d*)"
        )
        if x and y and z then
            targetPos.x = tonumber(x)
            targetPos.y = tonumber(y)
            targetPos.z = tonumber(z)
            positionSaved = true
        end
        migrated = true
    end

    syncGuiSettings()
    if migrated then
        saveConfig()
    end
end

local function clearDeliveryMarkers()
    if deliveryBlip ~= nil then
        removeBlip(deliveryBlip)
        deliveryBlip = nil
    end

end

local function initializeDeliveryMarkerRenderer()
    -- C3dMarkers::PlaceMarker in GTA SA 1.0 US. Refuse the call when the
    -- executable signature differs so another game build cannot be crashed.
    if memory.getuint8(0x725120, true) ~= 0x83
        or memory.getuint8(0x725121, true) ~= 0xEC
        or memory.getuint8(0x725122, true) ~= 0x58 then
        return false
    end

    deliveryMarkerNative.placeMarker = ffi.cast(
        'ET_PlaceMarker',
        0x725120
    )
    deliveryMarkerNative.position = ffi.new('ET_CVector')
    deliveryMarkerRendererAvailable = true
    return true
end

local function renderDeliveryMarkerLayers()
    if not deliveryMarkerRendererAvailable
        or not easytruck_enabled
        or not deliveryActive
        or not positionSaved then
        return
    end

    local position = deliveryMarkerNative.position
    for index, layer in ipairs(DELIVERY_MARKER_LAYERS) do
        position.x = targetPos.x
        position.y = targetPos.y
        position.z = targetPos.z + layer.zOffset

        deliveryMarkerNative.placeMarker(
            0x45540000 + index,
            1,
            position,
            layer.radius,
            DELIVERY_MARKER_RED,
            DELIVERY_MARKER_GREEN,
            DELIVERY_MARKER_BLUE,
            DELIVERY_MARKER_ALPHA,
            1024,
            0.0,
            0,
            0.0, 0.0, 1.0,
            false
        )
    end
end

local function createDeliveryMarkers()
    clearDeliveryMarkers()
    clearGpsRoute()

    if not easytruck_enabled or not deliveryActive then
        return
    end

    if not positionSaved then
        sampAddChatMessage("{FF00FF}[EasyTruck] {FFAA00}Delivery started, but no return position is saved. Use /setpos.", -1)
        return
    end

    deliveryBlip = addBlipForCoord(targetPos.x, targetPos.y, targetPos.z)
    changeBlipColour(deliveryBlip, DELIVERY_MARKER_COLOR)
    -- Appearance 0 preserves the custom color; appearance 2 forces red.
    setCoordBlipAppearance(deliveryBlip, 0)

    -- The three physical layers are submitted every frame with ground/roof
    -- snapping disabled, so targetPos.z remains the absolute base level.
end

local function setDeliveryActive(active)
    if active then
        if not deliveryActive then
            deliveryActive = true
            createDeliveryMarkers()
        end
    else
        deliveryActive = false
        clearDeliveryMarkers()
        clearGpsRoute()
    end
end

local function setReturnTripActive(active)
    if returnTripActive ~= active then
        returnTripActive = active
        clearGpsRoute()
    end
end

-- ========= Smart loading =========
local function getCurrentTruckerVehicle()
    if not isCharInAnyCar(PLAYER_PED) then
        return nil, nil, nil
    end

    local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
    if getDriverOfCar(vehicle) ~= PLAYER_PED then
        return nil, nil, nil
    end

    local model = getCarModel(vehicle)
    local name = TRUCK_MODELS[model]
    if not name then
        return nil, model, nil
    end
    return vehicle, model, name
end

local function getDocksDistance()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    return getDistanceBetweenCoords3d(
        px, py, pz,
        OCEAN_DOCKS_LOAD_POS.x,
        OCEAN_DOCKS_LOAD_POS.y,
        OCEAN_DOCKS_LOAD_POS.z
    )
end

local function isInsideLoadingArea()
    return getDocksDistance() <= settings.docksRadius
end

local function isTruckVehicleSyncRejection(text)
    local lower = text:lower()
    if not lower:find("truck", 1, true) then
        return false
    end
    return lower:find("you are not in", 1, true)
        or lower:find("you aren't in", 1, true)
        or lower:find("you are not inside", 1, true)
        or lower:find("you must be in", 1, true)
        or lower:find("you must be inside", 1, true)
        or lower:find("you need to be in", 1, true)
        or lower:find("you need to be inside", 1, true)
        or lower:find("you have to be in", 1, true)
end

local function resetLoadingRequests()
    statsCaptureActive = false
    statsDividerCount = 0
    statsDetectedTrucker = false
    loadInProgress = false
    loadStage = "idle"
    automaticCancelPending = false
    retryLoadAfterVehicleSync = false
    loadAttemptedThisVisit = false
    checkpointBlocked = false
    reloadPending = false
    manualLoadPending = false
    wasEligibleAtDocks = false
    jobCheckFailedThisVisit = false
end

local function setEasytruckEnabled(active, announce)
    easytruck_enabled = active == true
    guiEasytruckEnabled[0] = easytruck_enabled

    if easytruck_enabled then
        automationStatus = "Ready"
        if deliveryActive then
            createDeliveryMarkers()
        end
    else
        resetLoadingRequests()
        automationStatus = "Disabled"
        clearDeliveryMarkers()
        clearGpsRoute()
    end

    saveConfig()
    if announce then
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {FFFFFF}System "
                .. (easytruck_enabled and "{00FF00}enabled" or "{FF0000}disabled")
                .. ".",
            -1
        )
    end
end

local function setGpsEnabled(active, announce)
    gpsEnabled = active == true
    guiGpsEnabled[0] = gpsEnabled
    clearGpsRoute()
    saveConfig()
    if announce then
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {FFFFFF}GPS "
                .. (gpsEnabled and "{00FF00}enabled" or "{FF0000}disabled")
                .. ".",
            -1
        )
    end
end

local function beginStatsCheck()
    if statsCaptureActive or jobStatus == "checking" then
        return
    end

    statsCaptureActive = true
    statsCaptureStarted = getGameTimer()
    statsDividerCount = 0
    statsDetectedTrucker = false
    jobStatus = "checking"
    automationStatus = "Checking Trucker job"
    sampSendChat("/stats")
end

local function finishStatsCheck(timedOut)
    statsCaptureActive = false
    if timedOut then
        jobStatus = "unknown"
        jobCheckFailedThisVisit = true
        automationStatus = "Job check timed out"
    elseif statsDetectedTrucker then
        jobStatus = "trucker"
        automationStatus = "Trucker job confirmed"
    else
        jobStatus = "not_trucker"
        automationStatus = "Trucker job not found"
    end
end

local function requestTruckLoad(reason, bypassSmartChecks)
    local _, _, truckName = getCurrentTruckerVehicle()
    if not easytruck_enabled or deliveryActive or returnTripActive
        or loadInProgress then
        return false
    end
    if not bypassSmartChecks
        and (not truckName or not isInsideLoadingArea()) then
        return false
    end

    loadInProgress = true
    loadStage = "requested"
    automaticCancelPending = false
    retryLoadAfterVehicleSync = false
    loadAttemptedThisVisit = true
    checkpointBlocked = false
    reloadPending = false
    manualLoadPending = false
    automationStatus = reason == "reload"
        and "Loading the next delivery"
        or "Requesting a delivery"
    sampSendChat("/loadtruck")
    return true
end

local function queueManualLoad()
    if not easytruck_enabled then
        automationStatus = "Enable EasyTruck first"
        return
    end
    if loadInProgress then
        automationStatus = "Truck loading is already in progress"
        return
    end
    manualLoadPending = true
    checkpointBlocked = false
    loadAttemptedThisVisit = false
    jobCheckFailedThisVisit = false
    automationStatus = "Manual load queued"
end

local function setCurrentDeliveryPosition()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    targetPos.x, targetPos.y, targetPos.z = px, py, pz
    positionSaved = true
    if saveConfig() then
        if deliveryActive then
            createDeliveryMarkers()
        end
        sampAddChatMessage(
            string.format(
                "{FF00FF}[EasyTruck] {00FF00}New position set: %.2f, %.2f, %.2f",
                px, py, pz
            ),
            -1
        )
    else
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {FF0000}Failed to save the position.",
            -1
        )
    end
end

local function processSmartLoading()
    local now = getGameTimer()
    if statsCaptureActive and now - statsCaptureStarted > STATS_CAPTURE_TIMEOUT then
        finishStatsCheck(true)
    end

    if not easytruck_enabled then
        return
    end
    -- Server messages are the authoritative loading state. Only cancel for
    -- leaving the docks after the pickup request was accepted and before the
    -- server announced that physical loading started.
    if loadInProgress then
        if loadStage == "waiting" and not isInsideLoadingArea() then
            automaticCancelPending = true
            loadStage = "cancelling"
            automationStatus = "Cancelling load: left Ocean Docks"
            sampSendChat("/cancel truck")
            sampAddChatMessage(
                "{FF00FF}[EasyTruck] {FFAA00}Load request cancelled: you left Ocean Docks.",
                -1
            )
            return
        end

        if loadStage == "requested" then
            automationStatus = "Waiting for load request response"
        elseif loadStage == "waiting" then
            automationStatus = "Waiting in the Ocean Docks loading area"
        elseif loadStage == "loading" then
            automationStatus = "Truck loading in progress"
        elseif loadStage == "filled" then
            automationStatus = "Waiting for delivery assignment"
        elseif loadStage == "cancelling" then
            automationStatus = "Cancelling truck request"
        end
        return
    end
    if deliveryActive then
        automationStatus = "Delivering goods"
        return
    end
    if returnTripActive then
        automationStatus = "Returning to Ocean Docks"
        return
    end
    if retryLoadAfterVehicleSync then
        automationStatus = "Waiting for server vehicle sync"
        return
    end

    local _, _, truckName = getCurrentTruckerVehicle()
    local eligibleAtDocks = truckName ~= nil and isInsideLoadingArea()
    if not eligibleAtDocks then
        if wasEligibleAtDocks then
            loadAttemptedThisVisit = false
            checkpointBlocked = false
            jobCheckFailedThisVisit = false
        end
        wasEligibleAtDocks = false
        if not truckName then
            automationStatus = "Enter a Mule, Yankee, or Benson"
        else
            automationStatus = "Drive into the Ocean Docks loading area"
        end
        return
    end

    if not wasEligibleAtDocks then
        wasEligibleAtDocks = true
        loadAttemptedThisVisit = false
        checkpointBlocked = false
        jobCheckFailedThisVisit = false
    end
    local wantsReload = reloadPending and settings.autoReloadAfterDelivery
    local wantsInitial = settings.smartInitialLoad and not loadAttemptedThisVisit
    local wantsLoad = manualLoadPending or wantsReload or wantsInitial
    if not wantsLoad then
        automationStatus = "Ready at Ocean Docks"
        return
    end
    if checkpointBlocked and not manualLoadPending then
        automationStatus = "Blocked by an existing checkpoint"
        return
    end
    if jobStatus == "unknown" then
        if not jobCheckFailedThisVisit then
            beginStatsCheck()
        end
        return
    elseif jobStatus == "checking" then
        return
    elseif jobStatus ~= "trucker" then
        automationStatus = "Trucker job required"
        loadAttemptedThisVisit = true
        manualLoadPending = false
        reloadPending = false
        return
    end

    requestTruckLoad(wantsReload and "reload" or "initial")
end

-- ========= Interface =========
imgui.OnInitialize(function()
    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.FrameRounding = 5.0
    style.GrabRounding = 5.0
    style.WindowPadding = imgui.ImVec2(12.0, 12.0)
    style.ItemSpacing = imgui.ImVec2(8.0, 7.0)
    imgui.GetIO().IniFilename = nil
end)

imgui.OnFrame(function()
    return menuOpen[0]
end, function()
    local width, height = getScreenResolution()
    imgui.SetNextWindowPos(
        imgui.ImVec2(width * 0.5, height * 0.5),
        imgui.Cond.FirstUseEver,
        imgui.ImVec2(0.5, 0.5)
    )
    imgui.SetNextWindowSize(imgui.ImVec2(470.0, 0.0), imgui.Cond.FirstUseEver)
    imgui.Begin(
        "EasyTruck Control Center##EasyTruck",
        menuOpen,
        imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoCollapse
    )

    imgui.Text("SYSTEM")
    imgui.Separator()
    if imgui.Checkbox("Enable EasyTruck", guiEasytruckEnabled) then
        setEasytruckEnabled(guiEasytruckEnabled[0], true)
    end
    if imgui.Checkbox("Enable road GPS", guiGpsEnabled) then
        setGpsEnabled(guiGpsEnabled[0], false)
    end

    imgui.Spacing()
    imgui.Text("AUTOMATION")
    imgui.Separator()
    if imgui.Checkbox("Smart initial loading", guiSmartInitialLoad) then
        settings.smartInitialLoad = guiSmartInitialLoad[0]
        loadAttemptedThisVisit = false
        saveConfig()
    end
    if imgui.Checkbox("Load another delivery after payment", guiAutoReload) then
        settings.autoReloadAfterDelivery = guiAutoReload[0]
        if not settings.autoReloadAfterDelivery then
            if reloadPending then
                loadAttemptedThisVisit = true
            end
            reloadPending = false
        end
        saveConfig()
    end
    imgui.PushItemWidth(235.0)
    if imgui.SliderFloat(
        "Ocean Docks range",
        guiDocksRadius,
        5.0,
        100.0,
        "%.0f m"
    ) then
        settings.docksRadius = tonumber(guiDocksRadius[0])
        saveConfig()
    end
    imgui.PopItemWidth()

    imgui.Spacing()
    imgui.Text("LIVE STATUS")
    imgui.Separator()
    local _, model, truckName = getCurrentTruckerVehicle()
    local vehicleText = truckName or (model and "Unsupported vehicle" or "No truck")
    local jobText = ({
        unknown = "Not checked",
        checking = "Checking...",
        trucker = "Trucker",
        not_trucker = "Not a Trucker"
    })[jobStatus] or jobStatus
    imgui.Text(string.format("Status: %s", automationStatus))
    imgui.Text(string.format("Job: %s", jobText))
    imgui.Text(string.format("Vehicle: %s", vehicleText))
    imgui.Text(string.format(
        "Ocean Docks: %.1f m away (%s)",
        getDocksDistance(),
        isInsideLoadingArea() and "inside" or "outside"
    ))
    imgui.Text(string.format(
        "Server checkpoint: %s",
        hasCheckpoint and "detected" or "none"
    ))
    imgui.Text(string.format(
        "GPS renderer: %s",
        gpsRadarRendererActive and "native" or (gpsAvailable and "fallback" or "unavailable")
    ))

    imgui.Spacing()
    if imgui.Button("Load now", imgui.ImVec2(135.0, 30.0)) then
        queueManualLoad()
    end
    imgui.SameLine()
    if imgui.Button("Set delivery point here", imgui.ImVec2(190.0, 30.0)) then
        setCurrentDeliveryPosition()
    end
    imgui.SameLine()
    if imgui.Button("Close", imgui.ImVec2(90.0, 30.0)) then
        menuOpen[0] = false
    end

    imgui.End()
end)

-- ========= Main =========
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    sampAddChatMessage("{FF00FF}Easy Truck has been loaded {FFFFFF}- {FF0000}by Haru Hayashi {808080}[/easytruck]", -1)
    loadConfig()
    if initializeDeliveryMarkerRenderer() then
        lua_thread.create(function()
            while true do
                wait(0)
                renderDeliveryMarkerLayers()
            end
        end)
    else
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {FFAA00}Absolute-position 3D markers are unavailable on this gta_sa.exe version.",
            -1
        )
    end
    gpsAvailable = initializeGps()
    if not gpsAvailable then
        sampAddChatMessage("{FF00FF}[EasyTruck] {FFAA00}Road GPS is unavailable: unsupported gta_sa.exe version.", -1)
    elseif not initializeGpsRadarRenderer() then
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {FFAA00}Native radar renderer is unavailable; using the screen renderer.",
            -1
        )
    else
        sampAddChatMessage(
            "{FF00FF}[EasyTruck] {00FF00}Native radar GPS renderer loaded.",
            -1
        )
    end

    sampRegisterChatCommand("easytruck", function()
        syncGuiSettings()
        menuOpen[0] = not menuOpen[0]
    end)

    sampRegisterChatCommand("easygps", function()
        setGpsEnabled(not gpsEnabled, true)
    end)

    sampRegisterChatCommand("aloadtruck", function()
        queueManualLoad()
    end)

    sampRegisterChatCommand("setpos", function()
        if easytruck_enabled then
            setCurrentDeliveryPosition()
        end
    end)

    while true do
        wait(100)

        processSmartLoading()
        if easytruck_enabled then
            if (returnTripActive or (deliveryActive and positionSaved)) and gpsEnabled then
                updateGpsRoute()
            end

            -- Auto Deliver Truck
            if deliveryActive and positionSaved and isCharInAnyCar(PLAYER_PED) then
                local veh = storeCarCharIsInNoSave(PLAYER_PED)
                if TRUCK_MODELS[getCarModel(veh)]
                    and getDriverOfCar(veh) == PLAYER_PED then
                    local px, py, pz = getCharCoordinates(PLAYER_PED)
                    if getDistanceBetweenCoords3d(px, py, pz, targetPos.x, targetPos.y, targetPos.z) < DELIVERY_RADIUS then
                        if os.clock() - lastDeliver > 3 then
                            sampSendChat("/delivertruck")
                            lastDeliver = os.clock()
                        end
                    end
                end
            end
        end
    end
end

function onD3DPresent()
    if not gpsRadarRendererActive then
        drawGpsRoute()
    end
end

 -- Check if any mission/delivery checkpoint blip exists
function hasActiveCheckpoint()
    for i = 0, 255 do
        if doesBlipExist(i) then
            local sprite = getBlipSprite(i)
            if sprite == 1 then -- 1 = red checkpoint marker (adjust if needed)
                return true
            end
        end
    end
    return false
end

-- ========= Event Hooks =========
function sampev.onInitGame(...)
    jobStatus = "unknown"
    resetLoadingRequests()
    automationStatus = easytruck_enabled and "Ready" or "Disabled"
end

function sampev.onShowDialog(id, style, title, btn1, btn2, text)
    if easytruck_enabled and loadInProgress then
        if id == 185 then
            sampSendDialogResponse(185, 1, 0, nil)
            return false
        elseif id == 186 then
            sampSendDialogResponse(186, 1, 2, nil)
            automationStatus = "Waiting for delivery assignment"
            return false
        end
    end
end

function sampev.onSendVehicleSync(data)
    if retryLoadAfterVehicleSync and easytruck_enabled then
        retryLoadAfterVehicleSync = false
        loadAttemptedThisVisit = false
        automationStatus = "Truck synchronized; retrying load"
    end
end

function sampev.onSetCheckpoint(x, y, z, radius)
    hasCheckpoint = true
end

function sampev.onDisableCheckpoint()
    hasCheckpoint = false
end

function sampev.onServerMessage(colorid, text)
    if statsCaptureActive then
        local plainText = text:gsub("{%x%x%x%x%x%x}", "")
        if plainText:find("(Job: Trucker", 1, true)
            or plainText:find("(Job 2: Trucker", 1, true)
            or plainText:find(" - (Job: Trucker", 1, true)
            or plainText:find(" - (Job 2: Trucker", 1, true) then
            statsDetectedTrucker = true
        end

        local compact = plainText:gsub("%s", "")
        if #compact >= 40 and compact:match("^_+$") then
            statsDividerCount = statsDividerCount + 1
            if statsDividerCount >= 2 then
                finishStatsCheck(false)
            end
        end

        -- The automatic /stats query is deliberately silent.
        return false
    end

    if text:find(CURRENT_CHECKPOINT_WARNING, 1, true) then
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        loadAttemptedThisVisit = true
        checkpointBlocked = true
        reloadPending = false
        manualLoadPending = false
        automationStatus = "Blocked by an existing checkpoint"
        if easytruck_enabled then
            sampAddChatMessage(
                "{FF00FF}[EasyTruck] {FFAA00}Loading paused: clear your current checkpoint first.",
                -1
            )
            return false
        end
    end

    if loadInProgress and isTruckVehicleSyncRejection(text) then
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = true
        loadAttemptedThisVisit = true
        automationStatus = "Waiting for server vehicle sync"
        return
    end

    if easytruck_enabled and text:find(LOADTRUCK_ACCEPTED_MESSAGE, 1, true) then
        loadInProgress = true
        loadStage = "waiting"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        loadAttemptedThisVisit = true
        automationStatus = "Waiting in the Ocean Docks loading area"
    elseif text:find(TRUCK_LOADING_MESSAGE, 1, true) then
        loadInProgress = true
        loadStage = "loading"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        loadAttemptedThisVisit = true
        automationStatus = "Truck loading in progress"
    elseif text:find(TRUCK_FILLED_MESSAGE, 1, true) then
        loadInProgress = true
        loadStage = "filled"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        loadAttemptedThisVisit = true
        automationStatus = "Waiting for delivery assignment"
    end

    if text:find(DELIVERY_TIP, 1, true) or text:find(HIJACK_WARNING, 1, true) then
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        checkpointBlocked = false
        reloadPending = false
        manualLoadPending = false
        automationStatus = "Delivering goods"
        setReturnTripActive(false)
        setDeliveryActive(true)
    end

    -- The cargo name between the fixed prefix and suffix can vary.
    local successfulDelivery = text:find(DELIVERY_SUCCESS_PREFIX, 1, true)
        and text:find(DELIVERY_SUCCESS_SUFFIX, 1, true)

    if successfulDelivery or text:find(RETURN_TIP, 1, true) then
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        automationStatus = "Returning to Ocean Docks"
        setDeliveryActive(false)
        setReturnTripActive(true)
    end

    local deliveryPaid = text:find("* You were paid ", 1, true)
        and text:find(" for delivering the goods and returning the truck.", 1, true)

    if deliveryPaid then
        setDeliveryActive(false)
        setReturnTripActive(false)
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        checkpointBlocked = false
        if easytruck_enabled then
            if settings.autoReloadAfterDelivery then
                reloadPending = false
                loadAttemptedThisVisit = true
                requestTruckLoad("reload", true)
            else
                reloadPending = false
                loadAttemptedThisVisit = true
                automationStatus = "Delivery completed"
            end
        end
    end

    local truckCancelled = text:find(TRUCK_CANCELLED, 1, true)
    if truckCancelled
        or text:find(CHECKPOINTS_RESET, 1, true)
        or text:find("Truck delivery cancelled completely", 1, true) then
        local hideCancelResponse = truckCancelled and easytruck_enabled
        setDeliveryActive(false)
        setReturnTripActive(false)
        loadInProgress = false
        loadStage = "idle"
        automaticCancelPending = false
        retryLoadAfterVehicleSync = false
        reloadPending = false
        manualLoadPending = false
        loadAttemptedThisVisit = true
        automationStatus = "Delivery cancelled"
        if hideCancelResponse then
            return false
        end
    end
end

function sampev.onSendCommand(command)
    if command:lower():match("^/cancel%s+truck") then
        setDeliveryActive(false)
        setReturnTripActive(false)
        retryLoadAfterVehicleSync = false
        reloadPending = false
        manualLoadPending = false
        loadAttemptedThisVisit = true
        if automaticCancelPending then
            loadInProgress = true
            loadStage = "cancelling"
            automationStatus = "Cancelling truck request"
        else
            loadInProgress = false
            loadStage = "idle"
            automationStatus = "Delivery cancelled"
        end
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        clearDeliveryMarkers()
        clearGpsRoute()
        if gpsRadarRendererActive then
            gpsRadarRenderer.ETGPS_Shutdown()
            gpsRadarRendererActive = false
        end
    end
end
