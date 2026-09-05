--[[
================================================================================
    MongooseChat - Babble First-Contact Hint

    Pure decision logic for the one-time "you're hearing babble" onboarding
    hint.

    THE SIGNAL: MC_Server additively sets msgData.babbled = true exactly when
    an utterance carried a real language (the speaker wasn't speaking
    English) AND this specific listener wasn't given the language tag (not
    native, hasn't identified it yet) -- i.e. genuinely unlabeled babble for
    THIS receiver. It is never set on the speaker's own echo. See MC_Server's
    sendChatToReceiver for the additive flag itself.

    THE ONCE-FLAG: consumeOnce() stores its marker in the local player's
    per-character modData table.
================================================================================
]]

local MC_Config = require("MC_Config")

local MC_BabbleHint = {}

-- Key written into the per-character modData table once the hint has fired.
MC_BabbleHint.MARKER = "MC_BabbleHintSeen"

--[[
    Does this incoming message qualify as a first-contact babble moment for
    localUsername? Pure predicate, no state touched.

    @param msgData        the (per-receiver) message table the client got
    @param localUsername  the local player's username
    @return boolean
]]
function MC_BabbleHint.isQualifyingBabble(msgData, localUsername)
    if type(msgData) ~= "table" then return false end
    if not msgData.babbled then return false end
    if localUsername and msgData.username == localUsername then return false end
    return true
end

--[[
    Once-per-character consumption against an injected store (shaped like
    player:getModData() -- a plain table). Returns true (and marks the store
    consumed) the FIRST time it is called against a fresh store; false on
    every subsequent call with the same store.

    A non-table store (modData unavailable this tick) fails toward NOT
    firing, matching MC_Server.checkFreshCharacter's own fail-toward-silence
    rule for the same class of per-character stamp.

    @param store table|nil
    @return boolean
]]
function MC_BabbleHint.consumeOnce(store)
    if type(store) ~= "table" then return false end
    if store[MC_BabbleHint.MARKER] then return false end
    store[MC_BabbleHint.MARKER] = true
    return true
end

--[[
    The single entry point the client wires in: true exactly once per
    character, on the first qualifying babbled message; false every other
    time (including every non-babble message, every message that's the
    listener's own speech, and every subsequent babbled message).

    @param msgData        the (per-receiver) message table the client got
    @param localUsername  the local player's username
    @param store           table|nil, the per-character once-flag store
    @return boolean
]]
function MC_BabbleHint.shouldFire(msgData, localUsername, store)
    -- Feature switch: another mod may explain unknown languages instead.
    if not MC_Config.featureOn("BabbleHintsEnabled") then return false end
    if not MC_BabbleHint.isQualifyingBabble(msgData, localUsername) then
        return false
    end
    return MC_BabbleHint.consumeOnce(store)
end

return MC_BabbleHint
