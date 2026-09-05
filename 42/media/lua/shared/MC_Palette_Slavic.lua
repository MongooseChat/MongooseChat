-- MC_Babble palette: Slavic
-- Slavic family. Phonological signature: consonant clusters, chunky endings,
-- hush textures, y-as-vowel, caron diacritics.
-- Built deliberately at opposite phonological poles to French -- distinct at a glance.

local slavic = {
    name   = "Slavic",
    family = "slavic",

    -- Tuning dials -- adjust to refine Slavic's rhythm without engine edits.
    -- See MC_Babble.lua header for the full schema. All fields optional;
    -- omitted values fall back to engine defaults.
    --
    -- Notes on Slavic-specific dial choices vs defaults:
    --   - lettersPerSyllable is 4 (was 3 for French) -- Slavic packs more
    --     consonants per syllable, so input letters map to fewer syllables.
    --   - elisionPrefixChance is 0 -- Slavic doesn't apostrophe-elide.
    tuning = {
        lettersPerSyllable     = 4,
        onsetChance            = 0.7,
        midCodaChance          = 0.5,
        endingPoolChance       = 0.7,  -- bias toward chunky ski/ov/ich/ka endings
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,    -- Slavic-specific: no elisions
        signatureBoostWeight   = 3,
        featuredSignatureCount = 2,
    },

    onsets = {
        "p", "t", "k", "b", "d", "g", "m", "n", "r", "s", "z", "l", "v", "h",
        "sz", "cz", "str", "kr", "sk", "rz",     -- consonantClusters signature
        "sh", "zh", "ch",                          -- hushTextures signature
        "\197\161", "\196\141", "\197\190",                             -- caronDiacritics signature
        "st", "sp", "pr", "br", "tr", "dr", "gr", "vl", "kn", "pl",
    },

    nuclei = {
        "a", "e", "i", "o", "u",
        "y",                                       -- yAsVowel signature element
    },

    codas = {
        "", "t", "k", "n", "r", "v", "z", "l",
        "ski", "ov", "ich", "ka",                  -- chunkyEndings signature
        "sh", "zh", "ch",                          -- hush appears at codas at base rate too
        "\197\161", "\196\141", "\197\190",                             -- carons too
        "y", "ny", "ev", "in", "ek", "sk", "st",
    },

    functionWords = {
        "\197\188e", "i\197\188", "ju\197\188", "co", "tak", "nie",
        "dla", "od", "po", "na",
    },

    elisionPrefixes = {
        -- Slavic doesn't apostrophe-elide; empty by design.
        -- (Also disabled via tuning.elisionPrefixChance = 0.)
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    fillers = {
        "nu",            -- "well" -- the universal Russian-flavoured filler
        "vot",           -- "here / so / like"
        "tak",           -- "so / right" -- trailing-off marker
    },

    -- Signature set: distinctive phonological elements. Per-utterance featuring picks
    -- `tuning.featuredSignatureCount` of these; the picker for each entry's category
    -- gets `tuning.signatureBoostWeight` weight on those elements. Non-featured
    -- signatures still appear at base rate via the general pools above.
    signatureSet = {
        chunkyEndings     = { category = "coda",     elements = {"ski", "ov", "ich", "ka"} },
        consonantClusters = { category = "onset",    elements = {"sz", "cz", "str", "kr", "sk", "rz"} },
        hushTextures      = { category = "onset",    elements = {"sh", "zh", "ch"} },
        yAsVowel          = { category = "nucleus",  elements = {"y"} },
        caronDiacritics   = { category = "onset",    elements = {"\197\161", "\196\141", "\197\190"} },
    },

    -- Mishearing rules (babble-resolve), as above. DRAFT -- for review. These
    -- target the Russian-flavoured transliteration of the lex (zh/kh/shch/ts/y),
    -- not the West-Slavic surface texture in signatureSet.
    -- (The design doc this once cited, docs/BABBLE_RESOLVE.md, was lost with
    -- an ephemeral workspace and never recovered -- see docs/ARCHITECTURE.md.)
    mishearing = {
        { "shch", "sh" },   -- shch cluster simplified
        { "kh", "k" },      -- velar fricative -> k
        { "zh", "z" },      -- zh -> z
        { "ts", "s" },      -- ts -> s
        { "yy", "y" },      -- -yy adjective ending flattened
    },

    -- Output guard (consumed by MC_Babble): real Slavic vulgarities that
    -- generated babble must never land on. Whole-word, all lowercase.
    -- See MC_Palette_Turkish for schema docs.
    babbleBlocklist = {
        "suka", "huy", "pizda", "kaka",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)
    -- Consumed by MC_Lang dictionary bleed + MC_Acquisition exposure.
    -- See MC_Babble.lua palette schema docs for field shapes.

    -- concept-keyed lex schema: concept-keyed (CONCEPT_ID -> { l2 = "form" }).
    --
    -- The forms are sourced from data/forms.tsv (the slavic column) via
    -- devtools/generate_palette_forms.py -- the same data-source pattern as
    -- MC_Concepts. Edit the TSV, then regenerate + escape (see the
    -- MC_PaletteFormsData.lua header). Coverage today is Tier 1 (213 concepts);
    -- Tier 2 forms are pending lexicalisation.
    --
    -- Identity note: this palette's lex is Russian-flavored transliteration
    -- (BGN/PCGN-adjacent: e/yo for е/ё, zh for ж, kh for х, ts for ц, ch
    -- for ч, sh for ш, shch for щ, y for ы, yu for ю, ya for я; soft signs
    -- dropped for cleaner forms). The phonological signature in signatureSet
    -- (š č ž carons, sz/cz/rz clusters) leans West Slavic (Czech/Polish/
    -- Slovak), creating a known tension with the Russian-flavored lex.
    -- "Slavic" remains a pragmatic pan-Slavic mash with Russian
    -- vocabulary leadership and West-Slavic surface texture.
    --
    -- Translation choices: standard modern Russian. Verbs use infinitive
    -- forms; adjectives use masculine singular base. Russian's body-part
    -- conflations are honored directly:
    --   ARM = HAND = ruka
    --   LEG = FOOT = noga
    --   FINGER = TOE = palets
    --   CHEST = BREAST = grud
    -- THIRSTY uses the verbal adjective (zhazhdushchiy); Russian
    -- natively uses periphrasis ("хочется пить"), but for substitution
    -- the closest single-word form is required.
    --
    -- TAKE uses vzyat (perfective, взять) rather than brat (imperfective,
    -- брать) because the latter is a transliteration homograph of brat
    -- "brother" (брат, used here for SIBLING). The soft-sign-drop
    -- convention above collapses the two distinct Russian verbs into the
    -- same Latin string; using the perfective preserves a real linguistic
    -- distinction at the L2 surface without re-introducing apostrophes
    -- (which the palette otherwise lacks).
    lex = require("MC_PaletteFormsData").slavic,

    -- Zipf frequency order: rank-1 = most common in the language at large.
    -- Reverse-looked-up by MC_Acquisition to give common words a head
    -- start (rank-1..10 acquired from first exposure; rare words need
    -- repetition). Forms here are L2 (Russian transliteration) lowercased.
    --
    -- Entries are a subset of lex L2 forms. Forms outside lex have no
    -- rank-lookup effect (production resolves through the concept tree,
    -- so orphan zipf entries never see queries). The order is corpus-
    -- grounded (wordfreq, via Cyrillic) and survival-first -- see the
    -- GENERATED header below; regenerate via devtools, don't hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "nyet", "da", "pomoshch", "privet", "eto", "pozhaluysta", "zhdat", "izvinite", "bezhat", "ostanavlivat",
        -- Rank 11-20
        "drug", "oruzhie", "snaruzhi", "ogon", "voda", "krov", "opasnost", "vrag", "yeda", "drugoy",
        -- Rank 21-30
        "pervy", "pryatat", "mertviy", "glaz", "golova", "ruka", "golodnyy", "khotet", "ustalyy", "kusat",
        -- Rank 31-40
        "vse", "nuzhno", "odin", "dva", "mnogo", "tri", "pyat", "chetyre", "malo", "shest",
        -- Rank 41-50
        "desyat", "sem", "vosem", "devyat", "odinakovyy", "ispolzovat", "nakhodit", "chtoto", "igra", "smotret",
        -- Rank 51-60
        "dlinny", "idti", "pokazat", "chuvstvovat", "semya", "ktoto", "khranit", "zapad", "prikhodit", "vostok",
        -- Rank 61-70
        "verkh", "lyuboe", "nedelya", "vsyo", "nachat", "razny", "tverdyy", "rasskazat", "vniz", "vverkh",
        -- Rank 71-80
        "sever", "yug", "ne", "chto", "storona", "rabota", "dalekiy", "otkryvat", "ya", "kak",
        -- Rank 81-90
        "istoriya", "mozhet", "to", "my", "vazhny", "molodoy", "rano", "do", "ty", "kogda",
        -- Rank 91-100
        "oni", "nepravilno", "pobedit", "kto", "yest", "posle", "gde", "dvigat", "seychas", "chelovek",
        -- Rank 101-110
        "pozdno", "segodnya", "pochemu", "ostatsya", "den", "god", "nichego", "skoro", "togda", "khorosho",
        -- Rank 111-120
        "spasibo", "legko", "plan", "novyy", "delat", "govorit", "dom", "gotov", "dom", "skazat",
        -- Rank 121-130
        "prinesti", "pesnya", "snova", "bolshoy", "mir", "gorod", "imya", "zavtra", "vchera", "noch",
        -- Rank 131-140
        "otdykhat", "tsena", "zhit", "rabotat", "syn", "delit", "silny", "sluchitsya", "zhenshchina", "plokho",
        -- Rank 141-150
        "seredina", "otets", "serdtse", "mat", "uchitsya", "odinoki", "tserkov", "litso", "lyubov", "chas",
        -- Rank 151-160
        "doveryat", "igrat", "sezon", "pole", "muzhchina", "mesyats", "vzyat", "znat", "yazyk", "zhena",
        -- Rank 161-170
        "poslat", "doch", "kniga", "vnutri", "svet", "vecher", "bedny", "prosto", "more", "brat",
        -- Rank 171-180
        "videt", "utro", "telo", "pol", "bezopasno", "dumat", "zdanie", "kofe", "muzh", "spat",
        -- Rank 181-190
        "iskat", "rebenok", "dver", "mashina", "vykhodit", "bol", "set", "polnyy", "staryy", "chasy",
        -- Rank 191-200
        "zemlya", "solntse", "schitat", "zapasti", "sto", "volosy", "belyy", "pisat", "vperedi", "radio",
        -- Rank 201-210
        "banka", "vkhodit", "banka", "chisty", "doroga", "khodit", "sidet", "malenkiy", "nikto", "sestra",
        -- Rank 211-220
        "pismo", "vozhd", "chitat", "krasnyy", "veter", "klyuch", "rot", "mechtat", "bogaty", "udacha",
        -- Rank 221-230
        "konchit", "zvezda", "pit", "ponimat", "okno", "borotsya", "davat", "stoyat", "vorota", "dozhd",
        -- Rank 231-240
        "nebo", "chernyy", "kamen", "poymat", "material", "les", "polovina", "derzhat", "strakh", "niz",
        -- Rank 241-250
        "nadezhda", "chay", "otvechat", "mozg", "babushka", "zhivoy", "most", "sneg", "leto", "stroit",
        -- Rank 251-260
        "radost", "zamok", "nos", "derevo", "derevo", "ruka", "sobaka", "myaso", "lager", "khleb",
        -- Rank 261-270
        "podarok", "reshit", "nosit", "grud", "sad", "grud", "karta", "dyadya", "transport", "gore",
        -- Rank 271-280
        "gotovit", "list", "ugol", "ferma", "maslo", "dvigatel", "moloko", "kray", "komnata", "slyshat",
        -- Rank 281-290
        "sol", "pomnit", "ptitsa", "odezhda", "ubivat", "pravyy", "ris", "mech", "szadi", "urozhay",
        -- Rank 291-300
        "rasti", "luna", "obeshchat", "ryba", "loshad", "nozh", "ozero", "sobirat", "nesti", "sok",
        -- Rank 301-310
        "teryat", "instrument", "tyazhelyy", "bolnoy", "vesna", "uchit", "zhivot", "slaby", "dyra", "steklo",
        -- Rank 311-320
        "dyshat", "gorlo", "zabyvat", "tikho", "kukhnya", "reka", "stranny", "zima", "siniy", "strelyat",
        -- Rank 321-330
        "palets", "led", "kozha", "kozha", "palets", "osen", "gorit", "pustoy", "bystryy", "ostorozhno",
        -- Rank 331-340
        "volk", "alkogol", "gost", "sukhoy", "letat", "semena", "dym", "gryazny", "shum", "sup",
        -- Rank 341-350
        "nenavist", "sledovat", "lezhat", "gora", "ukho", "stena", "krichat", "zhivotnoe", "syr", "tsvetok",
        -- Rank 351-360
        "gryaz", "gromko", "plecho", "lodka", "umirat", "pyl", "dedushka", "zelyonyy", "pesok", "sprashivat",
        -- Rank 361-370
        "kholodnyy", "luk", "lekarstvo", "tupoy", "seryy", "gruzovik", "koshka", "goryachiy", "gnev", "legkiy",
        -- Rank 371-380
        "noga", "lob", "levyy", "noga", "bumaga", "koleso", "krysha", "toplivo", "lechit", "rastenie",
        -- Rank 381-390
        "shchit", "meshok", "blizkiy", "napitok", "tsep", "podnimat", "zdorovyy", "bespokoystvo", "kost", "yad",
        -- Rank 391-400
        "spina", "padat", "krast", "maska", "udivlenie", "bryuki", "trava", "travma", "metall", "zmeya",
        -- Rank 401-410
        "brosat", "velosiped", "zabor", "koren", "ostryy", "zub", "zheltyy", "zakryvat", "tkan", "polnoch",
        -- Rank 411-420
        "myagkiy", "koleno", "zheludok", "trogat", "korobka", "tma", "pulya", "plemyannik", "lestnitsa", "rozovyy",
        -- Rank 421-430
        "lestnitsa", "strela", "butylka", "poka", "vedro", "plot", "odinochestvo", "pila", "chuzhoy", "sumka",
        -- Rank 431-440
        "prygat", "polden", "korova", "vstrechat", "topor", "oblako", "fakel", "kuritsa", "zerno", "tyanut",
        -- Rank 441-450
        "plavat", "legkoe", "vodit", "chelyust", "spokoynyy", "myt", "styd", "pepel", "lomat", "sheya",
        -- Rank 451-460
        "lampa", "remen", "rezat", "olen", "lokot", "oranzhevyy", "rana", "korichnevyy", "prosnutsya", "krysa",
        -- Rank 461-470
        "oblegchenie", "mokryy", "grust", "rubashka", "otvrashchenie", "grib", "lozhka", "shlyapa", "sosud", "likhoradka",
        -- Rank 471-480
        "gvozd", "probovat", "podborodok", "kust", "kopat", "peshchera", "tyotya", "lovushka", "plemyannitsa", "mladenets",
        -- Rank 481-490
        "medlennyy", "infektsiya", "orekh", "chinit", "odeyalo", "chashka", "ladon", "plastik", "molotok", "korzina",
        -- Rank 491-500
        "sapog", "tropa", "fioletovyy", "kryuk", "rebro", "svyazyvat", "shram", "guba", "okhotitsya", "ovtsa",
        -- Rank 501-510
        "tarelka", "frukt", "igla", "nosok", "seyat", "sinyak", "myod", "putanitsa", "pokryvat", "bochka",
        -- Rank 511-520
        "tolkat", "kuzen", "yagoda", "vilka", "svecha", "nasekomoe", "rezina", "lopata", "nyukhat", "nogot",
        -- Rank 521-530
        "ovoshch", "udaryat", "zhat", "pupok", "bint", "nitka", "dubina", "perchatka", "skovoroda", "shcheka",
        -- Rank 531-540
        "kastryulya", "veryovka", "sosed", "miska", "sornyak", "obmenivat", "pyatka", "lazat", "zhazhdushchiy", "krovotochit",
        -- Rank 541-548
        "tuflya", "lodyzhka", "svinya", "palto", "yaytso", "ruzhyo", "kopyo", "zapyastye",
    },

    -- lexicalSets declared centrally in MC_Concepts.lua.

    -- CULTURAL BLOCK (v8.6) -- see MC_Palette_French for full schema docs
    cultural = {
        { en = "Trust but verify",
          l2 = "Doveryai, no proveryai",
          tags = {} },
        { en = "Life is not all roses",
          l2 = "Zhizn ne sakhar",
          tags = {} },
        { en = "What's done is done",
          l2 = "Chto sdelano, to sdelano",
          tags = {} },
        { en = "Don't look a gift horse in the mouth",
          l2 = "Dar\195\171nomu konyu v zuby ne smotryat",
          tags = {} },
        { en = "Every cloud has a silver lining",
          l2 = "Net khuda bez dobra",
          tags = {} },
        { en = "Patience and time can do more than strength",
          l2 = "Terpenie i trud vse peretrut",
          tags = { "archaic" } },
    },
}

-- Self-register with the language system. Adding/removing this line is the
-- only integration touchpoint -- MC_Lang doesn't need to know we exist.
require("MC_LangRegistry").register("slavic", slavic)

return slavic
