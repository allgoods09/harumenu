/*
 * EasyTruckGPS - native GTA San Andreas 1.0 US radar renderer.
 *
 * EasyTruck.lua owns route calculation and sends a packed list of world-space
 * XY points through the exported functions below. This module only installs a
 * native radar hook and renders those points while GTA's circular radar mask
 * is active.
 *
 * The source is deliberately freestanding: it links without a C runtime and
 * uses only GTA's existing functions and its imported VirtualProtect entry.
 */

typedef unsigned char  et_u8;
typedef unsigned int   et_u32;
typedef signed int     et_i32;
typedef unsigned long  et_ulong;
typedef unsigned int   et_uintptr;

#define ET_CDECL   __attribute__((cdecl))
#define ET_STDCALL __attribute__((stdcall))

#define DLL_PROCESS_DETACH 0

#define GTA_RADAR_CALL_ADDRESS       0x005869BFu
#define GTA_RW_ENGINE_ADDRESS        0x00C97B24u
#define GTA_VIRTUAL_PROTECT_IAT      0x0085802Cu
#define GTA_WORLD_TO_RADAR_ADDRESS   0x00583530u
#define GTA_RADAR_TO_SCREEN_ADDRESS  0x00583480u

/*
 * CPathFind::DoPathSearch uses these fixed-size work buffers even when the
 * caller supplies a larger result array.  The stock 5,000-entry workspace can
 * end a long route search before it reaches the player's road node.
 */
#define GTA_PATH_STREAM_PTR_1        0x0044DE3Cu
#define GTA_PATH_STREAM_PTR_2        0x00450D03u
#define GTA_PATH_CLEAR_PTR_1         0x00451782u
#define GTA_PATH_CLEAR_PTR_2         0x00451904u
#define GTA_PATH_CLEAR_PTR_3         0x00451AC3u
#define GTA_PATH_CLEAR_PTR_4         0x00451B33u
#define GTA_PATH_CLEAR_LIMIT         0x004518F8u
#define GTA_PATH_SEARCH_LIMIT        0x004519B0u

#define GTA_PATH_STREAM_BUFFER       0x0096EFD0u
#define GTA_PATH_CLEAR_BUFFER        0x00972CD0u
#define GTA_PATH_CLEAR_COUNT         5000u
#define GTA_PATH_SEARCH_COUNT        4950u

#define PAGE_EXECUTE_READWRITE       0x40u
#define RW_RENDER_STATE_TEXTURE      1
#define RW_PRIM_TYPE_TRI_LIST        3

#define ET_ROUTE_CAPACITY            5000
#define ET_VERTEX_CAPACITY           32766
#define ET_PATH_STREAM_CAPACITY      1024
#define ET_PATH_CLEAR_CAPACITY       50000
#define ET_PATH_SEARCH_CAPACITY      49950
#define ET_CIRCLE_CORNERS            16
#define ET_RADAR_RADIUS              0.97f
#define ET_LINE_WIDTH                6.0f
#define ET_ROUTE_COLOR               0xFF6E00FDu
#define ET_NEAR_SCREEN_Z             0.0001f
#define ET_RECIP_NEAR_CLIP           3.333333254f

typedef struct EtVector2 {
    float x;
    float y;
} EtVector2;

typedef struct EtRwIm2DVertex {
    float x;
    float y;
    float z;
    float rhw;
    et_u32 emissiveColor;
    float u;
    float v;
} EtRwIm2DVertex;

typedef int  (ET_STDCALL *EtVirtualProtect)(void*, et_ulong, et_ulong, et_ulong*);
typedef void (ET_CDECL *EtRadarGangOverlay)(int);
typedef void (ET_CDECL *EtTransformRadarPoint)(EtVector2*, const EtVector2*);
typedef int  (ET_CDECL *EtRwRenderStateSet)(int, void*);
typedef int  (ET_CDECL *EtRwIm2DRenderPrimitive)(int, EtRwIm2DVertex*, int);

static EtVector2 g_route[ET_ROUTE_CAPACITY];
static EtRwIm2DVertex g_vertices[ET_VERTEX_CAPACITY];
static et_u8 g_pathNodesToStream[ET_PATH_STREAM_CAPACITY];
static et_i32 g_pathNodesToClear[ET_PATH_CLEAR_CAPACITY];
static volatile int g_routeCount = 0;
static int g_installed = 0;
static int g_clients = 0;
static int g_extendedPathSearch = 0;
static et_i32 g_originalDisplacement = 0;
static et_i32 g_hookDisplacement = 0;
static EtRadarGangOverlay g_originalRadarGangOverlay = (EtRadarGangOverlay)0;

static const et_uintptr g_pathStreamPointerAddresses[2] = {
    GTA_PATH_STREAM_PTR_1,
    GTA_PATH_STREAM_PTR_2
};

static const et_uintptr g_pathClearPointerAddresses[4] = {
    GTA_PATH_CLEAR_PTR_1,
    GTA_PATH_CLEAR_PTR_2,
    GTA_PATH_CLEAR_PTR_3,
    GTA_PATH_CLEAR_PTR_4
};

static const float g_circleX[ET_CIRCLE_CORNERS + 1] = {
    1.000000000f,  0.923879533f,  0.707106781f,  0.382683432f,
    0.000000000f, -0.382683432f, -0.707106781f, -0.923879533f,
   -1.000000000f, -0.923879533f, -0.707106781f, -0.382683432f,
    0.000000000f,  0.382683432f,  0.707106781f,  0.923879533f,
    1.000000000f
};

static const float g_circleY[ET_CIRCLE_CORNERS + 1] = {
    0.000000000f,  0.382683432f,  0.707106781f,  0.923879533f,
    1.000000000f,  0.923879533f,  0.707106781f,  0.382683432f,
    0.000000000f, -0.382683432f, -0.707106781f, -0.923879533f,
   -1.000000000f, -0.923879533f, -0.707106781f, -0.382683432f,
    0.000000000f
};

static float etSqrt(float value) {
    __asm__ __volatile__("fsqrt" : "=t" (value) : "0" (value));
    return value;
}

static float etMax(float first, float second) {
    return first > second ? first : second;
}

static float etMin(float first, float second) {
    return first < second ? first : second;
}

static int etWriteRadarDisplacement(et_i32 displacement) {
    volatile et_i32* operand = (volatile et_i32*)(GTA_RADAR_CALL_ADDRESS + 1u);
    EtVirtualProtect virtualProtect = *(EtVirtualProtect*)GTA_VIRTUAL_PROTECT_IAT;
    et_ulong oldProtection = 0;
    et_ulong ignoredProtection = 0;

    if (!virtualProtect || !virtualProtect(
            (void*)operand,
            4u,
            PAGE_EXECUTE_READWRITE,
            &oldProtection)) {
        return 0;
    }

    *operand = displacement;
    virtualProtect((void*)operand, 4u, oldProtection, &ignoredProtection);
    return *operand == displacement;
}

static int etWriteU32(et_uintptr address, et_u32 value) {
    volatile et_u32* destination = (volatile et_u32*)address;
    EtVirtualProtect virtualProtect = *(EtVirtualProtect*)GTA_VIRTUAL_PROTECT_IAT;
    et_ulong oldProtection = 0;
    et_ulong ignoredProtection = 0;

    if (!virtualProtect || !virtualProtect(
            (void*)destination,
            4u,
            PAGE_EXECUTE_READWRITE,
            &oldProtection)) {
        return 0;
    }

    *destination = value;
    virtualProtect((void*)destination, 4u, oldProtection, &ignoredProtection);
    return *destination == value;
}

static int etHasStockPathSearchWorkspace(void) {
    int index;

    for (index = 0; index < 2; ++index) {
        if (*(volatile et_u32*)g_pathStreamPointerAddresses[index]
                != GTA_PATH_STREAM_BUFFER) {
            return 0;
        }
    }
    for (index = 0; index < 4; ++index) {
        if (*(volatile et_u32*)g_pathClearPointerAddresses[index]
                != GTA_PATH_CLEAR_BUFFER) {
            return 0;
        }
    }

    return *(volatile et_u32*)GTA_PATH_CLEAR_LIMIT == GTA_PATH_CLEAR_COUNT
        && *(volatile et_u32*)GTA_PATH_SEARCH_LIMIT == GTA_PATH_SEARCH_COUNT;
}

static void etRestorePathSearchWorkspace(void);

static void etExtendPathSearchWorkspace(void) {
    int index;

    if (!etHasStockPathSearchWorkspace()) {
        return;
    }

    for (index = 0; index < ET_PATH_STREAM_CAPACITY; ++index) {
        g_pathNodesToStream[index] = 1u;
    }
    for (index = 0; index < ET_PATH_CLEAR_CAPACITY; ++index) {
        g_pathNodesToClear[index] = -1;
    }

    for (index = 0; index < 2; ++index) {
        if (!etWriteU32(
                g_pathStreamPointerAddresses[index],
                (et_u32)(et_uintptr)g_pathNodesToStream)) {
            etRestorePathSearchWorkspace();
            return;
        }
    }
    for (index = 0; index < 4; ++index) {
        if (!etWriteU32(
                g_pathClearPointerAddresses[index],
                (et_u32)(et_uintptr)g_pathNodesToClear)) {
            etRestorePathSearchWorkspace();
            return;
        }
    }
    if (!etWriteU32(GTA_PATH_CLEAR_LIMIT, ET_PATH_CLEAR_CAPACITY)
            || !etWriteU32(GTA_PATH_SEARCH_LIMIT, ET_PATH_SEARCH_CAPACITY)) {
        etRestorePathSearchWorkspace();
        return;
    }

    g_extendedPathSearch = 1;
}

static void etRestorePathSearchWorkspace(void) {
    et_u32 streamPointer = (et_u32)(et_uintptr)g_pathNodesToStream;
    et_u32 clearPointer = (et_u32)(et_uintptr)g_pathNodesToClear;
    int index;

    for (index = 0; index < 2; ++index) {
        if (*(volatile et_u32*)g_pathStreamPointerAddresses[index]
                == streamPointer) {
            etWriteU32(
                g_pathStreamPointerAddresses[index],
                GTA_PATH_STREAM_BUFFER
            );
        }
    }
    for (index = 0; index < 4; ++index) {
        if (*(volatile et_u32*)g_pathClearPointerAddresses[index]
                == clearPointer) {
            etWriteU32(
                g_pathClearPointerAddresses[index],
                GTA_PATH_CLEAR_BUFFER
            );
        }
    }
    if (*(volatile et_u32*)GTA_PATH_CLEAR_LIMIT == ET_PATH_CLEAR_CAPACITY) {
        etWriteU32(GTA_PATH_CLEAR_LIMIT, GTA_PATH_CLEAR_COUNT);
    }
    if (*(volatile et_u32*)GTA_PATH_SEARCH_LIMIT == ET_PATH_SEARCH_CAPACITY) {
        etWriteU32(GTA_PATH_SEARCH_LIMIT, GTA_PATH_SEARCH_COUNT);
    }
    g_extendedPathSearch = 0;
}

static void etSetVertex(int index, float x, float y) {
    EtRwIm2DVertex* vertex = &g_vertices[index];
    vertex->x = x;
    vertex->y = y;
    vertex->z = ET_NEAR_SCREEN_Z;
    vertex->rhw = ET_RECIP_NEAR_CLIP;
    vertex->emissiveColor = ET_ROUTE_COLOR;
    vertex->u = 0.0f;
    vertex->v = 0.0f;
}

static int etAddTriangle(
    int* vertexCount,
    float x1, float y1,
    float x2, float y2,
    float x3, float y3
) {
    int count = *vertexCount;
    if (count + 3 > ET_VERTEX_CAPACITY) {
        return 0;
    }

    etSetVertex(count, x1, y1);
    etSetVertex(count + 1, x2, y2);
    etSetVertex(count + 2, x3, y3);
    *vertexCount = count + 3;
    return 1;
}

static int etAddLine(
    int* vertexCount,
    float x1, float y1,
    float x2, float y2
) {
    float dx = x2 - x1;
    float dy = y2 - y1;
    float lengthSquared = dx * dx + dy * dy;
    float length;
    float halfWidth;
    float normalX;
    float normalY;
    float ax, ay, bx, by, cx, cy, dx2, dy2;

    if (lengthSquared < 0.0001f) {
        return 1;
    }

    length = etSqrt(lengthSquared);
    halfWidth = ET_LINE_WIDTH * 0.5f;
    normalX = -dy / length * halfWidth;
    normalY =  dx / length * halfWidth;
    ax = x1 + normalX;
    ay = y1 + normalY;
    bx = x1 - normalX;
    by = y1 - normalY;
    cx = x2 + normalX;
    cy = y2 + normalY;
    dx2 = x2 - normalX;
    dy2 = y2 - normalY;

    if (!etAddTriangle(vertexCount, ax, ay, bx, by, cx, cy)) {
        return 0;
    }
    return etAddTriangle(vertexCount, cx, cy, bx, by, dx2, dy2);
}

static int etAddCircle(int* vertexCount, float centerX, float centerY) {
    float radius = ET_LINE_WIDTH * 0.5f;
    int corner;

    for (corner = 0; corner < ET_CIRCLE_CORNERS; ++corner) {
        if (!etAddTriangle(
                vertexCount,
                centerX,
                centerY,
                centerX + g_circleX[corner] * radius,
                centerY + g_circleY[corner] * radius,
                centerX + g_circleX[corner + 1] * radius,
                centerY + g_circleY[corner + 1] * radius)) {
            return 0;
        }
    }
    return 1;
}

static int etClipLineToRadar(
    float x1, float y1,
    float x2, float y2,
    float* outX1, float* outY1,
    float* outX2, float* outY2
) {
    float dx = x2 - x1;
    float dy = y2 - y1;
    float a = dx * dx + dy * dy;
    float radiusSquared = ET_RADAR_RADIUS * ET_RADAR_RADIUS;
    float b;
    float c;
    float discriminant;
    float root;
    float enter;
    float leave;
    float start;
    float end;

    if (a < 0.0000001f) {
        if (x1 * x1 + y1 * y1 > radiusSquared) {
            return 0;
        }
        *outX1 = x1;
        *outY1 = y1;
        *outX2 = x2;
        *outY2 = y2;
        return 1;
    }

    b = 2.0f * (x1 * dx + y1 * dy);
    c = x1 * x1 + y1 * y1 - radiusSquared;
    discriminant = b * b - 4.0f * a * c;
    if (discriminant < 0.0f) {
        return 0;
    }

    root = etSqrt(discriminant);
    enter = (-b - root) / (2.0f * a);
    leave = (-b + root) / (2.0f * a);
    start = etMax(0.0f, enter);
    end = etMin(1.0f, leave);
    if (start > end) {
        return 0;
    }

    *outX1 = x1 + dx * start;
    *outY1 = y1 + dy * start;
    *outX2 = x1 + dx * end;
    *outY2 = y1 + dy * end;
    return 1;
}

static void etDrawRoute(void) {
    EtTransformRadarPoint worldToRadar;
    EtTransformRadarPoint radarToScreen;
    unsigned char* rwEngine;
    EtRwRenderStateSet renderStateSet;
    EtRwIm2DRenderPrimitive renderPrimitive;
    EtVector2 previousRadar;
    EtVector2 currentRadar;
    EtVector2 clippedStart;
    EtVector2 clippedEnd;
    EtVector2 screenStart;
    EtVector2 screenEnd;
    int routeCount = g_routeCount;
    int vertexCount = 0;
    int previousWasVisible = 0;
    int index;

    if (routeCount <= 0 || routeCount > ET_ROUTE_CAPACITY) {
        return;
    }

    worldToRadar = (EtTransformRadarPoint)GTA_WORLD_TO_RADAR_ADDRESS;
    radarToScreen = (EtTransformRadarPoint)GTA_RADAR_TO_SCREEN_ADDRESS;
    rwEngine = *(unsigned char**)GTA_RW_ENGINE_ADDRESS;
    if (!rwEngine) {
        return;
    }
    renderStateSet = *(EtRwRenderStateSet*)(rwEngine + 0x20);
    renderPrimitive = *(EtRwIm2DRenderPrimitive*)(rwEngine + 0x30);
    if (!renderStateSet || !renderPrimitive) {
        return;
    }

    previousRadar.x = 0.0f;
    previousRadar.y = 0.0f;

    for (index = 0; index < routeCount; ++index) {
        worldToRadar(&currentRadar, &g_route[index]);

        if (etClipLineToRadar(
                previousRadar.x,
                previousRadar.y,
                currentRadar.x,
                currentRadar.y,
                &clippedStart.x,
                &clippedStart.y,
                &clippedEnd.x,
                &clippedEnd.y)) {
            radarToScreen(&screenStart, &clippedStart);
            radarToScreen(&screenEnd, &clippedEnd);

            if (!etAddLine(
                    &vertexCount,
                    screenStart.x,
                    screenStart.y,
                    screenEnd.x,
                    screenEnd.y)) {
                break;
            }

            if (!previousWasVisible && !etAddCircle(
                    &vertexCount,
                    screenStart.x,
                    screenStart.y)) {
                break;
            }

            if (!etAddCircle(
                    &vertexCount,
                    screenEnd.x,
                    screenEnd.y)) {
                break;
            }
            previousWasVisible = 1;
        } else {
            previousWasVisible = 0;
        }

        previousRadar = currentRadar;
    }

    if (vertexCount >= 3) {
        renderStateSet(RW_RENDER_STATE_TEXTURE, (void*)0);
        renderPrimitive(RW_PRIM_TYPE_TRI_LIST, g_vertices, vertexCount);
    }
}

static void ET_CDECL etRadarHook(int showZones) {
    if (g_originalRadarGangOverlay) {
        g_originalRadarGangOverlay(showZones);
    }
    etDrawRoute();
}

int ET_CDECL ETGPS_Initialize(void) {
    volatile et_u8* opcode = (volatile et_u8*)GTA_RADAR_CALL_ADDRESS;
    volatile et_i32* operand = (volatile et_i32*)(GTA_RADAR_CALL_ADDRESS + 1u);
    et_uintptr originalTarget;

    if (g_installed) {
        ++g_clients;
        return 1;
    }
    if (*opcode != 0xE8u) {
        return 0;
    }

    g_originalDisplacement = *operand;
    originalTarget = GTA_RADAR_CALL_ADDRESS + 5u
        + (et_uintptr)g_originalDisplacement;
    g_originalRadarGangOverlay = (EtRadarGangOverlay)originalTarget;
    g_hookDisplacement = (et_i32)(
        (et_uintptr)&etRadarHook - (GTA_RADAR_CALL_ADDRESS + 5u)
    );

    if (!etWriteRadarDisplacement(g_hookDisplacement)) {
        g_originalRadarGangOverlay = (EtRadarGangOverlay)0;
        return 0;
    }

    etExtendPathSearchWorkspace();
    g_routeCount = 0;
    g_clients = 1;
    g_installed = 1;
    return 1;
}

void ET_CDECL ETGPS_ClearRoute(void) {
    g_routeCount = 0;
}

void ET_CDECL ETGPS_SetRoute(const float* packedXY, int count) {
    int index;

    g_routeCount = 0;
    if (!packedXY || count <= 0) {
        return;
    }
    if (count > ET_ROUTE_CAPACITY) {
        count = ET_ROUTE_CAPACITY;
    }

    for (index = 0; index < count; ++index) {
        g_route[index].x = packedXY[index * 2];
        g_route[index].y = packedXY[index * 2 + 1];
    }
    g_routeCount = count;
}

int ET_CDECL ETGPS_IsInstalled(void) {
    return g_installed;
}

void ET_CDECL ETGPS_Shutdown(void) {
    volatile et_i32* operand = (volatile et_i32*)(GTA_RADAR_CALL_ADDRESS + 1u);

    if (!g_installed) {
        return;
    }
    if (g_clients > 1) {
        --g_clients;
        return;
    }

    g_routeCount = 0;
    if (g_extendedPathSearch) {
        etRestorePathSearchWorkspace();
    }
    if (*operand == g_hookDisplacement) {
        etWriteRadarDisplacement(g_originalDisplacement);
    }
    g_originalRadarGangOverlay = (EtRadarGangOverlay)0;
    g_clients = 0;
    g_installed = 0;
}

int ET_STDCALL DllMain(void* module, et_ulong reason, void* reserved) {
    (void)module;
    (void)reserved;
    if (reason == DLL_PROCESS_DETACH) {
        g_clients = 1;
        ETGPS_Shutdown();
    }
    return 1;
}
