--[[
================================================================================
    MongooseChat - Player Identity (Client): nameplates, bio, and notes

    Owns everything client-side about a player's identity beyond the chat
    line itself:
      - Custom nameplate rendering: replaces vanilla player nameplates,
        character name + tagline as one anchored unit, with distance fade
        and LOS-gated visibility (MC_NameplatePanel).
      - Tagline / character-sheet description CRUD: local cache, the
        request/save round trip to the server's Bio*/Desc* commands, and
        the BioData/DescData/BioSyncAll sync handlers that populate it.
      - Personal notes: your own private remarks about another player
        (Note* commands) -- nobody else ever sees them.
      - The right-click "Character Sheet" context-menu entry that opens
        MC_CharacterSheet, and the fresh-character wipe that keeps a
        re-rolled character from wearing a dead one's bio.
      - Shared helpers other client modules require this file for:
        _getCharacterName (cached, sanitized name-building),
        _findClickedPlayer (context-menu click resolution), and
        _screenPosition (world-to-screen projection) -- each carries its
        own Internal-contract comment at its definition.

    REQUIRES SERVER CONFIG:
    Set DisplayUserName=false in your server INI to disable vanilla names.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Theme = require("MC_Theme")
local MC_Options = require("MC_Options")
local MC_Config = require("MC_Config")
local MC_Anonymity = require("MC_Anonymity")
local MC_Incident = require("MC_Incident")

local dbg = MC_Core.debugger("BIO")

local MC_Bio = {}

local function bioFeatureOn()
    return MC_Config.featureOn("BioEnabled")
end

-- CONFIGURATION

local NAMEPLATE_CONFIG = {
    -- Font settings
    nameFont = MC_Theme.font("nameplate", UIFont.Small),
    taglineFont = MC_Theme.font("nameplate", UIFont.Small),
    
    -- Colors (RGBA 0-1) -- Chalk on Slate: name in chalk, tagline in the
    -- quoted-thought family so a nameplate reads as kin to the bubble above
    -- it. Shadow stays black for contrast over the world.
    nameColor = (function() local r, g, b = MC_Theme.rgb01(MC_Theme.Channels.say) return {r, g, b, 1.0} end)(),
    taglineColor = (function() local r, g, b = MC_Theme.rgb01(MC_Theme.Channels.thought) return {r, g, b, 1.0} end)(),
    shadowColor = {0, 0, 0, 0.7},
    
    -- Positioning - below action bar, bubbles render above
    offsetY = 110,
    yAdjust = MC_Core.Display.BUBBLE_Y_ADJUST,
    lineSpacing = 2,                             -- Pixels between name and tagline
    
    -- Limits
    maxTaglineLength = 80,
    
    -- Visibility
    maxDistance = 15,                            -- Tiles - don't render nameplates beyond this
    fadeStartDistance = 12,                      -- Start fading at this distance
}

-- Fonts follow the direct Nameplate text size setting; refreshed on every Apply so
-- a change on the Options screen reaches nameplates without a rejoin.
local function refreshNameplateFonts()
    NAMEPLATE_CONFIG.nameFont = MC_Theme.font("nameplate", UIFont.Small)
    NAMEPLATE_CONFIG.taglineFont = MC_Theme.font("nameplate", UIFont.Small)
    -- Live plates re-measure themselves on their next frame (see
    -- MC_NameplatePanel:prerender), so the change is instant.
    NAMEPLATE_CONFIG.generation = (NAMEPLATE_CONFIG.generation or 0) + 1
end
MC_Options.onApply(refreshNameplateFonts)

-- This is the tagline limit MC_Bio.saveTagline actually enforces (below);
-- exposed so MC_CharacterSheet's tagline entry box caps input at the same
-- number instead of keeping its own separate literal that could drift.
MC_Bio.MAX_TAGLINE_LENGTH = NAMEPLATE_CONFIG.maxTaglineLength

-- LOS nameplate visibility constants
local LOS_CHECK_INTERVAL_MS = 200              -- Throttle checkCanSeeClient calls (ms)
local LOS_GRACE_MS = 1500                      -- Grace period before hiding after LOS lost
local LOS_FADE_MS = 500                        -- Fade duration at tail end of grace period

-- Crouch concealment. A crouching player's nameplate range collapses from
-- NAMEPLATE_CONFIG.maxDistance to the NameplateCrouchRange sandbox value, so
-- sneaking makes you unidentifiable at a distance while someone standing over
-- you can still read the plate. The fade band is fixed rather than
-- proportional: scaling the standing 12/15 ratio down to a 3-tile range gives
-- a 0.6-tile fade, which reads as a snap rather than a fade.
local CROUCH_FADE_BAND = 1                     -- Tiles of fade at the edge of crouch range

--[[
    The distance envelope one nameplate observation should use.

    Standing players keep the module's configured range untouched. A crouching
    player's range collapses to `crouchRange` (clamped into 0..maxDistance),
    fading over the last CROUCH_FADE_BAND tiles of it. A crouch range of 0
    means "never visible while crouching", which the caller must treat as
    hidden rather than dividing by an empty fade band.

    @return maxDistance, fadeStartDistance
]]
function MC_Bio._crouchVisibilityRange(crouching, crouchRange)
    if not crouching then
        return NAMEPLATE_CONFIG.maxDistance, NAMEPLATE_CONFIG.fadeStartDistance
    end
    local maxDist = crouchRange
    if type(maxDist) ~= "number" or maxDist ~= maxDist then maxDist = 0 end
    if maxDist < 0 then maxDist = 0 end
    if maxDist > NAMEPLATE_CONFIG.maxDistance then
        maxDist = NAMEPLATE_CONFIG.maxDistance
    end
    local fadeStart = maxDist - CROUCH_FADE_BAND
    if fadeStart < 0 then fadeStart = 0 end
    return maxDist, fadeStart
end

-- LOCAL STATE

-- Cache of username -> tagline
local bioCache = {}

-- Cache of username -> character-sheet description (longer free text, shown on
-- the sheet rather than the nameplate)
local descCache = {}
local MAX_DESCRIPTION_LENGTH = 500

-- This is the description limit sanitizeDescription actually enforces
-- (below); exposed so MC_CharacterSheet's description (and private-notes)
-- entry boxes cap input at the same number instead of keeping their own
-- separate literal that could drift.
MC_Bio.MAX_DESCRIPTION_LENGTH = MAX_DESCRIPTION_LENGTH

-- Cache of target-username -> MY private note about them (only I ever see it)
local noteCache = {}

-- Identity mutations are not optimistic. A transport call only creates one
-- bounded pending request; the cache and success feedback move when the server
-- returns the matching durable-commit acknowledgement. Notes have one slot per
-- target, capped so a disconnected server cannot grow this table forever.
local MUTATION_TOKEN_MAX_LENGTH = 48
local MAX_PENDING_NOTE_MUTATIONS = 32
local pendingIdentityMutations = {
    bio = nil,
    description = nil,
    notes = {},
    noteCount = 0,
}
local mutationSequence = 0
local mutationEpoch = nil

-- Cache of username -> a value bound to the live player + descriptor identity.
-- A username alone is an account identity, not a character identity: reusing a
-- username after death must never return the previous character's real name.
local nameCache = {}

-- Track active nameplate panels
local activeNameplates = {}  -- username -> panel

-- SAFETY UTILITIES

-- Nil-is-failure contract; see MC_Core.safeGet/safeExec for why that
-- differs from MC_Core.safe. Kept under this file's own names since every
-- call site here already uses them.
local safeGet = MC_Core.safeGet
local function safeExec(fn)
    local ok, err = MC_Core.safeExec(fn)
    if not ok then
        dbg("safeExec failed: %s", tostring(err))
    end
    return ok
end

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function reportNameplate(code, detail)
    MC_Incident.report(code, detail)
end

local function sanitizeString(str)
    if not str or type(str) ~= "string" then
        return ""
    end
    str = str:gsub("[%c]", "")  -- Remove all control chars
    str = str:match("^%s*(.-)%s*$") or ""
    return str
end

local function reportIdentityMutation(code, kind, stage)
    MC_Incident.report(code,
        "kind=" .. tostring(kind or "unknown")
            .. " stage=" .. tostring(stage or "unknown"))
end

local function validMutationToken(token)
    return type(token) == "string"
        and #token > 0
        and #token <= MUTATION_TOKEN_MAX_LENGTH
        and token:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function nextMutationToken(kind)
    if mutationEpoch == nil then
        local ok, value = pcall(MC_Core.getTimeMs)
        if ok and isFiniteNumber(value) then
            mutationEpoch = math.floor(math.abs(value)) % 1000000000
        else
            reportIdentityMutation("IDENTITY_MUTATION_REQUEST_FAILED",
                kind, "clock")
            return nil
        end
    end
    mutationSequence = mutationSequence + 1
    if mutationSequence > 999999999 then mutationSequence = 1 end
    local prefix = (kind == "bio" and "b")
        or (kind == "description" and "d") or "n"
    local token = prefix .. "-" .. tostring(mutationEpoch)
        .. "-" .. tostring(mutationSequence)
    if not validMutationToken(token) then
        reportIdentityMutation("IDENTITY_MUTATION_REQUEST_FAILED",
            kind, "token")
        return nil
    end
    return token
end

local function currentPending(kind, target)
    if kind == "note" then
        return pendingIdentityMutations.notes[target]
    end
    return pendingIdentityMutations[kind]
end

local function clearPending(kind, target, token)
    local pending = currentPending(kind, target)
    if not pending or pending.token ~= token then return false end
    if kind == "note" then
        pendingIdentityMutations.notes[target] = nil
        pendingIdentityMutations.noteCount =
            math.max(0, pendingIdentityMutations.noteCount - 1)
    else
        pendingIdentityMutations[kind] = nil
    end
    return true
end

local function beginIdentityMutation(kind, target, value, command, args)
    local token = nextMutationToken(kind)
    if not token then return false end

    local pending = {
        token = token,
        kind = kind,
        target = target,
        value = value,
    }
    if kind == "note" then
        if pendingIdentityMutations.notes[target] == nil then
            if pendingIdentityMutations.noteCount
                >= MAX_PENDING_NOTE_MUTATIONS then
                reportIdentityMutation("IDENTITY_MUTATION_QUEUE_FULL",
                    kind, "pending")
                return false
            end
            pendingIdentityMutations.noteCount =
                pendingIdentityMutations.noteCount + 1
        end
        pendingIdentityMutations.notes[target] = pending
    else
        pendingIdentityMutations[kind] = pending
    end

    args.requestToken = token
    local ok, result = pcall(sendClientCommand,
        "MongooseChat", command, args)
    if not ok or result == false then
        clearPending(kind, target, token)
        reportIdentityMutation("IDENTITY_MUTATION_REQUEST_FAILED",
            kind, "transport")
        return false
    end
    return true
end

-- NAME UTILITIES

--[[
    Get character name from player descriptor.
    Caches result to avoid repeated descriptor access.
]]
local function getCharacterName(player, username)
    if not player or type(username) ~= "string" or username == "" then return nil end

    local descriptorOk, descriptor = pcall(function()
        return player:getDescriptor()
    end)
    if not descriptorOk or descriptor == nil then
        nameCache[username] = nil
        return nil
    end

    -- Re-read both raw fields before accepting the cache. Besides binding the
    -- entry to the live player/descriptor objects, this catches an engine-side
    -- descriptor mutation that happens without replacing either wrapper.
    local fieldsOk, rawForename, rawSurname = pcall(function()
        return descriptor:getForename(), descriptor:getSurname()
    end)
    if not fieldsOk then
        nameCache[username] = nil
        return nil
    end
    if rawForename ~= nil and type(rawForename) ~= "string" then
        nameCache[username] = nil
        return nil
    end
    if rawSurname ~= nil and type(rawSurname) ~= "string" then
        nameCache[username] = nil
        return nil
    end

    rawForename = rawForename or ""
    rawSurname = rawSurname or ""
    local descriptorSurname = rawSurname
    local cached = nameCache[username]
    if cached
        and cached.player == player
        and cached.descriptor == descriptor
        and cached.forename == rawForename
        and cached.surname == rawSurname
    then
        return cached.name
    end

    -- Strip any legacy tagline from surname (in case of old data)
    if rawSurname:find("\n") then
        rawSurname = rawSurname:match("^([^\n]*)") or rawSurname
    end

    local forename = sanitizeString(rawForename)
    local surname = sanitizeString(rawSurname)
    local name
    if surname == "" then
        name = forename
    elseif forename == "" then
        name = surname
    else
        name = forename .. " " .. surname
    end

    if name and name ~= "" then
        nameCache[username] = {
            player = player,
            descriptor = descriptor,
            forename = rawForename,
            surname = descriptorSurname,
            name = name,
        }
        return name
    end

    nameCache[username] = nil
    return nil
end

-- Internal contract: getCharacterName is the one cached, sanitizeString-
-- cleaned name builder in the mod -- MC_Client (vanilla-shout conversion),
-- MC_Bubble (pure-emote fallback), MC_CharacterSheet (sheet title), and
-- MC_LangAdmin (context-menu target label) all call this instead of
-- re-reading the descriptor themselves, so a single fix to sanitization or
-- the legacy-tagline-in-surname strip covers everyone.
MC_Bio._getCharacterName = getCharacterName

-- COORDINATE TRANSFORMATION

--[[
    Shared screen-space projection: world position -> UI element top-left,
    centered horizontally and anchored above the target by its bottom edge.
    IsoUtils + live zoom + centering is identical for the nameplate, every
    speech bubble, and the typing indicator; only what each draws
    (width/height) and how far above the target it floats (offsetY, plus a
    flat yAdjust nudge) differ, so those are parameters.

    Internal contract: also called by MC_Bubble and MC_Typing (through
    MC_Bio._screenPosition) instead of each keeping its own copy of this
    math. Homed here rather than in MC_Bubble (the fuller original) because
    MC_Bubble requires MC_Bio for _getCharacterName -- the reverse
    dependency would cycle.

    @param target   Object with getX/getY/getZ, OR a table {x=, y=, z=}
    @param width    Element width, for horizontal centering
    @param height   Element height, subtracted so the element sits ABOVE
                    the target (pass 0 to skip that, e.g. the typing
                    indicator, which anchors differently)
    @param offsetY  Extra world-scaled vertical lift, divided by zoom
    @param yAdjust  Flat screen-pixel nudge, NOT divided by zoom
    @return x, y screen coordinates, or nil, nil if not calculable
]]
local function screenPosition(target, width, height, offsetY, yAdjust)
    if not target then return nil, nil end

    local localPlayer = safeGet(function() return getPlayer() end, nil)
    if not localPlayer then return nil, nil end

    if not IsoUtils or not IsoUtils.XToScreenExact or not IsoUtils.YToScreenExact then
        return nil, nil
    end
    if not isFiniteNumber(width) or not isFiniteNumber(height)
        or not isFiniteNumber(offsetY) or not isFiniteNumber(yAdjust)
    then
        return nil, nil
    end

    -- Get world coordinates (a plain {x=,y=,z=} table, or an object with
    -- getX/getY/getZ -- MC_Bubble's radio bubbles pass ground positions)
    local coordinateOk, wx, wy, wz = pcall(function()
        if type(target) == "table" and target.x ~= nil then
            -- Ground-position callers (radio bubbles) historically omit z;
            -- that table shape explicitly means ground level, unlike a live
            -- player getter returning nil.
            return target.x, target.y, target.z or 0
        elseif target.getX then
            return target:getX(), target:getY(), target:getZ()
        end
        return nil, nil, nil
    end)
    if not coordinateOk
        or not isFiniteNumber(wx)
        or not isFiniteNumber(wy)
        or not isFiniteNumber(wz)
    then
        return nil, nil
    end

    -- Project to screen space
    local projectionOk, x, y = pcall(function()
        return IsoUtils.XToScreenExact(wx, wy, wz, 0),
            IsoUtils.YToScreenExact(wx, wy, wz, 0)
    end)
    if not projectionOk or not isFiniteNumber(x) or not isFiniteNumber(y) then
        return nil, nil
    end

    -- Get zoom
    local playerNum = safeGet(function() return localPlayer:getPlayerNum() end, nil)
    local core = safeGet(function() return getCore() end, nil)
    local zoom = core and safeGet(function() return core:getZoom(playerNum) end, nil) or nil
    if not isFiniteNumber(playerNum) or not isFiniteNumber(zoom) or zoom <= 0 then
        return nil, nil
    end

    -- Apply zoom scaling
    x = x / zoom - width / 2
    y = y / zoom - height - (offsetY / zoom) - yAdjust
    if not isFiniteNumber(x) or not isFiniteNumber(y) then
        return nil, nil
    end

    return x, y
end
MC_Bio._screenPosition = screenPosition

--[[
    Calculate distance between two players in tiles
]]
local function getDistance(player1, player2)
    if not player1 or not player2 then return nil end

    local coordinateOk, x1, y1, x2, y2 = pcall(function()
        return player1:getX(), player1:getY(), player2:getX(), player2:getY()
    end)
    if not coordinateOk
        or not isFiniteNumber(x1)
        or not isFiniteNumber(y1)
        or not isFiniteNumber(x2)
        or not isFiniteNumber(y2)
    then
        return nil
    end

    local distanceOk, distance = pcall(MC_Core.distance2D, x1, y1, x2, y2)
    if not distanceOk or not isFiniteNumber(distance) then return nil end
    return distance
end

-- NAMEPLATE PANEL

local MC_NameplatePanel = ISPanel:derive("MC_NameplatePanel")
MC_Bio._NameplatePanel = MC_NameplatePanel

function MC_NameplatePanel:initialise()
    ISPanel.initialise(self)
end

-- MOUSE PASSTHROUGH
-- Nameplates must not intercept clicks - players need to interact with the world
function MC_NameplatePanel:onMouseDown(x, y)
    return false  -- Pass through to world
end

function MC_NameplatePanel:onMouseUp(x, y)
    return false
end

function MC_NameplatePanel:onRightMouseDown(x, y)
    return false
end

function MC_NameplatePanel:onRightMouseUp(x, y)
    return false
end

function MC_NameplatePanel:onMouseMove(dx, dy)
    return false
end

function MC_NameplatePanel:onMouseMoveOutside(dx, dy)
    return false
end

function MC_NameplatePanel:isMouseOver()
    return false  -- Never report as hovered
end

local function hidePanelForIncident(panel, code, detail, shouldRemove)
    if panel then
        panel.currentAlpha = 0
        if shouldRemove then panel.shouldRemove = true end
    end
    reportNameplate(code, detail)
end

--[[
    Measure a plate for its name and tagline with the CURRENT fonts.
    Shared by the constructor and the live re-measure.
]]
local function measurePlate(characterName, tagline)
    local textManager = getTextManager()
    local nameWidth, nameHeight, taglineWidth, taglineHeight = 0, 0, 0, 0
    if characterName and characterName ~= "" then
        nameWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, characterName)
        nameHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.nameFont)
    end
    if tagline and tagline ~= "" then
        taglineWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.taglineFont, tagline)
        taglineHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.taglineFont)
    end
    local maskedWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, MC_Anonymity.Config.maskedName)
    local distantWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, MC_Anonymity.Config.distantName)
    local width = math.max(nameWidth, maskedWidth, distantWidth, taglineWidth) + 20
    local height = nameHeight + taglineHeight + NAMEPLATE_CONFIG.lineSpacing + 4
    return width, height, nameHeight, taglineHeight
end

function MC_NameplatePanel:prerender()
    -- Text size changed on the Options screen: re-measure with the new
    -- fonts before positioning, so the plate never draws at a stale size.
    if self.fontGeneration ~= NAMEPLATE_CONFIG.generation then
        self.fontGeneration = NAMEPLATE_CONFIG.generation
        local ok, w, h, nh, th = pcall(measurePlate, self.realCharacterName, self.realTagline)
        if ok and w then
            self:setWidth(w)
            self:setHeight(h)
            self.nameHeight = nh
            self.taglineHeight = th
        end
    end

    -- Update position each frame to follow player
    if not self.player then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=target-player", true)
        return
    end

    local localPlayer = safeGet(function() return getPlayer() end, nil)
    if not localPlayer then
        hidePanelForIncident(self, "NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE",
            "stage=prerender", false)
        return
    end

    -- Check if player still exists and is alive
    local aliveOk, isAlive = pcall(function() return self.player:isAlive() end)
    if not aliveOk or type(isAlive) ~= "boolean" then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=alive", false)
        return
    end
    if not isAlive then
        self.currentAlpha = 0
        self.shouldRemove = true
        return
    end

    -- Check if player is invisible (ghost mode, admin invisibility, etc.)
    local invisibleOk, isInvisible = pcall(function()
        return self.player:isInvisible()
    end)
    if not invisibleOk or type(isInvisible) ~= "boolean" then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=invisible", false)
        return
    end
    if isInvisible then
        self.currentAlpha = 0
        return
    end

    -- Reject players from a different or unavailable world cell. Engine
    -- visibility (including HidePlayersBehindYou) is checked in
    -- updateNameplates via IsVisibleToPlayer, and LOS mode is verified below
    -- with checkCanSeeClient. Build 42.20 does not expose getPlayerSprite().
    local renderStateOk, shouldHide = pcall(function()
        -- Check if player is in a different cell (can't see across cells)
        local localCell = localPlayer:getCell()
        local otherCell = self.player:getCell()
        if not localCell or not otherCell then return nil end
        if localCell ~= otherCell then return true end
        return false
    end)
    if not renderStateOk or type(shouldHide) ~= "boolean" then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=render-state", false)
        return
    end

    if shouldHide then
        self.currentAlpha = 0
        return
    end

    -- Calculate distance-based alpha
    local distance = getDistance(localPlayer, self.player)
    if not isFiniteNumber(distance) then
        hidePanelForIncident(self, "NAMEPLATE_POSITION_UNAVAILABLE",
            "stage=distance", false)
        return
    end

    -- Crouch concealment. Reading the OTHER player's sneak state, not our
    -- own: crouching is what hides YOU from everyone else. Fails CLOSED, the
    -- same direction as every other perception check in this module -- an
    -- unreadable sneak state is treated as crouching, so the failure hides a
    -- plate rather than exposing someone who believed they were hidden.
    local sneakOk, isSneaking = pcall(function()
        return self.player:isSneaking()
    end)
    if not sneakOk or type(isSneaking) ~= "boolean" then
        MC_Incident.report("NAMEPLATE_PERCEPTION_UNAVAILABLE", "stage=sneak")
        isSneaking = true
    end
    local maxDistance, fadeStartDistance = MC_Bio._crouchVisibilityRange(
        isSneaking, MC_Config.liveSandbox("NameplateCrouchRange", 3))

    if maxDistance <= 0 or distance > maxDistance then
        self.currentAlpha = 0
        return
    elseif distance > fadeStartDistance and MC_Theme.fadeMs() > 0 then
        local fadeRange = maxDistance - fadeStartDistance
        local fadeProgress = (distance - fadeStartDistance) / fadeRange
        self.currentAlpha = 1 - fadeProgress
    else
        -- Inside the fade band, or reduced motion: full, then gone at
        -- maxDistance -- a step, never a slow drift.
        self.currentAlpha = 1
    end
    
    -- LOS visibility check (Line of Sight mode)
    -- Skip for own player (you can always see your own nameplate)
    local visMode = MC_Config.liveSandbox("NameplateVisibility", nil)

    if visMode ~= 1 and visMode ~= 2 then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=visibility-policy", false)
        return
    end

    if visMode == 2 and not self.isOwnPlayer then
        local now = safeGet(function() return MC_Core.getTimeMs() end, nil)
        if not isFiniteNumber(now) or not isFiniteNumber(self.losLastCheck) then
            hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
                "stage=los-clock", false)
            return
        end

        -- Throttled LOS check (don't call checkCanSeeClient every frame)
        if (now - self.losLastCheck) >= LOS_CHECK_INTERVAL_MS then
            self.losLastCheck = now
            local losOk, canSee = pcall(function()
                return localPlayer:checkCanSeeClient(self.player)
            end)

            if not losOk or type(canSee) ~= "boolean" then
                self.losVisible = false
                self.losGraceStart = nil
                hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
                    "stage=los", false)
                return
            end

            if canSee then
                -- Visible: clear grace period
                self.losVisible = true
                self.losGraceStart = nil
            else
                -- Not visible: start grace only after a previously verified
                -- visible state. A new/unverified panel is hidden immediately.
                if self.losVisible then
                    self.losGraceStart = now
                end
                self.losVisible = false
            end
        end

        -- Apply LOS alpha modulation
        if not self.losVisible and not self.losGraceStart then
            self.currentAlpha = 0
            return
        elseif not self.losVisible and self.losGraceStart then
            local currentTime = safeGet(function() return MC_Core.getTimeMs() end, nil)
            if not isFiniteNumber(currentTime) or not isFiniteNumber(self.losGraceStart) then
                hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
                    "stage=los-grace-clock", false)
                return
            end
            local elapsed = currentTime - self.losGraceStart
            if not isFiniteNumber(elapsed) or elapsed < 0 then
                hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
                    "stage=los-grace-elapsed", false)
                return
            end
            if elapsed >= LOS_GRACE_MS then
                -- Grace expired: fully hidden
                self.currentAlpha = 0
                return
            else
                local fadeMs = MC_Theme.fadeMs(LOS_FADE_MS)
                if fadeMs > 0 and elapsed >= (LOS_GRACE_MS - fadeMs) then
                    -- In fade zone at tail of grace period
                    local fadeElapsed = elapsed - (LOS_GRACE_MS - fadeMs)
                    local fadeProgress = fadeElapsed / fadeMs
                    self.currentAlpha = self.currentAlpha * (1 - fadeProgress)
                end
            end
            -- else: within grace but before fade zone, show at current alpha
        end
    end
    
    -- Check anonymity (masked or too far to recognize)
    -- getDisplayName handles self-indicator for masked local player
    local speakerUsername = safeGet(function() return self.player:getUsername() end, nil)
    if type(speakerUsername) ~= "string" or speakerUsername == "" then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=username", false)
        return
    end

    -- Call getDisplayName directly with pcall to capture both return values
    local ok, name, anon = pcall(function()
        return MC_Anonymity.getDisplayName(
            self.player, 
            speakerUsername, 
            self.realCharacterName
        )
    end)
    if not ok or type(name) ~= "string" or name == ""
        or type(anon) ~= "boolean"
    then
        hidePanelForIncident(self, "NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=anonymity", false)
        return
    end

    self.characterName = name
    self.isAnonymous = anon
    -- Hide tagline when anonymous
    self.tagline = anon and "" or self.realTagline

    -- Update position - if we can't get a screen position, player is likely hidden
    local x, y = screenPosition(self.player, self.width, self.height,
        NAMEPLATE_CONFIG.offsetY, NAMEPLATE_CONFIG.yAdjust)
    if isFiniteNumber(x) and isFiniteNumber(y) then
        self:setX(x)
        self:setY(y)
    else
        hidePanelForIncident(self, "NAMEPLATE_POSITION_UNAVAILABLE",
            "stage=screen", false)
    end
end

function MC_NameplatePanel:render()
    -- Feature switch: with the bio feature off the plate is a name only.
    if not MC_Config.featureOn("BioEnabled") then self.tagline = "" end
    if self.currentAlpha <= 0 then return end
    
    local theme = MC_Theme
    local alpha = theme.readableAlpha(self.currentAlpha)
    local yOffset = 0
    
    -- Draw name (centered)
    if self.characterName and self.characterName ~= "" then
        local nameWidth = getTextManager():MeasureStringX(NAMEPLATE_CONFIG.nameFont, self.characterName)
        local nameX = (self.width - nameWidth) / 2

        if theme.access().highContrast then
            self:drawRect(nameX - 2, yOffset - 1, nameWidth + 4,
                self.nameHeight + 2, 1, 0, 0, 0)
        end
        
        -- A backed high-contrast label needs no second offset copy of its
        -- words.  In normal modes the old shadow remains unchanged.
        if not theme.access().highContrast then self:drawText(
            self.characterName,
            nameX + 1, yOffset + 1,
            NAMEPLATE_CONFIG.shadowColor[1],
            NAMEPLATE_CONFIG.shadowColor[2],
            NAMEPLATE_CONFIG.shadowColor[3],
            NAMEPLATE_CONFIG.shadowColor[4] * alpha,
            NAMEPLATE_CONFIG.nameFont
        ) end
        
        -- Name
        local nameColor = theme.readableColor({
            NAMEPLATE_CONFIG.nameColor[1] * 255,
            NAMEPLATE_CONFIG.nameColor[2] * 255,
            NAMEPLATE_CONFIG.nameColor[3] * 255,
        })
        self:drawText(
            self.characterName,
            nameX, yOffset,
            nameColor[1] / 255,
            nameColor[2] / 255,
            nameColor[3] / 255,
            NAMEPLATE_CONFIG.nameColor[4] * alpha,
            NAMEPLATE_CONFIG.nameFont
        )
        
        yOffset = yOffset + self.nameHeight + NAMEPLATE_CONFIG.lineSpacing
    end
    
    -- Draw tagline (centered)
    if self.tagline and self.tagline ~= "" then
        local taglineWidth = getTextManager():MeasureStringX(NAMEPLATE_CONFIG.taglineFont, self.tagline)
        local taglineX = (self.width - taglineWidth) / 2

        if theme.access().highContrast then
            self:drawRect(taglineX - 2, yOffset - 1, taglineWidth + 4,
                self.taglineHeight + 2, 1, 0, 0, 0)
        end
        
        -- Shadow
        if not theme.access().highContrast then self:drawText(
            self.tagline,
            taglineX + 1, yOffset + 1,
            NAMEPLATE_CONFIG.shadowColor[1],
            NAMEPLATE_CONFIG.shadowColor[2],
            NAMEPLATE_CONFIG.shadowColor[3],
            NAMEPLATE_CONFIG.shadowColor[4] * alpha,
            NAMEPLATE_CONFIG.taglineFont
        ) end
        
        -- Tagline
        local taglineColor = theme.readableColor({
            NAMEPLATE_CONFIG.taglineColor[1] * 255,
            NAMEPLATE_CONFIG.taglineColor[2] * 255,
            NAMEPLATE_CONFIG.taglineColor[3] * 255,
        })
        self:drawText(
            self.tagline,
            taglineX, yOffset,
            taglineColor[1] / 255,
            taglineColor[2] / 255,
            taglineColor[3] / 255,
            NAMEPLATE_CONFIG.taglineColor[4] * alpha,
            NAMEPLATE_CONFIG.taglineFont
        )
    end
end

function MC_NameplatePanel:new(player, characterName, tagline)
    local textManager = getTextManager()
    
    -- Calculate dimensions for real name
    local nameWidth = 0
    local nameHeight = 0
    local taglineWidth = 0
    local taglineHeight = 0
    
    if characterName and characterName ~= "" then
        nameWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, characterName)
        nameHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.nameFont)
    end
    
    if tagline and tagline ~= "" then
        taglineWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.taglineFont, tagline)
        taglineHeight = textManager:getFontHeight(NAMEPLATE_CONFIG.taglineFont)
    end
    
    -- Also calculate width for anonymity labels (use widest possible)
    local maskedWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, MC_Anonymity.Config.maskedName)
    local distantWidth = textManager:MeasureStringX(NAMEPLATE_CONFIG.nameFont, MC_Anonymity.Config.distantName)
    local maxNameWidth = math.max(nameWidth, maskedWidth, distantWidth)
    
    local width = math.max(maxNameWidth, taglineWidth) + 20  -- Padding
    local height = nameHeight + taglineHeight + NAMEPLATE_CONFIG.lineSpacing + 4
    
    local o = ISPanel:new(0, 0, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    -- Store real values
    o.realCharacterName = characterName
    o.realTagline = tagline
    -- Display values (updated in prerender based on anonymity)
    o.characterName = characterName
    o.tagline = tagline
    o.isAnonymous = false
    
    o.nameHeight = nameHeight
    o.taglineHeight = taglineHeight
    o.fontGeneration = NAMEPLATE_CONFIG.generation
    -- A panel is not visible until its first complete perception pass.
    o.currentAlpha = 0
    o.shouldRemove = false
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor = {r=0, g=0, b=0, a=0}
    
    -- LOS visibility tracking
    o.losVisible = false             -- Becomes true only after verified LOS
    o.losLastCheck = -LOS_CHECK_INTERVAL_MS
    o.losGraceStart = nil            -- When LOS was lost (nil = has LOS)
    o.isOwnPlayer = false            -- Set by showNameplate()
    
    return o
end

-- NAMEPLATE MANAGEMENT

local function removeNameplatePanel(panel, stage)
    if not panel then return true end
    panel.currentAlpha = 0
    panel.shouldRemove = true
    local removed = safeExec(function() panel:removeFromUIManager() end)
    if not removed then
        reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=" .. (stage or "panel-remove"))
    end
    return removed
end

local function showNameplate(player, username)
    if not player or type(username) ~= "string" or username == "" then
        reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE", "stage=show-identity")
        return false
    end

    local characterName = getCharacterName(player, username)
    local tagline = bioFeatureOn() and (bioCache[username] or "") or ""

    -- Check if we need to update existing panel
    local existing = activeNameplates[username]
    if not characterName or characterName == "" then
        if existing then
            removeNameplatePanel(existing, "identity-remove")
            activeNameplates[username] = nil
        end
        reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE",
            "stage=character-name")
        return false
    end

    if existing then
        -- A same-account re-roll can retain the same literal name/tagline.
        -- Object identity still changed, so never leave the panel attached to
        -- the previous character merely because its strings compare equal.
        if existing.player == player
            and existing.realCharacterName == characterName
            and existing.realTagline == tagline
        then
            return true  -- No change needed
        end
        -- Data changed, remove old panel
        removeNameplatePanel(existing, "replace-remove")
        activeNameplates[username] = nil
    end

    -- Get local player index for UIManager (0 for single player)
    local localPlayer = safeGet(function() return getPlayer() end, nil)
    local playerIndex = localPlayer and safeGet(function()
        return localPlayer:getPlayerNum()
    end, nil) or nil
    if not localPlayer or not isFiniteNumber(playerIndex) then
        reportNameplate("NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE",
            "stage=show-player-index")
        return false
    end

    -- Determine if this is the local player's own nameplate
    local localUsername = safeGet(function() return localPlayer:getUsername() end, nil)
    if type(localUsername) ~= "string" or localUsername == "" then
        reportNameplate("NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE",
            "stage=show-username")
        return false
    end

    -- Create new panel
    local panel = MC_NameplatePanel:new(player, characterName, tagline)
    panel.isOwnPlayer = (username == localUsername)
    panel:initialise()
    panel:addToUIManager(playerIndex)
    activeNameplates[username] = panel

    dbg("showNameplate: %s = '%s' / '%s'", username, characterName or "", tagline)
    return true
end

local function hideNameplate(username)
    if activeNameplates[username] then
        removeNameplatePanel(activeNameplates[username], "hide-remove")
        activeNameplates[username] = nil
        dbg("hideNameplate: %s", username)
    end
end

local function hideAllNameplates()
    for _, panel in pairs(activeNameplates) do
        removeNameplatePanel(panel, "hide-all-remove")
    end
    activeNameplates = {}
end

-- UPDATE LOOP

-- Track when we last requested a full sync (in ticks)
local ticksSinceSync = 999 -- Start high so we sync immediately
local SYNC_REQUEST_TICKS = 300 -- About 10 seconds at 30fps

local function updateNameplates()
    local bioEnabled = bioFeatureOn()
    local localPlayer = safeGet(function() return getPlayer() end, nil)
    if not localPlayer then
        hideAllNameplates()
        reportNameplate("NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE", "stage=update")
        return
    end

    local nameplatesEnabled =
        MC_Config.liveSandbox("NameplatesEnabled", false)

    if not nameplatesEnabled then
        hideAllNameplates()
        return
    end

    local players = safeGet(function() return getOnlinePlayers() end, nil)
    if not players then
        hideAllNameplates()
        reportNameplate("NAMEPLATE_ROSTER_UNAVAILABLE", "stage=roster")
        return
    end

    local count = safeGet(function() return players:size() end, nil)
    if not isFiniteNumber(count) or count < 0 or count ~= math.floor(count) then
        hideAllNameplates()
        reportNameplate("NAMEPLATE_ROSTER_UNAVAILABLE", "stage=roster-size")
        return
    end

    local seenUsernames = {}
    local missingData = false

    local localUsername = safeGet(function() return localPlayer:getUsername() end, nil)
    if type(localUsername) ~= "string" or localUsername == "" then
        hideAllNameplates()
        reportNameplate("NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE",
            "stage=update-username")
        return
    end

    ticksSinceSync = ticksSinceSync + 1

    for i = 0, count - 1 do
        local player = safeGet(function() return players:get(i) end, nil)

        if not player then
            hideAllNameplates()
            reportNameplate("NAMEPLATE_ROSTER_UNAVAILABLE",
                "stage=roster-entry")
            return
        end

        local aliveOk, isAlive = pcall(function() return player:isAlive() end)
        local username = safeGet(function() return player:getUsername() end, nil)
        if not aliveOk or type(isAlive) ~= "boolean"
            or type(username) ~= "string" or username == ""
        then
            hideAllNameplates()
            reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE",
                "stage=roster-identity")
            return
        end

        seenUsernames[username] = true

        -- Check if we're missing tagline data for this player
        if bioEnabled and bioCache[username] == nil then
            missingData = true
        end

        local isOwnPlayer = (username == localUsername)
        local hideOwnEnabled = MC_Config.liveSandbox("HideOwnNameplate", false)
        local shouldHideOwn = hideOwnEnabled and isOwnPlayer

        -- Respect game's visibility system (HidePlayersBehindYou etc).
        -- Staff have an unreliable IsVisibleToPlayer field, but prerender
        -- still verifies their invisibility, sprite/cell, distance and LOS.
        local isVisibleToLocal = true
        if not isOwnPlayer then
            local accessLevel = safeGet(function()
                return player:getAccessLevel()
            end, nil)
            if type(accessLevel) ~= "string" then
                hideAllNameplates()
                reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE",
                    "stage=access-level")
                return
            end

            local isStaff = accessLevel ~= "None" and accessLevel ~= ""
            if not isStaff then
                local visibilityOk, visibility = pcall(function()
                    return player.IsVisibleToPlayer
                end)
                if not visibilityOk or type(visibility) ~= "boolean" then
                    hideAllNameplates()
                    reportNameplate("NAMEPLATE_PERCEPTION_UNAVAILABLE",
                        "stage=engine-visibility")
                    return
                end
                isVisibleToLocal = visibility
            end
        end

        if isAlive and not shouldHideOwn and isVisibleToLocal then
            if not showNameplate(player, username) then
                hideNameplate(username)
            end
        else
            hideNameplate(username)
        end
    end

    -- If we're missing data and haven't requested recently, request now
    if bioEnabled and missingData and isClient()
        and ticksSinceSync > SYNC_REQUEST_TICKS then
        ticksSinceSync = 0
        MC_Bio.requestAllTaglines()
        dbg("updateNameplates: requested sync (missing data)")
    end
    
    -- Remove nameplates for players no longer online
    local staleUsernames = {}
    for username, panel in pairs(activeNameplates) do
        if not seenUsernames[username] or panel.shouldRemove then
            staleUsernames[#staleUsernames + 1] = username
        end
    end
    for _, username in ipairs(staleUsernames) do hideNameplate(username) end
end

-- PUBLIC API

function MC_Bio.getTagline(username)
    if not bioFeatureOn() then return nil end
    if not username then return nil end
    return bioCache[username]
end

function MC_Bio.requestTagline(username)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    if not username or username == "" then return end
    
    safeExec(function()
        sendClientCommand("MongooseChat", "BioLoad", {username = username})
    end)
    dbg("requestTagline: requested %s", username)
end

function MC_Bio.requestAllTaglines()
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    
    safeExec(function()
        sendClientCommand("MongooseChat", "BioSyncAll", {})
    end)
    dbg("requestAllTaglines: requested full sync")
end

function MC_Bio.saveTagline(tagline)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    
    local player = safeGet(function() return getPlayer() end, nil)
    if not player then
        reportIdentityMutation("IDENTITY_MUTATION_IDENTITY_UNAVAILABLE",
            "bio", "local-player")
        return false
    end
    
    tagline = sanitizeString(tagline or "")
    tagline = tagline:sub(1, NAMEPLATE_CONFIG.maxTaglineLength)
    
    if not beginIdentityMutation("bio", nil, tagline, "BioSave", {
        tagline = tagline,
    }) then
        dbg("saveTagline: failed to send to server")
        return false
    end
    dbg("saveTagline: awaiting durable commit acknowledgement")
    return true
end

-- CHARACTER-SHEET DESCRIPTION
-- A longer free-text description shown on the character sheet (not the
-- nameplate). Parallel to the tagline API above, over the Desc* commands.
-- Multi-line: newlines are preserved end to end (client, server, MC_Json).

-- Strip control chars but keep newlines, trim the ends, cap length. The server
-- re-sanitizes identically; this keeps the local cache honest on save.
local function sanitizeDescription(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:match("^%s*(.-)%s*$") or ""
    return text:sub(1, MAX_DESCRIPTION_LENGTH)
end

function MC_Bio.getDescription(username)
    if not bioFeatureOn() then return nil end
    if not username then return nil end
    return descCache[username]
end

function MC_Bio.requestDescription(username)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    if not username or username == "" then return end
    safeExec(function()
        sendClientCommand("MongooseChat", "DescLoad", {username = username})
    end)
    dbg("requestDescription: requested %s", username)
end

function MC_Bio.saveDescription(text)
    if not bioFeatureOn() then return false end
    if not isClient() then return end

    local player = safeGet(function() return getPlayer() end, nil)
    if not player then
        reportIdentityMutation("IDENTITY_MUTATION_IDENTITY_UNAVAILABLE",
            "description", "local-player")
        return false
    end

    text = sanitizeDescription(text or "")

    if not beginIdentityMutation("description", nil, text, "DescSave", {
        description = text,
    }) then
        dbg("saveDescription: failed to send to server")
        return false
    end
    dbg("saveDescription: awaiting durable commit acknowledgement")
    return true
end

-- PERSONAL NOTES (private remarks about ANOTHER player -- only you ever see
-- them). noteCache is keyed by target username = my note about them. Rides the
-- Note* commands, which the server keys strictly to the authenticated sender.

function MC_Bio.getNote(targetUsername)
    if not bioFeatureOn() then return nil end
    if not targetUsername then return nil end
    return noteCache[targetUsername]
end

function MC_Bio.requestNote(targetUsername)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    if not targetUsername or targetUsername == "" then return end
    safeExec(function()
        sendClientCommand("MongooseChat", "NoteLoad", {target = targetUsername})
    end)
end

function MC_Bio.saveNote(targetUsername, text)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    if type(targetUsername) ~= "string" or targetUsername == ""
        or #targetUsername > 64
        or targetUsername:find("[%c]") then
        reportIdentityMutation("IDENTITY_MUTATION_REQUEST_MALFORMED",
            "note", "target")
        return false
    end
    local player = safeGet(function() return getPlayer() end, nil)
    if not player then
        reportIdentityMutation("IDENTITY_MUTATION_IDENTITY_UNAVAILABLE",
            "note", "local-player")
        return false
    end

    text = sanitizeDescription(text or "")   -- same rules (multi-line, capped)

    if not beginIdentityMutation("note", targetUsername, text, "NoteSave", {
        target = targetUsername,
        note = text,
    }) then
        return false
    end
    dbg("saveNote: awaiting durable commit acknowledgement")
    return true
end

--[[
    Clear the tagline when a fresh character is created.

    Taglines are keyed by username server-side, so without this a re-rolled
    character walks around wearing the dead character's bio -- visible to
    everyone but the owner. Called from MC_ChatPanel's OnCreatePlayer
    detection (the same hook that wipes stale chat history).

    A fresh character has survived zero hours; an existing character
    relogging has already accrued time, so their tagline is left alone.

    @param player IsoPlayer the freshly created player object
]]
function MC_Bio.clearTaglineForFreshCharacter(player)
    if not bioFeatureOn() then return false end
    if not isClient() then return end
    if not player then return end

    local hours = safeGet(function() return player:getHoursSurvived() end, nil)
    if hours == nil or hours > 0 then return end

    local username = safeGet(function() return player:getUsername() end, nil)
    if not username then return end

    -- BioLoad is also the first authenticated server command on the ordinary
    -- fresh-character path. The server performs and verifies the complete
    -- identity wipe before dispatching this load, then returns the resulting
    -- empty state. Clients never authorize their own destructive wipe.
    safeExec(function()
        sendClientCommand("MongooseChat", "BioLoad", {username = username})
    end)

    -- Clear local presentation immediately while the authoritative load/wipe
    -- round-trip completes.
    bioCache[username] = ""
    nameCache[username] = nil
    hideNameplate(username)

    descCache[username] = ""

    -- The server's admission gate clears both directions of the note graph.
    -- The removed NoteClearAbout command was client-authorized and could be
    -- abused by an established character to erase other players' private
    -- observations.
    for k in pairs(noteCache) do noteCache[k] = nil end

    dbg("clearTaglineForFreshCharacter: cleared cached identity + tagline + description + notes for %s", username)
end

-- CONTEXT MENU

local function onViewBio(player)
    -- Open the character sheet: editable for your own character, read-only and
    -- anonymity-gated for anyone else. Lazy require keeps the sheet module off
    -- MC_Bio's load-order path.
    local ok, MC_CharacterSheet = pcall(require, "MC_CharacterSheet")
    if ok and MC_CharacterSheet then
        safeExec(function() MC_CharacterSheet.open(player) end)
    else
        dbg("onViewBio: MC_CharacterSheet unavailable")
    end
end

-- Find an IsoPlayer under the cursor: walks worldObjects -> square ->
-- movingObjects, returning the first IsoPlayer found.
--
-- Internal contract: shared with MC_LangAdmin's own
-- context-menu handlers, which mirrored this exact resolution before
-- converging on it -- a click can only ever resolve one way.
local function findClickedPlayer(worldObjects)
    for _, worldObj in ipairs(worldObjects or {}) do
        local square = safeGet(function() return worldObj:getSquare() end, nil)
        if square then
            local movingObjects = safeGet(function() return square:getMovingObjects() end, nil)
            if movingObjects then
                local objCount = safeGet(function() return movingObjects:size() end, 0)
                for j = 0, objCount - 1 do
                    local obj = safeGet(function() return movingObjects:get(j) end, nil)
                    if obj and instanceof(obj, "IsoPlayer") then
                        return obj
                    end
                end
            end
        end
    end
    return nil
end
MC_Bio._findClickedPlayer = findClickedPlayer

local function onContextMenu(player, context, worldObjects, test)
    if not bioFeatureOn() then return end
    if test then return true end

    local playerObj = safeGet(function() return getSpecificPlayer(player) end, nil)
    if not playerObj then return end

    local clickedPlayer = findClickedPlayer(worldObjects)

    if clickedPlayer then
        local username = safeGet(function() return clickedPlayer:getUsername() end, nil)
        if username then
            MC_Bio.requestTagline(username)
            MC_Bio.requestDescription(username)

            safeExec(function()
                if clickedPlayer == playerObj then
                    context:addOption("Character Sheet", clickedPlayer, onViewBio)
                else
                    context:addOption("View Character Sheet", clickedPlayer, onViewBio)
                end
            end)
        end
    end
end
MC_Bio._onContextMenuForTest = onContextMenu

-- SERVER COMMAND HANDLERS

local ACK_FAILURE_REASONS = {
    malformed_request = true,
    identity_unavailable = true,
    persistence_failed = true,
    internal_failure = true,
}
local MUTATION_FAILURE_MESSAGES = {
    malformed_request =
        "The server rejected that change as invalid. Your local record was not changed.",
    identity_unavailable =
        "The server could not verify your identity for that change. Your local record was not changed.",
    persistence_failed =
        "The server could not verify that change was stored. Your local record was not changed; an incident was recorded.",
    internal_failure =
        "The server could not confirm that change. Check the sheet before retrying; an incident was recorded.",
}

local function findPendingByToken(token)
    if pendingIdentityMutations.bio
        and pendingIdentityMutations.bio.token == token then
        return pendingIdentityMutations.bio
    end
    if pendingIdentityMutations.description
        and pendingIdentityMutations.description.token == token then
        return pendingIdentityMutations.description
    end
    for _, pending in pairs(pendingIdentityMutations.notes) do
        if pending.token == token then return pending end
    end
    return nil
end

local function showMutationFeedback(player, pending, committed, propagated)
    safeExec(function()
        if propagated ~= true then
            player:addLineChatElement(
                "Saved, but live identity sync failed. An incident was recorded.",
                1, 0.65, 0.2)
            return
        end
        if pending.kind == "bio" then
            if committed ~= "" then
                player:addLineChatElement("Tagline set: " .. committed,
                    0.5, 1, 0.5)
            else
                player:addLineChatElement("Tagline cleared.",
                    0.7, 0.7, 0.7)
            end
        elseif pending.kind == "description" then
            player:addLineChatElement(
                committed ~= "" and "Description saved."
                    or "Description cleared.",
                committed ~= "" and 0.5 or 0.7,
                committed ~= "" and 1 or 0.7,
                committed ~= "" and 0.5 or 0.7)
        else
            player:addLineChatElement(
                committed ~= "" and "Note saved." or "Note cleared.",
                committed ~= "" and 0.5 or 0.7,
                committed ~= "" and 1 or 0.7,
                committed ~= "" and 0.5 or 0.7)
        end
    end)
end

local function showMutationFailure(player, reason)
    if not player then return end
    safeExec(function()
        player:addLineChatElement(
            MUTATION_FAILURE_MESSAGES[reason]
                or "That change was not committed. Nothing was changed.",
            1, 0.4, 0.4)
    end)
end

local function handleIdentityMutationAck(args)
    if type(args) ~= "table" then
        reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
            "unknown", "args")
        return
    end
    local token = args.requestToken
    if not validMutationToken(token) then
        reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
            args.kind, "token")
        return
    end

    local pending = findPendingByToken(token)
    if not pending then
        reportIdentityMutation("IDENTITY_MUTATION_ACK_STALE",
            args.kind, "token")
        return
    end
    if args.kind ~= pending.kind or type(args.ok) ~= "boolean" then
        reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
            pending.kind, "shape")
        return
    end

    if not args.ok then
        if not ACK_FAILURE_REASONS[args.reason] then
            reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
                pending.kind, "reason")
            return
        end
        clearPending(pending.kind, pending.target, pending.token)
        showMutationFailure(
            safeGet(function() return getPlayer() end, nil),
            args.reason)
        dbg("identity mutation rejected: kind=%s reason=%s",
            pending.kind, args.reason)
        return
    end

    if args.reason ~= nil or type(args.propagated) ~= "boolean"
        or type(args.value) ~= "string"
        or args.value ~= pending.value
        or (pending.kind == "note" and args.propagated ~= true) then
        reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
            pending.kind, "commit-value")
        return
    end

    local player = safeGet(function() return getPlayer() end, nil)
    if not player then
        clearPending(pending.kind, pending.target, pending.token)
        reportIdentityMutation("IDENTITY_MUTATION_IDENTITY_UNAVAILABLE",
            pending.kind, "ack-player")
        return
    end

    local committed
    if pending.kind == "bio" then
        committed = sanitizeString(args.value)
        if committed ~= args.value
            or type(args.username) ~= "string" or args.username == ""
            or #args.username > 64 or args.username:find("[%c]") then
            reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
                pending.kind, "commit-shape")
            return
        end
    elseif pending.kind == "description" then
        committed = sanitizeDescription(args.value)
        if committed ~= args.value
            or type(args.username) ~= "string" or args.username == ""
            or #args.username > 64 or args.username:find("[%c]") then
            reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
                pending.kind, "commit-shape")
            return
        end
    else
        committed = sanitizeDescription(args.value)
        if committed ~= args.value or args.target ~= pending.target then
            reportIdentityMutation("IDENTITY_MUTATION_RESPONSE_MALFORMED",
                pending.kind, "commit-shape")
            return
        end
    end

    if pending.kind == "bio" or pending.kind == "description" then
        local username = safeGet(function() return player:getUsername() end, nil)
        if type(username) ~= "string" or username == ""
            or username ~= args.username then
            clearPending(pending.kind, pending.target, pending.token)
            reportIdentityMutation("IDENTITY_MUTATION_IDENTITY_UNAVAILABLE",
                pending.kind, "ack-username")
            return
        end
        if pending.kind == "bio" then
            bioCache[username] = committed
            hideNameplate(username)
        else
            descCache[username] = committed
        end
    else
        noteCache[pending.target] = committed
    end

    clearPending(pending.kind, pending.target, pending.token)
    showMutationFeedback(player, pending, committed, args.propagated)
    dbg("identity mutation committed: kind=%s", pending.kind)
end

-- OnServerCommand is a broadcast event: MC_Client's coordinator and this
-- identity module both receive every MongooseChat packet. Keep ownership in
-- one table so the coordinator can distinguish a genuinely unknown command
-- from one intentionally delegated to this listener.
local SERVER_COMMANDS = {
    IdentityMutationAck = true,
    BioUpdate           = true,
    BioData             = true,
    BioSyncAll          = true,
    DescUpdate          = true,
    DescData            = true,
    NoteData            = true,
    NoteAboutCleared    = true,
}

function MC_Bio.handlesServerCommand(command)
    return type(command) == "string" and SERVER_COMMANDS[command] == true
end

local function onServerCommand(module, command, args)
    if module ~= "MongooseChat" or not MC_Bio.handlesServerCommand(command) then
        return
    end
    if not bioFeatureOn() then return end
    if type(args) ~= "table" then
        if command == "IdentityMutationAck" then
            handleIdentityMutationAck(args)
        end
        return
    end
    
    if command == "IdentityMutationAck" then
        handleIdentityMutationAck(args)

    elseif command == "BioUpdate" then
        if args.username then
            local tagline = sanitizeString(args.tagline or "")
            bioCache[args.username] = tagline
            -- Force nameplate refresh for this player
            hideNameplate(args.username)
            dbg("BioUpdate: %s = '%s'", args.username, tagline)
        end
        
    elseif command == "BioData" then
        if args.username then
            local tagline = sanitizeString(args.tagline or "")
            bioCache[args.username] = tagline
            dbg("BioData: %s = '%s'", args.username, tagline)
        end
        
    elseif command == "BioSyncAll" then
        if args.bios and type(args.bios) == "table" then
            local syncCount = 0
            for username, tagline in pairs(args.bios) do
                if username and type(username) == "string" then
                    bioCache[username] = sanitizeString(tagline or "")
                    syncCount = syncCount + 1
                end
            end
            
            -- Mark all visible players as synced (empty string if no tagline)
            local players = getOnlinePlayers()
            if players then
                local count = safeGet(function() return players:size() end, 0)
                for i = 0, count - 1 do
                    local player = safeGet(function() return players:get(i) end, nil)
                    if player then
                        local username = safeGet(function() return player:getUsername() end, nil)
                        if username and bioCache[username] == nil then
                            bioCache[username] = ""
                        end
                    end
                end
            end
            
            dbg("BioSyncAll: received %d bios", syncCount)
        end

        -- Descriptions ride the same full-sync payload (additive field).
        if args.descriptions and type(args.descriptions) == "table" then
            for username, desc in pairs(args.descriptions) do
                if type(username) == "string" then
                    descCache[username] = sanitizeDescription(desc or "")
                end
            end
        end

    elseif command == "DescUpdate" then
        if args.username then
            descCache[args.username] = sanitizeDescription(args.description or "")
            dbg("DescUpdate: %s (%d chars)", args.username, #descCache[args.username])
        end

    elseif command == "DescData" then
        if args.username then
            descCache[args.username] = sanitizeDescription(args.description or "")
            dbg("DescData: %s (%d chars)", args.username, #descCache[args.username])
        end

    elseif command == "NoteData" then
        if args.target then
            noteCache[args.target] = sanitizeDescription(args.note or "")
        end

    elseif command == "NoteAboutCleared" then
        if args.target then
            noteCache[args.target] = nil
        end
    end
end
MC_Bio._onServerCommandForTest = onServerCommand

-- EVENT HANDLERS

local function OnGameStart()
    dbg("OnGameStart: requesting tagline sync")
    MC_Bio.requestAllTaglines()
end

-- INITIALIZATION

safeExec(function() Events.OnServerCommand.Add(onServerCommand) end)
safeExec(function() Events.OnFillWorldObjectContextMenu.Add(onContextMenu) end)
safeExec(function() Events.OnGameStart.Add(OnGameStart) end)

-- Update nameplates each tick
safeExec(function() Events.OnTick.Add(updateNameplates) end)

dbg("=== MC_Bio module loaded (Player Identity: nameplates, bio, notes) ===")

return MC_Bio
