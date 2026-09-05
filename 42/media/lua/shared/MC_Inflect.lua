--[[
================================================================================
    MC_Inflect -- conservative English inflection generation

    THE PROBLEM
    -----------
    The concept tree's English aliases are lemma-only ("know", "help"),
    but players speak inflected English ("knows", "helping", "came").
    MC_Resolve feeds raw chat tokens to MC_Concepts.byEnglish, so every
    inflected content word silently bypassed the acquisition loop -- the
    speaker's sentence babbled correctly, but the listener's exposure
    table never heard it. Measured on a generic RP corpus, roughly half
    of content-word tokens were lost this way.

    THE FIX SHAPE
    -------------
    Inflection handling happens at INDEX BUILD TIME, not in the per-token
    hot path. MC_Concepts.buildEnglishIndex calls expand() once per alias
    and registers the generated forms alongside the lemma. Lookups stay
    O(1); the per-message render path is untouched.

    DESIGN RULES
    ------------
    - Conservative generation only: forms derived from KNOWN lemmas by
      regular morphology plus an explicit irregulars table. We never
      stem unknown input (stemming chat tokens risks false hits;
      generating from known lemmas risks only junk forms nobody types).
    - Junk tolerance: regular rules over-generate for some lemmas
      ("angers", "biggest" is NOT generated -- no comparatives). A junk
      form costs one index slot and can never fire unless a player
      actually types it, at which point mapping "angers" -> ANGER is
      arguably correct anyway.
    - Collisions are fine by construction: the English index maps
      form -> LIST of concept ids (homonyms already work this way --
      see NAIL/NAIL_FASTENER); the resolver tries candidates in order
      and the palette lexicalization filter does the rest.
    - Doubling heuristic: final-consonant doubling (run -> running,
      stop -> stopped) applies only to single-vowel-group lemmas. That
      gets the short Germanic verbs right and correctly leaves
      "open -> opened", "visit -> visited" undoubled. Stress-based
      doubling (occur -> occurred) is not modelled; those verbs are
      rare in survival-RP register and miss harmlessly.

    Kahlua-safe: pure Lua 5.1, ASCII-only string ops.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Inflect = {}

-- Irregular verbs: lemma -> { past forms / participles }. The regular
-- -s and -ing forms are still generated for these (knows, knowing); only
-- the -ed rule is replaced. Scoped to content verbs plausible in the
-- concept tree's register -- auxiliaries (be/do/have as AUX) are function
-- words and deliberately not concepts.
MC_Inflect.IRREGULAR_PAST = {
    become = { "became" },
    begin  = { "began", "begun" },
    bite   = { "bit", "bitten" },
    bleed  = { "bled" },
    blow   = { "blew", "blown" },
    -- NOTE: "break" is a Lua keyword, hence the bracket-key form below.
    ["break"] = { "broke", "broken" },
    bring  = { "brought" },
    build  = { "built" },
    burn   = { "burnt" },
    buy    = { "bought" },
    catch  = { "caught" },
    choose = { "chose", "chosen" },
    come   = { "came" },
    cut    = { "cut" },
    die    = { "died" },  -- regular; listed explicitly so nobody "fixes" it later
    dig    = { "dug" },
    draw   = { "drew", "drawn" },
    drink  = { "drank", "drunk" },
    drive  = { "drove", "driven" },
    eat    = { "ate", "eaten" },
    fall   = { "fell", "fallen" },
    feed   = { "fed" },
    feel   = { "felt" },
    fight  = { "fought" },
    find   = { "found" },
    fly    = { "flew", "flown" },
    forget = { "forgot", "forgotten" },
    freeze = { "froze", "frozen" },
    get    = { "got", "gotten" },
    give   = { "gave", "given" },
    go     = { "went", "gone" },
    grow   = { "grew", "grown" },
    hang   = { "hung" },
    hear   = { "heard" },
    hide   = { "hid", "hidden" },
    hit    = { "hit" },
    hold   = { "held" },
    hurt   = { "hurt" },
    keep   = { "kept" },
    know   = { "knew", "known" },
    leave  = { "left" },
    lie    = { "lay", "lain" },
    lose   = { "lost" },
    make   = { "made" },
    meet   = { "met" },
    pay    = { "paid" },
    put    = { "put" },
    read   = { "read" },
    ride   = { "rode", "ridden" },
    ring   = { "rang", "rung" },
    rise   = { "rose", "risen" },
    run    = { "ran" },
    say    = { "said" },
    see    = { "saw", "seen" },
    sell   = { "sold" },
    send   = { "sent" },
    shoot  = { "shot" },
    sing   = { "sang", "sung" },
    sink   = { "sank", "sunk" },
    sit    = { "sat" },
    sleep  = { "slept" },
    speak  = { "spoke", "spoken" },
    stand  = { "stood" },
    steal  = { "stole", "stolen" },
    swim   = { "swam", "swum" },
    take   = { "took", "taken" },
    teach  = { "taught" },
    tear   = { "tore", "torn" },
    tell   = { "told" },
    think  = { "thought" },
    throw  = { "threw", "thrown" },
    wake   = { "woke", "woken" },
    wear   = { "wore", "worn" },
    win    = { "won" },
    write  = { "wrote", "written" },
}

-- Irregular plurals: lemma -> plural. Presence here SUPPRESSES the
-- regular +s form ("childs" is never generated).
MC_Inflect.IRREGULAR_PLURAL = {
    child = "children",
    foot  = "feet",
    knife = "knives",
    leaf  = "leaves",
    life  = "lives",
    man   = "men",
    mouse = "mice",
    tooth = "teeth",
    wife  = "wives",
    wolf  = "wolves",
    woman = "women",
}

-- Rule helpers

local VOWELS = { a = true, e = true, i = true, o = true, u = true }

local function isVowel(c) return VOWELS[c] == true end

-- Single-vowel-group heuristic for final-consonant doubling: true for
-- run/stop/plan/grab; false for open/visit/listen.
local function singleVowelGroup(w)
    local groups, inGroup = 0, false
    for i = 1, #w do
        local v = isVowel(w:sub(i, i))
        if v and not inGroup then groups = groups + 1 end
        inGroup = v
    end
    return groups == 1
end

-- CVC-final shape with a doublable consonant (not w/x/y).
local function doublesFinal(w)
    if #w < 3 then return false end
    local c1 = w:sub(-3, -3)
    local c2 = w:sub(-2, -2)
    local c3 = w:sub(-1, -1)
    if isVowel(c1) or not isVowel(c2) or isVowel(c3) then return false end
    if c3 == "w" or c3 == "x" or c3 == "y" then return false end
    return singleVowelGroup(w)
end

local function endsWith(w, suf) return w:sub(-#suf) == suf end

local function sForm(w)
    if endsWith(w, "s") or endsWith(w, "x") or endsWith(w, "z")
       or endsWith(w, "ch") or endsWith(w, "sh") then
        return w .. "es"
    end
    if endsWith(w, "y") and #w >= 2 and not isVowel(w:sub(-2, -2)) then
        return w:sub(1, -2) .. "ies"
    end
    return w .. "s"
end

local function edForm(w)
    if endsWith(w, "e") then return w .. "d" end
    if endsWith(w, "y") and #w >= 2 and not isVowel(w:sub(-2, -2)) then
        return w:sub(1, -2) .. "ied"
    end
    if doublesFinal(w) then return w .. w:sub(-1) .. "ed" end
    return w .. "ed"
end

local function ingForm(w)
    if endsWith(w, "ie") then return w:sub(1, -3) .. "ying" end
    if endsWith(w, "ee") then return w .. "ing" end
    if endsWith(w, "e") then return w:sub(1, -2) .. "ing" end
    if doublesFinal(w) then return w .. w:sub(-1) .. "ing" end
    return w .. "ing"
end

-- Public API

-- True if a lemma is eligible for expansion: pure lowercase ASCII letters,
-- length >= 3. Hyphenated aliases ("back-of") and very short function-ish
-- words are skipped.
function MC_Inflect.expandable(lemma)
    return type(lemma) == "string"
       and #lemma >= 3
       and lemma:match("^%l+$") ~= nil
end

-- Generate inflected forms for a lemma. Returns an array of UNIQUE forms,
-- never including the lemma itself. Deterministic order.
function MC_Inflect.expand(lemma)
    local out, seen = {}, { [lemma] = true }
    local function add(form)
        if form and form ~= "" and not seen[form] then
            seen[form] = true
            out[#out + 1] = form
        end
    end
    if not MC_Inflect.expandable(lemma) then return out end

    -- s-form: 3sg verb / regular plural (suppressed by irregular plural)
    local irrPl = MC_Inflect.IRREGULAR_PLURAL[lemma]
    if irrPl then add(irrPl) else add(sForm(lemma)) end

    -- ing-form (always regular; irregular verbs still take regular -ing)
    add(ingForm(lemma))

    -- past forms: irregular replaces the -ed rule entirely
    local irrPast = MC_Inflect.IRREGULAR_PAST[lemma]
    if irrPast then
        for _, f in ipairs(irrPast) do add(f) end
    else
        add(edForm(lemma))
    end

    return out
end

return MC_Inflect
