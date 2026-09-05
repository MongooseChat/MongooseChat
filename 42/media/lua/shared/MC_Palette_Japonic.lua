-- MC_Babble palette: Japonic
-- Japonic family. Phonological signature: clean open CV(y) morae, vowel-or-n
-- word endings, sh/ch/ts sibilants + affricates, occasional long vowels, and
-- ZERO consonant clusters. Built to read as unmistakably Japanese at a glance
-- and to sit at the opposite pole from the cluster-heavy Slavic palette.
--
-- Identity: standard (Tokyo) Japanese, romanised. Orthography is ASCII-clean
-- wapuro/Hepburn-hybrid romaji -- NO multibyte escaping (unlike the French and
-- Turkish palettes): shi/chi/tsu/fu, sh/ch/ts for the sibilant-affricate tells,
-- long vowels spelled per-kana (ou/oo/aa/ii/uu/ee/ei), geminates doubled
-- (kk/tt/ss/pp), moraic n written n or nn (never the apostrophe n').
--
-- DYNASTIC, NOT CADET: this one palette is the broad Japonic-sphere stand-in --
-- Japanese and its Japonic varieties (Ryukyuan, historical stages). Players who
-- want one of those use this palette and self-identify their variety in RP; the
-- babble stays at the family level rather than splitting into a cadet palette
-- per variety. (Korean is NOT here -- it has strong standalone demand and a
-- distinct sound, so it lives in its own Koreanic palette, MC_Palette_Korean.)
--
-- A NOTE ON GEMINATES IN GENERATED BABBLE
-- Japanese geminates (sokuon: kk, tt, ss, pp, tch) are strictly intervocalic
-- and require coordinating two adjacent morae. The pure MC_Babble engine builds
-- each mora independently, so it cannot force a clean intervocalic geminate
-- without either risking a non-Japanese cluster (a stop coda colliding with a
-- mismatched following onset) or an engine change -- and engine changes are out
-- of scope. Rather than compromise the "clean CV / ZERO clusters" signature,
-- generated babble models the achievable tells (open CV(y) morae, vowel-or-n
-- endings, long vowels, sh/ch/ts, palatal glides). Geminates live where they
-- read correctly: in the acquired lex (gakkou, nattsu, happa, koppu, torakku)
-- and in the mishearing rules below (geminate -> single as the tell flattens).

local japonic = {
    name   = "Japonic",
    family = "japonic",

    -- Tuning dials -- see MC_Babble.lua header for the full schema. Japanese
    -- morae are short and open, so:
    --   - lettersPerSyllable is 2 (CV morae track ~2 input letters), giving the
    --     staccato multi-mora rhythm.
    --   - midCodaChance / endingPoolChance are low: syllables are open; the only
    --     coda is moraic n, kept occasional so most morae end in a vowel.
    --   - elisionPrefixChance is 0 -- Japanese does not apostrophe-elide.
    tuning = {
        lettersPerSyllable     = 2,
        onsetChance            = 0.9,   -- most morae are CV; only ~10% onsetless (vowel morae)
        midCodaChance          = 0.18,  -- non-final morae rarely closed (only moraic n)
        endingPoolChance       = 0.22,  -- occasional forced -n ending (the signature)
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,     -- Japonic-specific: no elisions
        signatureBoostWeight   = 2,     -- milder than the default 3: Japanese texture is fairly
                                        --   uniform, so a gentle boost avoids tell-pileups
        featuredSignatureCount = 1,     -- feature ONE tell per utterance (nasal OR long-vowel OR
                                        --   sibilant) so they don't stack into gibberish
    },

    onsets = {
        -- Base single consonants (Japanese onsets never cluster). No bare "w"
        -- beyond the particle "wa" (w+i/u/e/o are not modern morae) and no Cy
        -- glides (kya/ryo...): the engine picks onset and nucleus independently,
        -- so a glide would land on i/e ~40% of the time and yield non-morae
        -- (kyi/rye). The palatal tell is carried cleanly by sh/ch/ts, which stay
        -- valid across every vowel (sha/shi/shu/sho, cha/chi/chu/cho, tsu...).
        "k", "s", "t", "n", "h", "m", "y", "r", "g", "z", "d", "b", "p",
        "f", "j",                                  -- fu, ji and friends
        "sh", "ch", "ts",                          -- sibilantAffricates signature
    },

    nuclei = {
        -- Short vowels form the clean-CV core; listed 7x each so long vowels
        -- stay ~13% of nuclei -- most morae are a crisp short vowel, and long
        -- vowels rarely stack more than one per word.
        "a", "a", "a", "a", "a", "a", "a", "i", "i", "i", "i", "i", "i", "i",
        "u", "u", "u", "u", "u", "u", "u", "e", "e", "e", "e", "e", "e", "e",
        "o", "o", "o", "o", "o", "o", "o",
        -- Occasional long vowels (the tell), spelled per-kana.
        "ou", "oo", "aa", "ii", "uu",              -- longVowels signature
    },

    codas = {
        -- Open syllables dominate; moraic n is the only real coda. Weighted 4:1
        -- toward empty so most morae end in a vowel. No stop codas -> no clusters.
        "", "", "", "", "n",
    },

    functionWords = {
        -- Particles and common short words a Japanese speaker sprinkles between
        -- content words. (Any that collide with the engine's English short-word
        -- guard -- e.g. "no", "to" -- are simply re-rolled; harmless.)
        "wa", "ga", "wo", "ni", "no", "to", "de", "mo", "ka", "ya",
        "na", "ne", "yo", "kara", "made", "dake", "hodo", "kana", "sa",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs). Inserted by
    -- the production pass on the first failed roll per message; not acquirable.
    fillers = {
        "eeto",          -- "um / er" -- the universal Japanese filler
        "ano",           -- "uh / you know" (hesitation use)
        "maa",           -- "well / I mean" -- trailing-off marker
    },

    -- Signature set: distinctive Japonic phonological elements the per-utterance
    -- featuring system promotes. Per utterance `featuredSignatureCount` of these
    -- are featured and their elements get `signatureBoostWeight` in their pool.
    -- (Geminates are a declared tell realised in the lex + mishearing, not force-
    -- generated -- see the header note; they are intentionally absent here so the
    -- clean-CV / zero-cluster signature is never violated.)
    signatureSet = {
        moraicNEnding      = { category = "coda",    elements = {"n"} },
        longVowels         = { category = "nucleus", elements = {"ou", "oo", "aa", "ii", "uu"} },
        sibilantAffricates = { category = "onset",   elements = {"sh", "ch", "ts"} },
    },

    -- Mishearing rules (babble-resolve). How Japonic's distinctive features
    -- flatten in a generic non-native ear; consumed by MC_Babble.resolveWord
    -- for the "misheard" resolution state. Ordered {from, to}; whole-cluster
    -- rules run before single-letter ones. DRAFT -- for review.
    --   geminate -> single (kk/tt/ss/pp -> k/t/s/p; tch -> ch first)
    --   long vowel -> short (ou/oo/uu/aa/ii/ee/ei -> o/u/a/i/e)
    --   sh/ch/ts -> s/t (the sibilant-affricate tells flatten)
    -- See docs/BABBLE_RESOLVE.md.
    mishearing = {
        { "tch", "ch" },                                                  -- de-geminate the affricate first
        { "kk", "k" }, { "tt", "t" }, { "ss", "s" }, { "pp", "p" },       -- de-geminate stops
        { "ou", "o" }, { "oo", "o" }, { "uu", "u" }, { "aa", "a" },       -- shorten long vowels
        { "ii", "i" }, { "ee", "e" }, { "ei", "e" },
        { "sh", "s" }, { "ch", "t" }, { "ts", "s" },                      -- flatten sibilants/affricates
    },

    -- Output guard (consumed by MC_Babble): real Japanese vulgarities that
    -- generated babble must never land on -- clean CV combinatorics readily
    -- produce these (manko, chinko, kuso...), so the guard matters here.
    -- Whole-word, all lowercase. See MC_Palette_Turkish for schema docs.
    babbleBlocklist = {
        "kuso", "unko", "chinko", "chinpo", "chinchin", "manko",
        "shine", "chikushou", "bakayarou", "kutabare", "yariman", "sukebe",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)
    -- Consumed by MC_Lang dictionary bleed + MC_Acquisition exposure.
    -- See MC_Babble.lua palette schema docs for field shapes.

    -- concept-keyed lex (CONCEPT_ID -> { l2 = "form" }), sourced from
    -- data/forms.tsv (the japonic column) via devtools/generate_palette_forms.py
    -- -- the same data-source pattern as MC_Concepts; edit the TSV, then
    -- regenerate + escape (see the MC_PaletteFormsData.lua header). Forms are
    -- standard-Japanese romaji: verbs in dictionary form (taberu, iku); nouns in
    -- base form; adjectives in their citation form (i- or na-adjective base).
    -- Japanese has no grammatical gender, so no inflection variant to pick.
    --
    -- These forms are DRAFTS pending native-speaker review (flagged in the TSV
    -- `note` column). Translation choices worth knowing (beyond the many romaji
    -- homophones and real conflations, all noted in forms.tsv):
    --   ASK = tazuneru       -- 尋ねる 'inquire'; 聞く kiku doubles as hear/ask,
    --                           so the dedicated verb keeps ASK != HEAR
    --   SMELL = kagu         -- 嗅ぐ 'to sniff/perceive'; 匂う niou is the emit
    --                           direction, the opposite sense
    --   HEAL = iyasu / FIX = naosu -- 癒す vs 直す, splitting the naosu homophone
    --   LOOK = nagameru / SEE = miru -- 眺める vs 見る, splitting 見る
    --   SKIN = hada          -- 肌; keeps RIVER/LEATHER=kawa (川/革) distinct
    --   Real single-word conflations honoured directly (Japanese has one word):
    --     FOOT = LEG = ashi, FINGER = TOE = yubi, CHEST = BREAST = mune,
    --     MONTH = MOON = tsuki, FLESH = MEAT = niku, JAW = CHIN = ago,
    --     JOB = WORK = shigoto, WORK/SIBLING splits (kyoudai) age-flagged.
    lex = require("MC_PaletteFormsData").japonic,

    -- Zipf frequency order: rank-1 = most common in the language at large.
    -- MC_Acquisition reverse-looks-up to give common words a head start
    -- (rank-1..10 acquired from first exposure; rare words need repetition).
    -- Forms here are the L2 (Japonic) romaji lowercased.
    --
    -- Entries are a subset of lex L2 forms; forms outside the lex have no
    -- rank-lookup effect. Generated by devtools/generate_rankings.py from the
    -- concepts' English-frequency percentile (japonic has no frozen 8.16.1
    -- baseline -- it never shipped -- so ALL forms flow through the insertion
    -- rule; see the generator docstring). Regenerate after editing forms.tsv;
    -- do NOT hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "naka", "watashi", "are", "anata", "kore", "nai", "watashitachi", "zenbu", "karera", "ichi",
        -- Rank 11-20
        "kan", "ue", "soto", "nani", "itsu", "iie", "dare", "atarashii", "dou", "ima",
        -- Rank 21-30
        "hoka", "ii", "ato", "saisho", "shiru", "miru", "ni", "tsukuru", "kangaeru", "sorekara",
        -- Rank 31-40
        "senaka", "hoshii", "iku", "genki", "doko", "hitsuyou", "migi", "shigoto", "toshi", "hi",
        -- Rank 41-50
        "mae", "naze", "toru", "takusan", "iu", "shita", "ai", "otoko", "uchi", "nagai",
        -- Rank 51-60
        "nagameru", "nanika", "tsukau", "onaji", "kuru", "san", "mitsukeru", "tasukeru", "furui", "geemu",
        -- Rank 61-70
        "ageru", "ie", "mata", "miseru", "ookii", "kanjiru", "tamotsu", "kazoku", "onegai", "dareka",
        -- Rank 71-80
        "hidari", "namae", "yoru", "asobu", "sukoshi", "chigau", "ue", "hajimeru", "shuu", "nandemo",
        -- Rank 81-90
        "hito", "kyou", "subete", "ippai", "ikiru", "yomu", "warui", "yon", "katai", "tsutaeru",
        -- Rank 91-100
        "tomeru", "mizu", "atama", "chiisai", "shiro", "tooi", "shigoto", "yoko", "tamesu", "hai",
        -- Rank 101-110
        "hashiru", "akeru", "kisetsu", "arigatou", "kuro", "kuruma", "kao", "go", "tabun", "monogatari",
        -- Rank 111-120
        "kibou", "juuyou", "hon", "hayai", "wakai", "hanbun", "te", "karada", "tabemono", "minami",
        -- Rank 121-130
        "heya", "katsu", "machigai", "oboeru", "tomodachi", "naguru", "wakaru", "shimeru", "ugoku", "matsu",
        -- Rank 131-140
        "onna", "tazuneru", "osoi", "kita", "nokogiri", "hikari", "karui", "asa", "nokoru", "aka",
        -- Rank 141-150
        "sugu", "shinzou", "kodomo", "hi", "ushiro", "tatemono", "kantan", "chikai", "keikaku", "roku",
        -- Rank 151-160
        "nishi", "mae", "junbi", "musuko", "mottekuru", "au", "akachan", "chichi", "uta", "tsuki",
        -- Rank 161-170
        "kiru", "nohara", "haha", "michi", "machi", "tatakau", "kiku", "nedan", "yasumu", "natsu",
        -- Rank 171-180
        "tsuma", "tsuyoi", "konbou", "wakeru", "shinda", "okoru", "motsu", "hoshi", "kowasu", "jikan",
        -- Rank 181-190
        "mannaka", "gomen", "kotaeru", "narau", "hitori", "kyoukai", "higashi", "atsui", "tsuiteiku", "tatsu",
        -- Rank 191-200
        "ao", "unten", "taberu", "ochiru", "hayai", "midori", "shinrai", "kagi", "koukan", "kyoudai",
        -- Rank 201-210
        "koppu", "nikumu", "okuru", "chi", "inu", "abura", "korosu", "binbou", "oou", "doa",
        -- Rank 211-220
        "kaminoke", "nakusu", "nana", "tanjun", "aruku", "musume", "shinu", "kami", "anzen", "tsuchi",
        -- Rank 221-230
        "wasureru", "umi", "neru", "juu", "hako", "tateru", "kurai", "kabe", "itami", "kawa",
        -- Rank 231-240
        "hanasu", "kaku", "samui", "hachi", "me", "heiwa", "takuwaeru", "ashita", "chairo", "rajio",
        -- Rank 241-250
        "otto", "koori", "kirei", "taiyou", "teppou", "omoi", "sagasu", "kowai", "riidaa", "tegami",
        -- Rank 251-260
        "zairyou", "daremo", "shimai", "nou", "yuka", "nai", "haru", "kiru", "yume", "owaru",
        -- Rank 261-270
        "un", "kanemochi", "hada", "sawaru", "kinou", "nomu", "sakana", "sodatsu", "suwaru", "hakobu",
        -- Rank 271-280
        "shokubutsu", "fuyu", "byouki", "tsukamaeru", "ashi", "kyuu", "koohii", "yuugata", "garasu", "osoi",
        -- Rank 281-290
        "ki", "soko", "enjin", "yokotawaru", "kanashimi", "kaze", "shinpai", "kazoeru", "mizuumi", "kuchi",
        -- Rank 291-300
        "nageru", "kinzoku", "hiku", "osu", "doubutsu", "hairu", "ishi", "mado", "kaban", "kyanpu",
        -- Rank 301-310
        "neko", "kimeru", "okurimono", "mokuzai", "hashi", "niwa", "ikiteru", "uma", "chizu", "ami",
        -- Rank 311-320
        "norimono", "okiru", "kado", "noujou", "naosu", "tobu", "odoroki", "kawaita", "fuchi", "kega",
        -- Rank 321-330
        "ude", "kusuri", "yama", "utsu", "ajiwau", "ocha", "nenryou", "konnichiwa", "sora", "fune",
        -- Rank 331-340
        "hyaku", "komichi", "yakusoku", "ame", "tsukareta", "teki", "mori", "tsuki", "tobu", "kiiro",
        -- Rank 341-350
        "yawarakai", "kemuri", "oshieru", "ana", "ashi", "miruku", "yuki", "yowai", "kusari", "ryouri",
        -- Rank 351-360
        "daidokoro", "shizuka", "hen", "torakku", "tori", "owan", "niwatori", "niku", "kubi", "shatsu",
        -- Rank 361-370
        "orenji", "sake", "shio", "shinchou", "kiken", "kara", "kyaku", "bin", "chiizu", "kudamono",
        -- Rank 371-380
        "dougu", "kitanai", "yorokobi", "oto", "sara", "anshin", "kome", "yane", "haji", "odayaka",
        -- Rank 381-390
        "kakureru", "buki", "nureta", "moeru", "boushi", "urusai", "mune", "pinku", "joumae", "hana",
        -- Rank 391-400
        "purasuchikku", "musubu", "pan", "mochiageru", "kata", "sharin", "yabu", "karu", "kagu", "yubi",
        -- Rank 401-410
        "haiiro", "surudoi", "hone", "fuku", "mon", "kumo", "tamago", "arau", "kuufuku", "oji",
        -- Rank 411-420
        "suna", "ito", "tokei", "mimi", "ikari", "beruto", "hana", "ibukuro", "itoko", "hokori",
        -- Rank 421-430
        "naifu", "ne", "nusumu", "nabe", "furaipan", "kusa", "hachimitsu", "kagi", "tane", "katana",
        -- Rank 431-440
        "shita", "kooto", "juusu", "mune", "deru", "kawa", "ookami", "kansen", "hiza", "wana",
        -- Rank 441-450
        "murasaki", "kamu", "masuku", "mayonaka", "yumi", "sayounara", "tate", "nodo", "tanin", "zassou",
        -- Rank 451-460
        "aki", "kokyuu", "tama", "atsumeru", "ojiisan", "kutsu", "kizu", "tenohira", "gomu", "hebi",
        -- Rank 461-470
        "noboru", "horu", "netsu", "happa", "saku", "tsume", "kugi", "oyogu", "doukutsu", "niku",
        -- Rank 471-480
        "buutsu", "konran", "hitsuji", "kokumotsu", "taru", "nezumi", "hai", "oba", "kanazuchi", "sakumotsu",
        -- Rank 481-490
        "suupu", "ushi", "obaasan", "buta", "kaidan", "ya", "kuchibiru", "doro", "shika", "iyasu",
        -- Rank 491-500
        "hiru", "onaka", "hai", "kanashimi", "doku", "ha", "kago", "moufu", "baketsu", "yubi",
        -- Rank 501-510
        "roopu", "sakebu", "ranpu", "nattsu", "nuno", "iremono", "fooku", "shuukaku", "hashigo", "oi",
        -- Rank 511-520
        "oyayubi", "tekubi", "ago", "jitensha", "ago", "hari", "ashikubi", "kinomi", "hoho", "nibui",
        -- Rank 521-530
        "yasai", "tsubo", "fukuro", "rousoku", "supuun", "hitai", "hiji", "kakato", "mei", "ono",
        -- Rank 531-540
        "kizuato", "mushi", "kawaki", "taimatsu", "tebukuro", "shukketsu", "yari", "zubon", "nomimono", "rinjin",
        -- Rank 541-550
        "kodoku", "kinoko", "iya", "kyoudai", "kutsushita", "abara", "shaberu", "maku", "houtai", "aza",
        -- Rank 551-551
        "heso",
    },

    -- lexicalSets are declared centrally in MC_Concepts.lua as concept-keyed
    -- semantic neighborhoods; palettes no longer declare their own.

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs.
    --
    -- Japanese has a rich stock of set phrases (aisatsu) that natives use by
    -- convention and that no amount of lexical exposure lets a non-native
    -- acquire: mealtime and work-parting formulae, arrival/departure pairs, the
    -- resignation idiom. Prime native-tester validation surface. Romaji (ASCII)
    -- to match this palette's orthography; multi-word l2 phrases are fine (the
    -- cultural pass substitutes whole phrases, not single tokens).
    cultural = {
        { en = "Thank you for the meal",              l2 = "Gochisousama deshita",    tags = {"meal"} },
        { en = "Please take good care of me",         l2 = "Yoroshiku onegaishimasu", tags = {"greeting", "formal"} },
        { en = "Thank you for your hard work today",  l2 = "Otsukaresama deshita",    tags = {"work"} },
        { en = "It cannot be helped, so let it go",   l2 = "Shou ga nai",             tags = {} },
        { en = "I am heading out, see you later",     l2 = "Ittekimasu",              tags = {"farewell"} },
        { en = "Welcome back, I am glad you returned",l2 = "Okaerinasai",             tags = {"greeting"} },
    },
}

-- Self-register with the language system. Adding/removing this line is the
-- only integration touchpoint -- MC_Lang doesn't need to know we exist.
require("MC_LangRegistry").register("japonic", japonic)

return japonic
