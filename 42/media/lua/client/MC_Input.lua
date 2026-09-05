--[[
================================================================================
    MongooseChat - Chat Input Handler
    
    Intercepts vanilla chat input and routes messages through MongooseChat.
    Handles command prefix parsing, channel selection, and typing indicators.
    
    KEYBOARD HANDLING:
    - Enter/Toggle Chat: Focus chat input
    - Slash: Focus chat with "/" prefix for commands
    - Escape: Unfocus chat (B42 fix included)
    - Q (Shout): Vanilla Callout disabled; localized line routed through MC
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Radio = require("MC_Radio")
local MC_InputHistory = require("MC_InputHistory")
local MC_KeyBindings = require("MC_KeyBindings")
local MC_Theme = require("MC_Theme")
local MC_Incident = require("MC_Incident")
local MC_StringUtils = require("MC_StringUtils")
local MC_API = require("MC_API")

local dbg = MC_Core.debugger("INPUT")

-- Presentation and input-widget failures must not disappear into DEBUG-only
-- output: they can leave the player believing a command was sent, an input
-- limit was applied, or focus was released when it was not.
local function safeExec(operation, fn)
    local ok, err = MC_Core.safeExec(fn)
    if not ok then
        dbg("safeExec failed (%s): %s", tostring(operation), tostring(err))
        MC_Incident.report("CHAT_INPUT_OPERATION_FAILED",
            "operation=" .. tostring(operation or "unknown"))
    end
    return ok
end

local MC_Input = {}
MC_Input._safeExec = safeExec

-- ChatWindowEnabled is also the ownership switch for the vanilla input and
-- Callout seams.
local function chatSurfaceOn()
    return MC_Config.featureOn("ChatWindowEnabled")
end

local function escapeCancelsFocus()
    return chatSurfaceOn() and MC_Theme.access().escapeCancelsFocus ~= false
end

-- Our own chat window, when it is up. Defined here, at the top, because
-- closures built further down (the unfocus and focus seams) call it: a
-- local declared after them would resolve to a nil global instead --
-- exactly the "Object tried to call nil in mcUnfocus" that left chat
-- stuck focused and ate every key. Lazy require: MC_ChatWindow pulls
-- MC_Input back in on submit, so a module-scope require would cycle.
local function mcWindow()
    local ok, win = pcall(function()
        return require("MC_ChatWindow").instance
    end)
    if ok then return win end
    return nil
end

local function seedRememberedPrefix(entry)
    if not entry then return end
    pcall(function()
        local text = entry:getText() or ""
        if text == "" and MC_Input.lastSlashPrefix ~= "" then
            entry:setText(MC_Input.lastSlashPrefix)
            text = MC_Input.lastSlashPrefix
        end
    end)
end

function MC_Input.armFreshFocus(entry)
    if not entry then return end
    entry.mcFreshFocusFirstEdit = true
    entry.mcFreshFocusText = entry:getText() or ""
end

function MC_Input.disarmFreshFocus(entry)
    if not entry then return end
    entry.mcFreshFocusFirstEdit = false
    entry.mcFreshFocusText = nil
    entry.mcWholeLineSelected = false
    entry.mcNeedsSelectOnFocus = false
end

function MC_Input.setFreshSlash(entry)
    if not entry then return false end
    MC_Input.disarmFreshFocus(entry)
    local ok = pcall(function()
        entry:setText("/")
        MC_Input.disarmFreshFocus(entry)
        if type(entry.setCursorPos) == "function" then entry:setCursorPos(1) end
    end)
    return ok
end

local function finishFocusSelection(entry)
    if not entry then return false end
    if entry.mcNeedsSelectOnFocus ~= true then
        return entry.mcWholeLineSelected == true
    end
    local selected = false
    if MC_Theme.access().selectTextOnFocus ~= false
        and type(entry.mcSelectWholeLine) == "function" then
        local ok, result = pcall(entry.mcSelectWholeLine, entry)
        selected = ok and result == true
    end
    entry.mcNeedsSelectOnFocus = false
    entry.mcWholeLineSelected = selected
    if not selected and type(entry.setCursorPos) == "function" then
        pcall(entry.setCursorPos, entry,
            MC_StringUtils.utf8len(entry:getText() or ""))
    end
    MC_Input.armFreshFocus(entry)
    return selected
end
-- STATE

-- Current default channel (used when no prefix specified)
MC_Input.channel = "say"

-- Vanilla remembers the last chat-stream command (for example "/all ") and
-- restores only that prefix the next time chat opens. MC intercepts before
-- vanilla can update lastChatCommand, so it owns the equivalent session state.
MC_Input.lastSlashPrefix = ""

-- Typing broadcast throttle
local lastTypingBroadcast = 0
local TYPING_THROTTLE_MS = 1000

-- Hook state (submit-boundary state lives with the boundary itself below)
local pendingUnfocus = false
-- Escape is not the same operation as submit/ordinary blur.  It captures the
-- exact entry/tab at key time, then applies on the safe tick seam.  Keeping it
-- separate prevents a held key or a second Escape seam from clearing whichever
-- tab happens to be active a frame later.
local pendingEscapeCancellation = nil
local escapeCycleActive = false
local scheduleEscapeCancellation
local lastMessageSentTime = 0  -- Cooldown to prevent Enter from reopening chat after send
local ENTER_COOLDOWN_MS = 200  -- Ignore Enter for this long after sending

-- Vanilla may fire OnConnected before ISChat.createChat. Until
-- OnChatWindowInit says the widget is expected, absence is a wait state, not
-- a broken input boundary.
local chatWindowExpected = false
local inputLimitPending = true
local inputLimitAppliedEntry = nil
local inputLimitAppliedValue = nil

-- Vanilla's Q key is not a chat-input seam. B42 dispatches it through
-- IsoGameCharacter:Callout(), including a zero-argument overload that does
-- NOT honor setCanShout(false) for vehicle passengers / controller wheels.
-- Keep the Java gate down and replace those two shipped zero-argument Lua
-- call sites; every actual line is then sent through MC_Server below.
local qVehicleWrapper = nil
local qVehicleHooked = false
local qDPadWrapper = nil
local qDPadHooked = false
local qEmotePressWrapper = nil
local qEmotePressHooked = false
local qEmoteReleaseWrapper = nil
local qEmoteReleaseHooked = false
local qEmoteActionWrapper = nil
local qEmoteActionHooked = false
local qFootPress = nil
local qSuppressedPlayers = setmetatable({}, { __mode = "k" })
local Q_RADIAL_HOLD_MS = 450

-- Command history: a per-session ring of SENT messages (~50 deep, no
-- duplicates-in-a-row). Session-memory only -- NOT persisted, fresh every
-- login. Cycle/dedup/cap logic lives in MC_InputHistory.lua (pure,
-- offline-testable); this module is thin glue over it.
local inputHistory = MC_InputHistory.new()

-- COMMAND PREFIX PARSING

-- Map of command prefixes to channel names.
-- NOTE: /admin is INTENTIONALLY NOT HERE (as of 0.8.0). Vanilla PZ has its own
-- admin chat pipeline with built-in access-level filtering on the server side
-- and a vanilla-rendered Admin tab. We let those prefixes fall through to the
-- engine so admin messages stay access-controlled and stay in the Admin tab.
local PREFIXES = {
    {"/whisper ", "whisper"},
    {"/w ", "whisper"},
    {"/say ", "say"}, 
    {"/s ", "say"},
    {"/yell ", "yell"},
    {"/y ", "yell"},
    {"/me ", "emote"},
    {"/em ", "emote"},
    {"/e ", "emote"},
    {"/do ", "do"},
    {"/event ", "event"},
    {"/announce ", "announce"},
    {"/you ", "mood"},
    {"/ooc ", "ooc"},
    {"/o ", "ooc"},
    {"/all ", "all"},
    {"/low ", "low"},
    {"/l ", "low"},
    {"/tell ", "tell"},
    {"/t ", "tell"},
    {"/faction ", "faction"},
    {"/f ", "faction"},
    {"/safehouse ", "safehouse"},
    {"/sh ", "safehouse"},
    {"/bio ", "bio"},
    {"/tagline ", "bio"},
    {"/roll ", "roll"},
    {"/r ", "roll"},
}

-- Optional MC surfaces must stop claiming their command words when a host
-- hands them to another mod. These reads are live so a switch takes effect
-- without rebuilding the chat box or its hint renderer.
local function optionalChannelOn(channel)
    if channel == "bio" then
        return MC_Config.featureOn("BioEnabled")
    end
    if channel == "ooc" or channel == "roll" then
        return MC_Config.optionalOn("OOCEnabled",
            not (MC_Config.Channels and MC_Config.Channels.oocEnabled == false))
    end
    if channel == "all" then
        return MC_Config.optionalOn("ALLEnabled",
            not (MC_Config.Channels and MC_Config.Channels.allEnabled == false))
    end
    return true
end

local function optionalCommandOn(command)
    if command == "/bio" or command == "/tagline" then
        return optionalChannelOn("bio")
    end
    if command == "/ooc" or command == "/o"
        or command == "/roll" or command == "/r" then
        return optionalChannelOn("ooc")
    end
    if command == "/all" then return optionalChannelOn("all") end
    return true
end

-- Inline command discovery for every slash command this input boundary accepts,
-- including aliases and selected vanilla commands worth discovering. `usage` is ghost text and
-- is never inserted into or submitted from the entry box.
local COMMAND_HINTS = {
    -- Put the common global OOC command ahead of the vanilla admin stream so
    -- the shared "/a" prefix predicts /all; later characters immediately
    -- refine it to /admin when the player types "/ad".
    {command = "/all", usage = "<message> -- sends server-wide OOC."},
    {command = "/admin", usage = "<message> -- vanilla staff chat."},
    {command = "/announce", usage = "<message> -- a server-wide announcement (admins)."},
    {command = "/setaccesslevel", usage = "<username> <level> -- set a user's access level."},
    {command = "/whisper", usage = "<message> -- heard only right beside you."},
    {command = "/w", usage = "<message> -- short for /whisper."},
    {command = "/say", usage = "<message> -- a normal speaking voice."},
    {command = "/s", usage = "<message> -- short for /say."},
    {command = "/yell", usage = "<message> -- a shout that carries."},
    {command = "/y", usage = "<message> -- short for /yell."},
    {command = "/low", usage = "<message> -- kept low for those close by."},
    {command = "/l", usage = "<message> -- short for /low."},
    {command = "/me", usage = "<action> -- describe what your character does."},
    {command = "/em", usage = "<action> -- short for /me."},
    {command = "/e", usage = "<action> -- short for /me."},
    {command = "/do", usage = "<text> -- narrate the nearby scene."},
    {command = "/event", usage = "<narration> -- storyteller narration (admins)."},
    {command = "/you", usage = "<feeling> -- a private mood note."},
    {command = "/ooc", usage = "<message> -- nearby out-of-character chat."},
    {command = "/o", usage = "<message> -- short for /ooc."},
    {command = "/tell", usage = "<name> <message> -- address someone directly."},
    {command = "/t", usage = "<name> <message> -- short for /tell."},
    {command = "/faction", usage = "<message> -- your faction chat."},
    {command = "/f", usage = "<message> -- short for /faction."},
    {command = "/safehouse", usage = "<message> -- your safehouse chat."},
    {command = "/sh", usage = "<message> -- short for /safehouse."},
    {command = "/bio", usage = "<text> -- set the line beneath your name."},
    {command = "/tagline", usage = "<text> -- set the line beneath your name."},
    {command = "/roll", usage = "<dice> -- for example 2d6 or d20+3."},
    {command = "/r", usage = "<dice> -- short for /roll."},
    {command = "/hue", usage = "<#RRGGBB|reset> -- set your speaking colour."},
    {command = "/lang", usage = "-- view or manage languages."},
    {command = "/lex", usage = "-- view words you have picked up."},
    {command = "/comp", usage = "-- view language comprehension."},
    {command = "/forget", usage = "-- start your character's languages over."},
    {command = "/ll", usage = "-- switch back to your previous language."},
    {command = "/mc", usage = "help -- list MongooseChat commands."},
}

local function commandHintForText(text)
    if type(text) ~= "string" or text:sub(1, 1) ~= "/"
        or #text < 2 or text:find("%s") then
        return nil
    end

    local lower = text:lower()
    -- A finished command shows its own usage, and is never treated as the
    -- beginning of a longer one. For example /l is already the low-voice
    -- alias, so it explains /low rather than turning into /lang or /lex.
    -- The usage stays up until the first space starts the arguments.
    for _, candidate in ipairs(COMMAND_HINTS) do
        if candidate.command == lower and optionalCommandOn(candidate.command) then
            return {
                display = " " .. candidate.usage,
                completion = candidate.command,
                exact = true,
            }
        end
    end

    -- Ordered prediction resolves shared prefixes deterministically and then
    -- updates on every character. /a predicts /all; /ad predicts /admin.
    for _, candidate in ipairs(COMMAND_HINTS) do
        if optionalCommandOn(candidate.command)
            and candidate.command:sub(1, #lower) == lower then
            return {
                display = candidate.command:sub(#text + 1) .. " " .. candidate.usage,
                completion = candidate.command,
            }
        end
    end
    return nil
end

MC_Input._commandHintForText = commandHintForText
MC_Input._commandHints = COMMAND_HINTS

local function acceptCommandHint(textEntry)
    if not textEntry then return false end
    local hint = commandHintForText(textEntry:getText())
    -- An already-finished command has nothing left to complete, so the key
    -- falls through to whatever the entry box normally does with it.
    if not hint or hint.exact then return false end
    textEntry:setText(hint.completion)
    return true
end

-- Sticky channel memory (2026-07-14): typing one of these full-word prefixes
-- doesn't just send that one line -- it becomes MC_Input.channel, so the
-- NEXT bare (no-prefix) line goes to the same channel instead of always
-- falling back to "say". Deliberately narrow to the typed proximity speech
-- channels only: /whisper, /say, /yell, /low (and their short aliases,
-- since parsePrefix already folds those to the same channel name above).
-- Everything else that can set `channel` here -- /me, /do, /event, /you,
-- /ooc, /all, /tell, /faction, /safehouse, /bio, /roll -- is either a
-- utility/config command, an admin surface, or simply not proximity speech,
-- and must NOT overwrite what bare text means next. Radio needs no entry of
-- its own: MC_Radio's passive broadcast model (see MC_Radio.lua's header)
-- means radio transmission is a side effect of speaking near an unmuted
-- radio on one of these same channels, never a channel a player types.
local STICKY_CHANNELS = {
    say = true,
    whisper = true,
    yell = true,
    low = true,
}

local parsePrefix

-- Read-only UI seam. It answers only the reach shape the current draft can
-- prove. A typed proximity prefix wins over sticky memory; every other slash
-- command is neutral. Low has no fourth visual shape, so it deliberately uses
-- the even Say rim rather than pretending to a range it does not have.
local function visualTargetForDraft(text)
    if type(text) ~= "string" then return "neutral" end
    local explicit = parsePrefix(text)
    if explicit == "whisper" then return "whisper" end
    if explicit == "say" or explicit == "low" then return "say" end
    if explicit == "yell" then return "yell" end
    if text:sub(1, 1) == "/" then return "neutral" end
    local sticky = MC_Input.channel
    if sticky == "whisper" then return "whisper" end
    if sticky == "say" or sticky == "low" then return "say" end
    if sticky == "yell" then return "yell" end
    return "neutral"
end

MC_Input.visualTargetForDraft = visualTargetForDraft

-- E2 ergonomics (2026-07-08): the one-shot "@<language> message" prefix is
-- deliberately NOT a PREFIXES entry and never will be -- "@" isn't a
-- channel switch, it's a per-message language override. A message that
-- starts with "@" and isn't otherwise a "/" command falls straight through
-- parsePrefix (no match) to the plain-text branch below and is forwarded to
-- the server byte-for-byte, exactly like ordinary chat text; MC_Server.lua's
-- resolveOneShotLanguage does the actual parsing/resolution/rejection
-- server-side (it alone knows which languages the speaker can select).
-- Never add "@" here.

--[[
    Parse command prefix from message text
    @param text  Raw input text
    @return channel (or nil), message (text after prefix)
]]
parsePrefix = function(text)
    local lower = text:lower()
    for _, p in ipairs(PREFIXES) do
        if lower:sub(1, #p[1]) == p[1] and optionalChannelOn(p[2]) then
            return p[2], text:sub(#p[1] + 1), p[1]
        end
    end
    return nil, text
end

-- Return the normalized slash-command token that should be restored when the
-- player next opens chat. This is intentionally broader than PREFIXES: MC
-- server commands, locally answered commands, vanilla administration, and
-- other mods' commands all cross the same submit boundary even though MC must
-- yield authority for the latter two classes.
local function slashCommandPrefix(text)
    if type(text) ~= "string" then return nil end
    local token = text:match("^(/[%w_.%-]+)")
    if not token then return nil end
    return token:lower() .. " "
end

-- DICE ROLLING

--[[
    Parse dice notation like "4d10+4", "2d6", "d20-2", "3d8"
    @param notation  String like "4d10+4"
    @return count, sides, modifier (or nil if invalid)
]]
local function parseDice(notation)
    if not notation then return nil end
    
    -- Trim and lowercase
    local s = notation:gsub("%s+", ""):lower()
    
    -- Pattern: optional count, 'd', sides, optional modifier
    -- Examples: "4d10+4", "d20", "2d6-1", "3d8"
    local count, sides, modSign, modVal = s:match("^(%d*)d(%d+)([%+%-]?)(%d*)$")
    
    if not sides then return nil end
    
    count = tonumber(count) or 1
    sides = tonumber(sides)
    modSign = modSign or "+"
    modVal = tonumber(modVal) or 0
    
    if modSign == "-" then modVal = -modVal end
    
    -- Sanity limits
    if count < 1 then count = 1 end
    if count > 100 then count = 100 end
    if sides < 2 then sides = 2 end
    if sides > 1000 then sides = 1000 end
    
    return count, sides, modVal
end

--[[
    Roll dice and format result
    @param notation  String like "4d10+4"
    @return formatted result string, total value, isCrit, isFumble
]]
local function rollDice(notation)
    local count, sides, modifier = parseDice(notation)
    
    if not count then
        return nil, nil, false, false
    end
    
    -- Roll the dice
    local rolls = {}
    local total = 0
    for i = 1, count do
        local roll = ZombRand(sides) + 1  -- ZombRand(n) returns 0 to n-1
        table.insert(rolls, roll)
        total = total + roll
    end
    
    -- Detect natural 1 and natural 20 (only for single d20)
    local isCrit = false
    local isFumble = false
    if count == 1 and sides == 20 then
        if rolls[1] == 20 then
            isCrit = true
            dbg("rollDice: NAT 20!")
        elseif rolls[1] == 1 then
            isFumble = true
            dbg("rollDice: NAT 1!")
        end
    end
    
    total = total + modifier
    
    -- Format modifier string
    local modStr = ""
    if modifier > 0 then
        modStr = "+" .. modifier
    elseif modifier < 0 then
        modStr = tostring(modifier)
    end
    
    -- Format rolls string - truncate if more than 5 dice
    local rollsStr
    if count <= 5 then
        rollsStr = "[" .. table.concat(rolls, ", ") .. "]"
    else
        -- Show first 5 + how many more
        local firstFive = {rolls[1], rolls[2], rolls[3], rolls[4], rolls[5]}
        local remaining = count - 5
        rollsStr = "[" .. table.concat(firstFive, ", ") .. ", ... +" .. remaining .. " more]"
    end
    
    -- Format: "4d10+4: [3, 7, 2, 9] + 4 = 25"
    local diceStr = count .. "d" .. sides .. modStr
    
    local resultStr
    if modifier ~= 0 then
        local modDisplayStr = modifier > 0 and (" + " .. modifier) or (" - " .. math.abs(modifier))
        resultStr = string.format("%s: %s%s = %d", diceStr, rollsStr, modDisplayStr, total)
    else
        resultStr = string.format("%s: %s = %d", diceStr, rollsStr, total)
    end
    
    -- Add crit/fumble indicator to message
    if isCrit then
        resultStr = resultStr .. " - NAT 20!"
    elseif isFumble then
        resultStr = resultStr .. " - NAT 1!"
    end
    
    return resultStr, total, isCrit, isFumble
end

-- LOCAL FEEDBACK
-- Client-only system lines in the chat panel -- no server round-trip.
-- Mirrors the render shape of ClientCommands.SystemMessage in MC_Client.

--[[
    Print a system line only this client sees
    @param message  Line text
    @param color    {r, g, b} 0-255 (optional, defaults to neutral grey)
]]
local function localSysMsg(message, color)
    return safeExec("local-feedback", function()
        local MC_ChatPanel = require("MC_ChatPanel")
        if not MC_ChatPanel
            or type(MC_ChatPanel.systemMessage) ~= "function"
        then
            error("chat panel system-message API unavailable")
        end
        MC_ChatPanel.systemMessage(message, { color = color })
    end)
end

--[[
    Local player's access level, lowercased ("admin", "moderator", ...).
    Returns nil when it can't be read positively -- callers must treat nil
    as UNKNOWN, not as denial. Client-side only: every admin surface is
    re-gated server-side; this merely shapes local UX (usage lines, /mc
    help extras, sparing non-admins a round-trip).
]]
local function localAccessLevel()
    local playerOK, player = pcall(getPlayer)
    if not playerOK or not player then
        MC_Incident.report("CHAT_INPUT_OPERATION_FAILED",
            "operation=access-level-player")
        return nil
    end
    local levelOK, level = pcall(function() return player:getAccessLevel() end)
    if not levelOK or type(level) ~= "string" or level == "" then
        MC_Incident.report("CHAT_INPUT_OPERATION_FAILED",
            "operation=access-level-read")
        return nil
    end
    return level:lower()
end

-- Bare command -> one-line usage. PREFIXES entries only match
-- "<command> <text>", so bare forms ("/roll", "/tell") would otherwise fall
-- through to vanilla as unknown commands while /lang and /lex answer
-- helpfully. Aliases share one line via the builder below.
local BARE_USAGE = {}
local function addUsage(names, line)
    for _, name in ipairs(names) do
        BARE_USAGE[name] = line
    end
end
addUsage({"/whisper", "/w"}, "Usage: /whisper <message>  (or /w) -- heard only right beside you.")
addUsage({"/say", "/s"}, "Usage: /say <message>  (or /s) -- a normal speaking voice.")
addUsage({"/yell", "/y"}, "Usage: /yell <message>  (or /y) -- a shout that carries.")
addUsage({"/low", "/l"}, "Usage: /low <message>  (or /l) -- kept low, for those close by.")
addUsage({"/me", "/em", "/e"}, "Usage: /me <action>  (or /em, /e) -- an action, shown as *Name waves*.")
addUsage({"/do"}, "Usage: /do <text> -- narrate the scene for everyone nearby.")
addUsage({"/event"}, "Usage: /event <narration> -- storyteller's narration that carries far (admins).")
addUsage({"/you"}, "Usage: /you <feeling> -- a private note of how you're feeling; only you see it.")
addUsage({"/ooc", "/o"}, "Usage: /ooc <message>  (or /o) -- out-of-character, heard nearby.")
addUsage({"/all"}, "Usage: /all <message> -- out-of-character, the whole server hears.")
addUsage({"/tell", "/t"}, "Usage: /tell <name> <message>  (or /t <name> <message>)")
addUsage({"/faction", "/f"}, "Usage: /faction <message>  (or /f)")
addUsage({"/safehouse", "/sh"}, "Usage: /safehouse <message>  (or /sh)")
addUsage({"/roll", "/r"}, "Usage: /roll 2d6  (or /r) -- also d20, 4d10+4. The result lands in OOC.")
-- /hue normally rides through isMCServerCommand to the server (which knows
-- the current color and answers bare /hue with it); this line is the local
-- fallback should that route ever be unavailable.
addUsage({"/hue"}, "Usage: /hue #RRGGBB or /hue r,g,b (0-255). /hue reset restores your default hue.")

-- /mc help: the player-facing command list. Player commands only -- the
-- admin surfaces (/lang grant, etc.) stay out of it. Staff
-- see one extra /event line, appended at print time in handleLocalCommand.
local MC_HELP = {
    "MongooseChat commands:",
    "  /whisper /low /say /yell <message> -- quiet through loud (or /w /l /s /y)",
    "  /me <action> -- an action, shown as *Name waves* (or /em, /e)",
    "  /do <text> -- narrate the scene for everyone nearby",
    "  /you <feeling> -- a private note of how you're feeling; only you see it",
    "  /tell <name> <message> -- address someone directly (or /t)",
    { channel = "roll", text = "  /roll 2d6 -- roll dice; the result lands in OOC (or /r)" },
    { channel = "bio", text = "  /bio <text> -- the line shown under your name (or /tagline)" },
    "  /hue #RRGGBB or /hue r,g,b -- set your name hue (/hue reset restores the default)",
    { channel = "ooc", text = "  /ooc <message> -- out-of-character, heard nearby (or /o)" },
    { channel = "all", text = "  /all <message> -- out-of-character, the whole server hears" },
    "  /lang -- your languages; /lex -- words you've picked up; /comp -- how much you follow",
    "  /forget -- start your character's languages over",
    "  /ll -- switch back to your previous language; @<language> at the start of a " ..
        "message speaks just that line in another (e.g. @french bonjour)",
}

--[[
    Answer bare command forms and /mc locally
    @param text  Raw input text (starts with "/", unknown to parsePrefix)
    @return true if handled (feedback printed), false to fall through
]]
local function handleLocalCommand(text)
    local cmd = text:lower():match("^%s*(.-)%s*$")

    -- /mc, /mc help: command discovery
    if cmd == "/mc" or cmd == "/mc help" then
        for _, item in ipairs(MC_HELP) do
            if type(item) == "string" or optionalChannelOn(item.channel) then
                localSysMsg(type(item) == "string" and item or item.text)
            end
        end
        -- Staff-only extra (cosmetic gate -- the server owns the real one).
        local level = localAccessLevel()
        if level and level ~= "none" then
            localSysMsg("  /event <narration> -- narrate an event, heard at double yell range (admin)")
        end
        dbg("handleLocalCommand: printed /mc help")
        return true
    end

    -- Bare /bio (or /tagline): open your own character sheet -- the familiar old
    -- verb now opens the fuller editor (tagline + description + your full body).
    -- /bio <text> still quick-sets the tagline (handled in send()).
    if cmd == "/bio" or cmd == "/tagline" then
        if not optionalChannelOn("bio") then return false end
        local player = getPlayer()
        if player then
            local ok, MC_CharacterSheet = pcall(require, "MC_CharacterSheet")
            if ok and MC_CharacterSheet then
                MC_CharacterSheet.open(player)
            else
                localSysMsg("Usage: /bio <text> -- the line shown under your name.")
            end
        end
        dbg("handleLocalCommand: bare /bio -> character sheet")
        return true
    end

    local usage = BARE_USAGE[cmd]
    if usage then
        if not optionalCommandOn(cmd) then return false end
        localSysMsg(usage)
        dbg("handleLocalCommand: usage for %s", cmd)
        return true
    end

    return false
end

-- SEND MESSAGE

-- Build the hot-mic approval snapshot used by ordinary typed speech and the
-- Q-callout route alike. The server still discovers every physical emitter
-- and owns all routing metadata, but it intersects that result with this
-- client snapshot. That subtractive boundary is required because B42.20's
-- dedicated server drops state packets for non-hand inventory radios (belt
-- and bag radios): the client is the only side that reliably sees the Device
-- Options volume/microphone mute at the instant speech is submitted.
local RADIO_EMITTER_CHANNELS = {
    say = true,
    yell = true,
    low = true,
    whisper = true,
    tell = true,
}

local function collectRadioEmitters(player, channel)
    local radioEmitters = {}
    if not player then return radioEmitters, true end
    -- Feature switch: no radio means no emitters, authoritatively.
    if not MC_Config.featureOn("RadioEnabled") then return radioEmitters, true end

    -- Only spoken proximity channels can propagate through a radio. Global,
    -- narrative, action, mood, and OOC channels may deliberately use a
    -- negative/unbounded range sentinel; do not mistake that for failed radio
    -- discovery and block an otherwise valid message.
    if RADIO_EMITTER_CHANNELS[channel] ~= true then
        return radioEmitters, true
    end

    -- /tell is addressed proximity speech. The server resolves the target
    -- and canonicalizes it to "say".
    local voiceRange = (channel == "tell")
        and MC_Config.Ranges.say
        or MC_Config.Ranges[channel]
    if type(voiceRange) ~= "number" then
        MC_Incident.report("CHANNEL_INVALID",
            "client send channel=" .. tostring(channel))
        return radioEmitters, true
    end

    local ok, emitters, authoritative = pcall(
        MC_Radio.findPlayerEmitters, player, voiceRange)
    if not ok or type(emitters) ~= "table" or authoritative ~= true then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "client emitter discovery unavailable")
        -- Radio uncertainty must fail only the radio branch closed. The
        -- server treats this explicit empty snapshot as a veto while ordinary
        -- proximity speech (and the Q callout itself) remains playable.
        return radioEmitters, true
    end

    for _, e in ipairs(emitters) do
        if type(e) ~= "table" then
            MC_Incident.report("RADIO_METADATA_INVALID",
                "client emitter entry unavailable")
            return {}, true
        end
        table.insert(radioEmitters, {
            frequency = e.frequency,
            source = e.source,
            position = e.position,
            transmitRange = e.transmitRange,
        })
        dbg("send: emitter on freq %s source=%s",
            tostring(e.frequency), tostring(e.source))
    end

    if #radioEmitters == 0 then
        dbg("send: no active radio emitters")
    end
    return radioEmitters, true
end

-- The one owned player-text transport seam.  Public observers are told only
-- after the engine transport call returns.  The API hook is guarded again
-- here so a broken compat subscriber can never turn a successful send into a
-- failed one, even if the API module itself is replaced by another mod.
local function emitChatMessage(payload, origin, raw)
    local command = origin == "announce" and "Announce" or "ChatMessage"
    sendClientCommand("MongooseChat", command, payload)

    local observed = {
        channel = payload.channel or (origin == "announce" and "announce" or nil),
        message = payload.message,
        raw = raw,
        origin = origin,
        apiVersion = MC_API.VERSION,
    }
    if origin == "roll" then
        observed.isRoll = payload.isRoll
        observed.rollTotal = payload.rollTotal
        observed.isCrit = payload.isCrit
        observed.isFumble = payload.isFumble
    end
    pcall(MC_API._fire, "MCOutboundMessage", observed)
    return true
end

--[[
    Process chat input and send to server
    @param text  Raw input text (may include command prefix)
]]
function MC_Input.send(text, submitDefault)
    if not text or text == "" then
        dbg("send: empty text")
        return
    end
    if not isClient() then
        dbg("send: not client")
        return
    end

    local submittedCommand = text:lower():match("^(/[%w_.%-]+)")
    if submittedCommand and not optionalCommandOn(submittedCommand) then
        dbg("send: yielding disabled optional command %s", submittedCommand)
        return false
    end

    -- Add to command history (commands like /lang included -- see
    -- MC_InputHistory.lua header; only text that actually reaches send()
    -- counts as "sent")
    inputHistory:add(text)
    
    -- Remember every submitted slash-command token, not only chat-channel
    -- prefixes. interceptCommand performs the same update for commands MC
    -- deliberately yields to vanilla or another mod.
    local submittedSlashPrefix = slashCommandPrefix(text)
    if submittedSlashPrefix then
        MC_Input.lastSlashPrefix = submittedSlashPrefix
    end

    -- Parse any command prefix
    local explicitChannel, message, matchedPrefix = parsePrefix(text)
    local channel = explicitChannel
    if not channel and not text:match("^/") and submitDefault == "ooc"
        and optionalChannelOn("ooc") then
        channel = "ooc"
    end

    -- Remember only the command token, never the previous message body.
    -- This is independent of sticky proximity-channel memory below: /all can
    -- reopen as "/all " without changing what a future bare line means.
    if matchedPrefix then
        MC_Input.lastSlashPrefix = matchedPrefix
    end

    -- Use current channel if no prefix
    if not channel then
        channel = MC_Input.channel
    end

    -- Sticky channel memory: an explicit typed proximity-speech prefix
    -- becomes the new default for the next bare line (see STICKY_CHANNELS
    -- above). A one-shot "/yell hello" both sends as yell right now AND
    -- switches the remembered channel in the same stroke.
    if explicitChannel and STICKY_CHANNELS[explicitChannel] then
        MC_Input.channel = explicitChannel
    end

    dbg("send: [%s] %s", channel, message:sub(1, 30))
    
    -- Special handling for bio/tagline command
    if channel == "bio" then
        local MC_Bio = require("MC_Bio")
        MC_Bio.saveTagline(message)
        return
    end
    
    -- Special handling for dice roll command
    -- Rolls dice and sends result to OOC channel
    if channel == "roll" then
        -- Check if OOC is enabled (rolls go to OOC)
        if not optionalChannelOn("ooc") then
            dbg("send: roll blocked - OOC disabled")
            localSysMsg("Dice rolls go out over OOC, and OOC chat is disabled on this server.", {255, 100, 100})
            return
        end
        local resultStr, total, isCrit, isFumble = rollDice(message)
        if resultStr then
            -- Send as OOC with special roll flag for coloring
            emitChatMessage({
                channel = "ooc",
                message = resultStr,
                isRoll = true,
                rollTotal = total,
                isCrit = isCrit,
                isFumble = isFumble,
                radioEmitters = {},
            }, "roll", text)
            dbg("send: dice roll -> %s (crit=%s, fumble=%s)", resultStr, tostring(isCrit), tostring(isFumble))
        else
            -- Invalid notation - show local usage instead of eating the input
            dbg("send: invalid dice notation '%s'", message)
            localSysMsg("Couldn't read that roll -- try /roll 2d6 or /roll d20+3.", {255, 100, 100})
        end
        return
    end
    
    -- Special handling for /event (admin narration, v8.16.2). The access
    -- check here is UX only -- it spares non-admins a round-trip and
    -- answers them kindly; the authoritative gate lives in MC_Server's
    -- processMessage. When the level can't be read (nil), defer to that
    -- authoritative server decision. Sent with no radio emitters --
    -- narration is storytelling, not sound, so no hot mic picks it up.
    if channel == "event" then
        if localAccessLevel() == "none" then
            dbg("send: /event blocked locally (no staff access)")
            localSysMsg("The event voice belongs to the server's storytellers -- /event is for admins.")
            return
        end
        emitChatMessage({
            channel = "event",
            message = message,
            radioEmitters = {},
        }, "event", text)
        dbg("send: /event narration sent (%d chars)", #message)
        return
    end

    -- /announce (0.9.8): a server-wide system line for admins. Same UX-only
    -- access shaping as /event above -- the authoritative gate lives in
    -- MC_Server's ServerCommands.Announce; nil (unreadable) defers to it.
    -- Not a ChatMessage: nothing proximity- or radio-shaped rides along.
    if channel == "announce" then
        if localAccessLevel() == "none" then
            dbg("send: /announce blocked locally (no staff access)")
            localSysMsg("Announcements belong to the server's staff -- /announce is for admins.")
            return
        end
        emitChatMessage({ message = message }, "announce", text)
        dbg("send: /announce sent (%d chars)", #message)
        return
    end

    -- OOC/ALL sandbox gates are server-side only (v8.16.2). MC_Server's
    -- processMessage rejects a disabled channel and answers the sender with
    -- a friendly SystemMessage; a client-side early return here would
    -- swallow the message with no feedback at all.

    -- Find all radios that would emit this speech.
    local radioEmitters, radioOk
    if channel == "ooc" then
        radioEmitters, radioOk = {}, true
    else
        radioEmitters, radioOk = collectRadioEmitters(getPlayer(), channel)
    end
    if not radioOk then
        localSysMsg("Radio state could not be verified; your message was not sent.",
            {255, 100, 100})
        return
    end
    
    -- Send to server
    emitChatMessage({
        channel = channel,
        message = message,
        radioEmitters = radioEmitters,
    }, "input", text)
    
    dbg("send: sendClientCommand called")
end

-- TYPING INDICATOR

local function broadcastTyping(channel)
    if not isClient() then return end
    if not MC_Config.optionalOn("TypingIndicatorsEnabled",
        MC_Config.TypingIndicators
            and MC_Config.TypingIndicators.enabled == true) then return end
    if not STICKY_CHANNELS[channel] then return end
    
    local now = MC_Core.getTimeMs()
    if now - lastTypingBroadcast < TYPING_THROTTLE_MS then return end
    
    lastTypingBroadcast = now
    
    dbg("broadcastTyping: sending typing packet")
    
    sendClientCommand("MongooseChat", "Typing", {
        channel = channel,
    })
end

-- Resolve what the CURRENT draft would actually become. Utility, private and
-- global commands emit no typing presence; prefixed proximity speech uses its
-- own channel; bare text uses the remembered proximity channel.
local function typingChannelForDraft(text, submitDefault)
    if type(text) ~= "string" or text == "" then return nil end
    local channel = parsePrefix(text)
    if channel then
        return STICKY_CHANNELS[channel] and channel or nil
    end
    if text:match("^/") then return nil end
    if submitDefault == "ooc" then return nil end
    return STICKY_CHANNELS[MC_Input.channel] and MC_Input.channel or nil
end

-- ISCHAT HOOKS

--[[
    Lift the vanilla chat input box past its native ~250-char ceiling to the
    configured MaxMessageLength. MongooseChat reads straight from this box
    (interceptCommand) and sends through its own server path, so this setter is
    what actually lets players TYPE longer; the server cap only backstops a
    tampered client.

    Safe to call repeatedly. A missing box/setter is not treated as success:
    callers receive false and an always-on incident explains why the configured
    input contract could not be applied. Read live from MC_Config so it reflects
    whatever value is current, which is why MC_Client re-calls it after the
    OnConnected sandbox sync -- the box is hooked before the server's configured
    value arrives in MP.
]]
function MC_Input.applyChatBoxMaxLength()
    if not chatSurfaceOn() then
        inputLimitPending = false
        return true
    end

    local maxLength = MC_Config.MaxMessageLength
    if type(maxLength) ~= "number"
        or maxLength ~= maxLength
        or maxLength == math.huge
        or maxLength == -math.huge
        or maxLength < 1
        or maxLength % 1 ~= 0
    then
        inputLimitPending = true
        MC_Incident.report("CHAT_INPUT_LIMIT_UNAVAILABLE",
            "reason=invalid-config")
        return false
    end

    if inputLimitAppliedValue ~= maxLength then inputLimitPending = true end

    if type(ISChat) ~= "table" or type(ISChat.instance) ~= "table" then
        inputLimitPending = true
        if chatWindowExpected then
            MC_Incident.report("CHAT_INPUT_LIMIT_UNAVAILABLE",
                "reason=chat-instance-unavailable")
        end
        return false
    end
    local textEntry = ISChat.instance.textEntry
    if textEntry ~= inputLimitAppliedEntry then inputLimitPending = true end
    if type(textEntry) ~= "table"
        or type(textEntry.setMaxTextLength) ~= "function"
    then
        inputLimitPending = true
        if chatWindowExpected then
            MC_Incident.report("CHAT_INPUT_LIMIT_UNAVAILABLE",
                "reason=setter-unavailable")
        end
        return false
    end

    if not inputLimitPending and inputLimitAppliedEntry == textEntry
        and inputLimitAppliedValue == maxLength
    then
        return true
    end

    local ok = MC_Core.safeExec(function()
        textEntry:setMaxTextLength(maxLength)
    end)
    if not ok then
        inputLimitPending = true
        if chatWindowExpected then
            MC_Incident.report("CHAT_INPUT_LIMIT_UNAVAILABLE",
                "reason=setter-exception")
        end
        return false
    end

    inputLimitPending = false
    inputLimitAppliedEntry = textEntry
    inputLimitAppliedValue = maxLength
    dbg("applyChatBoxMaxLength: chat box max length set to %d", maxLength)
    return true
end

function MC_Input.markChatBoxMaxLengthPending()
    inputLimitPending = true
end

-- CHAT SUBMIT BOUNDARY (0.9.8)
--
-- The submit hooks used to be installed once behind a boolean latch and
-- trusted forever. Anything that replaced them afterward -- another mod
-- re-hooking on a later event (EHRE's /ehrfullheal hook re-installs on
-- OnChatWindowInit, which fires AFTER OnGameStart, and chains to a stale
-- cached "original" instead of whoever is currently installed), a future
-- build's rebinding -- left Enter silently dead: vanilla's echo renders
-- into chat views MongooseChat keeps hidden, so nothing appears and no
-- incident fires.
--
-- This boundary is the same identity-guarded, self-healing shape the
-- Q/Callout seams have always used (see maintainQBoundary below): every
-- tick the seams are compared by function identity and, if replaced,
-- reinstalled and reported. Two rules keep it honest:
--
--   * NEVER re-capture our own wrapper as the "original" -- that is the
--     self-referential trap. mcOwnSubmitWrappers records every wrapper we
--     have ever installed so a value we find in a seam can be classified.
--   * A FOREIGN value found in a seam becomes the new chain target, so the
--     newcomer's own command (e.g. /ehrfullheal) keeps working underneath
--     us. The ping-pong with a rude re-hooker stabilises with MongooseChat
--     outermost within one maintenance pass.
--
-- The wrappers themselves fail OPEN: an error inside MongooseChat's own
-- intercept path yields the submit to vanilla with an incident, so a bug
-- of ours can never eat the player's keystroke without a trace. (Content
-- decisions inside interceptCommand keep their own fail-closed postures.)

local submitClassWrapper = nil
local submitClassOriginal = nil
local submitEntryWrapper = nil
local submitEntryOriginal = nil
local hookedTextEntry = nil
local hookedInstance = nil
local mcUnfocus = nil
local mcUnfocusOriginal = nil
local mcOnKeyPress = nil
local mcOnKeyPressOriginal = nil
local mcFocus = nil
local mcFocusOriginal = nil
local submitBoundaryEverLive = false

-- Every wrapper MongooseChat has ever installed on a submit seam, so a
-- value found there can be told apart from a third party's. Weak keys:
-- superseded wrappers can be collected once no seam holds them.
local mcOwnSubmitWrappers = setmetatable({}, { __mode = "k" })

-- Server-side intercepted commands that aren't channel prefixes -- they
-- start with `/` but parsePrefix doesn't know them (it's channels only),
-- and vanilla doesn't know them either. MC_Server.processMessage handles
-- them server-side after they arrive as a normal ChatMessage. Without
-- this check the conditional in interceptCommand drops them to vanilla,
-- vanilla silently discards them, and the server never sees the input.
-- Single-sourced from MC_Core.SERVER_SLASH_COMMANDS -- see that
-- constant's own comment; MC_Server's SLASH_HANDLERS keys are built
-- from the exact same array, so the two can't hand-drift apart.
local function commandWord(text)
    if not text or text:sub(1, 1) ~= "/" then return false end
    local lower = text:lower()
    local spaceIdx = lower:find(" ", 1, true)
    return spaceIdx and lower:sub(1, spaceIdx - 1) or lower
end

local function isMCServerCommand(text)
    local cmdWord = commandWord(text)
    if not cmdWord then return false end
    for _, cmd in ipairs(MC_Core.SERVER_SLASH_COMMANDS) do
        if cmdWord == cmd then return true end
    end
    return false
end

-- Vanilla stores ISChat.onCommandEntered directly on the ISTextEntryBox.
-- That callback therefore receives the text entry as `self`, while our
-- deepest hook deliberately passes ISChat.instance. Accept both shapes:
-- a later chat-box recreation can bind our class wrapper directly.
local function resolveTextEntry(chatOrEntry)
    if not chatOrEntry then return nil end
    if chatOrEntry.textEntry then return chatOrEntry.textEntry end
    if chatOrEntry.getText and chatOrEntry.setText then return chatOrEntry end
    return nil
end

-- Vanilla suppresses trailing key events after a submit (doKeyPress(false)
-- plus a 20-tick timer its own ISChat.ontick -- which MC never touches --
-- re-enables). MC-routed submits used to skip both, leaving a window where
-- the Enter that sent a line leaked into other mods' raw key handlers.
local function suppressTrailingKeys()
    pcall(function()
        doKeyPress(false)
        if ISChat and ISChat.instance then
            ISChat.instance.timerTextEntry = 20
        end
    end)
end

-- Core intercept function - returns true if we handled it
local function interceptCommand(chatOrEntry, submitDefault)
    if not chatSurfaceOn() then return false end

    local textEntry = resolveTextEntry(chatOrEntry)
    if not textEntry then
        MC_Incident.report("CHAT_INPUT_TARGET_INVALID",
            "command callback target unavailable")
        return true
    end

    local text = textEntry:getText()
    dbg("interceptCommand: text = %s", tostring(text))

    if text and text ~= "" then
        local submittedSlashPrefix = slashCommandPrefix(text)
        if submittedSlashPrefix then
            MC_Input.lastSlashPrefix = submittedSlashPrefix
            -- Write-through to vanilla's own per-tab memory (0.9.8):
            -- ISChat:focus() prefills chatText.lastChatCommand, which only
            -- vanilla's submit path updates -- and MC intercepts before it
            -- ever runs, so without this the box always reopened on the
            -- tab default (/say) whenever MC's own restore lost a race or
            -- an unwrapped vanilla focus path ran. Now both memories agree.
            pcall(function()
                ISChat.instance.chatText.lastChatCommand = submittedSlashPrefix
            end)
        end
        local channel, _ = parsePrefix(text)

        -- Route through MongooseChat if it's our channel prefix, a
        -- server-intercepted MC command, or plain text.
        if channel or not text:match("^/") or isMCServerCommand(text) then
            dbg("interceptCommand: routing through MongooseChat [%s]", tostring(channel))
            MC_Input.send(text, submitDefault == "ooc" and "ooc" or nil)
            textEntry:setText("")
            suppressTrailingKeys()
            pendingUnfocus = true
            lastMessageSentTime = MC_Core.getTimeMs()
            return true  -- We handled it
        elseif handleLocalCommand(text) then
            -- Bare command form ("/roll", "/tell") or /mc help: answered
            -- locally with a usage line, nothing to send.
            dbg("interceptCommand: handled locally (bare command)")
            textEntry:setText("")
            suppressTrailingKeys()
            pendingUnfocus = true
            lastMessageSentTime = MC_Core.getTimeMs()
            return true  -- We handled it
        else
            -- Vanilla sends non-chat slash commands to the server through
            -- SendCommandToServer. Yield every command MC does not own so
            -- hosted-server administration (/setaccesslevel), vanilla
            -- moderation, and other mods' command surfaces keep working.
            dbg("interceptCommand: yielding unowned slash command to vanilla %s",
                tostring(commandWord(text)))
            return false
        end
    end

    return false  -- Let vanilla handle it
end

-- WINDOW SUBMIT ENTRY POINTS (MC_ChatWindow)
--
-- MC_ChatWindow owns its own ISTextEntryBox, so there is no vanilla seam
-- to wrap for it -- it calls in here directly. interceptCommand already
-- accepts a bare entry widget (resolveTextEntry), so the routing, prefix
-- parsing and local-command handling are shared with the vanilla path
-- rather than reimplemented.

--[[
    Route a submit from our own window.
    @param textEntry  the window's ISTextEntryBox
    @return true if MongooseChat handled it, false to yield to vanilla
]]
function MC_Input.submitFromWindow(textEntry, submitDefault)
    if not textEntry or not chatSurfaceOn() then return false end
    return interceptCommand(textEntry, submitDefault == "ooc" and "ooc" or nil) == true
end

--[[
    Speak on the admin channel from OUR box.

    Vanilla's own submit refuses an /admin line unless
    ISChat.instance.currentTabID equals the admin stream's tabID:

        if chat.currentTabID ~= stream.tabID then
            showWrongChatTabMessage(...); commandProcessed = true; break

    OUR window owns tab selection, so vanilla's currentTabID never points at
    its admin tab. The line was answered with a "wrong chat tab" notice
    painted into vanilla's own hidden view -- so it simply vanished, with
    nothing reaching the chat server.

    The engine exposes processAdminChatMessage as a global, which is what
    vanilla itself calls once past that guard. Call it directly with the
    exact argument vanilla would pass (it strips the command prefix with
    string.sub(command, #chatCommand)). If the global is missing, fall back
    to vanilla's submit with its guard satisfied, and only then give up --
    loudly, never silently.

    @return true if the line was handed off, false if it could not be sent
]]
local ADMIN_COMMAND = "/admin "

local function fireAdminOutbound(text)
    pcall(MC_API._fire, "MCOutboundMessage", {
        channel = "admin",
        message = text,
        raw = text,
        origin = "admin",
        apiVersion = MC_API.VERSION,
    })
end

function MC_Input._setSubmitOriginalForTest(fn)
    submitClassOriginal = fn
end

function MC_Input.sendAdminLine(text)
    if type(text) ~= "string" or text == "" then return false end
    local command = ADMIN_COMMAND .. text
    local payload = string.sub(command, #ADMIN_COMMAND)

    if type(processAdminChatMessage) == "function" then
        local ok = pcall(processAdminChatMessage, payload)
        if ok then
            pcall(function()
                local inst = ISChat and ISChat.instance
                if inst and type(inst.logChatCommand) == "function" then
                    inst:logChatCommand(command)
                end
            end)
            dbg("sendAdminLine: engine admin entry point")
            fireAdminOutbound(text)
            return true
        end
    end

    -- Fallback: vanilla's own submit, with the tab guard satisfied for the
    -- length of the call and put back exactly as it was.
    local delivered = pcall(function()
        local inst = ISChat and ISChat.instance
        local entry = inst and inst.textEntry
        if not entry or not submitClassOriginal then error("no vanilla path") end
        local adminTabID = nil
        for _, stream in ipairs((ISChat and ISChat.allChatStreams) or {}) do
            if type(stream) == "table" and stream.name == "admin" then
                adminTabID = stream.tabID
                break
            end
        end
        if adminTabID == nil then error("no admin stream") end
        local restore = inst.currentTabID
        inst.currentTabID = adminTabID
        local ok, err = pcall(function()
            entry:setText(command)
            submitClassOriginal(inst)
            entry:setText("")
        end)
        inst.currentTabID = restore
        if not ok then error(err) end
    end)
    if delivered then
        dbg("sendAdminLine: vanilla submit with tab guard satisfied")
        fireAdminOutbound(text)
        return true
    end

    MC_Incident.report("ADMIN_SEND_FAILED",
        "admin line could not be handed to the game's admin channel")
    localSysMsg("That could not be sent on the admin channel.", {255, 100, 100})
    return false
end

--[[
    Hand an unowned slash command to vanilla's own submit path, so hosted
    server administration (/setaccesslevel), vanilla moderation and other
    mods' command surfaces keep working now that the player is typing in
    our box rather than vanilla's.
]]
function MC_Input.yieldToVanilla(text)
    if type(text) ~= "string" or text == "" then return false end

    local delivered = pcall(function()
        local inst = ISChat and ISChat.instance
        local entry = inst and inst.textEntry
        if not entry or not submitClassOriginal then error("no vanilla path") end
        entry:setText(text)
        submitClassOriginal(inst)
        entry:setText("")
    end)

    if not delivered then
        -- Last resort: the server command pipe itself. Better a command
        -- that runs without vanilla's UI bookkeeping than one silently
        -- swallowed because our window replaced the box it expected.
        local sent = pcall(function() SendCommandToServer(text) end)
        if not sent then
            MC_Incident.report("CHAT_VANILLA_YIELD_FAILED",
                "unowned slash command could not be delivered")
        end
        return sent
    end
    return true
end

-- The class seam: ISChat.onCommandEntered. Fires first in vanilla when
-- Enter is pressed; vanilla also binds this exact function value onto the
-- text entry (ISChat:createChildren), which is why the wrapper accepts
-- either receiver shape via resolveTextEntry.
local function installSubmitClassHook()
    if not chatSurfaceOn() then return false end
    if not ISChat then return false end
    local current = ISChat.onCommandEntered
    if type(current) ~= "function" then
        dbg("installSubmitClassHook: no class seam on this build")
        return false
    end
    if submitClassWrapper and current == submitClassWrapper then return true end

    if submitClassWrapper == nil then
        -- First install: capture vanilla as the chain target and build the
        -- one wrapper this seam will ever carry (it reads
        -- submitClassOriginal through its upvalue, so later chain-target
        -- changes never rebuild it).
        submitClassOriginal = current
        submitClassWrapper = function(self)
            if not chatSurfaceOn() then
                if submitClassOriginal then return submitClassOriginal(self) end
                return
            end
            dbg("ISChat.onCommandEntered: FIRED!")
            local ok, handled = pcall(interceptCommand, self)
            if not ok then
                MC_Incident.report("CHAT_SUBMIT_INTERCEPT_FAILED",
                    "intercept raised; yielding this submit to vanilla")
            elseif handled then
                dbg("ISChat.onCommandEntered: intercepted by MongooseChat")
                return
            end
            if submitClassOriginal then
                dbg("ISChat.onCommandEntered: calling original")
                submitClassOriginal(self)
            end
            pendingUnfocus = true
            lastMessageSentTime = MC_Core.getTimeMs()
        end
        mcOwnSubmitWrappers[submitClassWrapper] = true
    elseif mcOwnSubmitWrappers[current] then
        -- A stale wrapper of our own drifted into the class slot (no third
        -- party involved) -- quietly reassert the canonical one without
        -- touching the chain target.
        dbg("installSubmitClassHook: reasserting over a stale own wrapper")
    else
        -- Foreign overwrite: chain to the newcomer so its own command
        -- handling keeps working underneath us, and say so.
        MC_Incident.report("CHAT_INPUT_HOOK_REPLACED",
            "class submit seam was overwritten; reinstalling around the newcomer")
        submitClassOriginal = current
    end

    local ok = pcall(function() ISChat.onCommandEntered = submitClassWrapper end)
    if not ok or ISChat.onCommandEntered ~= submitClassWrapper then
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "class submit seam installation failed")
        return false
    end
    return true
end

-- The per-widget seams that die with a recreated text entry: typing
-- indicator, ghost command hint, command history, Ctrl-A -- plus the
-- max-length raise, the other silently-reverting per-widget mutation.
-- Originals are captured fresh from THIS widget every time it changes.
local function installPerEntryExtras(textEntry)
    if not chatSurfaceOn() then return end
    -- We only promise whole-line selection, and only after our own proved
    -- selectAll call succeeds. Any edit/focus/caret seam drops the promise.
    textEntry.mcWholeLineSelected = false
    textEntry.mcNeedsSelectOnFocus = true
    -- Raise the vanilla chat box past its native ~250 ceiling. See
    -- MC_Input.applyChatBoxMaxLength -- re-applied after the sandbox sync
    -- (MC_Client OnConnected), since this hook runs before that lands.
    MC_Input.applyChatBoxMaxLength()

    -- Typing indicator.
    local original_onTextChange = textEntry.onTextChange
    textEntry.onTextChange = function(self)
        if not chatSurfaceOn() then
            if original_onTextChange then return original_onTextChange(self) end
            return
        end
        if self.mcFreshFocusFirstEdit == true then
            self.mcFreshFocusFirstEdit = false
            local before = self.mcFreshFocusText or ""
            local after = self:getText() or ""
            self.mcFreshFocusText = nil
            local slashFirst = after == "/"
            if not slashFirst and #after == #before + 1 then
                for i = 1, #after do
                    if after:sub(i, i) == "/"
                        and after:sub(1, i - 1) .. after:sub(i + 1) == before then
                        slashFirst = true
                        break
                    end
                end
            end
            if slashFirst and after ~= "/" then
                MC_Input.setFreshSlash(self)
                return
            elseif slashFirst then
                -- Native replacement of a selected line already produced the
                -- right byte. Collapse our selection state and leave the
                -- caret after it without firing another text-change callback.
                MC_Input.disarmFreshFocus(self)
                if type(self.setCursorPos) == "function" then
                    pcall(self.setCursorPos, self, 1)
                end
            end
        end
        self.mcWholeLineSelected = false
        if original_onTextChange then
            original_onTextChange(self)
        end

        local text = self:getText()
        if text and text ~= "" then
            -- Event narration composes in silence: typing dots over one
            -- head would point every onlooker at the narrator the server
            -- keeps nameless (see MC_Server's /event identity scrub).
            local win = mcWindow()
            local onAdmin = win and win.activeTab == 4
            local submitDefault = nil
            if win and type(win.submitDefaultChannel) == "function" then
                local ok, value = pcall(win.submitDefaultChannel, win)
                if ok and value == "ooc" then submitDefault = "ooc" end
            end
            if not onAdmin then
                broadcastTyping(typingChannelForDraft(text, submitDefault))
            end
        end
    end

    local original_onFocusLost = textEntry.onFocusLost
    textEntry.onFocusLost = function(self, ...)
        if not chatSurfaceOn() then
            if original_onFocusLost then return original_onFocusLost(self, ...) end
            return
        end
        MC_Input.disarmFreshFocus(self)
        self.mcNeedsSelectOnFocus = true
        if original_onFocusLost then return original_onFocusLost(self, ...) end
    end
    local original_onClick = textEntry.onClick
    textEntry.onClick = function(self, ...)
        if not chatSurfaceOn() then
            if original_onClick then return original_onClick(self, ...) end
            return
        end
        local gainedFocus = self.mcNeedsSelectOnFocus == true
        local result
        if original_onClick then result = original_onClick(self, ...) end
        if gainedFocus then
            escapeCycleActive = false
            finishFocusSelection(self)
        else
            MC_Input.disarmFreshFocus(self)
        end
        return result
    end

    -- Draw command guidance after the native entry has rendered its real
    -- text. The suffix is visual only: it never enters getText(), command
    -- history, transport, or the message-length budget.
    local original_textEntry_render = textEntry.render
    textEntry.render = function(self)
        if original_textEntry_render then
            original_textEntry_render(self)
        end
        if not chatSurfaceOn() then return end

        local ok, text, hint, focused, cursor = pcall(function()
            local current = self:getText()
            return current, commandHintForText(current), self:isFocused(),
                self:getCursorPos()
        end)
        if not ok or not focused or not hint or cursor ~= #text then return end

        local font = self.font or UIFont.Medium
        local manager = getTextManager()
        local x = 5 + manager:MeasureStringX(font, text)
        local y = math.floor((self.height - manager:getFontHeight(font)) / 2)
        if x < self.width - 5 then
            local rgb = {0.68*255, 0.68*255, 0.68*255}
            if MC_Theme.access().highContrast
                and type(MC_Theme.readableColor) == "function" then
                rgb = MC_Theme.readableColor(rgb)
            end
            local alpha = type(MC_Theme.readableAlpha) == "function"
                and MC_Theme.readableAlpha(0.55) or 0.55
            self:drawText(hint.display, x, y, rgb[1]/255, rgb[2]/255,
                rgb[3]/255, alpha, font)
        end
    end

    -- textEntry.onPressUp / onPressDown for command history, and
    -- onOtherKey for Ctrl-A select-all.
    --
    -- CORRECTED 2026-07-08 (live-test bug): a focused ISTextEntryBox has
    -- NO "onKeyStart" callback in this engine at all -- that name only
    -- exists as the global Events.OnKeyStartPressed event (see
    -- ISUIHandler.lua/ISVehicleMenu.lua/ISWorldMap.lua's
    -- onKeyStartPressed handlers in vanilla), never as a per-widget
    -- method any Java code invokes. The previous hook here
    -- (`textEntry.onKeyStart = function(self, key) ... end`, shipped
    -- since 0.7.9.4) set a table field nothing ever called -- silently
    -- dead from day one, which is exactly why it never threw and never
    -- worked: Up/Down, Ctrl-A, and the Escape-reset branch it carried
    -- all lived inside a function the engine never invokes.
    --
    -- The real seam: vanilla's OWN ISChat (Chat/ISChat.lua) wires its
    -- built-in chat-log recall through two dedicated per-instance
    -- callbacks Java calls directly on a focused textEntry --
    -- `onPressUp` (Up arrow) and `onPressDown` (Down arrow) -- see
    -- ISChat:initialise() (`self.textEntry.onPressUp = ISChat.onPressUp`
    -- etc.) and ISChat:onPressUp/onPressDown's own log-cycling body.
    -- Left/Right/Home/caret movement stay purely native (no Lua hook
    -- either side ever sees them). Escape already works today via the
    -- separate, real ISChat.instance.onKeyPress override below (a
    -- genuine, widely-used per-window seam -- see e.g.
    -- ISVehicleSeatUI:onKeyPress, TileGeometryEditor:onKeyPress in
    -- vanilla), which already calls inputHistory:reset(); the dead
    -- onKeyStart Escape branch was redundant even before it was inert.

    -- REPLACED, not chained -- deliberately. The originals here are
    -- vanilla's own ISChat.onPressUp/onPressDown, which cycle
    -- chatText.log -- a log only ISChat:logChatCommand populates, and
    -- MC's interceptCommand returns before vanilla's onCommandEntered
    -- can ever reach it, so under MongooseChat that log is permanently
    -- empty. Against an empty log the vanilla originals aren't neutral:
    -- onPressDown's else-branch calls setText("") -- so falling through
    -- on "not browsing" would WIPE an in-progress draft on a stray Down
    -- press. onPressUp's empty-log path happens to no-op, but both are
    -- replaced outright for the same reason: MC owns recall on this box,
    -- and a nil from the ring means "leave the box exactly as it is".
    local original_onPressUp = textEntry.onPressUp
    textEntry.onPressUp = function(self)
        if not chatSurfaceOn() then
            if original_onPressUp then return original_onPressUp(self) end
            return
        end
        MC_Input.disarmFreshFocus(self)
        local historyText = inputHistory:up(self:getText())
        if historyText then
            dbg("HISTORY UP: set '%s'", historyText:sub(1, 30))
            self:setText(historyText)
        end
    end

    local original_onPressDown = textEntry.onPressDown
    textEntry.onPressDown = function(self)
        if not chatSurfaceOn() then
            if original_onPressDown then return original_onPressDown(self) end
            return
        end
        MC_Input.disarmFreshFocus(self)
        local historyText = inputHistory:down()
        if historyText ~= nil then
            dbg("HISTORY DOWN: set '%s'", historyText:sub(1, 30))
            self:setText(historyText)
        end
    end

    -- CTRL-A - select all input text (real widget selection --
    -- selectAll() -> javaObject:selectAll(), the same call ISComboBox's
    -- editor and the debug teleport UI already use). Wired over
    -- onOtherKey, the one per-textEntry key seam vanilla's own ISChat
    -- demonstrably uses live today (ISChat.onOtherKey checks
    -- Keyboard.KEY_ESCAPE the same way) -- chained so that an Escape the
    -- player has chosen not to let MC handle reaches the old path unchanged.
    -- isCtrlKeyDown() is
    -- the same vanilla engine global ISInventoryPane uses for its own
    -- Ctrl-A select-all. GLFW_KEY_A = 65.
    local KEY_A = (Keyboard and Keyboard.KEY_A) or 65
    local KEY_C = (Keyboard and Keyboard.KEY_C) or 67
    local KEY_X = (Keyboard and Keyboard.KEY_X) or 88
    local KEY_V = (Keyboard and Keyboard.KEY_V) or 86
    local KEY_TAB = (Keyboard and Keyboard.KEY_TAB) or 258
    local KEY_RIGHT = (Keyboard and Keyboard.KEY_RIGHT) or 262
    local KEY_ESCAPE = (Keyboard and Keyboard.KEY_ESCAPE) or 256
    textEntry.mcSelectWholeLine = function(self)
        if not chatSurfaceOn() then return false end
        if not self.selectAll then
            self.mcWholeLineSelected = false
            return false
        end
        self.mcWholeLineSelected = safeExec("select-all", function() self:selectAll() end)
        if self.mcWholeLineSelected then self.mcNeedsSelectOnFocus = false end
        return self.mcWholeLineSelected
    end
    local function clipSet(text)
        if Clipboard and type(Clipboard.setClipboard) == "function" then
            return safeExec("clipboard-copy", function() Clipboard.setClipboard(text) end)
        end
        return false
    end
    local function clipGet()
        local value
        local ok = safeExec("clipboard-read", function()
            if not Clipboard or type(Clipboard.getClipboard) ~= "function" then
                error("clipboard reader unavailable")
            end
            value = Clipboard.getClipboard()
            if type(value) ~= "string" then error("clipboard text unavailable") end
        end)
        return ok and value or nil
    end
    local function splitAt(text, position)
        local left, right, i = {}, {}, 0
        for ch in MC_StringUtils.utf8chars(text) do
            if i < position then left[#left + 1] = ch else right[#right + 1] = ch end
            i = i + 1
        end
        return table.concat(left), table.concat(right)
    end
    local function clampChars(text, limit)
        local out, n = {}, 0
        for ch in MC_StringUtils.utf8chars(text) do
            if n >= limit then break end
            n = n + 1
            out[#out + 1] = ch
        end
        return table.concat(out)
    end
    local original_textEntry_onOtherKey = textEntry.onOtherKey
    textEntry.onOtherKey = function(self, key)
        if not chatSurfaceOn() then
            if original_textEntry_onOtherKey then
                return original_textEntry_onOtherKey(self, key)
            end
            return
        end
        -- Keep the one-shot fresh-focus marker until native text insertion for
        -- Slash.  onOtherKey can run before onTextChange; disarming here was
        -- what allowed a remembered "/ooc " to become "/ooc /say".
        local slashKey = key == 47 or key == 53
        if self.mcFreshFocusFirstEdit == true and not slashKey then
            MC_Input.disarmFreshFocus(self)
        end
        local win = key == KEY_ESCAPE and mcWindow() or nil
        local ownedMenu = win and (win.quickMenu or win.mcMenuEscapeConsumed)
        if key == KEY_ESCAPE and (ownedMenu or escapeCancelsFocus()) then
            if scheduleEscapeCancellation and scheduleEscapeCancellation() then
                return
            end
        end
        if key == KEY_TAB then
            local win = mcWindow()
            if win then win:cycleTab(1) end
            return
        end
        if key == KEY_RIGHT and self.mcWholeLineSelected then
            self.mcWholeLineSelected = false
            if self.setCursorPos then
                self:setCursorPos(MC_StringUtils.utf8len(self:getText() or ""))
            end
            return
        end
        if key == KEY_RIGHT and acceptCommandHint(self) then
            return
        end
        local ctrl = isCtrlKeyDown and isCtrlKeyDown()
        if key == KEY_A and ctrl then
            dbg("CTRL-A: select-all")
            if self.selectAll then
                self.mcWholeLineSelected = safeExec("select-all", function() self:selectAll() end)
            else
                self.mcWholeLineSelected = false
            end
            return
        end
        if ctrl and (key == KEY_C or key == KEY_X) and self.mcWholeLineSelected then
            local text = self:getText() or ""
            if clipSet(text) and key == KEY_X then
                self:setText("")
                if self.setCursorPos then self:setCursorPos(0) end
            end
            if key == KEY_X then self.mcWholeLineSelected = false end
            return
        end
        if ctrl and key == KEY_V then
            local pasted = clipGet()
            if pasted ~= nil then
                safeExec("clipboard-paste", function()
                    pasted = pasted:gsub("\r\n", "\n"):gsub("[\r\n]", " ")
                    local current = self:getText() or ""
                    local cursor = self.getCursorPos and self:getCursorPos()
                        or MC_StringUtils.utf8len(current)
                    local left, right = "", ""
                    if not self.mcWholeLineSelected then left, right = splitAt(current, cursor) end
                    local limit = inputLimitAppliedValue
                        or MC_Config.liveSandbox("MaxMessageLength", 1000)
                    local joined = clampChars(left .. pasted .. right, limit)
                    self:setText(joined)
                    if self.setCursorPos then
                        local desired = math.min(MC_StringUtils.utf8len(left .. pasted),
                            MC_StringUtils.utf8len(joined))
                        self:setCursorPos(desired)
                    end
                end)
            end
            self.mcWholeLineSelected = false
            return
        end
        self.mcWholeLineSelected = false
        if original_textEntry_onOtherKey then
            return original_textEntry_onOtherKey(self, key)
        end
    end
end

-- The deepest seam: textEntry.onCommandEntered on the live widget. Keyed
-- on widget identity -- a recreated widget gets the full per-entry set
-- rehooked with fresh originals; a tampered seam on the same widget gets
-- the wrapper reasserted (chaining to a foreign newcomer, never to a
-- stale copy of ourselves).
local function installTextEntryHooks()
    if not chatSurfaceOn() then return false end
    local instance = ISChat and ISChat.instance
    local textEntry = instance and resolveTextEntry(instance)
    if not textEntry then
        dbg("installTextEntryHooks: no text entry to hook")
        return false
    end
    local current = textEntry.onCommandEntered
    if textEntry == hookedTextEntry and submitEntryWrapper
        and current == submitEntryWrapper then
        return true
    end

    if submitEntryWrapper == nil then
        submitEntryWrapper = function()
            if not chatSurfaceOn() then
                if submitEntryOriginal then return submitEntryOriginal() end
                if submitClassOriginal and ISChat and ISChat.instance then
                    return submitClassOriginal(ISChat.instance)
                end
                return
            end
            dbg("textEntry.onCommandEntered: FIRED!")
            local ok, handled = pcall(interceptCommand, ISChat.instance)
            if not ok then
                MC_Incident.report("CHAT_SUBMIT_INTERCEPT_FAILED",
                    "intercept raised; yielding this submit to vanilla")
            elseif handled then
                dbg("textEntry.onCommandEntered: intercepted")
                return
            end
            if submitEntryOriginal then
                dbg("textEntry.onCommandEntered: calling original")
                submitEntryOriginal()
            end
            pendingUnfocus = true
            lastMessageSentTime = MC_Core.getTimeMs()
        end
        mcOwnSubmitWrappers[submitEntryWrapper] = true
    end

    if textEntry ~= hookedTextEntry then
        -- New widget: first run, or a recreation (vanilla never recreates
        -- it on current builds, but a third party or future build might).
        if hookedTextEntry ~= nil then
            MC_Incident.report("CHAT_INPUT_HOOK_REPLACED",
                "text entry was recreated; rehooking every per-entry seam")
        end
        hookedTextEntry = textEntry
        -- Fresh chain target from THIS widget -- unless the widget carries
        -- one of our own wrappers (vanilla's rebind pattern copies the
        -- class slot, which is us), in which case chaining to it would be
        -- the self-wrap trap; the class wrapper already owns that path.
        if type(current) == "function" and not mcOwnSubmitWrappers[current] then
            submitEntryOriginal = current
        else
            submitEntryOriginal = nil
        end
        installPerEntryExtras(textEntry)
    elseif mcOwnSubmitWrappers[current] then
        dbg("installTextEntryHooks: reasserting over a stale own wrapper")
    else
        MC_Incident.report("CHAT_INPUT_HOOK_REPLACED",
            "text entry submit seam was overwritten; reinstalling around the newcomer")
        if type(current) == "function" then
            submitEntryOriginal = current
        end
    end

    local ok = pcall(function()
        textEntry.onCommandEntered = submitEntryWrapper
    end)
    if not ok or textEntry.onCommandEntered ~= submitEntryWrapper then
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "text entry submit seam installation failed")
        return false
    end
    return true
end

-- The window-level seams that die with a recreated ISChat.instance:
-- unfocus (the B42 escape fix) and onKeyPress (Escape + history reset).
local function installInstanceHooks()
    if not chatSurfaceOn() then return false end
    local instance = ISChat and ISChat.instance
    if not instance then return false end
    if instance == hookedInstance
        and instance.unfocus == mcUnfocus
        and instance.onKeyPress == mcOnKeyPress
        and instance.focus == mcFocus then
        return true
    end

    if mcUnfocus == nil then
        -- B42 ESCAPE KEY FIX
        -- Override unfocus entirely - vanilla is broken
        mcUnfocus = function(self)
            if not chatSurfaceOn() then
                if mcUnfocusOriginal then return mcUnfocusOriginal(self) end
                return
            end
            dbg("unfocus: OVERRIDE - forcing complete unfocus")

            if self.textEntry then
                safeExec("clear-text", function() self.textEntry:setText("") end)
                safeExec("disable-editing", function() self.textEntry:setEditable(false) end)
                if self.textEntry.unfocus then
                    safeExec("widget-unfocus", function() self.textEntry:unfocus() end)
                end
            end

            -- Clear the CLASS flag vanilla and other mods actually read
            -- (ISChat:focus/:unfocus work on ISChat.focused), and drop any
            -- instance shadow so reads fall through to it. The old
            -- `self.focused = false` wrote a shadow field that hid the
            -- class flag forever after the first send: vanilla's fade
            -- never reset, its mouse handlers swallowed clicks, and every
            -- mod gating keybinds on ISChat.focused saw chat permanently
            -- focused. (Two guarded blocks that used to follow --
            -- ISUIElement.setKeyboardFocus / UIManager.setModalWindow --
            -- are gone: neither API exists in this build's vanilla lua,
            -- so both were dead no-ops.)
            self.focused = nil
            if ISChat then ISChat.focused = false end
            if self.fade then
                safeExec("fade-reset", function() self.fade:reset() end)
            end

            if self.textEntry and self.textEntry.onFocusLost then
                safeExec("focus-lost", function() self.textEntry:onFocusLost() end)
            end

            local win = mcWindow()
            if win then safeExec("mc-window-unfocus", function() win:unfocusInput() end) end

            dbg("unfocus: complete, focused=%s", tostring(ISChat and ISChat.focused))
        end
        mcOnKeyPress = function(self, key)
            if not chatSurfaceOn() then
                if mcOnKeyPressOriginal then return mcOnKeyPressOriginal(self, key) end
                return
            end
            -- Escape key - use Keyboard constant for B42 GLFW
            if key == Keyboard.KEY_ESCAPE and self.focused
                and escapeCancelsFocus() then
                dbg("onKeyPress: ESCAPE - scheduling cancellation")
                if scheduleEscapeCancellation and scheduleEscapeCancellation() then
                    return true
                end
            end

            -- History navigation is handled at textEntry.onPressUp/onPressDown level

            if mcOnKeyPressOriginal then
                return mcOnKeyPressOriginal(self, key)
            end
        end
    end

    if instance ~= hookedInstance then
        if hookedInstance ~= nil then
            MC_Incident.report("CHAT_INPUT_HOOK_REPLACED",
                "chat window was recreated; rehooking window seams")
        end
        hookedInstance = instance
        local currentUnfocus = instance.unfocus or (ISChat and ISChat.unfocus)
        if type(currentUnfocus) == "function" and currentUnfocus ~= mcUnfocus then
            mcUnfocusOriginal = currentUnfocus
        else
            mcUnfocusOriginal = nil
        end
        -- Fresh onKeyPress chain target from the new window (never one of
        -- our own wrappers).
        local currentKeyPress = instance.onKeyPress
        if type(currentKeyPress) == "function" and currentKeyPress ~= mcOnKeyPress then
            mcOnKeyPressOriginal = currentKeyPress
        else
            mcOnKeyPressOriginal = nil
        end
    end

    if mcFocus == nil then
        -- Java's hard-coded chat key (and anything else) that calls
        -- ISChat.instance:focus() lands in OUR box while our window is
        -- up. Only when the window is absent does vanilla's own focus run.
        mcFocus = function(self)
            if not chatSurfaceOn() then
                if mcFocusOriginal then return mcFocusOriginal(self) end
                return
            end
            local win = mcWindow()
            if win then
                dbg("focus: redirected to MC window")
                if not (ISChat and ISChat.focused == true) then
                    escapeCycleActive = false
                end
                win:focusInput(true)
                seedRememberedPrefix(win.entry)
                if self.mcDeferFocusSelection ~= true then
                    finishFocusSelection(win.entry)
                end
                return
            end
            if mcFocusOriginal then
                local result = mcFocusOriginal(self)
                seedRememberedPrefix(self.textEntry)
                if self.mcDeferFocusSelection ~= true then
                    finishFocusSelection(self.textEntry)
                end
                return result
            end
        end
    end
    if instance.focus ~= mcFocus then
        local currentFocus = instance.focus or (ISChat and ISChat.focus)
        if type(currentFocus) == "function" and currentFocus ~= mcFocus then
            mcFocusOriginal = currentFocus
        end
    end

    local ok = pcall(function()
        instance.unfocus = mcUnfocus
        instance.onKeyPress = mcOnKeyPress
        instance.focus = mcFocus
    end)
    if not ok then
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "window seam installation failed")
        return false
    end
    return true
end

-- The aggregate pass, mirroring maintainQBoundary: cheap identity compares
-- when healthy, reinstall + incident when not. Returns whether an
-- authoritative submit seam is live.
local function maintainChatSubmitBoundary()
    if not chatSurfaceOn() then return true end
    if not ISChat or not ISChat.instance then return false end
    local classOk = installSubmitClassHook()
    local entryOk = installTextEntryHooks()
    installInstanceHooks()
    local live = classOk or entryOk
    if live and not submitBoundaryEverLive then
        submitBoundaryEverLive = true
        dbg("maintainChatSubmitBoundary: === HOOKS INSTALLED ===")
    end
    return live
end

-- VANILLA Q / CALLOUT BOUNDARY

local function qClientRuntime()
    local ok, value = pcall(function() return isClient() end)
    if ok and value == false then return false end
    if not ok or value ~= true then
        -- A client Lua file with an unreadable runtime flag is treated as a
        -- client for suppression purposes. Leaving Callout live would be the
        -- unsafe direction; the incident makes the assumption operator-visible.
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "client runtime state unreadable; Callout kept suppressed")
    end
    return true
end

local function shoutKeyState(key)
    local okCore, core = pcall(function() return getCore() end)
    if not okCore or not core then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "getCore unavailable at Shout boundary")
        return false, false
    end

    local okIsKey, isShout = pcall(function()
        return core:isKey("Shout", key)
    end)
    if okIsKey and type(isShout) == "boolean" then
        return isShout, true
    end

    -- B42 bindings can include an alternate code and modifiers. getKey()
    -- exposes only the primary code, so it is not a safe substitute for
    -- isKey() at a suppression boundary.
    MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
        "Core.isKey unavailable; key event suppressed")
    return false, false
end

local function disableVanillaCallout(player)
    if not player then return false end

    local okBefore, before = pcall(function() return player:isCanShout() end)
    if okBefore and before == false then return true end
    if not okBefore or type(before) ~= "boolean" then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "IsoPlayer.canShout pre-disable state unreadable")
    end

    local okSet = pcall(function() player:setCanShout(false) end)
    if not okSet then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "IsoPlayer.setCanShout(false) failed")
        return false
    end

    local okAfter, after = pcall(function() return player:isCanShout() end)
    if not okAfter or after ~= false then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "IsoPlayer.canShout disable could not be verified")
        return false
    end
    if before == true then qSuppressedPlayers[player] = true end
    return true
end

local function restoreVanillaCallouts()
    for player in pairs(qSuppressedPlayers) do
        local okRead, value = pcall(function() return player:isCanShout() end)
        if okRead and value == true then
            qSuppressedPlayers[player] = nil
        elseif okRead and value == false then
            local okSet = pcall(function() player:setCanShout(true) end)
            if okSet then
                qSuppressedPlayers[player] = nil
            else
                MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                    "IsoPlayer.setCanShout(true) failed during feature hand-off")
            end
        else
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "IsoPlayer.canShout restore state unreadable")
        end
    end
end

-- Return vehicle, isDriver, reliable. An unreadable result is not equivalent
-- to "on foot": Q has a separate zero-argument passenger Callout path.
local function qVehicleState(player)
    local okVehicle, vehicle = pcall(function() return player:getVehicle() end)
    if not okVehicle then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "player vehicle state unreadable")
        return nil, false, false
    end
    if not vehicle then return nil, false, true end

    local okDriver, isDriver = pcall(function()
        return vehicle:isDriver(player)
    end)
    if not okDriver or type(isDriver) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "vehicle driver state unreadable")
        return vehicle, false, false
    end
    return vehicle, isDriver, true
end

-- Callout() also owns the vanilla bubble and world-noise event, so invoking it
-- after MC routing would duplicate both. This is the narrower voice primitive
-- used by Build 42's Callout implementation: it plays the selected character
-- voice locally and transmits that voice sound to nearby clients.
local function qTransmitShoutVoice(player, sneaking, roll)
    local sound = "ShoutHey"
    if sneaking then
        sound = roll == 2 and "WhisperHey" or "WhisperPsst"
    end

    local ok = pcall(function()
        player:transmitPlayerVoiceSound(sound)
    end)
    if not ok then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "Callout voice sound unavailable")
    end
    return ok
end

local function routeQCallout(player)
    if not player then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "local player unavailable")
        return false
    end

    local okDead, isDead = pcall(function() return player:isDead() end)
    if not okDead or type(isDead) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "player life state unreadable")
        return false
    end
    if isDead then return false end

    local okSneaking, sneaking = pcall(function()
        return player:isSneaking()
    end)
    if not okSneaking or type(sneaking) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "player crouch state unreadable")
        return false
    end

    local okRoll, roll = pcall(function() return ZombRand(3) end)
    if not okRoll or type(roll) ~= "number"
        or roll < 0 or roll >= 3 or roll ~= math.floor(roll)
    then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "Callout phrase selection unavailable")
        return false
    end

    local channel = sneaking and "low" or "yell"
    local key = "IGUI_PlayerText_Callout" .. tostring(roll + 1)
        .. (sneaking and "Sneak" or "New")
    local okText, text = pcall(function() return getText(key) end)
    if not okText or type(text) ~= "string" or text == "" or text == key then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "localized Callout phrase unavailable")
        return false
    end

    local radioEmitters, radioOk = collectRadioEmitters(player, channel)
    if not radioOk then
        localSysMsg("Radio state could not be verified; your callout was not sent.",
            {255, 100, 100})
        return false
    end

    local okSend = pcall(emitChatMessage, {
        channel = channel,
        message = text,
        radioEmitters = radioEmitters,
    }, "qshout", nil)
    if not okSend then
        MC_Incident.report("QSHOUT_ROUTE_FAILED",
            "ChatMessage transport unavailable")
        localSysMsg("Your callout could not be sent.", {255, 100, 100})
        return false
    end

    dbg("Q-SHOUT: routed localized %s through MC_Server", channel)
    qTransmitShoutVoice(player, sneaking, roll)
    return true
end

local function qTimestamp(stage)
    local ok, value = pcall(function() return getTimestampMs() end)
    if not ok or type(value) ~= "number"
        or value ~= value or value == math.huge or value == -math.huge
    then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            tostring(stage) .. " timestamp unavailable")
        return nil
    end
    return value
end

local function qRadialVisible(stage)
    local okRadial, radial = pcall(function()
        return getPlayerRadialMenu(0)
    end)
    if not okRadial or not radial then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            tostring(stage) .. " radial menu unavailable")
        return false, false
    end
    local okVisible, visible = pcall(function()
        return radial:isReallyVisible()
    end)
    if not okVisible or type(visible) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            tostring(stage) .. " radial visibility unreadable")
        return false, false
    end
    return visible, true
end

local function qRecordFootPress(key)
    qFootPress = nil
    local okCheck, eligible = pcall(function()
        return ISEmoteRadialMenu.checkKey(key)
    end)
    if not okCheck or type(eligible) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "Shout press eligibility unreadable")
        return
    end
    if not eligible then return end

    local at = qTimestamp("Shout press")
    if not at then return end

    local okCore, core = pcall(function() return getCore() end)
    local okToggle, toggle = false, nil
    if okCore and core then
        okToggle, toggle = pcall(function()
            return core:getOptionRadialMenuKeyToggle()
        end)
    end
    if not okToggle or type(toggle) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "radial toggle option unreadable")
        return
    end

    local radialWasVisible = false
    if toggle then
        local visible, reliable = qRadialVisible("Shout press")
        if not reliable then return end
        radialWasVisible = visible
    end
    qFootPress = {
        at = at,
        radialWasVisible = radialWasVisible,
    }
end

local function qShouldRouteFootRelease(key, player)
    local press = qFootPress
    qFootPress = nil
    if not press then return false end

    local okCheck, eligible = pcall(function()
        return ISEmoteRadialMenu.checkKey(key)
    end)
    if not okCheck or type(eligible) ~= "boolean" then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "Shout release eligibility unreadable")
        return false
    end
    if not eligible then return false end

    local now = qTimestamp("Shout release")
    if not now then return false end
    local elapsed = now - press.at
    if elapsed < 0 then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "Shout hold duration invalid")
        return false
    end
    local holdMs = tonumber(MC_Theme.access().qHoldMs) or Q_RADIAL_HOLD_MS
    if elapsed >= holdMs or press.radialWasVisible then
        return false
    end

    local vehicle, _, vehicleReliable = qVehicleState(player)
    if not vehicleReliable then return false end
    if vehicle then return false end

    local radialVisible, radialReliable = qRadialVisible("Shout release")
    if not radialReliable then return false end
    return not radialVisible
end

local function qPlayShoutEmote(player)
    local ok = pcall(function() player:playEmote("shout") end)
    if not ok then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "shout animation unavailable")
    end
    return ok
end

local function qSetJoypadRecenter(player)
    local ok = pcall(function()
        player:setJoypadIgnoreAimUntilCentered(true)
    end)
    if not ok then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "joypad recenter state unavailable")
    end
    return ok
end

local function installVehicleCalloutHook()
    if qVehicleHooked
        and ISVehicleMenu
        and ISVehicleMenu.onKeyPressed == qVehicleWrapper
    then
        return true
    end
    if not ISVehicleMenu or type(ISVehicleMenu.onKeyPressed) ~= "function" then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "ISVehicleMenu.onKeyPressed unavailable")
        return false
    end

    if qVehicleHooked and qVehicleWrapper then
        pcall(function() Events.OnKeyPressed.Remove(qVehicleWrapper) end)
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "vehicle Shout hook was replaced; reinstalling")
    end

    local original = ISVehicleMenu.onKeyPressed
    local wrapper = function(key)
        if not chatSurfaceOn() then return original(key) end
        local isShout, reliable = shoutKeyState(key)
        if not reliable then return end -- block every uncertain vehicle key
        if isShout then
            local okPlayer, player = pcall(function()
                return getSpecificPlayer(0)
            end)
            if not okPlayer or not player then
                MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
                    "vehicle Shout player unavailable")
                return
            end

            local vehicle, isDriver, vehicleReliable = qVehicleState(player)
            if not vehicleReliable then return end
            if vehicle and not isDriver then
                -- Replace vanilla's zero-argument Callout() overload here;
                -- setCanShout(false) cannot gate that overload.
                disableVanillaCallout(player)
                routeQCallout(player)
                return
            end
        end
        return original(key)
    end
    qVehicleWrapper = wrapper

    local okInstall = pcall(function()
        Events.OnKeyPressed.Remove(original)
        ISVehicleMenu.onKeyPressed = qVehicleWrapper
        Events.OnKeyPressed.Add(qVehicleWrapper)
    end)
    if not okInstall then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "vehicle Shout event hook installation failed")
        return false
    end
    qVehicleHooked = true
    return true
end

local function installEmoteCalloutHooks()
    if not ISEmoteRadialMenu then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "ISEmoteRadialMenu unavailable")
        return false
    end

    local pressOk = qEmotePressHooked
        and ISEmoteRadialMenu.onKeyPressed == qEmotePressWrapper
    if not pressOk then
        if type(ISEmoteRadialMenu.onKeyPressed) ~= "function" then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout press handler unavailable")
            return false
        end
        if qEmotePressHooked and qEmotePressWrapper then
            pcall(function()
                Events.OnKeyStartPressed.Remove(qEmotePressWrapper)
            end)
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout press hook was replaced; reinstalling")
        end

        local original = ISEmoteRadialMenu.onKeyPressed
        local wrapper = function(key)
            if not chatSurfaceOn() then return original(key) end
            local isShout, reliable = shoutKeyState(key)
            if not reliable then
                qFootPress = nil
                return
            end
            if isShout then
                qRecordFootPress(key)
                local okPlayer, player = pcall(function()
                    return getSpecificPlayer(0)
                end)
                if okPlayer and player then
                    disableVanillaCallout(player)
                else
                    MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
                        "Shout press player unavailable")
                    qFootPress = nil
                end
            end
            return original(key)
        end
        qEmotePressWrapper = wrapper
        local ok = pcall(function()
            Events.OnKeyStartPressed.Remove(original)
            ISEmoteRadialMenu.onKeyPressed = qEmotePressWrapper
            Events.OnKeyStartPressed.Add(qEmotePressWrapper)
        end)
        if not ok
            or ISEmoteRadialMenu.onKeyPressed ~= qEmotePressWrapper
        then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout press hook installation failed")
            return false
        end
        qEmotePressHooked = true
    end

    local releaseOk = qEmoteReleaseHooked
        and ISEmoteRadialMenu.onKeyReleased == qEmoteReleaseWrapper
    if not releaseOk then
        if type(ISEmoteRadialMenu.onKeyReleased) ~= "function" then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout release handler unavailable")
            return false
        end
        if qEmoteReleaseHooked and qEmoteReleaseWrapper then
            pcall(function()
                Events.OnKeyPressed.Remove(qEmoteReleaseWrapper)
            end)
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout release hook was replaced; reinstalling")
        end

        local original = ISEmoteRadialMenu.onKeyReleased
        local wrapper = function(key)
            if not chatSurfaceOn() then return original(key) end
            local isShout, reliable = shoutKeyState(key)
            if not reliable then
                qFootPress = nil
                return
            end
            if not isShout then return original(key) end

            local okPlayer, player = pcall(function()
                return getSpecificPlayer(0)
            end)
            if not okPlayer or not player then
                qFootPress = nil
                MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
                    "Shout release player unavailable")
                return
            end

            local shouldRoute = qShouldRouteFootRelease(key, player)
            if not disableVanillaCallout(player) then
                MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                    "vanilla Shout release withheld; canShout gate unavailable")
                return
            end

            -- Preserve vanilla's radial visibility/cleanup state machine.
            -- Callout(true) becomes a no-op while canShout is false.
            local result = original(key)
            if shouldRoute and routeQCallout(player) then
                qPlayShoutEmote(player)
            end
            return result
        end
        qEmoteReleaseWrapper = wrapper
        local ok = pcall(function()
            Events.OnKeyPressed.Remove(original)
            ISEmoteRadialMenu.onKeyReleased = qEmoteReleaseWrapper
            Events.OnKeyPressed.Add(qEmoteReleaseWrapper)
        end)
        if not ok
            or ISEmoteRadialMenu.onKeyReleased ~= qEmoteReleaseWrapper
        then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout release hook installation failed")
            return false
        end
        qEmoteReleaseHooked = true
    end

    local actionOk = qEmoteActionHooked
        and ISEmoteRadialMenu.emote == qEmoteActionWrapper
    if not actionOk then
        if type(ISEmoteRadialMenu.emote) ~= "function" then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout action unavailable")
            return false
        end
        if qEmoteActionHooked then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout action hook was replaced; reinstalling")
        end
        local original = ISEmoteRadialMenu.emote
        local wrapper = function(self, emote)
            if not chatSurfaceOn() then return original(self, emote) end
            if emote == "shout" then
                local player = self and self.character or nil
                disableVanillaCallout(player)
                if not player then
                    MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
                        "radial Shout player unavailable")
                    return
                end
                -- Preserve every non-Callout side effect of vanilla's
                -- ISEmoteRadialMenu:emote("shout").
                qPlayShoutEmote(player)
                local routed = routeQCallout(player)
                qSetJoypadRecenter(player)
                return routed
            end
            return original(self, emote)
        end
        qEmoteActionWrapper = wrapper
        local ok = pcall(function()
            ISEmoteRadialMenu.emote = qEmoteActionWrapper
        end)
        if not ok or ISEmoteRadialMenu.emote ~= qEmoteActionWrapper then
            MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
                "emote Shout action hook installation failed")
            return false
        end
        qEmoteActionHooked = true
    end
    return true
end

local function installDPadCalloutHook()
    if qDPadHooked
        and ISDPadWheels
        and ISDPadWheels.onShout == qDPadWrapper
    then
        return true
    end
    if not ISDPadWheels or type(ISDPadWheels.onShout) ~= "function" then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "ISDPadWheels.onShout unavailable")
        return false
    end
    if qDPadHooked then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "D-pad Shout hook was replaced; reinstalling")
    end
    local original = ISDPadWheels.onShout
    qDPadWrapper = function(player)
        if not chatSurfaceOn() then return original(player) end
        disableVanillaCallout(player)
        return routeQCallout(player)
    end
    local ok = pcall(function()
        ISDPadWheels.onShout = qDPadWrapper
    end)
    if not ok or ISDPadWheels.onShout ~= qDPadWrapper then
        MC_Incident.report("QSHOUT_BOUNDARY_UNAVAILABLE",
            "D-pad Shout hook installation failed")
        return false
    end
    qDPadHooked = true
    return true
end

local function maintainQBoundary()
    if not chatSurfaceOn() then
        qFootPress = nil
        restoreVanillaCallouts()
        return true
    end
    if not qClientRuntime() then return true end

    local okPlayer, player = pcall(function() return getPlayer() end)
    if okPlayer and player then
        disableVanillaCallout(player)
    elseif not okPlayer then
        MC_Incident.report("QSHOUT_STATE_UNAVAILABLE",
            "local player lookup failed during boundary maintenance")
    end
    installVehicleCalloutHook()
    installEmoteCalloutHooks()
    installDPadCalloutHook()
    return true
end

MC_Input._routeQCallout = routeQCallout
MC_Input._maintainQBoundary = maintainQBoundary
MC_Input._maintainChatSubmitBoundary = maintainChatSubmitBoundary

-- EVENT HANDLERS

local function OnGameStart()
    dbg("OnGameStart: called")
    maintainQBoundary()
    if ISChat and ISChat.instance then
        dbg("OnGameStart: installing submit boundary")
        if not maintainChatSubmitBoundary() then
            MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
                "no authoritative submit seam installed at game start")
        end
    else
        dbg("OnGameStart: ISChat not ready, will try on tick")
    end
end

-- FOCUS ROUTING (MC_ChatWindow)
--
-- MongooseChat owns the chat window now, so "focus chat" means focusing
-- OUR entry box. Vanilla's is still reachable and still real -- it backs
-- the Admin tab -- so every helper here falls back to it rather than
-- assuming our window exists. A build where our window failed to come up
-- must still be able to talk.


local function chatIsFocused()
    local win = mcWindow()
    if win then return win:isInputFocused() end
    return ISChat and ISChat.instance and ISChat.instance.focused == true
end

local function focusedTextEntry()
    local win = mcWindow()
    if win and win.entry then return win.entry end
    return ISChat and ISChat.instance and ISChat.instance.textEntry or nil
end

scheduleEscapeCancellation = function()
    -- All entry/window/global callbacks for one physical press share this
    -- latch.  In particular, a held Escape must not capture a second tab
    -- after the first tab's delayed request has already been applied.
    if escapeCycleActive then return true end
    escapeCycleActive = true

    local win = mcWindow()
    -- Native menu delivery and entry/global fallbacks meet here. Route Escape
    -- to the deepest menu before chat cancellation. The
    -- cycle latch keeps later callbacks for this physical press from falling
    -- through to the draft after the menu has closed.
    if win and win.quickMenu then
        local ok, handled = pcall(function()
            return require("MC_QuickMenu").dismissEscape(win)
        end)
        if ok and handled then return true end
        -- It is still our visible menu.  Fail closed if its route broke.
        MC_Incident.report("CHAT_INPUT_OPERATION_FAILED",
            "operation=menu-escape-route")
        return true
    end
    if win and win.mcMenuEscapeConsumed then return true end

    local clearDraft = MC_Theme.access().escapeClearsInput ~= false
    if win then
        -- A current owned window without the token API is not a supported old
        -- implementation.  Fail closed: consume Escape, clear and blur none.
        if type(win.captureInputCancellation) ~= "function" then return true end
        local ok, token = pcall(win.captureInputCancellation, win, clearDraft)
        if not ok or token == nil then return true end
        pendingEscapeCancellation = { window = win, token = token }
    else
        -- No owned box means there is no MC draft to clear.  Keep the old
        -- delayed unfocus behaviour and leave native text ownership alone.
        pendingUnfocus = true
    end

    inputHistory:reset()
    return true
end

-- Internal contract: the owned root menu's ISUIElement key-release seam joins
-- latch as the entry and global callbacks.  Keep this narrow: foreign UI must
-- never gain a route into chat cancellation.
function MC_Input._routeOwnedMenuEscape(owner)
    if not chatSurfaceOn() then return false end
    local win = mcWindow()
    if not win or win ~= owner or not win.quickMenu then return false end
    return scheduleEscapeCancellation() == true
end

local function applyEscapeCancellation()
    local request = pendingEscapeCancellation
    pendingEscapeCancellation = nil
    if not request or not chatSurfaceOn() or not escapeCancelsFocus() then return end

    local applied = false
    if request.window then
        local win = mcWindow()
        if win ~= request.window then return end
        if request.token and type(win.applyInputCancellation) == "function" then
            local ok, result = pcall(win.applyInputCancellation, win, request.token)
            applied = ok and result == true
        end
    end

    if applied and ISChat and ISChat.instance then
        -- Keep the vanilla class flag and hidden native widget in step with
        -- the owned box.  This remains delayed on the same safe tick seam.
        ISChat.instance:unfocus()
    end
end

local function releaseEscapeCycle()
    local win = mcWindow()
    if not escapeCycleActive or type(isKeyDown) ~= "function" then return end
    local escapeKey = (Keyboard and Keyboard.KEY_ESCAPE) or 256
    local ok, down = pcall(function()
        return isKeyDown(escapeKey) == true or isKeyDown(1) == true
    end)
    if ok and not down then
        escapeCycleActive = false
        if win then win.mcMenuEscapeConsumed = nil end
    end
end

-- Vanilla registers ISChat.onToggleChatBox on OnKeyPressed at game start,
-- AFTER our handler, so on the toggle key it focused its hidden box last
-- and won: keystrokes vanished into a box nobody could see. Once our
-- window is up, vanilla's handler is retired and ours carries both keys
-- it handled (toggle, switch stream). If we fell back to the vanilla
-- frame, vanilla keeps its handler.
local vanillaToggleRetired = false
local function retireVanillaToggle()
    if vanillaToggleRetired then return end
    if not (ISChat and type(ISChat.onToggleChatBox) == "function") then return end
    if not mcWindow() then return end
    local ok = pcall(function() Events.OnKeyPressed.Remove(ISChat.onToggleChatBox) end)
    if ok then
        vanillaToggleRetired = true
        dbg("retireVanillaToggle: vanilla chat toggle handler retired")
    else
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "vanilla toggle handler could not be retired")
    end
end

local function restoreVanillaToggle()
    if not vanillaToggleRetired then return end
    if not (ISChat and type(ISChat.onToggleChatBox) == "function") then return end
    local ok = pcall(function() Events.OnKeyPressed.Add(ISChat.onToggleChatBox) end)
    if ok then
        vanillaToggleRetired = false
        dbg("restoreVanillaToggle: vanilla chat toggle handler restored")
    else
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "vanilla toggle handler could not be restored during feature hand-off")
    end
end

-- Our own window's text box gets the same per-entry extras vanilla's
-- did -- command history, ghost hint, Tab/Right accept, Ctrl-A, typing
-- broadcast. Keyed on widget identity so a rebuilt window is rehooked.
-- (The first window cut wired only onCommandEntered and silently lost
-- all of these; this is the repair.)
local hookedWindowEntry = nil
local function installWindowEntryHooks()
    if not chatSurfaceOn() then return end
    local win = mcWindow()
    local entry = win and win.entry
    if not entry or entry == hookedWindowEntry then return end
    hookedWindowEntry = entry
    local ok = pcall(installPerEntryExtras, entry)
    if ok then
        dbg("installWindowEntryHooks: per-entry extras on the MC window box")
    else
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "per-entry extras failed on the MC window box")
    end
end

local function OnTickBody()
    if not chatSurfaceOn() then
        chatWindowExpected = false
        inputLimitPending = false
        pendingUnfocus = false
        pendingEscapeCancellation = nil
        restoreVanillaToggle()
        maintainQBoundary()
        return
    end

    retireVanillaToggle()
    installWindowEntryHooks()
    releaseEscapeCycle()

    -- Keep vanilla Callout disabled and repair any shipped-Lua seam another
    -- module replaced after OnGameStart. Incident reporting is rate-limited.
    maintainQBoundary()

    -- Identity-guarded liveness pass over the submit seams: a handful of
    -- compares when healthy, reinstall + incident when replaced. The
    -- not-yet-ready window before the chat window exists stays silent;
    -- losing a seam we once held does not.
    local live = maintainChatSubmitBoundary()
    if not live and submitBoundaryEverLive then
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "submit seam lost and could not be reinstalled")
    end


    if chatWindowExpected then
        local entry = ISChat and ISChat.instance and ISChat.instance.textEntry
        if entry ~= inputLimitAppliedEntry
            or MC_Config.MaxMessageLength ~= inputLimitAppliedValue
        then
            inputLimitPending = true
        end
        if inputLimitPending then MC_Input.applyChatBoxMaxLength() end
    end
    
    -- Escape cancellation is token-bound to the entry/tab which received the
    -- key.  Apply it before ordinary delayed submit blur.
    if pendingEscapeCancellation then
        dbg("OnTick: processing pending Escape cancellation")
        safeExec("delayed-escape-cancellation", applyEscapeCancellation)
    end

    -- Process delayed unfocus
    if pendingUnfocus then
        dbg("OnTick: processing pendingUnfocus")
        safeExec("delayed-unfocus", function()
            local win = mcWindow()
            if win then win:unfocusInput() end
            -- Vanilla is unfocused as well regardless: leaving
            -- ISChat.focused stuck true is the old bug that silently
            -- disabled every other mod's keybinds.
            if ISChat and ISChat.instance then
                ISChat.instance:unfocus()
            end
        end)
        pendingUnfocus = false
    end
end

-- PZ's event dispatch aborts the remaining handlers when one throws, so an
-- unguarded error here would starve every mod registered after us on the
-- shared OnTick -- exactly the failure class MongooseChat accuses others
-- of. The wrapper's incident is rate-limited by MC_Incident itself.
local function OnTick()
    safeExec("input-ontick", OnTickBody)
end

local function OnChatWindowInit()
    if not chatSurfaceOn() then
        chatWindowExpected = false
        inputLimitPending = false
        return
    end
    chatWindowExpected = true
    local live = maintainChatSubmitBoundary()
    if not live then
        MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
            "no authoritative submit seam installed at chat readiness")
    end
    MC_Input.applyChatBoxMaxLength()
end

MC_Input._onChatWindowInitForTest = OnChatWindowInit
MC_Input._inputLimitStateForTest = function()
    return {
        expected = chatWindowExpected,
        pending = inputLimitPending,
        entry = inputLimitAppliedEntry,
        value = inputLimitAppliedValue,
    }
end

local function focusChatWithRememberedPrefix()
    if not chatIsFocused() then escapeCycleActive = false end
    local win = mcWindow()
    if win then
        win:focusInput(true)
        seedRememberedPrefix(win.entry)
        finishFocusSelection(win.entry)
        return
    end
    local entry = ISChat.instance.textEntry
    local wasFocused = ISChat.instance.focused == true
    ISChat.instance:focus()
    if not wasFocused and entry and entry.mcWholeLineSelected ~= true then
        entry.mcNeedsSelectOnFocus = true
    end
    seedRememberedPrefix(entry)
    finishFocusSelection(entry)
end
MC_Input._focusChatWithRememberedPrefixForTest = focusChatWithRememberedPrefix

local function OnKeyPressed(key)
    if not chatSurfaceOn() then return end
    if not ISChat or not ISChat.instance then return end
    
    -- Escape backup handler
    local escapeKey = (Keyboard and Keyboard.KEY_ESCAPE) or 256
    if key == escapeKey or key == 1 then
        local win = mcWindow()
        local ownedMenu = win and (win.quickMenu or win.mcMenuEscapeConsumed)
        if ownedMenu or (chatIsFocused() and escapeCancelsFocus()) then
            dbg("OnKeyPressed: ESCAPE backup - scheduling cancellation")
            scheduleEscapeCancellation()
            return
        end
    end
    
    -- UITextBox2 does not reliably forward horizontal-arrow movement through
    -- onOtherKey on every B42 build. The global key-release event is the
    -- fallback acceptance seam while chat is focused. Support both the GLFW
    -- and legacy LWJGL right-arrow codes used across the supported builds.
    if chatIsFocused() then
        local configuredRight = Keyboard and Keyboard.KEY_RIGHT or nil
        if key == configuredRight or key == 262 or key == 205 then
            acceptCommandHint(focusedTextEntry())
        end
        return
    end
    
    -- Don't intercept in main menu
    if MainScreen and MainScreen.instance and MainScreen.instance:isVisible() then return end
    
    local player = getPlayer()
    if not player then return end
    
    -- Chat toggle keys
    local toggleKey = getCore():getKey("Toggle chat")
    local altToggleKey = getCore():getKey("Alt toggle chat")
    local mcToggleKey = MC_KeyBindings.key(MC_KeyBindings.NAMES.TOGGLE)
    
    -- Cooldown check for Enter - prevents reopening immediately after send
    if key == 28 then  -- 28 = Enter
        local now = MC_Core.getTimeMs()
        local cooldown = MC_Theme.access().enterCooldownMs
        if cooldown == nil then cooldown = ENTER_COOLDOWN_MS end
        if cooldown > 0 and (now - lastMessageSentTime) < cooldown then
            dbg("OnKeyPressed: Enter ignored (cooldown)")
            return
        end
    end
    
    if key == toggleKey or key == altToggleKey or key == mcToggleKey
        or key == 28 then  -- 28 = Enter
        focusChatWithRememberedPrefix()
        return
    end

    -- MongooseChat's own rebindable keys (Options > Key Bindings). All
    -- single presses; all unbound by default except the toggle.
    do
        local win = mcWindow()
        local N = MC_KeyBindings.NAMES
        if win then
            if key == MC_KeyBindings.key(N.NEXT_TAB) then
                win:cycleTab(1)
                return
            elseif key == MC_KeyBindings.key(N.PREV_TAB) then
                win:cycleTab(-1)
                return
            elseif key == MC_KeyBindings.key(N.LOCK) then
                local MC_ChatWindow = require("MC_ChatWindow")
                MC_ChatWindow.setAccess("locked", not MC_ChatWindow.getAccess().locked)
                return
            elseif key == MC_KeyBindings.key(N.TEXT_BIGGER)
                or key == MC_KeyBindings.key(N.TEXT_SMALLER) then
                local MC_Options = require("MC_Options")
                if MC_Options.available() then
                    local step = (key == MC_KeyBindings.key(N.TEXT_BIGGER)) and 1 or -1
                    local a = MC_Options.access()
                    -- textSize combo: 1 Follow, 2 Small, 3 Medium, 4 Large
                    local current = a.followVanillaFont and 1 or (a.fontStep + 1)
                    local target = math.max(2, math.min(4, (current == 1 and 3 or current) + step))
                    MC_Options.set("textSize", target)
                end
                return
            end
        end
    end

    -- Vanilla's "Switch chat stream" key cycled its tabs; it cycles ours.
    local switchKey = getCore():getKey("Switch chat stream")
    if switchKey and key == switchKey then
        local win = mcWindow()
        if win then
            win:cycleTab()
            return
        end
    end
    
    -- Slash key - open with "/" prefix
    if key == 53 then  -- KEY_SLASH
        local win = mcWindow()
        if win then
            win:focusInput(true)
            MC_Input.setFreshSlash(win.entry)
            return
        end
        ISChat.instance.mcDeferFocusSelection = true
        ISChat.instance:focus()
        ISChat.instance.mcDeferFocusSelection = false
        if ISChat.instance.textEntry then
            local entry = ISChat.instance.textEntry
            MC_Input.setFreshSlash(entry)
        end
        return
    end
    
end

local function OnKeyKeepPressed(key)
    if not chatSurfaceOn() then return end
    local escapeKey = (Keyboard and Keyboard.KEY_ESCAPE) or 256
    local win = mcWindow()
    local ownedMenu = win and (win.quickMenu or win.mcMenuEscapeConsumed)
    if (key == escapeKey or key == 1)
        and (ownedMenu or (chatIsFocused() and escapeCancelsFocus())) then
        dbg("OnKeyKeepPressed: ESCAPE held - scheduling cancellation")
        scheduleEscapeCancellation()
    end
end

-- INITIALIZATION

Events.OnGameStart.Add(OnGameStart)
Events.OnTick.Add(OnTick)
-- OnChatWindowInit fires after OnGameStart and is where vanilla finishes
-- the chat window -- and where at least one third-party mod re-hooks the
-- submit seams over whoever holds them. Running the boundary here too
-- repairs that clobber in the same dispatch instead of a tick later.
if Events.OnChatWindowInit then
    Events.OnChatWindowInit.Add(OnChatWindowInit)
end
Events.OnKeyPressed.Add(OnKeyPressed)
Events.OnKeyKeepPressed.Add(OnKeyKeepPressed)

dbg("=== MC_Input module loaded ===")

return MC_Input
