-- MC_Babble palette: German
-- Germanic family (the first non-baseline Germanic palette; English is the
-- Germanic-adjacent baseline but has no palette). Phonological signature:
-- heavy consonant clusters (schw-/str-/spr-/zw-/kn-/pf-), the sch and ch
-- gutturals, the umlauts (a/o/u-umlaut), the eszett, and the -en/-er/-ung/
-- -lich/-heit/-keit suffix tail. Built at the cluster-heavy pole, cousin to
-- Slavic but unmistakably German (umlauts + sch/ch + -ung/-lich).
--
-- Identity: standard Hochdeutsch. NOTE: German capitalizes nouns, but the lex
-- forms are all-lowercase (the engine lowercases for matching -- see the case
-- audit); the capitalization is a rendering nicety dropped for now, flagged in
-- the forms notes. Umlauts (a/o/u-umlaut) and the eszett are byte-escaped
-- (\NNN) like the French/Turkish palettes, so the file stays Kahlua-safe.

local german = {
    name   = "German",
    family = "germanic",

    -- Tuning dials -- see MC_Babble.lua header. German packs consonants
    -- (lettersPerSyllable 4, like Slavic), closes most syllables (high
    -- midCodaChance), and strongly favours the -en/-er/-ung/-lich endings
    -- (high endingPoolChance).
    tuning = {
        lettersPerSyllable     = 4,
        onsetChance            = 0.82,
        midCodaChance          = 0.5,
        endingPoolChance       = 0.42,  -- the -ung/-lich/-keit tail is a sprinkle; most words
                                        --   end in the plainer -en/-er/-t/-e via the base codas
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,     -- German-specific: no apostrophe elisions
        signatureBoostWeight   = 3,
        featuredSignatureCount = 2,
    },

    onsets = {
        "b", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z",
        "sch", "ch", "pf",                                   -- sch/ch/pf digraphs
        "st", "sp", "str", "schw", "spr", "zw", "kn",        -- German-signature clusters
        "tr", "br", "gr", "kr", "fr", "fl", "pl", "kl", "bl",-- obstruent+liquid clusters
    },

    nuclei = {
        -- Base vowels weighted heavier than the diphthongs/umlauts.
        "a", "a", "e", "e", "e", "i", "i", "o", "o", "u", "u",
        -- Diphthongs (ei/ie/au/eu very common: nein, wieder, haus, heute).
        "ei", "ie", "au", "eu",
        -- Umlauts -- the signature tell (a/o/u-umlaut).
        "\195\164", "\195\182", "\195\188",
    },

    codas = {
        -- German closes syllables freely; -t/-n/-r/-s and the -st/-nd/-cht
        -- clusters are the common finals. A little empty for the -e schwa
        -- endings (katze, sonne, blume).
        "", "", "t", "n", "r", "s", "st", "nd", "rt", "nt", "ch",
    },

    functionWords = {
        "der", "die", "das", "ein", "eine", "und", "ist", "ich", "du", "er",
        "sie", "es", "zu", "auf", "mit", "von", "nicht", "den", "dem", "im",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    fillers = {
        "also",          -- "so / well" -- the universal German filler
        "halt",          -- "just / simply" (softener)
        "naja",          -- "well / meh" -- trailing-off marker
    },

    -- Signature set. Umlauts on the nucleus; German clusters on the onset; the
    -- guttural + suffix endings on the coda (they attach onto a nucleus:
    -- a + cht -> "acht", u + ng -> "ung", a + lich -> "alich").
    signatureSet = {
        umlauts      = { category = "nucleus", elements = {"\195\164", "\195\182", "\195\188"} },
        clusters     = { category = "onset",   elements = {"sch", "schw", "str", "spr", "zw", "kn", "pf"} },
        gutturalCoda = { category = "coda",    elements = {"ch", "cht", "sch", "ng"} },   -- -ich/-acht/-isch/-ung
        suffixTail   = { category = "coda",    elements = {"lich", "heit", "keit", "chen"} },  -- -lich/-heit/-keit/-chen
    },

    -- Mishearing rules (babble-resolve). Clusters/gutturals simplify, umlauts
    -- flatten, eszett -> s. Ordered {from, to}; whole-cluster/multibyte rules
    -- first. DRAFT -- for review. See docs/BABBLE_RESOLVE.md.
    mishearing = {
        { "sch", "s" }, { "cht", "t" }, { "ch", "k" }, { "pf", "f" }, { "tz", "ts" },  -- clusters/gutturals
        { "\195\159", "s" },                                                            -- eszett -> s
        { "\195\164", "a" }, { "\195\182", "o" }, { "\195\188", "u" },                  -- umlauts flatten
    },

    -- Output guard: real German vulgarities generated babble must never land on.
    -- Whole-word, lowercase, eszett byte-escaped. See MC_Palette_Turkish for docs.
    babbleBlocklist = {
        "schei\195\159e", "scheisse", "arsch", "arschloch", "fick", "ficken",
        "fotze", "schwanz", "hure", "wichser", "kacke", "pisse",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)

    -- concept-keyed lex sourced from data/forms.tsv (the german column) via
    -- devtools/generate_palette_forms.py. Standard German: verbs in the
    -- infinitive (-en); nouns in the singular (LOWERCASED -- see the header
    -- note); adjectives in the uninflected base form. DRAFTS pending native-
    -- speaker review (flagged in the TSV note column).
    lex = require("MC_PaletteFormsData").german,

    -- Zipf frequency order. Generated by devtools/generate_rankings.py; German
    -- never shipped, so all forms ride the baseline-less English-frequency path.
    -- Regenerate after editing forms.tsv; do NOT hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "in", "ich", "das", "du", "dies", "nicht", "wir", "alle", "sie", "eins",
        -- Rank 11-20
        "dose", "hoch", "drau\195\159en", "was", "wann", "nein", "wer", "neu", "wie", "jetzt",
        -- Rank 21-30
        "andere", "gut", "nach", "erste", "wissen", "sehen", "zwei", "machen", "denken", "dann",
        -- Rank 31-40
        "r\195\188cken", "wollen", "gehen", "gesund", "wo", "brauchen", "rechts", "arbeiten", "jahr", "tag",
        -- Rank 41-50
        "vor", "warum", "nehmen", "viele", "sagen", "unten", "liebe", "mann", "zuhause", "lang",
        -- Rank 51-60
        "schauen", "etwas", "benutzen", "gleich", "kommen", "drei", "finden", "helfen", "alt", "spiel",
        -- Rank 61-70
        "geben", "haus", "wieder", "zeigen", "gro\195\159", "f\195\188hlen", "behalten", "verwandte", "bitte", "jemand",
        -- Rank 71-80
        "links", "name", "nacht", "spielen", "wenig", "anders", "oben", "anfangen", "woche", "irgendetwas",
        -- Rank 81-90
        "person", "heute", "alles", "voll", "leben", "lesen", "schlecht", "vier", "hart", "erz\195\164hlen",
        -- Rank 91-100
        "stoppen", "wasser", "kopf", "klein", "wei\195\159", "weit", "aufgabe", "seite", "versuchen", "ja",
        -- Rank 101-110
        "rennen", "\195\182ffnen", "jahreszeit", "danke", "schwarz", "auto", "gesicht", "f\195\188nf", "vielleicht", "geschichte",
        -- Rank 111-120
        "hoffnung", "wichtig", "buch", "fr\195\188h", "jung", "halb", "hand", "k\195\182rper", "essen", "s\195\188den",
        -- Rank 121-130
        "zimmer", "gewinnen", "falsch", "erinnern", "freund", "schlagen", "verstehen", "schlie\195\159en", "bewegen", "warten",
        -- Rank 131-140
        "frau", "fragen", "sp\195\164t", "norden", "s\195\164ge", "licht", "leicht", "morgen", "bleiben", "rot",
        -- Rank 141-150
        "bald", "herz", "kind", "feuer", "hinter", "geb\195\164ude", "leicht", "nah", "plan", "sechs",
        -- Rank 151-160
        "westen", "vorne", "bereit", "sohn", "bringen", "treffen", "baby", "vater", "lied", "monat",
        -- Rank 161-170
        "schneiden", "feld", "mutter", "stra\195\159e", "stadt", "k\195\164mpfen", "h\195\182ren", "preis", "ausruhen", "sommer",
        -- Rank 171-180
        "ehefrau", "stark", "keule", "teilen", "tot", "passieren", "halten", "stern", "brechen", "stunde",
        -- Rank 181-190
        "mitte", "entschuldigung", "antworten", "lernen", "allein", "kirche", "osten", "hei\195\159", "folgen", "stehen",
        -- Rank 191-200
        "blau", "fahren", "essen", "fallen", "schnell", "gr\195\188n", "vertrauen", "schl\195\188ssel", "tauschen", "bruder",
        -- Rank 201-210
        "becher", "hassen", "schicken", "blut", "hund", "\195\182l", "t\195\182ten", "arm", "bedecken", "t\195\188r",
        -- Rank 211-220
        "haar", "verlieren", "sieben", "einfach", "laufen", "tochter", "sterben", "papier", "sicher", "erde",
        -- Rank 221-230
        "vergessen", "meer", "schlafen", "zehn", "kiste", "bauen", "dunkel", "wand", "schmerz", "fluss",
        -- Rank 231-240
        "sprechen", "schreiben", "kalt", "acht", "auge", "frieden", "lagern", "morgen", "braun", "radio",
        -- Rank 241-250
        "ehemann", "eis", "sauber", "sonne", "pistole", "schwer", "suchen", "angst", "anf\195\188hrer", "brief",
        -- Rank 251-260
        "material", "niemand", "schwester", "gehirn", "fu\195\159boden", "nichts", "fr\195\188hling", "tragen", "tr\195\164umen", "beenden",
        -- Rank 261-270
        "gl\195\188ck", "reich", "haut", "ber\195\188hren", "gestern", "trinken", "fisch", "wachsen", "sitzen", "tragen",
        -- Rank 271-280
        "pflanze", "winter", "krank", "fangen", "fu\195\159", "neun", "kaffee", "abend", "glas", "langsam",
        -- Rank 281-290
        "baum", "unten", "motor", "hinlegen", "traurigkeit", "wind", "sorge", "z\195\164hlen", "see", "mund",
        -- Rank 291-300
        "werfen", "metall", "ziehen", "schieben", "tier", "betreten", "stein", "fenster", "tasche", "lager",
        -- Rank 301-310
        "katze", "entscheiden", "geschenk", "holz", "br\195\188cke", "garten", "lebendig", "pferd", "landkarte", "netz",
        -- Rank 311-320
        "fahrzeug", "aufwachen", "ecke", "bauernhof", "reparieren", "fliegen", "\195\188berraschung", "trocken", "kante", "verletzung",
        -- Rank 321-330
        "arm", "medizin", "berg", "schie\195\159en", "schmecken", "tee", "kraftstoff", "hallo", "himmel", "boot",
        -- Rank 331-340
        "hundert", "pfad", "versprechen", "regen", "m\195\188de", "feind", "wald", "mond", "springen", "gelb",
        -- Rank 341-350
        "weich", "rauch", "beibringen", "loch", "bein", "milch", "schnee", "schwach", "kette", "kochen",
        -- Rank 351-360
        "k\195\188che", "leise", "seltsam", "lastwagen", "vogel", "sch\195\188ssel", "huhn", "fleisch", "hals", "hemd",
        -- Rank 361-370
        "orange", "alkohol", "salz", "vorsichtig", "gefahr", "leer", "gast", "flasche", "k\195\164se", "obst",
        -- Rank 371-380
        "werkzeug", "schmutzig", "freude", "ger\195\164usch", "teller", "erleichterung", "reis", "dach", "scham", "ruhig",
        -- Rank 381-390
        "verstecken", "waffe", "nass", "brennen", "hut", "laut", "brustkorb", "rosa", "schloss", "nase",
        -- Rank 391-400
        "plastik", "binden", "brot", "heben", "schulter", "rad", "busch", "jagen", "riechen", "finger",
        -- Rank 401-410
        "grau", "scharf", "knochen", "kleidung", "tor", "wolke", "ei", "waschen", "hungrig", "onkel",
        -- Rank 411-420
        "sand", "faden", "uhr", "ohr", "wut", "g\195\188rtel", "blume", "magen", "cousin", "staub",
        -- Rank 421-430
        "messer", "wurzel", "stehlen", "topf", "pfanne", "gras", "honig", "haken", "samen", "schwert",
        -- Rank 431-440
        "zunge", "mantel", "saft", "brust", "verlassen", "leder", "wolf", "infektion", "knie", "falle",
        -- Rank 441-450
        "lila", "bei\195\159en", "maske", "mitternacht", "bogen", "tsch\195\188ss", "schild", "kehle", "fremder", "unkraut",
        -- Rank 451-460
        "herbst", "atmen", "kugel", "sammeln", "opa", "schuh", "wunde", "handfl\195\164che", "gummi", "schlange",
        -- Rank 461-470
        "klettern", "graben", "fieber", "blatt", "zaun", "nagel", "nagel", "schwimmen", "h\195\182hle", "fleisch",
        -- Rank 471-480
        "stiefel", "verwirrung", "schaf", "getreide", "fass", "ratte", "asche", "tante", "hammer", "feldfrucht",
        -- Rank 481-490
        "suppe", "kuh", "oma", "schwein", "treppe", "pfeil", "lippe", "schlamm", "reh", "heilen",
        -- Rank 491-500
        "mittag", "bauch", "lunge", "trauer", "gift", "zahn", "korb", "decke", "eimer", "zeh",
        -- Rank 501-510
        "seil", "schreien", "lampe", "nuss", "stoff", "beh\195\164lter", "gabel", "ernten", "leiter", "neffe",
        -- Rank 511-520
        "daumen", "handgelenk", "kinn", "fahrrad", "kiefer", "nadel", "kn\195\182chel", "beere", "wange", "stumpf",
        -- Rank 521-530
        "gem\195\188se", "einmachglas", "sack", "kerze", "l\195\182ffel", "stirn", "ellenbogen", "ferse", "nichte", "axt",
        -- Rank 531-540
        "narbe", "insekt", "durstig", "fackel", "handschuh", "bluten", "speer", "hose", "getr\195\164nk", "nachbar",
        -- Rank 541-550
        "einsamkeit", "pilz", "ekel", "geschwister", "socke", "rippe", "schaufel", "s\195\164en", "verband", "bluterguss",
        -- Rank 551-551
        "bauchnabel",
    },

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs.
    cultural = {
        { en = "Everything comes to an end eventually",  l2 = "Alles hat ein Ende",          tags = {} },
        { en = "It makes no difference to me at all",    l2 = "Das ist mir Wurst",           tags = {"informal"} },
        { en = "Practice makes the master perfect",      l2 = "\195\156bung macht den Meister", tags = {} },
        { en = "Enjoy your meal, everyone",              l2 = "Guten Appetit",               tags = {"meal"} },
        { en = "I wish you all the very best",           l2 = "Alles Gute",                  tags = {"farewell"} },
        { en = "It is really no problem at all",         l2 = "Kein Problem",                tags = {} },
    },
}

-- Self-register with the language system.
require("MC_LangRegistry").register("german", german)

return german
