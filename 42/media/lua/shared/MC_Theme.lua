local MC_Theme = {}

-- AUDIT:SURFACES:BEGIN
MC_Theme.Surfaces = {
    slate     = {38, 40, 35},
    slateDeep = {26, 28, 23},
    rim       = {249, 249, 249},
    rule      = {161, 161, 161},
    umber     = {49, 47, 42},
    cream     = {243, 231, 197},
}
-- AUDIT:SURFACES:END

-- Plain values model the familiar base-game chat frame without taking back
-- ISChat ownership. They are used only by the opt-in Classic PZ paint skin.
MC_Theme.VanillaSurfaces = {
    slate     = {24, 24, 24},
    slateDeep = {12, 12, 12},
    rim       = {128, 128, 128},
    rule      = {105, 105, 105},
    umber     = {34, 34, 34},
    cream     = {235, 235, 235},
}

-- Mongoose Lichen (#B8C96A) is the one product colour. It marks our own interface
-- authorship; it is not a player identity colour or a channel colour.
MC_Theme.Brand = {
    mongoose = {184, 201, 106},
}

-- One entry per channel. The trailing `family:` tag is read by the audit:
-- channels in different families must stay apart in every simulated colour
-- space; channels in the same family must differ by a visible lightness
-- step (or be exact aliases of one another).
-- AUDIT:CHANNELS:BEGIN
MC_Theme.Channels = {
    say       = {242, 242, 242}, -- family:chalk   ordinary speech
    whisper   = {196, 196, 196}, -- family:chalk   quiet
    low       = {150, 150, 150}, -- family:chalk   quieter still; tag [low] differs too

    yell      = {255, 209, 102}, -- family:amber   loud; tag is already [YELL]
    system    = {255, 209, 102}, -- family:amber   alias: server lines carry the [SERVER] name
    emote     = {217, 160, 102}, -- family:amber   warm action, *framed*
    safehouse = {217, 160, 102}, -- family:amber   alias: home; tag [safehouse] differs

    ["do"]    = {243, 231, 197}, -- family:cream   hand-written narration
    doTag     = {196, 196, 196}, -- family:chalk   alias of whisper: the leading (Name) on /do, a quiet label distinct from both the cream body and chalk speech
    event     = {243, 231, 197}, -- family:cream   alias: admin event narration

    thought   = {154, 210, 255}, -- family:sky     alias: quoted thought reads as out-of-world
    mood      = {170, 140, 250}, -- family:lilac   inner voice, **framed**

    ooc       = {154, 210, 255}, -- family:sky     out of world
    all       = {79, 159, 224},  -- family:sky     global OOC

    admin     = {240, 117, 121}, -- family:rose    authority; [ADMIN]

    radio     = {94, 224, 224},  -- family:teal    electronic
    faction   = {63, 176, 184},  -- family:teal    group; tag [faction] differs
}
-- AUDIT:CHANNELS:END

-- AUDIT:HIGH_CONTRAST:BEGIN
-- Legacy checked palette data retained for the offline colour-vision report.
-- Live paint now resolves the base channel by the smallest passing lift.
MC_Theme.HighContrast = {
    low       = {190, 190, 190},
    emote     = {245, 200, 150},
    safehouse = {245, 200, 150},
    mood      = {215, 185, 240},
    all       = {150, 200, 245},
    admin     = {255, 175, 178},
    faction   = {120, 215, 220},
}
-- AUDIT:HIGH_CONTRAST:END

MC_Theme.Markup = {
    emote = MC_Theme.Channels.emote,
    mood  = MC_Theme.Channels.mood,
}

MC_Theme.Metrics = {
    corner     = 15,   -- analytic 15px rounded corner; never scale it smaller
    rimPx      = 6,    -- native body rim: three disjoint 2px bands
    tabH       = 26,   -- >= 24 motor target, plus 2 for the rim
    tabPadX    = 12,
    tabGap     = 2,
    edge       = 6,
    entryH     = 30,   -- full 15px corners must never meet or overlap
    lineGap    = 2,
    messageGap = 3,
    fadeMs     = 500,
}

-- Only Soft's lichen controls take the slightly leaner face. Sharp and
-- Classic keep their established square/native width even though all three
-- skins share the layout code.
function MC_Theme.tabPadX(skin)
    return (skin or MC_Theme.skin()) == "soft" and 8 or MC_Theme.Metrics.tabPadX
end

-- The theme is shared code and must not require the client-only window.
-- MC_ChatWindow registers a provider on load; until then, or on a server,
-- the defaults apply. Comfort settings can never break rendering: an
-- unreadable provider is the same as no provider.

local DEFAULT_ACCESS = {
    highContrast  = false,
    tagsOnly      = false,
    reducedMotion = false,
    playerHueOnly = false,
    sharpTheme    = false,
    interfaceSkin = "vanilla",
    opacity       = 0.80,
    lineSpacing   = 2,
    messageGap    = 3,
    windowTheme  = false,
}

local HC_GROUND = {0, 0, 0}
local HC_STATE_GROUND = {18, 18, 18}
local HC_MIN_CONTRAST = 7

local function finiteByte(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value >= 0 and value <= 255
end

local function safeRGB(value, fallback)
    local source = type(value) == "table" and value or fallback
    if type(source) ~= "table" then return {255, 255, 255} end
    local out = {}
    for index = 1, 3 do
        local component = source[index]
        if not finiteByte(component) then
            if source ~= fallback then return safeRGB(fallback, {255, 255, 255}) end
            return {255, 255, 255}
        end
        out[index] = component
    end
    return out
end

local function linearChannel(component)
    local value = component / 255
    if value <= 0.04045 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

local function luminance(rgb)
    return 0.2126 * linearChannel(rgb[1])
        + 0.7152 * linearChannel(rgb[2])
        + 0.0722 * linearChannel(rgb[3])
end

function MC_Theme.contrastRatio(foreground, background)
    local fg = safeRGB(foreground, MC_Theme.Channels.say)
    local bg = safeRGB(background, HC_STATE_GROUND)
    local light, dark = luminance(fg), luminance(bg)
    if dark > light then light, dark = dark, light end
    return (light + 0.05) / (dark + 0.05)
end

-- Keep a passing shade byte-for-byte. A failing shade moves only along its
-- straight line to white; binary search finds the first rounded RGB that
-- clears the requested ratio after integer rounding.
function MC_Theme.ensureContrast(rgb, background, minRatio)
    local raw = safeRGB(rgb, MC_Theme.Channels.say)
    local source = {}
    for index = 1, 3 do source[index] = math.floor(raw[index] + 0.5) end
    local bg = safeRGB(background, HC_STATE_GROUND)
    local target = type(minRatio) == "number" and minRatio or HC_MIN_CONTRAST
    if target < 1 then target = 1 end
    if MC_Theme.contrastRatio(source, bg) >= target then return source end

    local white = {255, 255, 255}
    if MC_Theme.contrastRatio(white, bg) < target then return white end
    local low, high = 0, 1
    local best = white
    for _ = 1, 24 do
        local weight = (low + high) / 2
        local candidate = {}
        for index = 1, 3 do
            candidate[index] = math.floor(source[index]
                + (255 - source[index]) * weight + 0.5)
        end
        if MC_Theme.contrastRatio(candidate, bg) >= target then
            best, high = candidate, weight
        else
            low = weight
        end
    end
    return best
end

function MC_Theme.highContrastBackground(state)
    return safeRGB(state and HC_STATE_GROUND or HC_GROUND, HC_GROUND)
end

function MC_Theme.readableColor(rgb, background)
    local color = safeRGB(rgb, MC_Theme.Channels.say)
    if not MC_Theme.access().highContrast then return color end
    return MC_Theme.ensureContrast(color, background or HC_STATE_GROUND,
        HC_MIN_CONTRAST)
end

local function opaqueWhenVisible(alpha)
    if type(alpha) ~= "number" or alpha <= 0 then return 0 end
    return 1
end

function MC_Theme.readableAlpha(alpha)
    if not MC_Theme.access().highContrast then return alpha end
    return opaqueWhenVisible(alpha)
end

function MC_Theme.backgroundAlpha(alpha)
    if not MC_Theme.access().highContrast then return alpha end
    return opaqueWhenVisible(alpha)
end

-- Filled below, beside the texture loader. Keeping this as a narrow function
-- lets shared/server loads stay harmless while client paint can ask for one
-- all-or-nothing custom set.
local activeWindowTheme = function() return nil end

-- PZ may replace a shared module table while client modules remain alive.
-- Keep only the two provider FUNCTIONS in a private process registry so the
-- new Theme table adopts the same access and identity seams at load. No hue,
-- account, session, preference value, or other payload is stored here.
local PROVIDER_REGISTRY_KEY = "__MONGOOSECHAT_THEME_PROVIDERS_V1"
local function cleanProviderRegistry(create)
    local registry = rawget(_G, PROVIDER_REGISTRY_KEY)
    if type(registry) ~= "table" then
        if not create then return nil end
        registry = {}
        rawset(_G, PROVIDER_REGISTRY_KEY, registry)
    end
    local access = type(registry.access) == "function" and registry.access or nil
    local identity = type(registry.identity) == "function" and registry.identity or nil
    -- A foreign or stale write cannot turn the registry into payload storage.
    for key in pairs(registry) do registry[key] = nil end
    if access then registry.access = access end
    if identity then registry.identity = identity end
    return registry
end

cleanProviderRegistry(true)

local function liveProvider(name)
    local registry = cleanProviderRegistry(false)
    local provider = registry and registry[name] or nil
    return type(provider) == "function" and provider or nil
end

-- The client identity cache registers this narrow provider. Shared theme code
-- never reaches into client state, and renderers never receive identity data.
function MC_Theme.setIdentityColorProvider(fn)
    cleanProviderRegistry(true).identity = type(fn) == "function" and fn or nil
end

function MC_Theme.setAccessProvider(fn)
    cleanProviderRegistry(true).access = type(fn) == "function" and fn or nil
end

function MC_Theme.access()
    local accessProvider = liveProvider("access")
    if accessProvider then
        local ok, a = pcall(accessProvider)
        if ok and type(a) == "table" then return a end
    end
    return DEFAULT_ACCESS
end

function MC_Theme.skin()
    local a = MC_Theme.access()
    if a.interfaceSkin == "vanilla" then return "vanilla" end
    if a.interfaceSkin == "sharp" or a.sharpTheme == true then return "sharp" end
    return "soft"
end

function MC_Theme.isSquareSkin(interfaceChrome)
    if interfaceChrome == true and activeWindowTheme() then return false end
    return MC_Theme.skin() == "sharp"
        or (interfaceChrome == true and MC_Theme.skin() == "vanilla")
end

function MC_Theme.windowUsesClassic()
    return activeWindowTheme() == nil and MC_Theme.skin() == "vanilla"
end

--[[
    Content colour as {r, g, b} 0-255, honouring the player's access mode.
    Tags-only makes names, message text, chunks, and bubbles chalk.  Visible
    transcript tags use tagChannel() below and keep carrying channel meaning.
    High contrast lifts only colours which do not yet meet the shared target.
    Unknown channels get chalk, never nil -- a missing colour must not be a
    render failure.
]]
function MC_Theme.channel(name)
    local a = MC_Theme.access()
    if a.tagsOnly then return MC_Theme.Channels.say end
    return MC_Theme.readableColor(MC_Theme.Channels[name]
        or MC_Theme.Channels.say)
end

-- Colour for a visible transcript channel/speech tag.  Tags-only changes
-- content, not this semantic cue.  Keep the same high-contrast substitution
-- and safe unknown-channel fallback as channel().
function MC_Theme.tagChannel(name)
    local a = MC_Theme.access()
    return MC_Theme.readableColor(MC_Theme.Channels[name]
        or MC_Theme.Channels.say)
end

function MC_Theme.brand(name)
    if MC_Theme.access().tagsOnly then return MC_Theme.Channels.say end
    return MC_Theme.Brand[name] or MC_Theme.Brand.mongoose
end

local borderClock = { generation=nil, revision=nil, anchorMs=nil }
local contentBloomClock = {
    generation=nil, revision=nil, startedMs=nil, lastMs=nil,
}
-- A hue change gets one soft, readable full-rim breath. The periodic breath is
-- slower and quieter, but still reaches every band rather than hiding in the
-- two-pixel lip.
local CONTENT_BLOOM_MS = 900
local CONTENT_BLOOM_LICHEN_WEIGHT = 0.72

local function copyRGB(v)
    if type(v) ~= "table" then return nil end
    local out = {}
    for i = 1, 3 do
        local n = v[i]
        if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 255 then
            return nil
        end
        out[i] = n
    end
    return out
end

local function trustedBorderSource()
    local identityColorProvider = liveProvider("identity")
    if not identityColorProvider then return nil end
    local ok, value = pcall(identityColorProvider)
    if not ok or type(value) ~= "table" then return nil end
    local color = copyRGB(value.color)
    local generation, revision = value.generation, value.revision
    if not color or type(generation) ~= "number" or generation ~= math.floor(generation)
        or generation < 0 or type(revision) ~= "number"
        or revision ~= math.floor(revision) or revision < 0 then return nil end
    return { color=color, generation=generation, revision=revision }
end

local function resolvedWindowControl(source)
    local state = activeWindowTheme()
    local a = MC_Theme.access()
    if a.tagsOnly then return copyRGB(MC_Theme.Channels.say) end
    local color
    if a.playerHueOnly == true then
        color = source and source.color or MC_Theme.Brand.mongoose
    elseif state then
        color = state.defaultRGB
    elseif state == nil and MC_Theme.skin() == "vanilla" then
        color = MC_Theme.VanillaSurfaces.text or {205, 205, 200}
    else
        color = MC_Theme.Brand.mongoose
    end
    return MC_Theme.readableColor(color)
end

local function mixedRGB(base, target, weight)
    local out = {}
    for i = 1, 3 do out[i] = math.floor(base[i] + (target[i] - base[i]) * weight + 0.5) end
    return out
end

local function shadedRGB(base, factor)
    local out = {}
    for i = 1, 3 do
        out[i] = math.max(0, math.min(255, math.floor(base[i] * factor + 0.5)))
    end
    return out
end

local function brightenedRGB(base, weight)
    return mixedRGB(base, {255, 255, 255}, weight)
end

local function automaticContentBloom(source, nowMs, access)
    if not source or type(nowMs) ~= "number" then
        contentBloomClock = {
            generation=nil, revision=nil, startedMs=nil, lastMs=nil,
        }
        return 0
    end

    local first = contentBloomClock.generation == nil
    local newGeneration = contentBloomClock.generation ~= source.generation
    local clockRolledBack = contentBloomClock.lastMs ~= nil
        and nowMs < contentBloomClock.lastMs
    if first or newGeneration or clockRolledBack then
        contentBloomClock.generation = source.generation
        contentBloomClock.revision = source.revision
        contentBloomClock.startedMs = nil
        contentBloomClock.lastMs = nowMs
        return 0
    end

    if access.tagsOnly or access.reducedMotion then
        contentBloomClock.revision = source.revision
        contentBloomClock.startedMs = nil
        contentBloomClock.lastMs = nowMs
        return 0
    end

    if contentBloomClock.revision ~= source.revision then
        contentBloomClock.revision = source.revision
        contentBloomClock.startedMs = nowMs
    end
    contentBloomClock.lastMs = nowMs
    if not contentBloomClock.startedMs then return 0 end
    local elapsed = nowMs - contentBloomClock.startedMs
    if elapsed < 0 or elapsed >= CONTENT_BLOOM_MS then
        contentBloomClock.startedMs = nil
        return 0
    end
    -- Ease from the new hue into Lichen and back out. Starting at zero keeps
    -- the hue command's first frame truthful; the middle frame is the peak.
    return math.max(0, math.sin((elapsed / CONTENT_BLOOM_MS) * math.pi))
end

-- Stable internal compositor for every MongooseChat rim. The caller supplies
-- its render clock in milliseconds, which keeps all elements in phase. A new
-- trusted session starts at quiet zero and therefore cannot enter a pulse that
-- was already underway. Hue revisions change the base without moving the clock.
function MC_Theme.themedBorder(nowMs, observedSource, sourceObserved)
    local chalk = copyRGB(MC_Theme.Channels.say)
    local access = MC_Theme.access()
    if access.tagsOnly then
        local neutral = MC_Theme.skin() == "vanilla"
            and copyRGB(MC_Theme.VanillaSurfaces.slate)
            or copyRGB(MC_Theme.Surfaces.slate)
        local weight = 0
        if not access.reducedMotion and type(nowMs) == "number" then
            local phase = nowMs % 30000
            if phase >= 28500 then
                weight = 0.42 * math.sin(((phase - 28500) / 1500) * math.pi)
            end
        end
        local themed = mixedRGB(neutral, MC_Theme.Brand.mongoose, weight)
        if access.highContrast then
            return { outer=chalk, inner=themed, color=copyRGB(themed), weight=weight,
                animated=weight > 0, trusted=false }
        end
        return { outer=themed, inner=nil, color=copyRGB(themed), weight=weight,
            animated=weight > 0, trusted=false }
    end

    local source = sourceObserved == true and observedSource or trustedBorderSource()
    if not source or type(nowMs) ~= "number" then
        borderClock = { generation=nil, revision=nil, anchorMs=nil }
        return { outer=chalk, inner=nil, color=copyRGB(chalk), weight=0,
            animated=false, trusted=false }
    end

    if borderClock.generation ~= source.generation or borderClock.anchorMs == nil
        or nowMs < borderClock.anchorMs then
        borderClock.generation = source.generation
        borderClock.anchorMs = nowMs
    end
    borderClock.revision = source.revision

    local weight = 0
    if not access.reducedMotion then
        local phase = (nowMs - borderClock.anchorMs) % 10000
        if phase >= 8600 then
            local t = (phase - 8600) / 1400
            weight = 0.42 * math.sin(t * math.pi)
        end
    end
    if weight < 0 then weight = 0 elseif weight > 0.42 then weight = 0.42 end
    local themed = mixedRGB(source.color, MC_Theme.Brand.mongoose, weight)
    if access.highContrast then
        return { outer=chalk, inner=themed, color=copyRGB(themed), weight=weight,
            animated=weight > 0, trusted=true }
    end
    return { outer=themed, inner=nil, color=copyRGB(themed), weight=weight,
        animated=weight > 0, trusted=true }
end

-- Three tints for the exact curved-edge masks. `content` follows the local
-- viewer's trusted hue. Opted-in Match controls use that same trusted hue. The
-- periodic shimmer and hue-change bloom breathe through all three bands. Each
-- band moves toward its matching Lichen control tint, so the rim keeps its
-- dark/middle/bright depth instead of becoming one flat stripe. Reduced-motion
-- is a clean static result.
local function strictRGB(value)
    if type(value) ~= "table" then return nil end
    local copy = {}
    for index = 1, 3 do
        local component = value[index]
        if type(component) ~= "number" or component ~= component
            or component == math.huge or component == -math.huge
            or component < 0 or component > 255 then
            return nil
        end
        copy[index] = component
    end
    return copy
end

function MC_Theme.edgePalette(kind, nowMs, bloomWeight, baseOverride, interfaceChrome)
    local access = MC_Theme.access()
    local chalk = copyRGB(MC_Theme.Channels.say)
    -- Classic keeps its old neutral palette on every surface. Its one narrow
    -- exception is opted-in player hue on MC-owned interface controls.
    local classicPlayerControl = kind == "control" and interfaceChrome == true
        and access.playerHueOnly == true and not access.tagsOnly
    if MC_Theme.skin() == "vanilla" and not classicPlayerControl then
        local neutral = copyRGB(MC_Theme.VanillaSurfaces.rim)
        if access.tagsOnly then
            neutral = copyRGB(MC_Theme.VanillaSurfaces.slate)
        end
        local lichen = copyRGB(MC_Theme.Brand.mongoose)
        local weight = 0
        if not access.reducedMotion and type(nowMs) == "number" then
            -- One short reminder in each long interval; quiet the rest of the time.
            local phase = nowMs % 30000
            if phase >= 28500 then
                weight = 0.55 * math.sin(((phase - 28500) / 1500) * math.pi)
            end
        end
        local middle = mixedRGB(neutral, lichen, weight)
        local outer = access.highContrast
            and copyRGB(MC_Theme.VanillaSurfaces.cream) or copyRGB(neutral)
        if access.highContrast then
            outer = MC_Theme.ensureContrast(outer, HC_STATE_GROUND)
            middle = MC_Theme.ensureContrast(middle, HC_STATE_GROUND)
        end
        return {
            outer=outer, middle=middle, lip=copyRGB(middle),
            shimmerWeight=weight, animated=weight > 0,
            bloomWeight=0, trusted=false,
        }
    end
    local lichen = copyRGB(MC_Theme.Brand.mongoose)
    local base, trusted = chalk, false
    local source = trustedBorderSource()
    -- World bubbles may carry the authenticated speaker's already-scrubbed
    -- visible hue. Copy it here: render code must never retain or alter the
    -- message table. Product controls never use the speaker override seam.
    local override = kind ~= "control" and strictRGB(baseOverride) or nil

    if access.tagsOnly then
        base = copyRGB(MC_Theme.Surfaces.slate)
    elseif kind == "control" then
        if interfaceChrome == true then
            base = resolvedWindowControl(source)
        else
            base = access.playerHueOnly == true and source
                and copyRGB(source.color) or lichen
        end
        trusted = source ~= nil
    elseif override then
        base, trusted = override, true
    else
        if source then base, trusted = source.color, true end
    end

    -- Every edge call observes the revision clock. A control drawn first in a
    -- frame can therefore start the bloom, while only content consumes it.
    local automaticBloom = override and 0
        or automaticContentBloom(source, nowMs, access)

    -- themedBorder owns the one shared generation-aware phase.
    local phase = MC_Theme.themedBorder(nowMs, source, true)
    local shimmer = not access.reducedMotion and phase.weight or 0
    local lipBase = kind == "control"
        and brightenedRGB(base, 0.18) or brightenedRGB(base, 0.12)
    local outer = shadedRGB(base, 0.62)
    if access.highContrast then outer = chalk end

    -- A hue revision may bloom once through the SAME middle and lip masks.
    -- It never adds geometry, never touches product controls, and access modes
    -- which suppress motion also suppress this weight.
    local bloom = type(bloomWeight) == "number" and bloomWeight or 0
    if bloom < 0 then bloom = 0 elseif bloom > 1 then bloom = 1 end
    if kind ~= "control" and automaticBloom > bloom then bloom = automaticBloom end
    if kind == "control" or access.reducedMotion or access.tagsOnly then bloom = 0 end
    local middle = copyRGB(base)
    local lip = copyRGB(lipBase)
    if kind == "control" and not access.highContrast
        and access.playerHueOnly == true and source then
        local lichenOuter = shadedRGB(lichen, 0.62)
        local lichenMiddle = copyRGB(lichen)
        local lichenLip = brightenedRGB(lichen, 0.18)
        outer = mixedRGB(outer, lichenOuter, shimmer)
        middle = mixedRGB(middle, lichenMiddle, shimmer)
        lip = mixedRGB(lip, lichenLip, shimmer)
    elseif kind ~= "control" then
        local breath = shimmer
        local bloomBreath = bloom * CONTENT_BLOOM_LICHEN_WEIGHT
        if bloomBreath > breath then breath = bloomBreath end
        local lichenOuter = shadedRGB(lichen, 0.62)
        local lichenMiddle = copyRGB(lichen)
        local lichenLip = brightenedRGB(lichen, 0.18)
        outer = mixedRGB(outer, lichenOuter, breath)
        middle = mixedRGB(middle, lichenMiddle, breath)
        lip = mixedRGB(lip, lichenLip, breath)
    end

    if access.highContrast then
        -- Shimmer stays decorative: final essential bands are checked after
        -- every mix, including future custom/control colour replacements.
        outer = MC_Theme.ensureContrast(outer, HC_STATE_GROUND)
        middle = MC_Theme.ensureContrast(middle, HC_STATE_GROUND)
        lip = MC_Theme.ensureContrast(lip, HC_STATE_GROUND)
    end

    return {
        outer=outer, middle=middle, lip=lip,
        shimmerWeight=shimmer, animated=shimmer > 0,
        bloomWeight=bloom,
        trusted=trusted and not access.tagsOnly,
    }
end

--[[
    Surface colour as an {r, g, b, a} table in 0..1, the shape ISUIElement
    wants for backgroundColor / borderColor. High contrast paints slate as
    black at near-full alpha and the rim at full alpha.
]]
function MC_Theme.surface(name, alpha, interfaceChrome)
    local a = MC_Theme.access()
    local surfaces = interfaceChrome == true and not activeWindowTheme()
        and MC_Theme.skin() == "vanilla"
        and MC_Theme.VanillaSurfaces or MC_Theme.Surfaces
    local rgb = surfaces[name] or surfaces.slate
    if a.highContrast then
        if name == "slate" or name == "slateDeep" then
            rgb = MC_Theme.highContrastBackground(false)
            alpha = 1
        elseif name == "rim" then
            alpha = 1.0
        end
    elseif name == "slate" and alpha == nil then
        alpha = a.opacity
    end
    return { r = rgb[1] / 255, g = rgb[2] / 255, b = rgb[3] / 255, a = alpha or 1 }
end

-- Custom art is a fourth window-only choice layered over Interface shape.
-- These helpers keep Classic's greys from leaking into that art while world
-- surfaces continue to use surface() exactly as before.
function MC_Theme.windowSurfaceRGB(name)
    if MC_Theme.access().highContrast then
        return MC_Theme.highContrastBackground(false)
    end
    local surfaces = MC_Theme.windowUsesClassic()
        and MC_Theme.VanillaSurfaces or MC_Theme.Surfaces
    return surfaces[name] or surfaces.slate
end

function MC_Theme.windowControlColor()
    return resolvedWindowControl(trustedBorderSource())
end

function MC_Theme.rgb01(rgb)
    rgb = rgb or MC_Theme.Channels.say
    return rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
end

-- Base skins carry their normal fill in the PNG. High contrast multiplies the
-- same native shape to black; separate pieces such as bubble arrows use this
-- too, so they cannot drift from their nine-slice body.
function MC_Theme.baseTint()
    if MC_Theme.access().highContrast then return 0, 0, 0 end
    return 1, 1, 1
end

local FONT_STEP_NAMES = { "small", "medium", "large" }

local function faceFor(name)
    if type(UIFont) ~= "table" then return nil end
    if name == "small" then return UIFont.Small end
    if name == "medium" then return UIFont.Medium end
    if name == "large" then return UIFont.Large end
    return nil
end

function MC_Theme.font(surface, default)
    local a = MC_Theme.access()
    if surface == "nameplate" and a.nameplateFollowChat == false then
        return faceFor(FONT_STEP_NAMES[a.nameplateFontStep or 1] or "small") or default
    end
    if a.followVanillaFont ~= false then return default end
    local applies = {
        window    = true,
        bubble    = a.applyBubbles ~= false,
        nameplate = true,
        note      = a.applyNotes ~= false,
        sheet     = a.applySheet ~= false,
    }
    if applies[surface] == false then return default end
    local face = faceFor(FONT_STEP_NAMES[a.fontStep or 2] or "medium")
    return face or default
end

function MC_Theme.fadeMs(base)
    if MC_Theme.access().reducedMotion then return 0 end
    return base or MC_Theme.Metrics.fadeMs
end

-- Sets live under media/ui/MongooseChat/<folder>/<prefix>-<piece>.png.
-- Bubbles: folder "bubble/simple", prefix "bubble". Window art: folder
-- "window", prefixes "frame", "tab-active", "tab-idle", "well".

local PIECES = {
    { key = "topLeft",  file = "top-left"  },
    { key = "top",      file = "top"       },
    { key = "topRight", file = "top-right" },
    { key = "left",     file = "left"      },
    { key = "center",   file = "center"    },
    { key = "right",    file = "right"     },
    { key = "botLeft",  file = "bot-left"  },
    { key = "bot",      file = "bot"       },
    { key = "botRight", file = "bot-right" },
    { key = "arrow",    file = "arrow"     },
}

local WINDOW_PLANES = { "bg", "edge", "inner", "lip" }
local WINDOW_FILES = {
    topLeft="top-left", top="top", topRight="top-right",
    left="left", center="center", right="right",
    botLeft="btm-left", bot="btm", botRight="btm-right",
}
local windowThemeCache = {}
local windowThemeIncident = false
local windowCatalog = nil
local windowCatalogTried = false

local function reportWindowThemeOnce(detail)
    if windowThemeIncident then return end
    windowThemeIncident = true
    local ok, incident = pcall(require, "MC_Incident")
    if ok and type(incident) == "table" and type(incident.report) == "function" then
        pcall(incident.report, "WINDOW_THEME_UNAVAILABLE", detail or "custom window theme unavailable; using Match")
    end
end

local function loadWindowCatalog()
    if windowCatalogTried then return windowCatalog end
    windowCatalogTried = true
    local ok, data = pcall(require, "MC_WindowThemesData")
    if not ok or type(data) ~= "table" or data.formatVersion ~= 1
        or type(data.order) ~= "table" or type(data.themes) ~= "table" then
        reportWindowThemeOnce("window theme catalog unavailable; using Match")
        return nil
    end
    local byId = {}
    for _, row in ipairs(data.themes) do
        if type(row) == "table" and type(row.id) == "string" then byId[row.id] = row end
    end
    for _, id in ipairs(data.order) do
        if not byId[id] then
            reportWindowThemeOnce("window theme catalog invalid; using Match")
            return nil
        end
    end
    data.byId = byId
    windowCatalog = data
    return data
end

local function sanePair(pair)
    return type(pair) == "table" and type(pair[1]) == "number"
        and type(pair[2]) == "number" and pair[1] >= 1 and pair[2] >= 1
end

local function loadWindowTheme(id)
    if windowThemeCache[id] ~= nil then return windowThemeCache[id] or nil end
    local catalog = loadWindowCatalog()
    local row = catalog and catalog.byId[id] or nil
    local geometry = row and row.geometry or nil
    local rgb = row and row.defaultRGB or nil
    if not row or row.formatVersion ~= 1 or type(row.root) ~= "string"
        or type(geometry) ~= "table" or type(geometry.offsets) ~= "table"
        or type(geometry.frame) ~= "table" or type(geometry.joins) ~= "table"
        or type(rgb) ~= "table" then
        windowThemeCache[id] = false
        reportWindowThemeOnce("window theme metadata invalid; using Match")
        return nil
    end
    for _, plane in ipairs(WINDOW_PLANES) do
        local g = geometry.frame[plane]
        if type(g) ~= "table" or not sanePair(g.corner)
            or not sanePair(g.horizontal) or not sanePair(g.vertical)
            or (plane == "bg" and not sanePair(g.center))
            or not sanePair(geometry.joins[plane])
            or type(geometry.offsets[plane]) ~= "number" then
            windowThemeCache[id] = false
            reportWindowThemeOnce("window theme geometry invalid; using Match")
            return nil
        end
    end
    if type(getTexture) ~= "function" then
        windowThemeCache[id] = false
        reportWindowThemeOnce("window theme textures unavailable; using Match")
        return nil
    end

    local state = { row=row, geometry=geometry, frame={}, joins={} }
    local okAll = true
    for _, plane in ipairs(WINDOW_PLANES) do
        local set = {}
        for key, file in pairs(WINDOW_FILES) do
            if plane == "bg" or key ~= "center" then
                local ok, texture = pcall(getTexture,
                    row.root .. "/frame/" .. plane .. "/" .. file .. ".png")
                if not ok or not texture then okAll = false else set[key] = texture end
            end
        end
        state.frame[plane] = set
        state.joins[plane] = {}
        for _, side in ipairs({"left", "right"}) do
            local ok, texture = pcall(getTexture,
                row.root .. "/join/" .. plane .. "/" .. side .. ".png")
            if not ok or not texture then okAll = false else state.joins[plane][side] = texture end
        end
    end
    if not okAll then
        windowThemeCache[id] = false
        reportWindowThemeOnce("window theme texture set incomplete; using Match")
        return nil
    end
    state.defaultRGB = {
        math.floor((tonumber(rgb[1]) or 0) * 255 + 0.5),
        math.floor((tonumber(rgb[2]) or 0) * 255 + 0.5),
        math.floor((tonumber(rgb[3]) or 0) * 255 + 0.5),
    }
    windowThemeCache[id] = state
    return state
end

activeWindowTheme = function()
    local id = MC_Theme.access().windowTheme
    if type(id) ~= "string" or id == "" then return nil end
    return loadWindowTheme(id)
end

local textureCache = {}

local edgeMaskCache = {}

local function hasAnyPiece(set)
    if type(set) ~= "table" then return false end
    for _, piece in pairs(set) do
        if piece ~= nil then return true end
    end
    return false
end

local function loadNamedPieces(folder, prefix)
    local tex = {}
    if type(getTexture) ~= "function" then return tex end
    for _, p in ipairs(PIECES) do
        local ok, got = pcall(getTexture,
            "media/ui/MongooseChat/" .. folder .. "/" .. prefix .. "-" .. p.file .. ".png")
        if ok and got then tex[p.key] = got end
    end
    return tex
end

local function drawWindowPlane(el, set, geom, x, y, w, h, alpha, rgb, openBottom)
    if type(set) ~= "table" or type(geom) ~= "table" or not el
        or type(el.drawTextureScaled) ~= "function" or type(w) ~= "number"
        or type(h) ~= "number" or w <= 0 or h <= 0 then return false end
    local cw, ch = geom.corner[1], geom.corner[2]
    local hw, hh = geom.horizontal[1], geom.horizontal[2]
    local vw, vh = geom.vertical[1], geom.vertical[2]
    local r, g, b = MC_Theme.rgb01(rgb)
    local function draw(piece, px, py, pw, ph)
        if piece and pw > 0 and ph > 0 then
            el:drawTextureScaled(piece, px, py, pw, ph, alpha or 1, r, g, b)
        end
    end
    -- Very small controls keep a sound fill and omit corners rather than
    -- squeezing or overlapping them. Every corner draw below is native size.
    if w < cw * 2 or h < ch + (openBottom and 0 or ch) then
        if set.center then draw(set.center, x, y, w, h) end
        return set.center ~= nil
    end
    draw(set.topLeft, x, y, cw, ch)
    draw(set.top, x + cw, y, w - cw * 2, hh)
    draw(set.topRight, x + w - cw, y, cw, ch)
    local bottomH = openBottom and 0 or ch
    local middleY, middleH = y + ch, math.max(0, h - ch - bottomH)
    draw(set.left, x, middleY, vw, middleH)
    draw(set.center, x + cw, middleY, w - cw * 2, middleH)
    draw(set.right, x + w - vw, middleY, vw, middleH)
    if not openBottom then
        draw(set.botLeft, x, y + h - ch, cw, ch)
        draw(set.bot, x + cw, y + h - hh, w - cw * 2, hh)
        draw(set.botRight, x + w - cw, y + h - ch, cw, ch)
    end
    return true
end

local function customPlaneColor(state, plane, palette)
    if plane == "bg" then
        if MC_Theme.access().highContrast then return {0, 0, 0} end
        return MC_Theme.windowSurfaceRGB("slate")
    end
    if palette then
        if plane == "edge" then return palette.outer end
        if plane == "inner" then return palette.middle end
        return palette.lip
    end
    return state.defaultRGB
end

local function drawCustomPlanes(el, state, prefix, x, y, w, h, alpha, palette, first, last)
    local openBottom = type(prefix) == "string" and prefix:find("tab%-", 1) == 1
    for index = first, last do
        local plane = WINDOW_PLANES[index]
        local offset = state.geometry.offsets[plane]
        local dw, dh = w - offset * 2, h - offset * 2
        if dw > 0 and dh > 0 then
            local drawAlpha = plane == "bg"
                and MC_Theme.backgroundAlpha(alpha or 1)
                or MC_Theme.readableAlpha(alpha or 1)
            drawWindowPlane(el, state.frame[plane], state.geometry.frame[plane],
                x + offset, y + offset, dw, dh, drawAlpha,
                customPlaneColor(state, plane, palette), openBottom)
        end
    end
    return true
end

-- Load the three alpha-mask bands generated beside a normal slice family.
-- Each mask keeps the base piece's exact dimensions and curve. Missing pieces
-- stay nil (tabs have no bottom row; only bubbles have arrows).
function MC_Theme.edgeMasks(folder, prefix)
    if type(folder) ~= "string" or type(prefix) ~= "string" then return nil, false end
    local key = folder .. "/" .. prefix
    if edgeMaskCache[key] then
        local cached = edgeMaskCache[key]
        return cached, cached.outer.topLeft ~= nil or cached.outer.top ~= nil
    end
    local masks = {
        outer = loadNamedPieces(folder, prefix .. "-edge"),
        middle = loadNamedPieces(folder, prefix .. "-edge-inner"),
        lip = loadNamedPieces(folder, prefix .. "-edge-lip"),
    }
    -- A join-time texture lookup can briefly return nil for every piece.  Do
    -- not make that transient miss permanent; the next frame may load them.
    local available = hasAnyPiece(masks.outer)
        or hasAnyPiece(masks.middle)
        or hasAnyPiece(masks.lip)
    if available then edgeMaskCache[key] = masks end
    return masks, masks.outer.topLeft ~= nil or masks.outer.top ~= nil
end

-- Edge masks have no centre by design. Draw their real pieces with the same
-- coordinates as slice(); overlaid outer -> middle -> lip. The base texture
-- remains responsible for fill. Arrow masks are exposed on each set for the
-- bubble caller, whose arrow has its own placement outside the nine-slice.
local function drawMaskSlice(el, tex, x, y, w, h, alpha, rgb)
    if type(tex) ~= "table" or not el or type(el.drawTextureScaled) ~= "function" then return false end
    local c = MC_Theme.Metrics.corner
    -- The art owns fixed 15px corners. A smaller target would make opposite
    -- corners overlap and paint some alpha twice. Skip the skin until layout
    -- has a sound box; never squash it or replace it with a jagged rectangle.
    if type(w) ~= "number" or type(h) ~= "number"
        or w < c * 2 or h < c * 2 then return false end
    local hasBottom = tex.bot ~= nil
    local midH = hasBottom and (h - c * 2) or (h - c)
    if midH < 0 then midH = 0 end
    local r, g, b = MC_Theme.rgb01(rgb)
    local function draw(piece, px, py, pw, ph)
        if piece and pw > 0 and ph > 0 then
            el:drawTextureScaled(piece, px, py, pw, ph, alpha or 1, r, g, b)
        end
    end
    draw(tex.topLeft, x, y, c, c)
    draw(tex.top, x + c, y, w - c * 2, c)
    draw(tex.topRight, x + w - c, y, c, c)
    draw(tex.left, x, y + c, c, midH)
    draw(tex.right, x + w - c, y + c, c, midH)
    if hasBottom then
        draw(tex.botLeft, x, y + h - c, c, c)
        draw(tex.bot, x + c, y + h - c, w - c * 2, c)
        draw(tex.botRight, x + w - c, y + h - c, c, c)
    end
    return true
end

-- The sharp skin is deliberately plain geometry: one-pixel square edges and
-- no texture masks. It still consumes the normal edge palette, so trusted hue,
-- Mongoose Lichen shimmer, contrast, and motion settings keep one owner.
local function drawSharpEdge(el, x, y, w, h, alpha, rgb, openBottom)
    if not el or type(el.drawRect) ~= "function"
        or type(x) ~= "number" or type(y) ~= "number"
        or type(w) ~= "number" or type(h) ~= "number"
        or w < 1 or h < 1 then return false end
    local r, g, b = MC_Theme.rgb01(rgb)
    local a = alpha or 1
    el:drawRect(x, y, w, 1, a, r, g, b)
    if not openBottom and h > 1 then
        el:drawRect(x, y + h - 1, w, 1, a, r, g, b)
    end
    -- Bottomless tabs still need both sides to reach the frame below them.
    local sideH = h - (openBottom and 1 or 2)
    if sideH > 0 then
        el:drawRect(x, y + 1, 1, sideH, a, r, g, b)
        if w > 1 then
            el:drawRect(x + w - 1, y + 1, 1, sideH, a, r, g, b)
        end
    end
    return true
end

-- A small pixel triangle keeps speech tied to its speaker without bringing
-- the soft bubble skin back. The first row replaces the body edge at the
-- mouth, then the tail narrows 7,7,5,5,3,3,1 to one clear point.
local function drawSharpTail(el, box, alpha, rgb)
    if type(box) ~= "table" or not el or type(el.drawRect) ~= "function" then
        return false
    end
    local x, y = box.x, box.y
    local w, h = box.w, box.h
    if type(x) ~= "number" or type(y) ~= "number"
        or type(w) ~= "number" or type(h) ~= "number"
        or w < 3 or h < 2 then return false end
    w = math.floor(w)
    if w % 2 == 0 then w = w - 1 end
    local half = math.floor(w / 2)
    local rows = math.min(math.floor(h - 1), half * 2 + 1)
    if rows < 1 then return false end
    local fill = MC_Theme.surface("slate", alpha)
    local er, eg, eb = MC_Theme.rgb01(rgb)
    for row = 0, rows - 1 do
        local inset = math.min(half, math.floor(row / 2))
        local rowX = x + inset
        local rowW = w - inset * 2
        local rowY = y + 1 + row
        el:drawRect(rowX, rowY, rowW, 1,
            fill.a, fill.r, fill.g, fill.b)
        el:drawRect(rowX, rowY, 1, 1, alpha or 1, er, eg, eb)
        if rowW > 1 then
            el:drawRect(rowX + rowW - 1, rowY, 1, 1,
                alpha or 1, er, eg, eb)
        end
    end
    return true
end

function MC_Theme.drawEdgeSlice(el, masks, x, y, w, h, alpha, kind, nowMs, bloomWeight, baseOverride, interfaceChrome, openBottom)
    alpha = MC_Theme.readableAlpha(alpha or 1)
    local palette = MC_Theme.edgePalette(
        kind == "control" and "control" or "content", nowMs, bloomWeight,
        baseOverride, interfaceChrome)
    local custom = interfaceChrome == true and activeWindowTheme() or nil
    if custom then
        if kind == "control" and not MC_Theme.access().highContrast
            and not MC_Theme.access().tagsOnly
            and not MC_Theme.access().playerHueOnly then
            palette = { outer=custom.defaultRGB, middle=custom.defaultRGB,
                lip=custom.defaultRGB, shimmerWeight=0, animated=false }
        end
        return palette, drawCustomPlanes(el, custom,
            type(masks) == "table" and masks._prefix or "frame",
            x, y, w, h, alpha, palette, 2, 4)
    end
    if MC_Theme.isSquareSkin(interfaceChrome) then
        return palette, drawSharpEdge(el, x, y, w, h, alpha, palette.middle,
            openBottom == true)
    end
    if type(masks) ~= "table" then return palette, false end
    local drawn = drawMaskSlice(el, masks.outer, x, y, w, h, alpha, palette.outer)
    drawMaskSlice(el, masks.middle, x, y, w, h, alpha, palette.middle)
    drawMaskSlice(el, masks.lip, x, y, w, h, alpha, palette.lip)
    return palette, drawn == true
end

local function drawMaskPiece(el, piece, box, alpha, rgb)
    if not piece or type(box) ~= "table" or not el
        or type(el.drawTextureScaled) ~= "function" then return end
    local x, y, w, h = box.x, box.y, box.w, box.h
    if type(x) ~= "number" or type(y) ~= "number" or type(w) ~= "number"
        or type(h) ~= "number" or w < 0 or h < 0 then return end
    local r, g, b = MC_Theme.rgb01(rgb)
    el:drawTextureScaled(piece, x, y, w, h, alpha or 1, r, g, b)
end

function MC_Theme.drawEdgePiece(el, folder, prefix, piece, box, alpha,
        nowMs, fromKind, toKind, drawBase)
    if type(folder) ~= "string" or type(prefix) ~= "string"
        or type(piece) ~= "string" or type(box) ~= "table" then return false end
    alpha = MC_Theme.readableAlpha(alpha or 1)
    local custom = folder == "window" and activeWindowTheme() or nil
    if custom then
        local from = MC_Theme.edgePalette(
            fromKind == "control" and "control" or "content", nowMs, nil, nil, true)
        local target = toKind ~= nil and MC_Theme.edgePalette(
            toKind == "control" and "control" or "content", nowMs, nil, nil, true) or from
        if fromKind == "control" and not MC_Theme.access().highContrast
            and not MC_Theme.access().tagsOnly
            and not MC_Theme.access().playerHueOnly then
            from = {outer=custom.defaultRGB, middle=custom.defaultRGB, lip=custom.defaultRGB}
        end
        if toKind == "control" and not MC_Theme.access().highContrast
            and not MC_Theme.access().tagsOnly
            and not MC_Theme.access().playerHueOnly then
            target = {outer=custom.defaultRGB, middle=custom.defaultRGB, lip=custom.defaultRGB}
        end
        local function mix(a, b)
            local colour = { (a[1]+b[1])/2, (a[2]+b[2])/2, (a[3]+b[3])/2 }
            if MC_Theme.access().highContrast then
                return MC_Theme.ensureContrast(colour, HC_STATE_GROUND)
            end
            return colour
        end
        if prefix == "tab-join" and (piece == "left" or piece == "right") then
            for index, plane in ipairs(WINDOW_PLANES) do
                if drawBase ~= false or plane ~= "bg" then
                    local dims = custom.geometry.joins[plane]
                    local px = piece == "right" and (box.x + box.w - dims[1]) or box.x
                    local py = box.y
                    local colour = plane == "bg" and customPlaneColor(custom, plane)
                        or (plane == "edge" and from.outer)
                        or (plane == "inner" and mix(from.middle, target.middle))
                        or target.lip
                    local r,g,b = MC_Theme.rgb01(colour)
                    el:drawTextureScaled(custom.joins[plane][piece], px, py,
                        dims[1], dims[2], alpha or 1, r,g,b)
                end
            end
            return true
        end
        local fileKey = piece
        for index, plane in ipairs(WINDOW_PLANES) do
            if drawBase ~= false or plane ~= "bg" then
                local geom = custom.geometry.frame[plane]
                local dims = (piece == "top") and geom.horizontal or geom.corner
                local colour = plane == "bg" and customPlaneColor(custom, plane)
                    or (plane == "edge" and from.outer)
                    or (plane == "inner" and mix(from.middle, target.middle))
                    or target.lip
                local r,g,b = MC_Theme.rgb01(colour)
                local offset = custom.geometry.offsets[plane]
                local pw = piece == "top" and math.max(0, box.w - offset * 2) or dims[1]
                local px = box.x + offset
                if piece == "topRight" then px = box.x + box.w - offset - dims[1] end
                el:drawTextureScaled(custom.frame[plane][fileKey], px, box.y + offset,
                    pw, dims[2], alpha or 1, r,g,b)
            end
        end
        return true
    end
    if MC_Theme.isSquareSkin() then
        -- These are curved bridge pieces used only to join the soft card and
        -- tab skins. Square shells meet cleanly without extra join art.
        return true
    end
    local masks = MC_Theme.edgeMasks(folder, prefix)
    if type(masks) ~= "table" then return false end
    local bases = MC_Theme.textures(folder, prefix)
    local basePiece = type(bases) == "table" and bases[piece] or nil
    local outerPiece = type(masks.outer) == "table" and masks.outer[piece] or nil
    local middlePiece = type(masks.middle) == "table" and masks.middle[piece] or nil
    local lipPiece = type(masks.lip) == "table" and masks.lip[piece] or nil
    if not outerPiece or not middlePiece or not lipPiece
        or (drawBase ~= false and not basePiece) then
        -- A join-time lookup may see only part of a new four-plane asset.
        -- Forget this prefix only, so the next frame retries both caches.
        local key = folder .. "/" .. prefix
        textureCache[key] = nil
        edgeMaskCache[key] = nil
        return false
    end
    local from = MC_Theme.edgePalette(
        fromKind == "control" and "control" or "content", nowMs, nil, nil)
    local target = from
    if toKind ~= nil then
        target = MC_Theme.edgePalette(
            toKind == "control" and "control" or "content", nowMs, nil, nil)
    end
    local function mix(a, b)
        local colour = { (a[1]+b[1])/2, (a[2]+b[2])/2, (a[3]+b[3])/2 }
        if MC_Theme.access().highContrast then
            return MC_Theme.ensureContrast(colour, HC_STATE_GROUND)
        end
        return colour
    end
    if drawBase ~= false then
        local br, bg, bb = MC_Theme.baseTint()
        drawMaskPiece(el, basePiece, box, alpha, { br, bg, bb })
    end
    drawMaskPiece(el, outerPiece, box, alpha, from.outer)
    drawMaskPiece(el, middlePiece, box, alpha, mix(from.middle, target.middle))
    drawMaskPiece(el, lipPiece, box, alpha, target.lip)
    return true
end

-- One-call compositor for callers. `arrow` is nil/false when the base hides
-- its arrow, or the base arrow's exact {x,y,w,h} box when it is shown. Theme
-- never guesses bubble direction or placement.
function MC_Theme.drawSliceEdge(el, folder, prefix, x, y, w, h, alpha, nowMs, kind, arrow, bloomWeight, baseOverride, interfaceChrome)
    alpha = MC_Theme.readableAlpha(alpha or 1)
    local custom = interfaceChrome == true and folder == "window" and activeWindowTheme() or nil
    if custom then
        local palette = MC_Theme.edgePalette(
            kind == "control" and "control" or "content", nowMs, bloomWeight,
            baseOverride, true)
        if kind == "control" and not MC_Theme.access().highContrast
            and not MC_Theme.access().tagsOnly
            and not MC_Theme.access().playerHueOnly then
            palette = { outer=custom.defaultRGB, middle=custom.defaultRGB,
                lip=custom.defaultRGB, shimmerWeight=0, animated=false }
        end
        return palette, drawCustomPlanes(el, custom, prefix, x, y, w, h,
            alpha, palette, 2, 4)
    end
    if MC_Theme.isSquareSkin(interfaceChrome) then
        -- Do not load curved masks. The optional speech tail is plain pixel
        -- geometry and shares the same live hue/Lichen palette as the box.
        -- Only the named window tabs have open bottoms. Missing texture
        -- pieces must not turn frames, fields or bubbles into open boxes.
        local openBottom = interfaceChrome == true and folder == "window"
            and (prefix == "tab-active" or prefix == "tab-idle")
        local palette, drawn = MC_Theme.drawEdgeSlice(el, nil, x, y, w, h, alpha, kind,
            nowMs, bloomWeight, baseOverride, interfaceChrome, openBottom)
        if drawn and type(arrow) == "table" then
            drawSharpTail(el, arrow, alpha, palette.middle)
        end
        return palette, drawn
    end
    local masks = MC_Theme.edgeMasks(folder, prefix)
    local palette, drawn = MC_Theme.drawEdgeSlice(
        el, masks, x, y, w, h, alpha, kind, nowMs, bloomWeight, baseOverride,
        interfaceChrome)
    if drawn and type(arrow) == "table" and type(masks) == "table" then
        drawMaskPiece(el, masks.outer and masks.outer.arrow, arrow, alpha, palette.outer)
        drawMaskPiece(el, masks.middle and masks.middle.arrow, arrow, alpha, palette.middle)
        drawMaskPiece(el, masks.lip and masks.lip.arrow, arrow, alpha, palette.lip)
    end
    return palette, drawn
end

--[[
    Load and cache one 9-slice set. Pieces that do not exist (tabs have no
    bottom row; only bubbles have an arrow) are simply nil. A set with no
    center texture is unusable and is reported once by the caller through
    MC_Theme.textures' second return.

    @return tex, ok  -- ok is false when center is missing
]]
function MC_Theme.textures(folder, prefix)
    if folder == "window" then
        local custom = activeWindowTheme()
        if custom then
            return { center=true, _windowTheme=custom, _prefix=prefix }, true
        end
    end
    local key = folder .. "/" .. prefix
    local cached = textureCache[key]
    if cached then return cached, cached.center ~= nil end

    local tex = {}
    if type(getTexture) == "function" then
        for _, p in ipairs(PIECES) do
            local ok, t = pcall(getTexture,
                "media/ui/MongooseChat/" .. folder .. "/" .. prefix .. "-" .. p.file .. ".png")
            if ok and t then tex[p.key] = t end
        end
    end
    textureCache[key] = tex
    return tex, tex.center ~= nil
end

--[[
    Draw a 9-slice set into an element's local space.

    Lifted verbatim from MC_Bubble's render so bubble, window, tab and well
    are one draw. Sets without a bottom row (tabs) draw the middle row all
    the way to the bottom edge, which is exactly what makes an active tab
    look cut into the frame beneath it.

    @param el     the ISUIElement to draw on
    @param tex    a set from MC_Theme.textures
    @param alpha  0..1
]]
function MC_Theme.slice(el, tex, x, y, w, h, alpha, interfaceChrome)
    if interfaceChrome == true and type(tex) == "table" and tex._windowTheme then
        return drawCustomPlanes(el, tex._windowTheme, tex._prefix,
            x, y, w, h, alpha, nil, 1, 1)
    end
    if MC_Theme.isSquareSkin(interfaceChrome) then
        if not el or type(el.drawRect) ~= "function"
            or type(x) ~= "number" or type(y) ~= "number"
            or type(w) ~= "number" or type(h) ~= "number"
            or w < 1 or h < 1 then return false end
        local fill = MC_Theme.surface("slate", alpha, interfaceChrome)
        el:drawRect(x, y, w, h, fill.a, fill.r, fill.g, fill.b)
        return true
    end
    if not tex or not tex.center then return false end
    local c = MC_Theme.Metrics.corner
    if not el or type(el.drawTextureScaled) ~= "function"
        or type(w) ~= "number" or type(h) ~= "number"
        or w < c * 2 or h < c * 2 then return false end
    local hasBottom = tex.bot ~= nil
    local midH = hasBottom and (h - c * 2) or (h - c)
    if midH < 0 then midH = 0 end
    local tintR, tintG, tintB = MC_Theme.baseTint()
    alpha = MC_Theme.backgroundAlpha(alpha or 1)
    local function draw(piece, px, py, pw, ph)
        if piece and pw > 0 and ph > 0 then
            el:drawTextureScaled(piece, px, py, pw, ph,
                alpha, tintR, tintG, tintB)
        end
    end

    draw(tex.topLeft,  x,         y, c,         c)
    draw(tex.top,      x + c,     y, w - c * 2, c)
    draw(tex.topRight, x + w - c, y, c,         c)

    draw(tex.left,   x,         y + c, c,         midH)
    draw(tex.center, x + c,     y + c, w - c * 2, midH)
    draw(tex.right,  x + w - c, y + c, c,         midH)

    if hasBottom then
        draw(tex.botLeft,  x,         y + h - c, c,         c)
        draw(tex.bot,      x + c,     y + h - c, w - c * 2, c)
        draw(tex.botRight, x + w - c, y + h - c, c,         c)
    end
    return true
end

function MC_Theme.texture(path)
    local key = "single/" .. path
    if textureCache[key] ~= nil then return textureCache[key] or nil end
    local t = nil
    if type(getTexture) == "function" then
        local ok, got = pcall(getTexture, "media/ui/MongooseChat/" .. path)
        if ok and got then t = got end
    end
    textureCache[key] = t or false
    return t
end

return MC_Theme
