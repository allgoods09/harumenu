script_name("HaruMenu")
script_version("0.3-command-preserving-beta")
script_author("Haru Hayashi")
script_description("Integrated control center for Haru's MoonLoader modules")

-- Beta 0.3 embeds its modules while preserving their original commands and controls.

require "moonloader"
local imgui = require "mimgui"
local sampev = require "lib.samp.events"
local wm = require "lib.windows.message"
local new = imgui.new
local unpackValues = unpack or table.unpack

local menuOpen = new.bool(false)
local currentPage = "home"
local entrySource = nil
local layoutDirty = true
local noticeText = "Integrated beta ready. Module actions run directly inside HaruMenu."
local noticeColor

local COLOR = {
    accent = imgui.ImVec4(0.431, 0.000, 0.992, 1.0),
    accentHover = imgui.ImVec4(0.535, 0.145, 1.000, 1.0),
    accentActive = imgui.ImVec4(0.350, 0.000, 0.820, 1.0),
    panel = imgui.ImVec4(0.045, 0.040, 0.070, 0.965),
    panelSoft = imgui.ImVec4(0.080, 0.070, 0.115, 0.940),
    border = imgui.ImVec4(0.300, 0.250, 0.410, 0.800),
    textMuted = imgui.ImVec4(0.650, 0.670, 0.730, 1.0),
    green = imgui.ImVec4(0.250, 0.900, 0.490, 1.0),
    amber = imgui.ImVec4(1.000, 0.690, 0.250, 1.0),
    red = imgui.ImVec4(1.000, 0.380, 0.420, 1.0),
}
noticeColor = COLOR.textMuted

local MODULE_SPECS = {
    {
        id = "easytruck",
        category = "AUTOMATION",
        title = "EasyTruck",
        file = "EasyTruck.lua",
        standaloneName = "EasyTruck",
        description = "Truck loading automation, delivery checkpoints, and road GPS.",
        enabled = true,
        source = [====[script_name('EasyTruck')
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
]====],
        exportCode = [====[
__HARU_EXPORTS = {
    initialize = function()
        loadConfig()
        if not initializeDeliveryMarkerRenderer() then
            sampAddChatMessage(
                "{6E00FD}[HaruMenu] {FFAA00}EasyTruck absolute-position markers are unavailable.",
                -1
            )
        end
        gpsAvailable = initializeGps()
        if gpsAvailable then
            initializeGpsRadarRenderer()
        end
    end,
    tick = function()
        processSmartLoading()
        if easytruck_enabled then
            if (returnTripActive or (deliveryActive and positionSaved)) and gpsEnabled then
                updateGpsRoute()
            end
            if deliveryActive and positionSaved and isCharInAnyCar(PLAYER_PED) then
                local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
                if TRUCK_MODELS[getCarModel(vehicle)] and getDriverOfCar(vehicle) == PLAYER_PED then
                    local px, py, pz = getCharCoordinates(PLAYER_PED)
                    if getDistanceBetweenCoords3d(px, py, pz, targetPos.x, targetPos.y, targetPos.z) < DELIVERY_RADIUS
                        and os.clock() - lastDeliver > 3 then
                        sampSendChat("/delivertruck")
                        lastDeliver = os.clock()
                    end
                end
            end
        end
    end,
    frame = renderDeliveryMarkerLayers,
    isEnabled = function() return easytruck_enabled == true end,
    setEnabled = function(value) setEasytruckEnabled(value == true, true) end,
    isGpsEnabled = function() return gpsEnabled == true end,
    setGpsEnabled = function(value) setGpsEnabled(value == true, true) end,
    toggleGps = function() setGpsEnabled(not gpsEnabled, true) end,
    queueLoad = queueManualLoad,
    setDeliveryPoint = setCurrentDeliveryPosition,
    prepareUi = syncGuiSettings,
    renderControls = function()
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
        if imgui.SliderFloat("Ocean Docks range", guiDocksRadius, 5.0, 100.0, "%.0f m") then
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
        imgui.Text(string.format("Server checkpoint: %s", hasCheckpoint and "detected" or "none"))
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
            return true
        end
        return false
    end,
    status = function()
        return automationStatus, jobStatus, hasCheckpoint, deliveryActive, returnTripActive
    end,
}
]====],
    },
    {
        id = "smartlock",
        category = "VEHICLES",
        title = "SmartLock",
        file = "SmartLock.lua",
        standaloneName = "SmartVehicleLock",
        description = "Chooses the correct personal or family vehicle lock command.",
        enabled = true,
        source = [====[script_name("SmartVehicleLock")
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
]====],
        exportCode = [====[
__HARU_EXPORTS = {
    tick = function()
        if isKeyJustPressed(SMART_LOCK_KEY)
            and not isPauseMenuActive()
            and not sampIsChatInputActive()
            and not sampIsDialogActive()
            and not isSampfuncsConsoleActive()
            and not sampIsScoreboardOpen() then
            startSmartLock()
        end
    end,
    action = startSmartLock,
    reset = resetOperation,
    isBusy = function() return operation.active == true end,
}
]====],
    },
    {
        id = "keybinder",
        category = "KEYBINDS",
        title = "Keybinder 2.0",
        file = "Keybinder2.0.lua",
        standaloneName = "Keybinder2.0",
        description = "Haru's command binds and gameplay shortcuts.",
        enabled = true,
        source = [====[require "lib.sampfuncs"
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
]====],
        exportCode = [====[
local function haruKeybinderLocationAction()
    local positions = {
        {623, -601, 17, "garage"},
        {2230, 2465, 791, "garage"},
        {1600, -1609, 13, "impound"},
        {614, -598, 17, "impound"},
        {619, -554, 5, "locker"},
        {2908, -4970, 9331, "locker"},
        {94, 1727, 405, "locker"},
        {1552, -1685, 5052, "locker"},
    }
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    for _, position in ipairs(positions) do
        if getDistanceBetweenCoords3d(px, py, pz, position[1], position[2], position[3]) <= 3.0 then
            if position[4] == "garage" then
                setVirtualKeyDown(0x59, true)
                wait(100)
                setVirtualKeyDown(0x59, false)
            elseif position[4] == "impound" then
                sampSendChat("/impound")
            else
                setVirtualKeyDown(0x12, true)
                wait(500)
                setVirtualKeyDown(0x4C, true)
                wait(500)
                setVirtualKeyDown(0x12, false)
                setVirtualKeyDown(0x4C, false)
            end
            return
        end
    end
end

__HARU_EXPORTS = {
    initialize = function()
        loadConfig()
        if toggler == nil then toggler = true end
    end,
    toggle = function()
        toggler = not toggler
        sampAddChatMessage(
            toggler
                and "{FF00FF}Hayashi's Binds {00FF00}activated."
                or "{FF00FF}Hayashi's Binds {FF0000}deactivated.",
            0x1e81b0
        )
        saveConfig()
    end,
    levelCalculator = function(args)
        local startLvl, endLvl = tostring(args or ""):match("^(%d+)%s+(%d+)$")
        startLvl, endLvl = tonumber(startLvl), tonumber(endLvl)
        if not startLvl or not endLvl or startLvl < 1 or endLvl <= startLvl then
            sampAddChatMessage("{FFFF00}Usage: {FFFFFF}/levcal [startLevel] [endLevel]", -1)
            return
        end
        local totalRP, totalCash = 0, 0
        for lvl = startLvl + 1, endLvl do
            totalRP = totalRP + 8 + (lvl - 2) * 4
            totalCash = totalCash + 5000 + (lvl - 2) * 2500
        end
        sampAddChatMessage(string.format(
            "{00FF00}[LevelCalc] {FFFFFF}From level %d to %d, you need a total of {FFFF00}%d respect points {FFFFFF}and {FFFF00}$%s.",
            startLvl, endLvl, totalRP, totalCash
        ), -1)
    end,
    trafficStop = cmd_tstop1,
    tick = function()
        if not toggler or not isGameFree() then return end
        for key, action in pairs(binds) do
            if isKeyJustPressed(key) and not ((key == 49 or key == 50) and isKeyDown(17)) then
                if type(action) == "string" then
                    sampSendChat(action)
                elseif type(action) == "function" then
                    action()
                end
            end
        end
        if isKeyJustPressed(0x05) then
            haruKeybinderLocationAction()
        end
    end,
    clearChat = function()
        lua_thread.create(function()
            for _ = 1, 100 do
                sampAddChatMessage(" ", -1)
                wait(10)
            end
        end)
    end,
    exitVehicle = function()
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
    end,
    isEnabled = function() return toggler == true end,
    setEnabled = function(value)
        toggler = value == true
        saveConfig()
        sampAddChatMessage(
            toggler
                and "{6E00FD}[HaruMenu] {FFFFFF}Keybinds enabled."
                or "{6E00FD}[HaruMenu] {FFFFFF}Keybinds disabled.",
            -1
        )
    end,
}
]====],
    },
    {
        id = "smartfix",
        category = "UTILITIES",
        title = "SmartFix",
        file = "SmartFix.lua",
        standaloneName = "SmartFix",
        description = "Automates the mechanic repair sequence around the driver seat.",
        enabled = true,
        source = [====[script_name("SmartFix")
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
]====],
        exportCode = [====[
__HARU_EXPORTS = {
    action = startSmartFix,
    isBusy = function() return session.active == true end,
    status = function() return session.state or "idle" end,
    stop = function()
        if session.active then
            abortSession("Repair sequence stopped from HaruMenu.")
        end
    end,
}
]====],
    },
}

local modules = {}
for _, spec in ipairs(MODULE_SPECS) do
    modules[spec.id] = spec
end

local keybindRows = {
    { "3", "/accept bodyguard" },
    { "4", "/accept dicebet" },
    { "5", "/cancel dicebet" },
    { "6", "Set time 20 and weather 39" },
    { "7", "/kcp, then /farm" },
    { "8", "/getcrack 10" },
    { "9", "FBI traffic-stop megaphone sequence" },
    { "-", "/quithelp" },
    { "0", "/helprequests" },
    { "Numpad /", "/nos" },
}

local function normalizedPath(path)
    return tostring(path or ""):gsub("\\", "/"):lower()
end

local function setNotice(text, color)
    noticeText = text
    noticeColor = color or COLOR.textMuted
end

local function navigate(page)
    if currentPage ~= page then
        currentPage = page
        layoutDirty = true
    end
end

local function makeImguiProxy()
    local proxy = {}
    local emptySubscription = { Unsubscribe = function() end }
    setmetatable(proxy, {
        __index = function(_, key)
            if key == "OnInitialize" or key == "OnFrame" then
                return function() return emptySubscription end
            end
            return imgui[key]
        end
    })
    return proxy
end

local function makeEventProxy(runtime)
    return setmetatable({}, {
        __index = function(_, name)
            return runtime.handlers[name]
        end,
        __newindex = function(_, name, callback)
            runtime.handlers[name] = callback
        end,
    })
end

local metadataFunctions = {
    "script_name", "script_version", "script_version_number", "script_author",
    "script_description", "script_url", "script_moonloader", "script_dependencies",
    "script_properties"
}

local function createModuleEnvironment(runtime)
    local eventProxy = makeEventProxy(runtime)
    local imguiProxy = makeImguiProxy()
    local environment = {}

    setmetatable(environment, { __index = _G })
    environment._G = environment

    for _, functionName in ipairs(metadataFunctions) do
        environment[functionName] = function() end
    end

    environment.require = function(name)
        if name == "lib.samp.events" or name == "samp.events" then
            return eventProxy
        end
        if name == "mimgui" then
            return imguiProxy
        end
        return require(name)
    end

    environment.sampRegisterChatCommand = function(command, callback)
        command = tostring(command or ""):gsub("^/", ""):lower()
        runtime.commands[command] = callback
    end

    environment.isKeyJustPressed = function(key)
        if not runtime.enabled then
            return false
        end
        return isKeyJustPressed(key)
    end

    environment.sampSendChat = function(text)
        if runtime.enabled then
            return sampSendChat(text)
        end
    end

    return environment
end

local function unloadStandaloneCopies()
    local ownScript = thisScript()
    for _, loadedScript in ipairs(script.list()) do
        if loadedScript ~= ownScript then
            local loadedPath = normalizedPath(loadedScript.path)
            local loadedFile = loadedPath:match("([^/]+)$") or ""
            for _, spec in ipairs(MODULE_SPECS) do
                if loadedFile == spec.file:lower() then
                    loadedScript:unload()
                    break
                end
            end
        end
    end
end

local function loadIntegratedModule(spec)
    local runtime = {
        spec = spec,
        id = spec.id,
        title = spec.title,
        category = spec.category,
        description = spec.description,
        file = spec.file,
        enabled = spec.enabled,
        handlers = {},
        commands = {},
        exports = {},
        loaded = false,
        started = false,
        nextTick = 0,
        tickInterval = spec.id == "easytruck" and 100 or 0,
        error = nil,
    }

    runtime.environment = createModuleEnvironment(runtime)
    local source = spec.source .. "\n" .. spec.exportCode
    local chunk, compileError = loadstring(source, "@HaruMenu/" .. spec.file)
    if not chunk then
        runtime.error = compileError
        return runtime
    end

    setfenv(chunk, runtime.environment)
    local ok, loadError = pcall(chunk)
    if not ok then
        runtime.error = loadError
        return runtime
    end

    runtime.exports = rawget(runtime.environment, "__HARU_EXPORTS") or {}
    runtime.loaded = true

    if runtime.exports.initialize then
        local initialized, initializeError = pcall(runtime.exports.initialize)
        if not initialized then
            runtime.error = initializeError
            runtime.loaded = false
            return runtime
        end
    end

    local onModuleLoad = rawget(runtime.environment, "onScriptLoad")
    if onModuleLoad then
        pcall(onModuleLoad)
    end

    runtime.started = true

    return runtime
end

local function initializeIntegratedModules()
    unloadStandaloneCopies()
    wait(150)

    for _, spec in ipairs(MODULE_SPECS) do
        modules[spec.id] = loadIntegratedModule(spec)
        if modules[spec.id].error then
            sampAddChatMessage(
                string.format("{6E00FD}[HaruMenu] {FF6666}%s failed: %s", spec.title, tostring(modules[spec.id].error)),
                -1
            )
        end
    end
end

local function callExport(runtime, name, ...)
    if not runtime or not runtime.loaded then
        setNotice(runtime and (runtime.title .. " failed to load.") or "Module is unavailable.", COLOR.red)
        return nil
    end

    local callback = runtime.exports[name]
    if type(callback) ~= "function" then
        setNotice(runtime.title .. " does not expose " .. name .. ".", COLOR.red)
        return nil
    end

    local results = { pcall(callback, ...) }
    if not results[1] then
        setNotice(runtime.title .. " error: " .. tostring(results[2]), COLOR.red)
        return nil
    end

    table.remove(results, 1)
    return unpackValues(results)
end

local function callCapturedCommand(runtime, command, args)
    if not runtime or not runtime.loaded or not runtime.enabled then
        setNotice((runtime and runtime.title or "Module") .. " is disabled.", COLOR.red)
        return false
    end

    local callback = runtime.commands[tostring(command):gsub("^/", ""):lower()]
    if type(callback) ~= "function" then
        setNotice(runtime.title .. " is still initializing that action.", COLOR.amber)
        return false
    end

    local ok, err = pcall(callback, args or "")
    if not ok then
        setNotice(runtime.title .. " action failed: " .. tostring(err), COLOR.red)
        return false
    end
    return true
end

local function moduleEnabled(runtime)
    if not runtime or not runtime.loaded then
        return false
    end
    if runtime.exports.isEnabled then
        local ok, value = pcall(runtime.exports.isEnabled)
        if ok then
            runtime.enabled = value == true
        end
    end
    return runtime.enabled == true
end

local function setModuleEnabled(runtime, enabled)
    if not runtime or not runtime.loaded then
        setNotice("That integrated module is unavailable.", COLOR.red)
        return
    end

    if runtime.id == "smartfix" and not enabled and callExport(runtime, "isBusy") then
        setNotice("Finish or stop the current SmartFix sequence first.", COLOR.amber)
        return
    end

    runtime.enabled = enabled == true
    if runtime.exports.setEnabled then
        callExport(runtime, "setEnabled", runtime.enabled)
    elseif not runtime.enabled and runtime.exports.reset then
        callExport(runtime, "reset")
    end

    setNotice(runtime.title .. (runtime.enabled and " enabled." or " disabled."), runtime.enabled and COLOR.green or COLOR.amber)
end

local function dispatchEvent(name, ...)
    local args = { ... }
    local suppress = false
    local replacement = nil

    for _, spec in ipairs(MODULE_SPECS) do
        local runtime = modules[spec.id]
        local handler = runtime
            and runtime.enabled
            and runtime.handlers
            and runtime.handlers[name]
        if handler then
            local result = { handler(unpackValues(args)) }
            if result[1] == false then
                suppress = true
            elseif result[1] ~= nil then
                replacement = result
            end
        end
    end

    if suppress then
        return false
    end
    if replacement then
        return unpackValues(replacement)
    end
end

function sampev.onInitGame(...)
    return dispatchEvent("onInitGame", ...)
end

function sampev.onShowDialog(...)
    return dispatchEvent("onShowDialog", ...)
end

function sampev.onSendVehicleSync(...)
    return dispatchEvent("onSendVehicleSync", ...)
end

function sampev.onSendPlayerSync(...)
    return dispatchEvent("onSendPlayerSync", ...)
end

function sampev.onSetCheckpoint(...)
    return dispatchEvent("onSetCheckpoint", ...)
end

function sampev.onDisableCheckpoint(...)
    return dispatchEvent("onDisableCheckpoint", ...)
end

function sampev.onServerMessage(...)
    return dispatchEvent("onServerMessage", ...)
end

function sampev.onSendCommand(...)
    return dispatchEvent("onSendCommand", ...)
end

function sampev.onShowTextDraw(...)
    return dispatchEvent("onShowTextDraw", ...)
end

function sampev.onTextDrawSetString(...)
    return dispatchEvent("onTextDrawSetString", ...)
end

function sampev.onVehicleStreamOut(...)
    return dispatchEvent("onVehicleStreamOut", ...)
end

function sampev.onSetVehicleParams(...)
    return dispatchEvent("onSetVehicleParams", ...)
end

function sampev.onSetVehicleParamsEx(...)
    return dispatchEvent("onSetVehicleParamsEx", ...)
end

function onD3DPresent()
    for _, spec in ipairs(MODULE_SPECS) do
        local runtime = modules[spec.id]
        local callback = runtime
            and runtime.enabled
            and runtime.environment
            and rawget(runtime.environment, "onD3DPresent")
        if callback then callback() end
    end
end

function hasActiveCheckpoint()
    local runtime = modules.easytruck
    local callback = runtime
        and runtime.environment
        and rawget(runtime.environment, "hasActiveCheckpoint")
    if callback then return callback() end
    return false
end

local function closeAllPanels()
    menuOpen[0] = false
    entrySource = nil
end

local function prepareModulePage(page)
    local runtime = modules[page]
    if runtime and runtime.loaded and page == "easytruck" then
        callExport(runtime, "prepareUi")
    end
end

local function openPanel(page, source)
    currentPage = page or "home"
    entrySource = source or "hmenu"
    prepareModulePage(currentPage)
    menuOpen[0] = true
    layoutDirty = true
end

local function drawModuleHeading(runtime)
    imgui.TextColored(COLOR.textMuted, runtime.category)
    imgui.TextColored(COLOR.accentHover, runtime.title)
    imgui.TextColored(COLOR.textMuted, runtime.description)
    imgui.Separator()
    imgui.Spacing()
end

local function drawIntegrationStatus(runtime)
    imgui.Text("Runtime:")
    imgui.SameLine()
    if runtime and runtime.loaded then
        imgui.TextColored(COLOR.green, "INTEGRATED")
    else
        imgui.TextColored(COLOR.red, "FAILED")
        if runtime and runtime.error then
            imgui.TextColored(COLOR.red, tostring(runtime.error))
        end
    end
end

local function drawEnabledToggle(runtime)
    local value = new.bool(moduleEnabled(runtime))
    if imgui.Checkbox("Enable module##" .. runtime.id, value) then
        setModuleEnabled(runtime, value[0])
    end
end

local function drawSidebarButton(label, page)
    local selected = currentPage == page
    if selected then
        imgui.PushStyleColor(imgui.Col.Button, COLOR.accent)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, COLOR.accentHover)
    end
    local clicked = imgui.Button((selected and "  " or "") .. label .. "##nav_" .. page, imgui.ImVec2(-1.0, 26.0))
    if selected then
        imgui.PopStyleColor(2)
    end
    if clicked then
        prepareModulePage(page)
        navigate(page)
    end
end

local function drawSidebar()
    imgui.TextColored(COLOR.accentHover, "HARU")
    imgui.SameLine()
    imgui.Text("MENU")
    imgui.TextColored(COLOR.textMuted, "Beta 0.3")
    imgui.Separator()
    imgui.Spacing()

    drawSidebarButton("Main", "home")
    imgui.Spacing()
    imgui.TextColored(COLOR.textMuted, "MODULES")
    for _, spec in ipairs(MODULE_SPECS) do
        local runtime = modules[spec.id]
        drawSidebarButton(spec.title, spec.id)
        if runtime and not runtime.loaded then
            imgui.TextColored(COLOR.red, "Load failed")
        end
    end
end

local function drawHomeContent()
    imgui.TextColored(COLOR.accentHover, "Control Center")
    imgui.TextColored(COLOR.textMuted, "One runtime, with every original command preserved.")
    imgui.Separator()
    imgui.Spacing()

    local enabledCount = 0
    for _, spec in ipairs(MODULE_SPECS) do
        if moduleEnabled(modules[spec.id]) then enabledCount = enabledCount + 1 end
    end
    imgui.Text(string.format("Modules enabled: %d / %d", enabledCount, #MODULE_SPECS))
    imgui.Spacing()

    for _, spec in ipairs(MODULE_SPECS) do
        local runtime = modules[spec.id]
        imgui.BeginChild("card_" .. spec.id, imgui.ImVec2(0.0, 56.0), true)
        imgui.Text(spec.title)
        imgui.SameLine()
        if runtime and runtime.loaded then
            imgui.TextColored(moduleEnabled(runtime) and COLOR.green or COLOR.amber, moduleEnabled(runtime) and "[ENABLED]" or "[DISABLED]")
        else
            imgui.TextColored(COLOR.red, "[FAILED]")
        end
        imgui.TextColored(COLOR.textMuted, spec.description)
        imgui.EndChild()
        imgui.Spacing()
    end

    imgui.TextColored(noticeColor, noticeText)
end

local function drawEasyTruckPage()
    local runtime = modules.easytruck
    drawModuleHeading(runtime)
    if not runtime.loaded then
        drawIntegrationStatus(runtime)
        return
    end
    if callExport(runtime, "renderControls") then
        closeAllPanels()
    end
end

local function drawSmartLockPage()
    local runtime = modules.smartlock
    drawModuleHeading(runtime)
    drawIntegrationStatus(runtime)
    drawEnabledToggle(runtime)
    imgui.Spacing()

    if runtime.loaded and runtime.enabled then
        if imgui.Button("Lock / unlock nearest vehicle", imgui.ImVec2(255.0, 36.0)) then
            callExport(runtime, "action")
            closeAllPanels()
        end
    end
end

local function drawSmartFixPage()
    local runtime = modules.smartfix
    drawModuleHeading(runtime)
    drawIntegrationStatus(runtime)
    drawEnabledToggle(runtime)
    imgui.Spacing()

    if runtime.loaded and runtime.enabled then
        imgui.Text("State: " .. tostring(callExport(runtime, "status") or "idle"))
        if imgui.Button("Start SmartFix", imgui.ImVec2(200.0, 36.0)) then
            callExport(runtime, "action")
            closeAllPanels()
        end
        if callExport(runtime, "isBusy") then
            imgui.SameLine()
            if imgui.Button("Stop sequence", imgui.ImVec2(170.0, 36.0)) then
                callExport(runtime, "stop")
            end
        end
    end
end

local function drawKeybinderPage()
    local runtime = modules.keybinder
    drawModuleHeading(runtime)
    drawIntegrationStatus(runtime)
    drawEnabledToggle(runtime)

    if runtime.loaded then
        if imgui.Button("Clear chat", imgui.ImVec2(160.0, 32.0)) then
            callExport(runtime, "clearChat")
            closeAllPanels()
        end
        imgui.SameLine()
        if imgui.Button("Exit vehicle", imgui.ImVec2(160.0, 32.0)) then
            callExport(runtime, "exitVehicle")
            closeAllPanels()
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.TextColored(COLOR.accentHover, "Current bind overview")
    imgui.TextColored(COLOR.textMuted, "These binds now run from the embedded Keybinder module.")
    imgui.Spacing()

    imgui.BeginChild("keybind_list", imgui.ImVec2(0.0, 285.0), true)
    imgui.Columns(2, "keybind_columns", true)
    imgui.SetColumnWidth(0, 150.0)
    imgui.TextColored(COLOR.textMuted, "KEY")
    imgui.NextColumn()
    imgui.TextColored(COLOR.textMuted, "ACTION")
    imgui.NextColumn()
    imgui.Separator()
    for _, row in ipairs(keybindRows) do
        imgui.TextColored(COLOR.accentHover, row[1])
        imgui.NextColumn()
        imgui.Text(row[2])
        imgui.NextColumn()
    end
    imgui.Columns(1)
    imgui.EndChild()
end

local function pushTheme()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(11.0, 11.0))
    imgui.PushStyleColor(imgui.Col.WindowBg, COLOR.panel)
    imgui.PushStyleColor(imgui.Col.ChildBg, COLOR.panelSoft)
    imgui.PushStyleColor(imgui.Col.Border, COLOR.border)
    imgui.PushStyleColor(imgui.Col.TitleBg, COLOR.accentActive)
    imgui.PushStyleColor(imgui.Col.TitleBgActive, COLOR.accent)
    imgui.PushStyleColor(imgui.Col.Button, COLOR.accentActive)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, COLOR.accentHover)
    imgui.PushStyleColor(imgui.Col.ButtonActive, COLOR.accent)
    imgui.PushStyleColor(imgui.Col.Header, COLOR.accentActive)
    imgui.PushStyleColor(imgui.Col.HeaderHovered, COLOR.accentHover)
    imgui.PushStyleColor(imgui.Col.HeaderActive, COLOR.accent)
    imgui.PushStyleColor(imgui.Col.CheckMark, COLOR.accentHover)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.110, 0.095, 0.150, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.180, 0.130, 0.280, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0.220, 0.140, 0.360, 1.0))
end

local function popTheme()
    imgui.PopStyleColor(15)
    imgui.PopStyleVar(3)
end

imgui.OnFrame(function()
    return menuOpen[0]
end, function()
    local screenWidth, screenHeight = getScreenResolution()
    local directModule = entrySource == "direct" and currentPage ~= "home"
    local windowSize
    if directModule and currentPage == "easytruck" then
        windowSize = imgui.ImVec2(535.0, 520.0)
    elseif currentPage == "keybinder" then
        windowSize = imgui.ImVec2(900.0, 550.0)
    else
        windowSize = imgui.ImVec2(760.0, 500.0)
    end
    imgui.SetNextWindowSize(windowSize, imgui.Cond.Always)
    if layoutDirty then
        imgui.SetNextWindowPos(imgui.ImVec2(screenWidth * 0.5, screenHeight * 0.5), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        layoutDirty = false
    end

    pushTheme()
    local title = directModule
        and ((modules[currentPage] and modules[currentPage].title or "Module") .. " | HaruMenu Beta##HaruMenu")
        or "HaruMenu Integrated Beta v0.3##HaruMenu"
    imgui.Begin(title, menuOpen, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

    if directModule then
        imgui.BeginChild("direct_module_content", imgui.ImVec2(0.0, 0.0), false)
        if currentPage == "easytruck" then
            drawEasyTruckPage()
        elseif currentPage == "smartlock" then
            drawSmartLockPage()
        elseif currentPage == "keybinder" then
            drawKeybinderPage()
        elseif currentPage == "smartfix" then
            drawSmartFixPage()
        end
        imgui.EndChild()
    else
        imgui.BeginChild("navigation", imgui.ImVec2(150.0, 0.0), true)
        drawSidebar()
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild("content", imgui.ImVec2(0.0, 0.0), true)
        if currentPage == "home" then
            drawHomeContent()
        elseif currentPage == "easytruck" then
            drawEasyTruckPage()
        elseif currentPage == "smartlock" then
            drawSmartLockPage()
        elseif currentPage == "keybinder" then
            drawKeybinderPage()
        elseif currentPage == "smartfix" then
            drawSmartFixPage()
        else
            navigate("home")
        end
        imgui.EndChild()
    end

    imgui.End()
    popTheme()
end)

function onWindowMessage(msg, wparam, lparam)
    if not menuOpen[0] or wparam ~= 0x1B then return end

    if msg == wm.WM_KEYDOWN or msg == wm.WM_SYSKEYDOWN then
        consumeWindowMessage(true, false)
        return
    end

    if msg == wm.WM_KEYUP or msg == wm.WM_SYSKEYUP then
        consumeWindowMessage(true, false)
        if entrySource == "hmenu" and currentPage ~= "home" then
            navigate("home")
        else
            closeAllPanels()
        end
    end
end

function onScriptTerminate(terminatedScript, quitGame)
    if terminatedScript ~= thisScript() then return end
    local runtime = modules.easytruck
    local callback = runtime
        and runtime.environment
        and rawget(runtime.environment, "onScriptTerminate")
    if callback then callback(terminatedScript, quitGame) end
end

local function registerIntegratedCommands()
    sampRegisterChatCommand("hmenu", function()
        openPanel("home", "hmenu")
    end)

    sampRegisterChatCommand("easytruck", function()
        if menuOpen[0] and entrySource == "direct" and currentPage == "easytruck" then
            closeAllPanels()
        else
            openPanel("easytruck", "direct")
        end
    end)
    sampRegisterChatCommand("easygps", function()
        callExport(modules.easytruck, "toggleGps")
    end)
    sampRegisterChatCommand("aloadtruck", function()
        callExport(modules.easytruck, "queueLoad")
    end)
    sampRegisterChatCommand("setpos", function()
        if moduleEnabled(modules.easytruck) then
            callExport(modules.easytruck, "setDeliveryPoint")
        end
    end)

    sampRegisterChatCommand("smartlock", function()
        if moduleEnabled(modules.smartlock) then
            callExport(modules.smartlock, "action")
        else
            sampAddChatMessage("{6E00FD}[HaruMenu] {FFAA00}SmartLock is disabled.", -1)
        end
    end)
    sampRegisterChatCommand("sf", function()
        if moduleEnabled(modules.smartfix) then
            callExport(modules.smartfix, "action")
        else
            sampAddChatMessage("{6E00FD}[HaruMenu] {FFAA00}SmartFix is disabled.", -1)
        end
    end)

    sampRegisterChatCommand("cchat", function()
        callExport(modules.keybinder, "clearChat")
    end)
    sampRegisterChatCommand("abind", function()
        callExport(modules.keybinder, "toggle")
    end)
    sampRegisterChatCommand("exitveh", function()
        callExport(modules.keybinder, "exitVehicle")
    end)
    sampRegisterChatCommand("levcal", function(args)
        callExport(modules.keybinder, "levelCalculator", args)
    end)
    sampRegisterChatCommand("tstop1", function()
        callExport(modules.keybinder, "trafficStop")
    end)
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    initializeIntegratedModules()
    registerIntegratedCommands()

    sampAddChatMessage("{6E00FD}[HaruMenu] {FFFFFF}Command-preserving beta loaded. Use {6E00FD}/hmenu{FFFFFF}.", -1)

    while true do
        wait(0)
        local now = getGameTimer()

        for _, spec in ipairs(MODULE_SPECS) do
            local runtime = modules[spec.id]
            if runtime and runtime.loaded and moduleEnabled(runtime) then
                if runtime.exports.frame then
                    runtime.exports.frame()
                end
                if runtime.exports.tick and now >= runtime.nextTick then
                    runtime.nextTick = now + runtime.tickInterval
                    runtime.exports.tick()
                end
            end
        end

    end
end
