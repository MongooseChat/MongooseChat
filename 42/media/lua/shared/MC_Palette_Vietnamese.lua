-- MC_Babble palette: Vietnamese
-- Austroasiatic family. Vietnamese is the major Austroasiatic language; unlike
-- the broad Sinitic/Semitic stand-ins, this palette is Vietnamese-SPECIFIC (the
-- family slot happens to have one dominant member players reach for). Players
-- self-identify their nation in RP as usual.
--
-- Phonological signature: strictly monosyllabic (C)(w)V(C) building blocks with
-- ZERO consonant clusters; the ng-/ngh-/nh- initials and the -ng/-nh/-ch finals
-- that no other palette here uses, plus the ph/th/tr/kh/qu digraphs. Same clean,
-- open-syllable pole as Sinitic, opposite from Slavic/German.
--
-- Orthography: standard Vietnamese in TONELESS ASCII. Vietnamese is written in
-- Latin Quoc Ngu but with tone + vowel-quality diacritics -- ALL stripped here
-- (a-breve/a-circumflex -> a, o-horn/o-circumflex -> o, u-horn -> u, d-bar -> d,
-- every tone mark dropped), exactly as Sinitic uses toneless pinyin. Toneless
-- Vietnamese is DEEPLY homophone-dense (ma = ghost/mother/but/horse/tomb across
-- tones) -- those conflations are honest and noted in the forms.

local vietnamese = {
    name   = "Vietnamese",
    family = "austroasiatic",

    -- Tuning dials -- see MC_Babble.lua header. Short open/nasal-final syllables;
    -- onsets near-universal; codas restricted to the Vietnamese final set so no
    -- clusters can form. Two featured tells per utterance (the ng-/nh- signature).
    tuning = {
        lettersPerSyllable     = 4,     -- Vietnamese words are short (mostly monosyllabic);
                                        --   map more input letters per syllable so babble stays terse
        onsetChance            = 0.9,
        midCodaChance          = 0,     -- Vietnamese-specific: real Vietnamese syllables are
                                        --   space-separated words, so an internal coda would butt
                                        --   against the next onset and form a cross-syllable cluster
                                        --   (ng+k, n+tr) that Vietnamese never has. Keep internal
                                        --   syllables open; the Vietnamese final rides endingPool
                                        --   (word-final only). Same clean-juncture reasoning as Sinitic.
        endingPoolChance       = 0.55,
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,     -- Vietnamese-specific: no elisions
        signatureBoostWeight   = 2,
        featuredSignatureCount = 2,
    },

    onsets = {
        "b", "c", "d", "g", "gh", "h", "k", "kh", "l", "m", "n",
        "ng", "ngh", "nh",                            -- the velar/palatal-nasal initials (the tell)
        "ph", "qu", "r", "s", "t", "th", "tr", "v", "x", "gi",
    },

    nuclei = {
        -- Monophthongs weighted heavy; the rest are Vietnamese diphthongs
        -- (toneless, so o-horn/o-circumflex and u/u-horn have merged).
        "a", "a", "e", "e", "i", "i", "o", "o", "u", "u",
        "ai", "ao", "au", "ay", "eo", "oi", "ui", "ua", "ia", "uo", "uoi",
    },

    codas = {
        -- Only the Vietnamese final set (-c/-ch/-m/-n/-ng/-nh/-p/-t); empty for
        -- open syllables. No cluster can form.
        "", "", "ng", "nh", "n", "c", "ch", "m", "p", "t",
    },

    functionWords = {
        -- Ultra-common Vietnamese particles/pronouns/copula.
        "la", "va", "cua", "o", "voi", "cho", "khong", "co", "toi", "ban",
        "no", "nay", "do", "cai", "mot", "da", "se", "thi",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    fillers = {
        "u",             -- "u: uh / mm" -- the universal filler
        "thi",           -- "thi: well / then" (stalling)
        "cai",           -- "cai...: the thing / uh" (word-search)
    },

    -- Signature set. The nasal initials/finals and the digraph onsets are the tell.
    signatureSet = {
        nasalInitials = { category = "onset", elements = {"ng", "ngh", "nh"} },
        vietDigraphs  = { category = "onset", elements = {"ph", "th", "tr", "kh", "qu"} },
        nasalFinals   = { category = "coda",  elements = {"ng", "nh", "ch"} },
    },

    -- Mishearing rules (babble-resolve). The nasal initials/finals and aspirate
    -- digraphs flatten in a non-native ear. DRAFT -- for review.
    -- See docs/BABBLE_RESOLVE.md.
    mishearing = {
        { "ngh", "ng" }, { "nh", "n" }, { "ng", "n" },   -- nasals simplify
        { "tr", "ch" }, { "ph", "p" }, { "kh", "k" }, { "gh", "g" },  -- digraphs flatten
    },

    -- Output guard: real Vietnamese vulgarities generated babble must never land
    -- on. Whole-word, lowercase (toneless). Guards GENERATED babble only. DRAFT --
    -- native review. See MC_Palette_Turkish for docs.
    babbleBlocklist = {
        "dit", "lon", "cac", "buoi", "cu", "dm", "vcl", "vl", "cc", "dcm", "loz",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)

    -- concept-keyed lex sourced from data/forms.tsv (the vietnamese column) via
    -- devtools/generate_palette_forms.py. Standard Vietnamese, toneless ASCII:
    -- verbs in the bare base form (no inflection); nouns without classifiers.
    -- DRAFTS pending native-speaker review (flagged in the TSV note column).
    -- Toneless homophone conflations are expected and honest here.
    lex = require("MC_PaletteFormsData").vietnamese,

    -- Zipf frequency order. Generated by devtools/generate_rankings.py; Vietnamese
    -- never shipped, so all forms ride the baseline-less English-frequency path.
    -- Regenerate after editing forms.tsv; do NOT hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "trong", "toi", "do", "ban", "nay", "khong", "ta", "ca", "ho", "mot",
        -- Rank 11-20
        "lon", "len", "ngoai", "gi", "khi", "khong", "ai", "moi", "sao", "khac",
        -- Rank 21-30
        "tot", "sau", "dau", "biet", "thay", "hai", "lam", "nghi", "roi", "lung",
        -- Rank 31-40
        "muon", "di", "khoe", "dau", "can", "phai", "viec", "nam", "ngay", "truoc",
        -- Rank 41-50
        "sao", "lay", "nhieu", "noi", "xuong", "yeu", "nha", "dai", "nhin", "gi",
        -- Rank 51-60
        "dung", "giong", "den", "ba", "tim", "giup", "gia", "cho", "nha", "lai",
        -- Rank 61-70
        "bay", "to", "cam", "giu", "xin", "ai", "trai", "ten", "dem", "choi",
        -- Rank 71-80
        "it", "khac", "dinh", "tuan", "nguoi", "day", "song", "doc", "xau", "bon",
        -- Rank 81-90
        "cung", "ke", "dung", "nuoc", "dau", "nho", "trang", "xa", "viec", "ben",
        -- Rank 91-100
        "thu", "vang", "chay", "mo", "mua", "den", "xe", "mat", "nam", "chac",
        -- Rank 101-110
        "truyen", "mong", "sach", "som", "tre", "nua", "tay", "than", "nam", "phong",
        -- Rank 111-120
        "thang", "sai", "nho", "ban", "danh", "hieu", "dong", "chuyen", "cho", "hoi",
        -- Rank 121-130
        "muon", "bac", "cua", "sang", "nhe", "sang", "o", "do", "som", "tim",
        -- Rank 131-140
        "tre", "lua", "sau", "nha", "de", "gan", "sau", "tay", "truoc", "san",
        -- Rank 141-150
        "mang", "gap", "be", "cha", "thang", "cat", "ruong", "me", "duong", "danh",
        -- Rank 151-160
        "nghe", "gia", "nghi", "he", "vo", "manh", "gay", "chia", "chet", "cam",
        -- Rank 161-170
        "sao", "vo", "gio", "giua", "dap", "hoc", "dong", "nong", "theo", "dung",
        -- Rank 171-180
        "xanh", "lai", "an", "nga", "nhanh", "xanh", "tin", "buon", "anh", "coc",
        -- Rank 181-190
        "ghet", "gui", "mau", "cho", "dau", "giet", "ngheo", "che", "cua", "toc",
        -- Rank 191-200
        "mat", "bay", "chet", "giay", "an", "dat", "quen", "bien", "ngu", "muoi",
        -- Rank 201-210
        "hop", "xay", "toi", "tuong", "dau", "song", "noi", "viet", "lanh", "tam",
        -- Rank 211-220
        "mat", "yen", "tru", "mai", "nau", "dai", "chong", "da", "sach", "sung",
        -- Rank 221-230
        "nang", "tim", "so", "sep", "thu", "chat", "chi", "nao", "san", "xuan",
        -- Rank 231-240
        "mac", "mo", "xong", "may", "giau", "da", "cham", "uong", "ca", "lon",
        -- Rank 241-250
        "ngoi", "mang", "cay", "dong", "om", "bat", "chan", "chin", "toi", "kinh",
        -- Rank 251-260
        "cham", "cay", "day", "may", "nam", "buon", "gio", "lo", "dem", "ho",
        -- Rank 261-270
        "mieng", "nem", "keo", "day", "thu", "vao", "da", "tui", "trai", "meo",
        -- Rank 271-280
        "quyet", "qua", "go", "cau", "vuon", "song", "ngua", "luoi", "xe", "day",
        -- Rank 281-290
        "goc", "trai", "sua", "bay", "kho", "mep", "tay", "thuoc", "nui", "ban",
        -- Rank 291-300
        "nem", "tra", "xang", "chao", "troi", "thuyen", "tram", "duong", "hua", "mua",
        -- Rank 301-310
        "met", "dich", "rung", "trang", "nhay", "vang", "mem", "khoi", "day", "lo",
        -- Rank 311-320
        "chan", "sua", "tuyet", "yeu", "xich", "nau", "bep", "im", "la", "chim",
        -- Rank 321-330
        "bat", "ga", "thit", "co", "ao", "cam", "ruou", "muoi", "nguy", "rong",
        -- Rank 331-340
        "khach", "chai", "trai", "ban", "vui", "tieng", "dia", "gao", "mai", "nhuc",
        -- Rank 341-350
        "yen", "giau", "uot", "dot", "mu", "on", "nguc", "hong", "khoa", "mui",
        -- Rank 351-360
        "nhua", "buoc", "nang", "vai", "bui", "san", "ngui", "ngon", "xam", "sac",
        -- Rank 361-370
        "xuong", "cong", "may", "trung", "rua", "doi", "chu", "cat", "chi", "tai",
        -- Rank 371-380
        "gian", "nit", "hoa", "bui", "dao", "re", "trom", "noi", "chao", "co",
        -- Rank 381-390
        "mat", "moc", "hat", "kiem", "luoi", "vu", "ra", "da", "soi", "bay",
        -- Rank 391-400
        "tim", "can", "cung", "chao", "khien", "hong", "co", "thu", "tho", "dan",
        -- Rank 401-410
        "gom", "ong", "giay", "ran", "leo", "dao", "sot", "la", "rao", "mong",
        -- Rank 411-420
        "dinh", "boi", "hang", "thit", "ung", "roi", "cuu", "thoc", "thung", "chuot",
        -- Rank 421-430
        "tro", "co", "bua", "canh", "bo", "ba", "lon", "thang", "ten", "moi",
        -- Rank 431-440
        "bun", "nai", "chua", "trua", "bung", "phoi", "sau", "doc", "rang", "gio",
        -- Rank 441-450
        "chan", "xo", "day", "het", "den", "hat", "vai", "thung", "nia", "gat",
        -- Rank 451-460
        "thang", "chau", "cam", "ham", "kim", "dau", "ma", "cun", "rau", "lo",
        -- Rank 461-470
        "bao", "nen", "thia", "tran", "khuyu", "got", "chau", "riu", "seo", "sau",
        -- Rank 471-480
        "khat", "duoc", "gang", "giao", "quan", "nam", "gom", "tat", "suon", "xeng",
        -- Rank 481-484
        "gieo", "bang", "bam", "ron",
    },

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs. Toneless;
    -- multi-word l2 phrases are fine (the cultural pass substitutes whole
    -- phrases, not single tokens).
    cultural = {
        { en = "Hello there, greetings to you",       l2 = "xin chao",       tags = {"greeting"} },
        { en = "Thank you so very much",              l2 = "cam on nhieu",   tags = {} },
        { en = "It is nothing, never mind",           l2 = "khong sao",      tags = {} },
        { en = "Goodbye, see you again",              l2 = "tam biet",       tags = {"farewell"} },
        { en = "Please, go right ahead",              l2 = "moi ban",        tags = {} },
        { en = "Wishing you good health",             l2 = "chuc suc khoe",  tags = {} },
    },
}

-- Self-register with the language system.
require("MC_LangRegistry").register("vietnamese", vietnamese)

return vietnamese
