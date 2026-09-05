-- MC_Babble palette: Turkish
-- Turkic family. First Mongoose palette built with native-speaker tester
-- validation in mind. Phonological signature: vowel harmony (front/back),
-- soft-g (ğ), dotted/dotless i distinction, characteristic agglutinative
-- endings. Modern Turkish orthography throughout (ç ş ğ ı ö ü).
--
-- Identity: standard modern Turkish (Türkiye Türkçesi). Other Turkic
-- languages (Azerbaijani, Kazakh, Uzbek, Kyrgyz, etc.) would each be
-- separate palettes within family = "turkic", auto-receiving cross-language
-- family bonus via MC_Concepts.lexicalSets.
--
-- Tier 1 conflations honored where Turkish naturally collapses concepts:
--   FOOD = EAT = yemek          -- noun/verb share (parallel to English
--                                  "drink" being both noun and verb)
--   CHEST = BREAST = göğüs      -- single Turkish word for both
--   FINGER = TOE = parmak       -- TOE is "ayak parmağı" (compound);
--                                  bare parmak covers both as a single
--                                  token, matching the same pattern as
--                                  Russian palets in the Slavic palette
--   THEN = AFTER = sonra        -- one Turkish word, two English temporals
--
-- Tier 1 approximation worth flagging:
--   WHEN = kaçta                -- the natural Turkish form is "ne zaman"
--                                  (two words) which the current render
--                                  pipeline can't substitute as a single
--                                  token; "kaçta" (at-what-time) is the
--                                  closest single-word equivalent in use.
--                                  Current fallback is a single-token form.
--
-- Vowel harmony engine extension landed v8.9.2. The `vowelHarmony` field
-- below is consumed by MC_Babble: once the first vowel in a generated
-- word is picked, subsequent nucleus / coda / vowel-onset picks are
-- filtered to the same harmony class. Engine-generated babble is
-- harmony-clean (measured at 0% violations across 1600 sample words);
-- residual violations in the full pipeline come from authentic Turkish
-- loanwords (Merhaba, kalp, etc.) in the lex and cultural tables, which
-- correctly preserve their non-harmonising origin.

local turkish = {
    name   = "Turkish",
    family = "turkic",

    -- Tuning dials -- see MC_Babble.lua header for the full schema.
    tuning = {
        lettersPerSyllable     = 3,    -- Turkish syllables average 2-3 chars
        onsetChance            = 0.85, -- nearly all Turkish syllables have onsets
        midCodaChance          = 0.4,  -- moderate mid-word coda rate
        endingPoolChance       = 0.65, -- bias toward agglutinative endings
        functionWordChance     = 0.35,
        signatureBoostWeight   = 3,
        featuredSignatureCount = 2,
    },

    onsets = {
        -- Single consonants. Turkish doesn't natively cluster word-initially
        -- (br-, str-, pl- are loanword-only); the babble pool reflects this.
        "b", "c", "\195\167", "d", "g", "h", "k", "l", "m", "n",
        "p", "r", "s", "\197\159", "t", "v", "y", "z", "f",
        -- Vowel-initial syllables -- Turkish freely allows words like
        -- ev (house), av (hunt), et (meat), üzüm (grape), ağaç (tree).
        "a", "e", "i", "\196\177", "o", "\195\182", "u", "\195\188",
    },

    nuclei = {
        -- All 8 Turkish vowels. Vowel harmony (consumed by the engine
        -- via the vowelHarmony field once Session 3 lands) constrains
        -- co-occurrence within a word; this pool lists all choices.
        "a", "e", "\196\177", "i", "o", "\195\182", "u", "\195\188",
    },

    codas = {
        -- Empty coda -- vowel-final words are very common in Turkish
        -- (suffix-rich morphology often ends in a vowel).
        "",
        -- Single final consonants
        "n", "r", "k", "l", "m", "s", "t", "\197\159", "z", "p", "y", "\195\167",
        -- Common CVC final syllables across the 8 vowels
        "an", "en", "in", "un", "\196\177n", "\195\188n",
        "ar", "er", "\196\177r", "ir", "or", "ur",
        "ak", "ek", "\196\177k", "ik", "ok", "uk", "\195\182k", "\195\188k",
        "al", "el", "\196\177l", "il",
        "as", "es", "\196\177\197\159", "i\197\159",
        -- Real Turkish morphological suffixes -- the agglutinative texture
        -- that makes Turkish recognizably Turkic.
        "lar", "ler",                   -- plural
        "mek", "mak",                   -- infinitive
        "ci", "c\196\177", "cu", "c\195\188",         -- occupational/agentive
        "l\196\177k", "lik", "luk", "l\195\188k",     -- abstract noun (-ness/-hood)
        "siz", "s\196\177z", "suz", "s\195\188z",     -- without (-less)
        "li", "l\196\177", "lu", "l\195\188",         -- with (-ful)
        "den", "dan", "ten", "tan",     -- ablative (from)
    },

    functionWords = {
        -- Conjunctions and discourse particles
        "ve", "ile", "de", "da", "ki", "ama", "ya", "veya",
        -- Demonstratives and number
        "bu", "\197\159u", "o", "bir",
        -- Postpositional particles
        "i\195\167in", "kadar", "gibi", "her",
        -- Quantity / intensity
        "\195\167ok", "az", "hi\195\167",
    },

    -- Hesitation fillers: L2 discourse particles a learner reaches for when
    -- they blank on a word mid-speech. Not in the lex (not acquirable); the
    -- production pass inserts one on the first failed roll per message.
    fillers = {
        "\197\159ey",    -- şey: "thing/um" -- the universal Turkish filler
        "yani",          -- "I mean / that is"
        "hani",          -- "you know / like"
    },

    -- Signature set: distinctive Turkish phonological elements that the
    -- per-utterance featuring system promotes. Native ears should pick
    -- up on these immediately.
    signatureSet = {
        softG                 = { category = "coda",    elements = {"\196\177\196\159", "i\196\159", "u\196\159", "\195\188\196\159", "a\196\159", "e\196\159", "o\196\159", "\195\182\196\159"} },
        palatalSibilants      = { category = "onset",   elements = {"\195\167", "c", "\197\159", "j"} },
        roundedFrontVowels    = { category = "nucleus", elements = {"\195\182", "\195\188"} },
        dottedDotlessI        = { category = "nucleus", elements = {"\196\177", "i"} },
        agglutinativeSuffixes = { category = "coda",    elements = {"lar", "ler", "mek", "mak", "l\196\177k", "lik", "ci", "c\196\177"} },
    },

    -- Vowel harmony rules. Consumed by MC_Babble as of v8.9.2: once the
    -- first vowel is picked in a generated word, subsequent nucleus / coda
    -- / vowel-onset picks are filtered to the same harmony class. Engine-
    -- generated babble measures 0% mixed-class words (asserted in the
    -- morphology_properties scenario).
    --
    -- Turkish has two harmony systems: two-way (front/back) and four-way
    -- (front/back + rounded/unrounded). Only the two-way rule is implemented.
    vowelHarmony = {
        enabled     = true,
        backVowels  = {"a", "\196\177", "o", "u"},
        frontVowels = {"e", "i", "\195\182", "\195\188"},
        rule        = "twoWay",
    },

    -- Mishearing rules (babble-resolve). How this language's distinctive
    -- features flatten in a non-native ear; consumed by MC_Babble.resolveWord
    -- for the "misheard" resolution state. (The design doc this once cited,
    -- docs/BABBLE_RESOLVE.md, was lost with an ephemeral workspace and never
    -- recovered -- see docs/ARCHITECTURE.md.)
    --
    -- PENDING community validation (Merkur). Turkish phonology is NOT guessed
    -- here -- left empty until the Turkish RP community supplies/validates the
    -- set. Empty == words resolve texture -> true with no misheard stage, which
    -- is honest until the rules land. Candidate romanisations to validate
    -- (NOT shipped): c-cedilla->ch, s-cedilla->sh, dotless-i->i, o-uml->o,
    -- u-uml->u, soft-g->lengthen/drop.
    mishearing = {},

    -- Output guard (consumed by MC_Babble): real Turkish vulgarities that
    -- generated babble must never land on -- this palette is validated by
    -- native testers, who would read these instantly. Whole-word matched,
    -- all lowercase, non-ASCII byte-escaped like every other form in this
    -- file. Common suffixed forms are enumerated because matching is
    -- whole-word only.
    babbleBlocklist = {
        "sik", "sikmek", "sikim", "siktir", "siki\197\159",
        "am", "amk", "am\196\177na", "amc\196\177k",
        "g\195\182t", "g\195\182t\195\188", "g\195\182tler",
        "pi\195\167", "pi\195\167ler",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)
    -- Consumed by MC_Lang dictionary bleed + MC_Acquisition exposure.

    -- concept-keyed lex (CONCEPT_ID -> { l2 = "form" }), sourced from
    -- data/forms.tsv (the turkish column) via devtools/generate_palette_forms.py
    -- -- the same data-source pattern as MC_Concepts; edit the TSV, then
    -- regenerate + escape (see the MC_PaletteFormsData.lua header). Coverage
    -- today is Tier 1 (213 concepts); Tier 2 forms are pending. Standard modern
    -- Turkish. Verbs in infinitive (-mek/-mak); nouns in nominative base
    -- form; adjectives in their citation form (Turkish has no grammatical
    -- gender so no inflection variant to pick).
    --
    -- Translation choices worth knowing (beyond the conflations in the
    -- header):
    --   STAND = kalkmak           -- "to rise/get up" (durmak = to stop,
    --                                so kalkmak captures STAND-the-action)
    --   HIDE = saklanmak          -- reflexive ("to hide oneself"); the
    --                                transitive saklamak hides something
    --                                else, which isn't the Tier 1 sense
    --   FOLLOW = izlemek          -- single-word follow/watch; "takip
    --                                etmek" is more common but compound
    --   BREATHE = solumak         -- real Turkish verb; everyday speech
    --                                often uses compound "nefes almak"
    --   FEEL = hissetmek          -- emotional sense; physical sensing
    --                                is duymak (which is HEAR in Tier 1)
    --   KIN = aile                -- aile means "family"; Turkish doesn't
    --                                have a separate term for the broader
    --                                "kinship" abstract concept
    --   SIBLING = kardeş          -- Turkish has a neutral sibling term,
    --                                unlike French (frère) and Russian
    --                                (brat). Both brother and sister are
    --                                kardeş; gendered forms are erkek
    --                                kardeş / kız kardeş when needed.
    lex = require("MC_PaletteFormsData").turkish,

    -- Zipf frequency order. Forms here are L2 (Turkish) lowercased.
    -- The order is corpus-grounded (wordfreq) and survival-first, so it
    -- skews toward food/death/threat vocabulary by design -- see the
    -- GENERATED header below; regenerate via devtools, don't hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "evet", "l\195\188tfen", "hay\196\177r", "yard\196\177m", "merhaba", "pardon", "beklemek", "durmak", "ho\197\159\195\167akal", "ko\197\159mak",
        -- Rank 11-20
        "su", "yemek", "kan", "arkada\197\159", "ka\195\167ta", "\195\182l\195\188", "ate\197\159", "silah", "d\195\188\197\159man", "di\196\159er",
        -- Rank 21-30
        "bilmek", "ilk", "d\195\188\197\159\195\188nmek", "tehlike", "saklanmak", "istemek", "el", "g\195\182z", "ba\197\159", "\195\167al\196\177\197\159mak",
        -- Rank 31-40
        "gerekmek", "a\195\167", "yorgun", "\196\177s\196\177rmak", "bir", "\195\167ok", "iki", "az", "\195\188\195\167", "d\195\182rt",
        -- Rank 41-50
        "on", "kullanmak", "bir\197\159ey", "bakmak", "uzun", "yuva", "be\197\159", "oyun", "alt\196\177", "hepsi",
        -- Rank 51-60
        "yedi", "hissetmek", "g\195\182stermek", "sekiz", "birisi", "oynamak", "dokuz", "do\196\159u", "\195\188st", "ba\197\159lamak",
        -- Rank 61-70
        "herhangi", "farkl\196\177", "okumak", "her\197\159ey", "anlatmak", "gitmek", "kuzey", "g\195\188ney", "bat\196\177", "a\197\159a\196\159\196\177",
        -- Rank 71-80
        "yukar\196\177", "gelmek", "bu", "denemek", "yan", "i\197\159", "ne", "sa\196\159ol", "hikaye", "belki",
        -- Rank 81-90
        "mevsim", "a\195\167mak", "ben", "\195\182nemli", "gen\195\167", "erken", "sonra", "sonra", "v\195\188cut", "yanl\196\177\197\159",
        -- Rank 91-100
        "kazanmak", "iyi", "de\196\159il", "sen", "b\195\188y\195\188k", "yeni", "k\196\177p\196\177rdamak", "hi\195\167", "ge\195\167", "nas\196\177l",
        -- Rank 101-110
        "\195\182nce", "g\195\188n", "kalmak", "ayn\196\177", "biz", "yak\196\177nda", "\197\159u", "y\196\177l", "\197\159imdi", "adam",
        -- Rank 111-120
        "saat", "plan", "kolay", "saat", "bug\195\188n", "k\195\188\195\167\195\188k", "insan", "haz\196\177r", "kad\196\177n", "getirmek",
        -- Rank 121-130
        "gece", "\197\159ark\196\177", "eski", "kim", "k\196\177z", "\195\167ocuk", "k\195\182t\195\188", "ay", "ay", "dinlenmek",
        -- Rank 131-140
        "fiyat", "hafta", "tekrar", "yol", "payla\197\159mak", "ger\195\167ekle\197\159mek", "g\195\188\195\167l\195\188", "ev", "yapmak", "orta",
        -- Rank 141-150
        "h\196\177zl\196\177", "\195\182\196\159renmek", "yak\196\177n", "kilise", "yaln\196\177z", "onlar", "yar\196\177n", "sabah", "g\195\188venmek", "et",
        -- Rank 151-160
        "et", "niye", "ak\197\159am", "yaz", "almak", "yemek", "takas", "anne", "g\195\182ndermek", "beyaz",
        -- Rank 161-170
        "kitap", "d\195\188n", "canl\196\177", "deniz", "fakir", "basit", "at", "bo\197\159", "dolu", "\197\159ehir",
        -- Rank 171-180
        "g\195\182rmek", "a\196\159\196\177r", "uzak", "g\195\188venli", "g\195\188ne\197\159", "nefret", "aile", "a\197\159k", "vermek", "\195\182n",
        -- Rank 181-190
        "k\196\177rm\196\177z\196\177", "dil", "baba", "kurmak", "ac\196\177", "y\195\188z", "y\195\188z", "s\196\177cak", "sa\196\159", "bebek",
        -- Rank 191-200
        "siyah", "depolamak", "hasta", "\196\177\197\159\196\177k", "isim", "y\196\177ld\196\177z", "so\196\159uk", "radyo", "kalp", "yava\197\159",
        -- Rank 201-210
        "arka", "temiz", "toprak", "ta\197\159", "ate\197\159", "sol", "lider", "abla", "kimse", "mektup",
        -- Rank 211-220
        "nerede", "sert", "oda", "mavi", "kahve", "yar\196\177m", "bitirmek", "zengin", "\197\159ans", "r\195\188ya",
        -- Rank 221-230
        "ye\197\159il", "bal\196\177k", "al\196\177n", "\195\167ay", "sar\196\177", "kap\196\177", "kap\196\177", "hayvan", "araba", "ya\197\159amak",
        -- Rank 231-240
        "k\196\177\197\159", "koca", "yakalamak", "karde\197\159", "k\195\182pek", "ayak", "ara\195\167", "beyin", "karanl\196\177k", "d\196\177\197\159ar\196\177",
        -- Rank 241-250
        "alt", "\195\167i\195\167ek", "kar", "ku\197\159", "hafif", "ya\196\159mur", "korku", "bulmak", "umut", "sa\196\159l\196\177kl\196\177",
        -- Rank 251-260
        "s\195\182ylemek", "motor", "orman", "metal", "huzur", "sakin", "ila\195\167", "kedi", "buz", "kulak",
        -- Rank 261-270
        "kamp", "karar", "hediye", "sa\195\167", "ekmek", "bah\195\167e", "harita", "konu\197\159mak", "izlemek", "bina",
        -- Rank 271-280
        "a\196\159a\195\167", "i\195\167eri", "anahtar", "\195\167iftlik", "k\195\182\197\159e", "r\195\188zgar", "kurt", "kenar", "\195\167\196\177kmak", "s\195\188t",
        -- Rank 281-290
        "koyun", "di\197\159", "kuru", "anlamak", "bitki", "k\196\177l\196\177\195\167", "girmek", "meyve", "\195\167ekmek", "yumurta",
        -- Rank 291-300
        "s\195\182z", "cam", "bisiklet", "parmak", "keskin", "atmak", "parmak", "alkol", "ya\196\159", "yumu\197\159ak",
        -- Rank 301-310
        "duvar", "ka\196\159\196\177t", "ayakkab\196\177", "\195\182lmek", "\195\182\196\159retmek", "delik", "zay\196\177f", "tutmak", "bal", "da\196\159",
        -- Rank 311-320
        "mutfak", "sessiz", "bardak", "deri", "garip", "deri", "k\195\182pr\195\188", "bulut", "yak\196\177t", "malzeme",
        -- Rank 321-330
        "boyun", "yara", "tavuk", "duymak", "\195\182\196\159le", "kol", "yazmak", "ok", "dikkatli", "yay",
        -- Rank 331-340
        "a\196\159", "misafir", "pembe", "plastik", "toz", "diz", "kirli", "g\195\188r\195\188lt\195\188", "yaprak", "kar\196\177n",
        -- Rank 341-350
        "kemik", "kum", "g\195\182\196\159\195\188s", "g\195\182\196\159\195\188s", "tuz", "amca", "i\195\167mek", "a\196\159\196\177z", "burun", "kar\196\177",
        -- Rank 351-360
        "g\195\188r\195\188lt\195\188l\195\188", "endi\197\159e", "y\196\177lan", "sormak", "kutu", "gri", "i\195\167ecek", "alet", "mor", "b\196\177\195\167ak",
        -- Rank 361-370
        "duman", "peynir", "aramak", "kahverengi", "b\195\182cek", "kalkan", "\196\177slak", "\195\167anta", "tekne", "zemin",
        -- Rank 371-380
        "k\196\177yafet", "kilit", "nehir", "\195\167at\196\177", "sonbahar", "s\196\177rt", "\195\182ld\195\188rmek", "kamyon", "\195\182fke", "kaybetmek",
        -- Rank 381-390
        "avu\195\167", "mermi", "g\195\182l", "zehir", "pirin\195\167", "pencere", "teyze", "dede", "fare", "k\195\182k",
        -- Rank 391-400
        "i\196\159ne", "domuz", "\195\167almak", "mide", "ip", "utan\195\167", "\195\167orba", "k\195\188l", "kap", "bacak",
        -- Rank 401-410
        "g\195\182ky\195\188z\195\188", "akci\196\159er", "pantolon", "kemer", "\197\159i\197\159e", "toplamak", "kapatmak", "meyvesuyu", "g\195\182mlek", "maske",
        -- Rank 411-420
        "omuz", "bo\196\159az", "kald\196\177rmak", "mantar", "sevin\195\167", "\195\167amur", "uyumak", "sebze", "enfeksiyon", "geceyar\196\177s\196\177",
        -- Rank 421-430
        "f\196\177nd\196\177k", "k\195\188rek", "o\196\159ul", "y\195\188r\195\188mek", "ta\197\159\196\177mak", "zincir", "turuncu", "yabanc\196\177", "ot", "kesmek",
        -- Rank 431-440
        "merdiven", "g\195\182bek", "merdiven", "vurmak", "dudak", "\195\167orap", "ma\196\159ara", "tuzak", "odun", "inek",
        -- Rank 441-450
        "yaln\196\177zl\196\177k", "tabanca", "\197\159apka", "tohum", "k\196\177rmak", "unutmak", "bulu\197\159mak", "ka\197\159\196\177k", "geyik", "\195\188z\195\188nt\195\188",
        -- Rank 451-460
        "\195\167ene", "\195\167ene", "ilkbahar", "hat\196\177rlamak", "oturmak", "tabak", "yatmak", "kova", "yakmak", "t\196\177rnak",
        -- Rank 461-470
        "\195\167\195\188r\195\188k", "bez", "tarla", "ekin", "s\195\188rmek", "d\195\188\197\159mek", "giymek", "\195\167ivi", "dokunmak", "tah\196\177l",
        -- Rank 471-480
        "nine", "balta", "u\195\167mak", "eldiven", "ba\196\159lamak", "\195\167atal", "kuzen", "\195\167eki\195\167", "tencere", "m\196\177zrak",
        -- Rank 481-490
        "kar\196\177\197\159\196\177kl\196\177k", "keder", "battaniye", "lamba", "testere", "iplik", "konserve", "tekerlek", "bilek", "\195\167uval",
        -- Rank 491-500
        "hasat", "kalkmak", "sopa", "\195\167al\196\177", "b\195\188y\195\188mek", "kase", "saymak", "kau\195\167uk", "\195\167imen", "kanca",
        -- Rank 501-510
        "yaralanma", "dirsek", "tava", "tatmak", "uyanmak", "kavanoz", "\195\167izme", "\195\167it", "varil", "y\196\177kamak",
        -- Rank 511-520
        "sepet", "rahatlama", "mum", "ba\196\159\196\177rmak", "\197\159a\197\159k\196\177nl\196\177k", "me\197\159ale", "y\195\188zmek", "kaburga", "dikmek", "k\195\188t",
        -- Rank 521-530
        "topuk", "iz", "patika", "\195\182rtmek", "pi\197\159irmek", "ye\196\159en", "ye\196\159en", "b\195\182\196\159\195\188rtlen", "yanak", "susam\196\177\197\159",
        -- Rank 531-540
        "iyile\197\159mek", "kom\197\159u", "avlamak", "onarmak", "palto", "koklamak", "t\196\177rmanmak", "cevaplamak", "ba\197\159parmak", "itmek",
        -- Rank 541-547
        "bandaj", "kanamak", "solumak", "kazmak", "tiksinti", "d\195\182v\195\188\197\159mek", "z\196\177plamak",
    },

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs.
    --
    -- Turkish culture has rich phrase-conventions that native speakers
    -- learn culturally rather than picking up word-by-word: religious-
    -- origin modals used as everyday emphasis (inşallah, maşallah), set
    -- well-wishes (kolay gelsin, geçmiş olsun), specific greeting/farewell
    -- pairs. These are prime native-tester validation surface -- a Turkish
    -- speaker will immediately recognize whether each phrase reads as
    -- natural in-context use.
    cultural = {
        -- Greetings
        { en = "Hello",                l2 = "Merhaba",            tags = {"greeting"} },
        { en = "Good morning",         l2 = "G\195\188nayd\196\177n",           tags = {"greeting"} },
        { en = "Good evening",         l2 = "\196\176yi ak\197\159amlar",       tags = {"greeting"} },
        { en = "Good night",           l2 = "\196\176yi geceler",        tags = {"greeting", "farewell"} },
        { en = "Welcome",              l2 = "Ho\197\159 geldiniz",       tags = {"greeting", "formal"} },
        { en = "Goodbye",              l2 = "G\195\188le g\195\188le",          tags = {"farewell"} },
        { en = "Peace be upon you",    l2 = "Selam\195\188naleyk\195\188m",     tags = {"greeting", "traditional"} },

        -- Courtesy
        { en = "Thank you",            l2 = "Te\197\159ekk\195\188r ederim",    tags = {"courtesy"} },
        { en = "Thanks",               l2 = "Sa\196\159 ol",             tags = {"courtesy", "informal"} },
        { en = "You're welcome",       l2 = "Rica ederim",        tags = {"courtesy"} },
        { en = "Please",               l2 = "L\195\188tfen",             tags = {"courtesy"} },
        { en = "Excuse me",            l2 = "Affedersiniz",       tags = {"courtesy"} },

        -- Well-wishing (situational phrases woven through everyday speech)
        { en = "Bon appetit",          l2 = "Afiyet olsun",       tags = {"meal"} },
        { en = "May it come easy",     l2 = "Kolay gelsin",       tags = {"work", "encouragement"} },
        { en = "Get well soon",        l2 = "Ge\195\167mi\197\159 olsun",       tags = {"wellbeing"} },
        { en = "Take care",            l2 = "Kendine iyi bak",    tags = {"farewell"} },

        -- Modals and exclamations (culturally loaded, learned not lexically)
        { en = "God willing",          l2 = "\196\176n\197\159allah",           tags = {"modal"} },
        { en = "Wonderful, praise be", l2 = "Ma\197\159allah",           tags = {"admiration"} },
        { en = "I swear",              l2 = "Vallahi",            tags = {"emphasis", "informal"} },
        { en = "Let's go",             l2 = "Hadi gidelim",       tags = {"action"} },
    },
}

-- Self-register with the language system. Adding/removing this line is the
-- only integration touchpoint -- MC_Lang doesn't need to know we exist.
require("MC_LangRegistry").register("turkish", turkish)

return turkish
