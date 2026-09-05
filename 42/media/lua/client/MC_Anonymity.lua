--[[
================================================================================
    MongooseChat - Anonymity System
    
    Determines whether a speaker should be anonymous based on distance and
    face-covering clothing. Supports roleplay scenarios where players may
    not recognize distant speakers or masked individuals.
    
    RULES:
    - Within recognition range + unmasked -> Real name
    - Within recognition range + masked -> "A Masked Figure"
    - Beyond recognition range -> "Someone"
    - A readable empty appearance is an unmasked player, not an unsynced mask.
    - Truly unavailable/erroring mask state -> neutral "Someone"; only
      positive disguise evidence may claim "A Masked Figure".

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Incident = require("MC_Incident")

local dbg = MC_Core.debugger("ANON")

local MC_Anonymity = {}

local function safePlayerLabel(player)
    if not player then return "unavailable" end
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or username == nil or username == "" then return "unknown" end
    return tostring(username)
end

local function reportIncident(code, reason, player)
    local detail = "reason=" .. tostring(reason or "unknown")
    if player then
        detail = detail .. " speaker=" .. safePlayerLabel(player)
    end
    MC_Incident.report(code, detail)
end

-- CONFIGURATION

MC_Anonymity.Config = {
    -- Display names for anonymous speakers
    distantName = "Someone",
    maskedName = "A Masked Figure",

    -- Chat-panel name color for anonymous speakers. Overrides the speaker's
    -- signature color -- regulars can read a color at a glance, which would
    -- un-mask the mask.
    anonymousColor = {180, 180, 180},
    
    -- Legacy body-location policy, used only if neither the replicated
    -- ItemVisuals state nor the native disguise getter is available.
    --
    -- B42 fix (0.8.16.6): wornItem:getLocation() returns a real
    -- zombie.scripting.objects.ItemBodyLocation object (confirmed
    -- @UsedFromLua and extracted from the shipped jar, the same method the
    -- Deaf-trait fix used) -- vanilla lua NEVER compares it to a string; it
    -- always compares by `==` against the ItemBodyLocation global's own
    -- fields (e.g. ISInventoryPaneContextMenu.lua:
    -- `wornItem:getLocation() == ItemBodyLocation.SWEATER_HAT`). These
    -- names are field names on that global, resolved at check time --
    -- NOT the lowercase "base:mask"/"base:fullhat" strings from clothing
    -- item scripts' own BodyLocation= key (that key only exists at the
    -- item-script level; the runtime object never stringifies back to it).
    identityHidingSlots = {
        "MASK",       -- Bandanas, surgical masks, shemagh (face mode)
    },
    
    -- Specific items that hide identity even if not in standard slots
    -- Use full item type e.g. "Base.Hat_GasMask"
    alsoHidesIdentity = {
        "Base.Hat_BalaclavaFace",
        "Base.Hat_BalaclavaFull",
        "Base.Hat_GasMask",
        "Base.Hat_GasMask_nofilter",
    },
    
    -- Items that should NOT hide identity despite being in identity-hiding slots
    -- (empty by default, but available for server customization)
    neverHidesIdentity = {
        -- "Base.Hat_SurgicalMask_Blue",  -- Example: medical masks don't hide identity
    },
}

-- MASK CACHE
-- The authoritative fast path reads B42's replicated appearance/native state.
-- Cache invalidates on clothing changes and has a short expiry as a backstop.

-- Cache: key = player OnlineID, value = { isMasked = bool, timestamp = number }
MC_Anonymity.MaskCache = {}

-- Cache expiry in milliseconds (fallback if event doesn't fire)
MC_Anonymity.CACHE_EXPIRY_MS = 5000

local function getValidOnlineID(player)
    if not player then return nil end
    local ok, onlineID = pcall(function() return player:getOnlineID() end)
    if not ok
       or type(onlineID) ~= "number"
       or onlineID ~= onlineID
       or onlineID % 1 ~= 0
       or onlineID < 0
       or onlineID >= math.huge then
        return nil
    end
    return onlineID
end

--[[
    Update mask cache for a player. Called from OnClothingUpdated hook.
    @param player IsoGameCharacter
]]
function MC_Anonymity.updateMaskCache(player)
    if not player then return end
    
    local onlineID = getValidOnlineID(player)
    if onlineID == nil then
        reportIncident("ANON_MASK_CACHE_UNAVAILABLE",
            "online_id_unavailable_update_skipped", player)
        return
    end
    
    -- Force a fresh mask check
    local isMasked, isReliable = MC_Anonymity.checkMaskDirect(player)
    
    -- Only cache if reliable (clothing event should always have data, but be safe)
    if isReliable then
        MC_Anonymity.MaskCache[onlineID] = {
            isMasked = isMasked,
            timestamp = getTimestampMs()
        }
        dbg("updateMaskCache: player %s (ID=%d) -> masked=%s", 
            safePlayerLabel(player), onlineID, tostring(isMasked))
    else
        -- A clothing update supersedes any previously verified cache entry.
        -- Keeping it would let an unknown state inherit a stale answer until
        -- expiry, in either direction.
        MC_Anonymity.MaskCache[onlineID] = nil
        dbg("updateMaskCache: player %s (ID=%d) -> unreliable, not caching", 
            safePlayerLabel(player), onlineID)
    end
end

--[[
    Get cached mask status, or check directly if cache miss/stale.
    Only caches reliable results; unknown state keeps re-checking.
    @param player IsoPlayer
    @return boolean true only when positively masked
    @return boolean true when the mask state is reliable
]]
function MC_Anonymity.isMasked(player)
    if not player then
        return MC_Anonymity.checkMaskDirect(player)
    end
    
    local onlineID = getValidOnlineID(player)
    if onlineID == nil then
        -- Can't get ID, fall back to direct check (don't cache)
        reportIncident("ANON_MASK_CACHE_UNAVAILABLE",
            "online_id_unavailable_direct_check_used", player)
        return MC_Anonymity.checkMaskDirect(player)
    end
    
    local cached = MC_Anonymity.MaskCache[onlineID]
    local now = getTimestampMs()
    
    -- Use cache if fresh
    if cached and (now - cached.timestamp) < MC_Anonymity.CACHE_EXPIRY_MS then
        dbg("isMasked: using cached value for ID=%d -> %s", onlineID, tostring(cached.isMasked))
        return cached.isMasked, true
    end
    
    -- Cache miss or stale - check directly
    local isMasked, isReliable = MC_Anonymity.checkMaskDirect(player)
    
    -- Only cache if the result is reliable (we had actual clothing data)
    if isReliable then
        MC_Anonymity.MaskCache[onlineID] = {
            isMasked = isMasked,
            timestamp = now
        }
        dbg("isMasked: cached reliable result for ID=%d -> %s", onlineID, tostring(isMasked))
    else
        MC_Anonymity.MaskCache[onlineID] = nil
        dbg("isMasked: unreliable result for ID=%d (data not synced?), not caching", onlineID)
    end
    
    return isMasked, isReliable
end

-- HELPER FUNCTIONS

-- Calculate distance between two players in tiles
local function getDistanceBetween(player1, player2)
    if not player1 or not player2 then
        reportIncident("ANON_POSITION_UNAVAILABLE", "player_unavailable", nil)
        return 999
    end
    
    local ok, distance = pcall(function()
        local x1, y1 = player1:getX(), player1:getY()
        local x2, y2 = player2:getX(), player2:getY()
        return MC_Core.distance2D(x1, y1, x2, y2)
    end)
    
    if not ok or type(distance) ~= "number" or distance ~= distance
        or distance == math.huge or distance == -math.huge then
        reportIncident("ANON_POSITION_UNAVAILABLE",
            ok and "distance_invalid" or "distance_read_failed", player2)
        return 999
    end
    return distance
end

-- Check if item type is in the exception list
local function isInList(itemType, list)
    for _, entry in ipairs(list) do
        if entry == itemType then
            return true
        end
    end
    return false
end

-- MASK DETECTION

-- Read the appearance B42 actually replicates and renders for remote players.
-- Unlike getWornItems(), this collection remains authoritative on multiplayer
-- clients in 42.20. The policy preserves MongooseChat's historical MASK-slot
-- behaviour, while using the engine's disguise tags for full/combined outfits.
local function checkReplicatedDisguise(player)
    local ok, result, reliable, reason = pcall(function()
        if not ItemVisuals then
            return nil, false, "item_visuals_class_unavailable"
        end
        if not ItemTag
           or not ItemTag.IS_DISGUISE
           or not ItemTag.IS_LOWER_DISGUISE
           or not ItemTag.IS_UPPER_DISGUISE then
            return nil, false, "disguise_tags_unavailable"
        end
        if not ItemBodyLocation or not ItemBodyLocation.MASK then
            return nil, false, "mask_location_unavailable"
        end

        local visuals = ItemVisuals.new()
        if not visuals then
            return nil, false, "item_visuals_create_failed"
        end
        player:getItemVisuals(visuals)

        local size = visuals:size()
        if type(size) ~= "number" or size < 0 or size ~= math.floor(size) then
            return nil, false, "item_visuals_size_unavailable"
        end

        local hasLowerDisguise = false
        local hasUpperDisguise = false

        for i = 0, size - 1 do
            local visual = visuals:get(i)
            if visual then
                -- Vanilla's own calculation ignores visuals whose script item
                -- cannot be resolved (for example while a removed mod item is
                -- being discarded), so mirror that behaviour here.
                local scriptItem = visual:getScriptItem()
                if scriptItem then
                    local itemType = nil
                    local typeOk, fullName = pcall(function()
                        return scriptItem:getFullName()
                    end)
                    if typeOk and type(fullName) == "string" and fullName ~= "" then
                        itemType = fullName
                    else
                        local visualTypeOk, visualType = pcall(function()
                            return visual:getItemType()
                        end)
                        if visualTypeOk and type(visualType) == "string" and visualType ~= "" then
                            itemType = visualType
                        end
                    end

                    local excluded = itemType
                        and isInList(itemType, MC_Anonymity.Config.neverHidesIdentity)
                    if not excluded then
                        local location = scriptItem:getBodyLocation()
                        if location == ItemBodyLocation.MASK then
                            return true, true
                        end

                        if itemType
                           and isInList(itemType, MC_Anonymity.Config.alsoHidesIdentity) then
                            return true, true
                        end

                        if scriptItem:hasTag(ItemTag.IS_DISGUISE) then
                            return true, true
                        end
                        if scriptItem:hasTag(ItemTag.IS_LOWER_DISGUISE) then
                            hasLowerDisguise = true
                        end
                        if scriptItem:hasTag(ItemTag.IS_UPPER_DISGUISE) then
                            hasUpperDisguise = true
                        end
                    end
                end
            end
        end

        return hasLowerDisguise and hasUpperDisguise, true
    end)

    if not ok then
        return nil, false, "item_visuals_read_failed"
    end
    return result, reliable, reason
end

-- 42.20 exposes this public boolean directly to Lua. It is a cheap, reliable
-- fallback if replicated ItemVisuals cannot be inspected. Keep it under pcall
-- because 42.19 compatibility cannot assume the method exists.
local function checkNativeDisguise(player)
    local ok, result = pcall(function() return player:isDisguised() end)
    if ok and type(result) == "boolean" then
        return result, true
    end
    return nil, false, ok and "native_disguise_result_invalid"
        or "native_disguise_unavailable"
end

--[[
    Direct check if a player is wearing something that hides their identity.
    Called by the caching wrapper isMasked() - do not call directly.

    0.9.5 priority: replicated ItemVisuals (the remote appearance actually
    rendered by B42), then the native isDisguised boolean, then the historical
    WornItems scan solely for compatibility. A readable empty ItemVisuals list
    is a verified bare face. This matters because 42.20 remote WornItems can
    remain empty for an entire session even while ItemVisuals is populated.

    @param player IsoPlayer to check
    @return boolean true only when positive evidence says identity is hidden
    @return boolean true if the read was reliable (false = unknown, don't cache)
]]
function MC_Anonymity.checkMaskDirect(player)
    if not player then
        reportIncident("ANON_MASK_UNAVAILABLE", "player_unavailable", nil)
        return false, false
    end

    local visualResult, visualReliable, visualReason =
        checkReplicatedDisguise(player)
    if visualReliable == true and type(visualResult) == "boolean" then
        dbg("checkMaskDirect: replicated appearance for %s -> masked=%s",
            safePlayerLabel(player), tostring(visualResult))
        return visualResult, true
    end

    local nativeResult, nativeReliable, nativeReason =
        checkNativeDisguise(player)
    if nativeReliable == true and type(nativeResult) == "boolean" then
        dbg("checkMaskDirect: native disguise state for %s -> masked=%s",
            safePlayerLabel(player), tostring(nativeResult))
        return nativeResult, true
    end

    dbg("checkMaskDirect: modern appearance APIs unavailable for %s " ..
        "(visuals=%s, native=%s); using legacy WornItems",
        safePlayerLabel(player), tostring(visualReason), tostring(nativeReason))

    -- Compatibility fallback: wrap all Java calls in pcall for safety.
    local ok, result, reliable, unavailableReason = pcall(function()
        -- Get worn items container - this is always available on a valid player
        local wornItems = player:getWornItems()
        dbg("checkMaskDirect: wornItems=%s (type=%s) for %s",
            tostring(wornItems), type(wornItems), safePlayerLabel(player))
        if not wornItems then
            return false, false, "worn_items_nil"
        end

        -- Resolve the configured slot NAMES (see Config.identityHidingSlots)
        -- against the real ItemBodyLocation global's own fields -- a name
        -- with no matching field (typo, API drift, or the global itself
        -- unavailable) makes the entire read unverifiable.
        local hidingSlots = {}
        if not ItemBodyLocation then
            return false, false, "item_body_location_unavailable"
        end
        for _, slotName in ipairs(MC_Anonymity.Config.identityHidingSlots) do
            local slotObj = ItemBodyLocation[slotName]
            if not slotObj then
                return false, false, "hiding_slot_unavailable_" .. tostring(slotName)
            end
            hidingSlots[slotObj] = true
        end

        local sizeOk, size = pcall(function() return wornItems:size() end)
        if not sizeOk or type(size) ~= "number"
           or size < 0 or size ~= math.floor(size) then
            return false, false, "worn_items_size_unavailable"
        end
        dbg("checkMaskDirect: checking %d worn items for player %s", size,
            safePlayerLabel(player))

        -- Empty is a legitimate bare appearance. Treating it as an unsynced
        -- mask caused every bare-faced remote player on 42.20 to be mislabeled.
        if size == 0 then
            dbg("checkMaskDirect: wornItems empty for %s -> verified bare appearance",
                safePlayerLabel(player))
            return false, true
        end

        for i = 0, size - 1 do
            -- B42: get(i) returns a WornItem wrapper, not InventoryItem.
            local wornOk, wornItem = pcall(function() return wornItems:get(i) end)
            if not wornOk or not wornItem then
                return false, false, "worn_item_unavailable_" .. tostring(i)
            end

            -- WornItem is a tuple: getLocation() for slot, getItem() for the
            -- actual item. Every field is required: without the location we
            -- cannot test hiding slots; without the item/type we cannot test
            -- either exception list.
            local locOk, bodyLocation = pcall(function() return wornItem:getLocation() end)
            if not locOk or not bodyLocation then
                return false, false, "worn_item_location_unavailable_" .. tostring(i)
            end

            local itemOk, actualItem = pcall(function() return wornItem:getItem() end)
            if not itemOk or not actualItem then
                return false, false, "worn_item_value_unavailable_" .. tostring(i)
            end

            local typeOk, itemType = pcall(function() return actualItem:getFullType() end)
            if not typeOk or type(itemType) ~= "string" or itemType == "" then
                return false, false, "worn_item_type_unavailable_" .. tostring(i)
            end

            dbg("  [%d] %s @ slot present=true", i, tostring(itemType))

            -- Check 1: Is item in an identity-hiding slot? Object-identity
            -- compare against the real ItemBodyLocation field (see the
            -- function doc above) -- never stringified.
            if hidingSlots[bodyLocation] then
                -- Check if this specific item is exempt.
                if not isInList(itemType, MC_Anonymity.Config.neverHidesIdentity) then
                    dbg("checkMaskDirect: player %s has %s in a hiding slot -> MASKED",
                        safePlayerLabel(player), tostring(itemType))
                    return true, true  -- Masked, reliable
                end
            end

            -- Check 2: Is item in the alsoHidesIdentity exception list?
            if isInList(itemType, MC_Anonymity.Config.alsoHidesIdentity) then
                dbg("checkMaskDirect: player %s has exception item %s -> MASKED",
                    safePlayerLabel(player), tostring(itemType))
                return true, true  -- Masked, reliable
            end
        end

        dbg("checkMaskDirect: player %s has no identity-hiding items -> NOT MASKED",
            safePlayerLabel(player))
        return false, true  -- Not masked, reliable (we had data to check)
    end)

    if not ok then
        dbg("checkMaskDirect: error checking player -- state unknown (uncached): %s", tostring(result))
        reportIncident("ANON_MASK_UNAVAILABLE", "mask_check_error", player)
        return false, false
    end

    if reliable ~= true then
        reportIncident("ANON_MASK_UNAVAILABLE", unavailableReason or "mask_state_unreliable", player)
        return false, false
    end

    if type(result) ~= "boolean" then
        reportIncident("ANON_MASK_UNAVAILABLE", "mask_result_invalid", player)
        return false, false
    end

    return result, true
end

-- MAIN API

--[[
    Get the display name for a speaker from the local player's perspective.
    
    @param speakerPlayer IsoPlayer who is speaking (can be nil if not found)
    @param speakerUsername string username of the speaker
    @param realCharacterName string the speaker's actual character name
    @return string the name to display
    @return boolean true if the speaker is anonymous
    @return boolean true if the speaker is distant (beyond recognition range)
]]
function MC_Anonymity.getDisplayName(speakerPlayer, speakerUsername, realCharacterName)
    -- Check if anonymity system is enabled in sandbox settings
    if MC_Config.liveSandbox("AnonymityEnabled", true) == false then
        return realCharacterName, false, false
    end

    local localOk, localPlayer = pcall(function() return getPlayer() end)
    if not localOk or not localPlayer then
        reportIncident("ANON_LOCAL_PLAYER_UNAVAILABLE",
            localOk and "local_player_nil" or "local_player_read_failed", nil)
        return MC_Anonymity.Config.distantName, true, true
    end
    
    -- Speaking about yourself?
    local ok, localUsername = pcall(function() return localPlayer:getUsername() end)
    if not ok or type(localUsername) ~= "string" or localUsername == "" then
        reportIncident("ANON_LOCAL_PLAYER_UNAVAILABLE",
            "local_username_unavailable", nil)
        return MC_Anonymity.Config.distantName, true, true
    end
    if speakerUsername == localUsername then
        -- Self-indicator: if local player is masked, show them as masked to themselves
        -- This lets players know their disguise is working in chat too
        local selfMasked, selfMaskReliable = MC_Anonymity.isMasked(localPlayer)
        if selfMaskReliable ~= true then
            return MC_Anonymity.Config.distantName, true, false
        end
        if selfMasked then
            return MC_Anonymity.Config.maskedName, true, false  -- name, isAnonymous, isDistant
        end
        if type(realCharacterName) ~= "string" or realCharacterName == "" then
            reportIncident("ANON_MASK_UNAVAILABLE",
                "self_character_name_unavailable", localPlayer)
            return MC_Anonymity.Config.distantName, true, false
        end
        return realCharacterName, false, false
    end
    
    -- Can't find the speaker player object -- no mask or distance to check
    -- against. Investigated (wave-3): getDisplayName's other two callers
    -- (MC_Bio's nameplate loop, MC_CharacterSheet.open) both guard for and
    -- only ever pass an already-resolved player object, never nil -- this
    -- branch exists solely for MC_Client.onChatMessage's
    -- getPlayerByUsername(msgData.username) lookup, which CAN be nil for a
    -- genuine remote speaker (within the server's own say/yell range, just
    -- not yet streamed to this client). That is an unverified remote
    -- identity. Keep it anonymous without claiming a mask we cannot observe.
    if not speakerPlayer then
        dbg("getDisplayName: no player object for %s -> neutral anonymous name", speakerUsername)
        reportIncident("ANON_MASK_UNAVAILABLE", "speaker_player_unavailable", nil)
        return MC_Anonymity.Config.distantName, true, false
    end
    
    -- Check if player is visible (game's native visibility system)
    -- B42: Use checkCanSeeClient() which handles depth buffer, vision cones, 
    -- ghost mode, and faction visibility. IsVisibleToPlayer is deprecated.
    local visOk, canSee = pcall(function() 
        return localPlayer:checkCanSeeClient(speakerPlayer)
    end)
    dbg("getDisplayName: %s visibility check: visOk=%s, canSee=%s (type=%s)",
        speakerUsername, tostring(visOk), tostring(canSee), type(canSee))
    -- Not visible, OR the visibility check itself errored: either way we
    -- can't confirm the speaker is recognizable, so both resolve anonymous.
    -- An errored read fails closed here exactly like checkMaskDirect's own
    -- errored Java calls do, rather than falling through to the distance/
    -- mask checks below on a visibility state we never actually verified.
    if not visOk or type(canSee) ~= "boolean" then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            not visOk and "visibility_read_failed" or "visibility_not_confirmed",
            speakerPlayer)
        dbg("getDisplayName: %s visibility is unavailable -> '%s'",
            speakerUsername, MC_Anonymity.Config.distantName)
        return MC_Anonymity.Config.distantName, true, true
    end
    if not canSee then
        dbg("getDisplayName: %s is not visible to local player -> '%s'", 
            speakerUsername, MC_Anonymity.Config.distantName)
        return MC_Anonymity.Config.distantName, true, true
    end
    
    -- Check z-level (different floors = can't recognize)
    local zOk1, localZ = pcall(function() return localPlayer:getZ() end)
    local zOk2, speakerZ = pcall(function() return speakerPlayer:getZ() end)
    if not zOk1 or not zOk2 or type(localZ) ~= "number"
        or type(speakerZ) ~= "number" or localZ ~= localZ or speakerZ ~= speakerZ then
        reportIncident("ANON_POSITION_UNAVAILABLE",
            "z_level_unavailable", speakerPlayer)
        return MC_Anonymity.Config.distantName, true, true
    end
    if math.floor(localZ) ~= math.floor(speakerZ) then
        dbg("getDisplayName: %s is on different floor (z=%d vs %d) -> '%s'", 
            speakerUsername, math.floor(speakerZ), math.floor(localZ), MC_Anonymity.Config.distantName)
        return MC_Anonymity.Config.distantName, true, true
    end
    
    -- Calculate distance
    local distance = getDistanceBetween(localPlayer, speakerPlayer)

    -- Recognition range tracks the live authoritative SayRange. A fixed
    -- fallback could be larger than the server's configured range and reveal
    -- identity at a distance the owner explicitly disallowed, so uncertainty
    -- resolves to anonymous rather than consuming the substitute.
    local recognitionRange, rangeAuthoritative =
        MC_Config.liveSandbox("SayRange", 0)
    if rangeAuthoritative ~= true
       or type(recognitionRange) ~= "number"
       or recognitionRange ~= recognitionRange
       or recognitionRange < 0
       or recognitionRange <= -math.huge
       or recognitionRange >= math.huge then
        return MC_Anonymity.Config.distantName, true, true
    end
    local inRange = distance <= recognitionRange
    
    dbg("getDisplayName: %s at distance %.1f (range=%d, inRange=%s)",
        speakerUsername, distance, recognitionRange, tostring(inRange))
    
    -- Beyond recognition range = "Someone"
    if not inRange then
        dbg("getDisplayName: %s is distant -> '%s'", 
            speakerUsername, MC_Anonymity.Config.distantName)
        return MC_Anonymity.Config.distantName, true, true  -- name, isAnonymous, isDistant
    end
    
    -- Within range, but mask state unreadable = neutral anonymous identity.
    -- Only a reliable positive result may claim that the speaker is masked.
    local speakerMasked, speakerMaskReliable = MC_Anonymity.isMasked(speakerPlayer)
    if speakerMaskReliable ~= true then
        dbg("getDisplayName: %s mask state unavailable -> '%s'",
            speakerUsername, MC_Anonymity.Config.distantName)
        return MC_Anonymity.Config.distantName, true, false
    end

    -- Within range and positively masked = "A Masked Figure"
    if speakerMasked then
        dbg("getDisplayName: %s is masked -> '%s'", 
            speakerUsername, MC_Anonymity.Config.maskedName)
        return MC_Anonymity.Config.maskedName, true, false  -- name, isAnonymous, isDistant
    end
    
    -- Within range and unmasked = real name
    if type(realCharacterName) ~= "string" or realCharacterName == "" then
        reportIncident("ANON_MASK_UNAVAILABLE",
            "character_name_unavailable", speakerPlayer)
        return MC_Anonymity.Config.distantName, true, false
    end
    dbg("getDisplayName: %s is recognizable -> '%s'",
        speakerUsername, realCharacterName)
    return realCharacterName, false, false  -- name, isAnonymous, isDistant
end

-- SIGHT -- signed-modality display gate + the Deaf
-- reception ladder. Reuses the exact LOS + z-level primitive getDisplayName
-- already runs (checkCanSeeClient + the z-floor compare), pulled out here
-- so a caller that needs a plain "can I see them" boolean -- not a full
-- name resolution -- doesn't re-derive the pcall/fail-closed dance.
--
-- TRUST NOTE: this is a CLIENT-side read, the only place the
-- checkCanSeeClient primitive exists -- the exact same documented tamper
-- class as every mask/distance check elsewhere in this module. A modified
-- client could lie about what it can see. Server-side range gating
-- (routeProximity's existing channel ranges) is the only enforcement that
-- can't be spoofed; sight is a display-layer refinement on top of it, not
-- a security boundary.

--[[
    Can the local player currently see `otherPlayer`? Fails CLOSED (false)
    on no local player, no otherPlayer, an errored Java call, or a
    different floor -- "cannot verify" always means "not shown", never
    "shown by default."
    @return boolean
]]
function MC_Anonymity.canSee(otherPlayer)
    if not otherPlayer then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            "speaker_unavailable", nil)
        return false
    end
    local localOK, localPlayer = pcall(getPlayer)
    if not localOK or not localPlayer then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            localOK and "local_player_unavailable" or
                "local_player_lookup_failed", otherPlayer)
        return false
    end

    -- M5 fix: self-exemption, same precedent as getDisplayName's own
    -- explicit self-case above ("Speaking about yourself?") -- a signer
    -- must always see their own signs. checkCanSeeClient is built to
    -- answer "can I see THAT OTHER player"; whether it behaves sanely when
    -- asked about yourself is untested on a dedicated server.
    -- Comparing usernames sidesteps the question rather than
    -- trusting an edge case of a primitive built for someone else. An
    -- errored username read falls through to the normal check below.
    local selfOk, isSelf = pcall(function()
        return otherPlayer:getUsername() == localPlayer:getUsername()
    end)
    if selfOk and isSelf then return true end
    if not selfOk then
        -- Visibility can still be established by the engine primitive, but
        -- this is a real fallback from the self-exemption and must be visible.
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            "self_identity_check_failed", otherPlayer)
    end

    local visOk, canSee = pcall(function()
        return localPlayer:checkCanSeeClient(otherPlayer)
    end)
    if not visOk then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            "sight_read_failed", otherPlayer)
        return false
    end
    if type(canSee) ~= "boolean" then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            "sight_value_invalid", otherPlayer)
        return false
    end
    -- A verified false is ordinary lack of line of sight, not an incident.
    if not canSee then return false end

    local zOk1, localZ = pcall(function() return localPlayer:getZ() end)
    local zOk2, otherZ = pcall(function() return otherPlayer:getZ() end)
    local zValuesValid = zOk1 and zOk2
        and type(localZ) == "number" and localZ == localZ
        and localZ > -math.huge and localZ < math.huge
        and type(otherZ) == "number" and otherZ == otherZ
        and otherZ > -math.huge and otherZ < math.huge
    if not zValuesValid then
        reportIncident("ANON_VISIBILITY_UNAVAILABLE",
            (zOk1 and zOk2) and "z_value_invalid" or "z_read_failed",
            otherPlayer)
        return false
    end
    return math.floor(localZ) == math.floor(otherZ)
end

--[[
    Is the LOCAL player Deaf (base:deaf trait)?
    (dedicated-server incident, 0.8.16.6): the prior accessor --
    `player:getTraits():contains("Deaf")` -- crashed on real Kahlua
    (getTraits() is not a real instance method PZ exposes for a
    membership check; it doesn't appear anywhere in vanilla lua) and the
    resulting error escaped this function's own pcall, propagating all
    the way up through deafReception/onChatMessage to the visible client
    error every hearing player saw as a "..." bubble.

    The real, vanilla-proven idiom is `character:hasTrait(CharacterTrait.X)`
    -- used dozens of times across vanilla lua (ISBuildAction, ISHandcraft-
    Action, ISVehicleMenu, forageSystem, ISCraftAction, ...) with NO extra
    guarding, meaning the engine treats it as always-safe to call. Verified
    directly against the shipped projectzomboid.jar:
    zombie.scripting.objects.CharacterTrait carries a DEAF field whose
    string value is "Deaf" -- the exact same PascalCase pattern as
    HANDY -> "Handy". `CharacterTrait.DEAF` is required; an unavailable
    global is API uncertainty, not permission to assume hearing.

    0.9 stable contract: uncertainty is not evidence of hearing. Returns
    `(true, false)` on a missing player/global, invalid API result, or error:
    the first value conservatively suppresses existing boolean-only callers
    (notably radio), while the reliability value lets deafReception distinguish
    verified Deaf from an unknown/no-content state.
    @return boolean true when Deaf or when hearing status is unavailable
    @return boolean true only when the trait read was verified
]]
function MC_Anonymity.localPlayerIsDeaf()
    local ok, isDeaf, reliable, unavailableReason = pcall(function()
        local p = getPlayer()
        if not p then return true, false, "local_player_unavailable" end
        if not CharacterTrait or not CharacterTrait.DEAF then
            return true, false, "character_trait_unavailable"
        end
        local traitResult = p:hasTrait(CharacterTrait.DEAF)
        if type(traitResult) ~= "boolean" then
            return true, false, "has_trait_result_invalid"
        end
        return traitResult, true
    end)
    if not ok then
        dbg("localPlayerIsDeaf: trait check errored, suppressing spoken content: %s", tostring(isDeaf))
        reportIncident("DEAF_TRAIT_UNAVAILABLE", "trait_check_error", nil)
        return true, false
    end
    if reliable ~= true then
        reportIncident("DEAF_TRAIT_UNAVAILABLE",
            unavailableReason or "trait_state_unreliable", nil)
        return true, false
    end
    return isDeaf == true, true
end

--[[
    How should a Deaf local player perceive a SPOKEN message from
    `speakerPlayer`? Returns { mode = "full"|"nothing"|"presence"|"lipread" }:
      "full"     -- not Deaf, or the sandbox has the trait's enforcement off
                    -- unaffected, normal spoken-language rendering applies.
      "nothing"  -- Deaf and no sight of the speaker at all (no LOS, wrong
                    floor, through a wall) -- speech through walls is nothing.
      "presence" -- Deaf, sight confirmed, but beyond conversational range
                    (AddressedDistance) -- real lipreading dies with distance.
      "lipread"  -- Deaf, sight confirmed, within conversational range --
                    caller gaps the message (see shared/MC_Lipread.lua).
    Never "improvable to full" -- lipreading stays lossy at any distance
    inside range; this ladder has no state that climbs toward comprehension.

    OUTER SAFETY NET: the whole ladder runs inside its own pcall. Any trait
    uncertainty or escaped error resolves to `nothing`, never full hearing,
    and emits DEAF_TRAIT_UNAVAILABLE. Explicit DeafTraitEnforced=false is an
    operator policy and remains the sole uncertainty-independent `full` path.
]]
function MC_Anonymity.deafReception(speakerPlayer)
    local ok, result = pcall(function()
        if MC_Config.liveSandbox("DeafTraitEnforced", true) == false then
            return { mode = "full" }
        end
        local isDeaf, traitReliable = MC_Anonymity.localPlayerIsDeaf()
        if traitReliable ~= true then
            return { mode = "nothing", uncertain = true }
        end
        if not isDeaf then
            return { mode = "full" }
        end
        if not MC_Anonymity.canSee(speakerPlayer) then
            return { mode = "nothing" }
        end
        local localPlayer = getPlayer()
        local distance = getDistanceBetween(localPlayer, speakerPlayer)
        local addressedDistance, addressedAuthoritative =
            MC_Config.liveSandbox("AddressedDistance", 0)
        if addressedAuthoritative ~= true
           or type(addressedDistance) ~= "number"
           or addressedDistance ~= addressedDistance
           or addressedDistance < 0
           or addressedDistance <= -math.huge
           or addressedDistance >= math.huge then
            return { mode = "nothing", uncertain = true }
        end
        if distance <= addressedDistance then
            return { mode = "lipread" }
        end
        return { mode = "presence" }
    end)
    if not ok then
        dbg("deafReception: errored, suppressing spoken content: %s", tostring(result))
        reportIncident("DEAF_TRAIT_UNAVAILABLE", "reception_check_error", nil)
        return { mode = "nothing", uncertain = true }
    end
    return result
end

--[[
    Convenience function to transform message data in place.
    Modifies msgData.characterName if the speaker should be anonymous.
    
    @param msgData table with username, characterName fields
    @param speakerPlayer IsoPlayer who is speaking (optional, will lookup if nil)
    @return boolean true if the name was anonymized
]]
function MC_Anonymity.anonymizeMessageData(msgData, speakerPlayer)
    if not msgData or not msgData.username then return false end
    
    local displayName, isAnonymous, isDistant = MC_Anonymity.getDisplayName(
        speakerPlayer,
        msgData.username,
        msgData.characterName or msgData.username
    )
    
    if isAnonymous then
        msgData.characterName = displayName
        msgData.isAnonymous = true
        msgData.isDistant = isDistant  -- true = hide avatar, false = masked but visible
        -- Neutralize the signature name color too (masked and distant alike):
        -- keeping it would let regulars identify masks at a glance.
        msgData.playerColor = MC_Anonymity.Config.anonymousColor
    end

    return isAnonymous
end

--[[
    Radio identity policy for the 0.9.x family.

    Radio messages keep the server-supplied character name without mask,
    distance, or cross-cell substitution. The earlier partial radio-anonymity
    pass produced inconsistent identities depending on whether the speaker's
    player object happened to be streamed on a listener's client. A complete,
    Radio anonymity is not handled here.

    Keep this compatibility function as an explicit no-op so every current
    caller shares the same policy and cannot silently reintroduce one branch of
    the unfinished behaviour.

    @param msgData table with username, characterName fields
    @param speakerPlayer IsoPlayer who is speaking (unused in 0.9.x)
    @return boolean always false in 0.9.x
]]
function MC_Anonymity.anonymizeRadioMessageData(msgData, speakerPlayer)
    return false
end

-- EVENT HOOKS

--[[
    Hook OnClothingUpdated to keep mask cache fresh.
    This fires whenever any character's clothing changes (equip, unequip, dirty/bloody).
    Much more efficient than polling getWornItems() every frame.
]]
local function onClothingUpdated(character)
    if not character then return end
    
    -- Update cache for this character
    MC_Anonymity.updateMaskCache(character)
end

-- Register the hook
Events.OnClothingUpdated.Add(onClothingUpdated)
dbg("OnClothingUpdated hook registered for mask cache")

return MC_Anonymity
