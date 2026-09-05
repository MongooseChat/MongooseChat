-- MC_Babble palette: Sinitic
-- Sinitic family -- the broad, "dynastic" Chinese palette. DYNASTIC, NOT CADET:
-- one palette stands in for the whole Sinitic branch (Mandarin, Cantonese, Wu,
-- ...). A Western ear doesn't reliably tell them apart, so players who want to
-- voice a specific variety use this palette and self-identify their nation in
-- RP; the babble stays at the family level.
--
-- Phonological signature: strictly monosyllabic building blocks with the
-- unmistakable Mandarin-pinyin initials (zh/ch/sh/j/q/x/r), the -n and -ng nasal
-- finals, and ZERO consonant clusters -- clean (C)(G)V(N) syllables, opposite
-- pole from Slavic/German.
--
-- Orthography: standard Mandarin in TONELESS Hanyu Pinyin, ASCII-clean (no tone
-- marks, no multibyte -- the u-umlaut is written plain u: nu = woman, lu = green).
-- Toneless pinyin is deliberately homophone-dense (shi, ji, yi, gong...) -- those
-- conflations are honest and noted in the forms.

local sinitic = {
    name   = "Sinitic",
    family = "sinitic",

    -- Tuning dials -- see MC_Babble.lua header. Syllables are short and open
    -- (clean CV(N)); onsets are near-universal; the only "codas" are the -n/-ng
    -- baked into the finals (nuclei), so the coda pool stays empty and no
    -- clusters can form.
    tuning = {
        lettersPerSyllable     = 4,     -- Chinese words are short (1-2 syllables); map more
                                        --   input letters per syllable so babble stays terse
        onsetChance            = 0.92,  -- almost every Mandarin syllable has an initial
        midCodaChance          = 0.1,
        endingPoolChance       = 0.0,   -- finals (incl. -n/-ng) live in the nuclei, not a coda pool
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,     -- Sinitic-specific: no elisions
        signatureBoostWeight   = 2,
        featuredSignatureCount = 2,
    },

    onsets = {
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
        "j", "q", "x",                               -- palatals (the Beijing/Xi/Qing sound)
        "zh", "ch", "sh", "r",                        -- retroflexes
        "z", "c", "s", "y", "w",
    },

    nuclei = {
        -- Simple finals, weighted heavier.
        "a", "a", "e", "e", "i", "i", "o", "o", "u", "u",
        -- Diphthong finals.
        "ai", "ei", "ao", "ou",
        -- Nasal finals -- the -n/-ng signature tell.
        "an", "en", "ang", "eng", "ong", "in", "ing", "un",
        -- Glide finals.
        "ia", "ie", "iao", "ua", "uo", "ui", "uan", "ian",
    },

    codas = {
        -- Empty: Sinitic finals (including the -n/-ng nasals) are carried by the
        -- nuclei, so syllables are open or nasal-final and never cluster.
        "",
    },

    functionWords = {
        -- Ultra-common Mandarin particles/pronouns.
        "de", "le", "wo", "ni", "ta", "zhe", "na", "shi", "bu", "he",
        "zai", "you", "men", "yi", "ge", "hen", "dou", "ye", "ma", "ba",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    -- NOTE: the common Mandarin filler "nage" is deliberately EXCLUDED -- read
    -- aloud it collides with an English racial slur; "zhege"/"en"/"jiushi" carry
    -- the same hesitation function safely.
    fillers = {
        "en",            -- "uh / mm" -- the universal filler
        "jiushi",        -- "it's just / well"
        "zhege",         -- "this... / uh" (stalling)
    },

    -- Signature set. The pinyin initials and nasal finals are the tell.
    signatureSet = {
        pinyinInitials = { category = "onset",   elements = {"zh", "ch", "sh", "j", "q", "x", "r"} },
        nasalFinals    = { category = "nucleus", elements = {"ang", "eng", "ong", "an", "en", "in", "ing"} },
    },

    -- Mishearing rules (babble-resolve). The retroflex/palatal initials flatten
    -- and -ng collapses to -n in a non-native ear. DRAFT -- for review.
    -- See docs/BABBLE_RESOLVE.md.
    mishearing = {
        { "zh", "z" }, { "ch", "c" }, { "sh", "s" },   -- retroflexes -> dentals
        { "q", "ch" }, { "x", "s" },                    -- palatals flatten
        { "ng", "n" },                                  -- velar nasal -> alveolar
    },

    -- Output guard: real Mandarin vulgarities (toneless pinyin) generated babble
    -- must never land on. Whole-word, lowercase. See MC_Palette_Turkish for docs.
    babbleBlocklist = {
        "cao", "shabi", "jiba", "caonima", "wangbadan", "biaozi",
        "nima", "diao", "shaobi", "tmd",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)

    -- concept-keyed lex sourced from data/forms.tsv (the sinitic column) via
    -- devtools/generate_palette_forms.py. Standard Mandarin, toneless pinyin:
    -- verbs in the bare base form (Chinese has no infinitive); nouns/adjectives
    -- in base form. DRAFTS pending native-speaker review (flagged in the TSV
    -- note column). Homophone conflations are expected and honest here.
    lex = require("MC_PaletteFormsData").sinitic,

    -- Zipf frequency order. Generated by devtools/generate_rankings.py; Sinitic
    -- never shipped, so all forms ride the baseline-less English-frequency path.
    -- Regenerate after editing forms.tsv; do NOT hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "limian", "wo", "na", "ni", "zhe", "bu", "women", "quanbu", "tamen", "yi",
        -- Rank 11-20
        "guantou", "shang", "waimian", "shenme", "heshi", "bu", "shei", "xin", "zenme", "xianzai",
        -- Rank 21-30
        "qita", "hao", "yihou", "diyi", "zhidao", "kanjian", "er", "zuo", "xiang", "ranhou",
        -- Rank 31-40
        "bei", "yao", "qu", "jiankang", "nali", "xuyao", "youbian", "gongzuo", "nian", "baitian",
        -- Rank 41-50
        "yiqian", "weishenme", "na", "duo", "shuo", "xia", "ai", "nanren", "jia", "chang",
        -- Rank 51-60
        "kan", "dongxi", "yong", "yiyang", "lai", "san", "zhaodao", "bangzhu", "lao", "youxi",
        -- Rank 61-70
        "gei", "fangzi", "zai", "zhanshi", "da", "ganjue", "baoliu", "qinqi", "qing", "mouren",
        -- Rank 71-80
        "zuo", "mingzi", "wanshang", "wan", "shao", "butong", "dingbu", "kaishi", "xingqi", "renhe",
        -- Rank 81-90
        "ren", "jintian", "yiqie", "man", "huo", "du", "huai", "si", "ying", "gaosu",
        -- Rank 91-100
        "ting", "shui", "tou", "xiao", "bai", "yuan", "gongzuo", "pangbian", "shi", "shi",
        -- Rank 101-110
        "pao", "kai", "jijie", "xiexie", "hei", "qiche", "lian", "wu", "yexu", "gushi",
        -- Rank 111-120
        "xiwang", "zhongyao", "shu", "zao", "nianqing", "yiban", "shou", "shenti", "shiwu", "nan",
        -- Rank 121-130
        "fangjian", "ying", "cuo", "jide", "pengyou", "da", "dong", "guan", "yidong", "deng",
        -- Rank 131-140
        "nuren", "wen", "wan", "bei", "juzi", "guang", "qing", "zaoshang", "liu", "hong",
        -- Rank 141-150
        "mashang", "xinzang", "haizi", "huo", "houmian", "jianzhu", "rongyi", "jin", "jihua", "liu",
        -- Rank 151-160
        "xi", "qianmian", "zhunbei", "erzi", "dai", "jianmian", "yinger", "baba", "ge", "yue",
        -- Rank 161-170
        "qie", "tiandi", "mama", "lu", "zhen", "dajia", "tingjian", "jiage", "xiuxi", "xiatian",
        -- Rank 171-180
        "qizi", "qiangzhuang", "gunzi", "fenxiang", "si", "fasheng", "na", "xingxing", "dapo", "xiaoshi",
        -- Rank 181-190
        "zhongjian", "duibuqi", "huida", "xuexi", "duzi", "jiaotang", "dong", "re", "gen", "zhan",
        -- Rank 191-200
        "lan", "kaiche", "chi", "shuaidao", "kuai", "lu", "xinren", "yaoshi", "jiaohuan", "gege",
        -- Rank 201-210
        "beizi", "hen", "song", "xue", "gou", "you", "sha", "qiong", "gai", "men",
        -- Rank 211-220
        "toufa", "diu", "qi", "jiandan", "zou", "nuer", "si", "zhi", "anquan", "tu",
        -- Rank 221-230
        "wangji", "hai", "shuijiao", "shi", "hezi", "jianzao", "heian", "qiang", "teng", "heliu",
        -- Rank 231-240
        "shuo", "xie", "leng", "ba", "yanjing", "pingjing", "chucun", "mingtian", "zongse", "shouyinji",
        -- Rank 241-250
        "zhangfu", "bing", "ganjing", "taiyang", "qiang", "zhong", "zhao", "haipa", "lingdao", "xin",
        -- Rank 251-260
        "cailiao", "meiren", "jiejie", "naozi", "diban", "meiyou", "chuntian", "chuan", "meng", "jieshu",
        -- Rank 261-270
        "yunqi", "youqian", "pifu", "mo", "zuotian", "he", "yu", "zhang", "zuo", "ban",
        -- Rank 271-280
        "zhiwu", "dongtian", "shengbing", "zhua", "jiao", "jiu", "kafei", "wanshang", "boli", "man",
        -- Rank 281-290
        "shu", "dibu", "fadongji", "tang", "nanguo", "feng", "danxin", "shu", "hu", "zui",
        -- Rank 291-300
        "reng", "jinshu", "la", "tui", "dongwu", "jin", "shitou", "chuanghu", "daizi", "yingdi",
        -- Rank 301-310
        "mao", "jueding", "liwu", "mutou", "qiao", "huayuan", "huozhe", "ma", "ditu", "wang",
        -- Rank 311-320
        "che", "xing", "jiaoluo", "nongchang", "xiuli", "fei", "jingya", "gan", "bianyuan", "shang",
        -- Rank 321-330
        "gebo", "yao", "shan", "sheji", "chang", "cha", "ranliao", "nihao", "tiankong", "chuan",
        -- Rank 331-340
        "bai", "xiaolu", "chengnuo", "yu", "lei", "diren", "senlin", "yueliang", "tiao", "huang",
        -- Rank 341-350
        "ruan", "yan", "jiao", "dong", "tui", "niunai", "xue", "xuruo", "tielian", "zuofan",
        -- Rank 351-360
        "chufang", "anjing", "qiguai", "kache", "niao", "wan", "ji", "rou", "bozi", "chenshan",
        -- Rank 361-370
        "chengse", "jiu", "yan", "xiaoxin", "weixian", "kong", "keren", "pingzi", "nailao", "shuiguo",
        -- Rank 371-380
        "gongju", "zang", "gaoxing", "shengyin", "panzi", "fangxin", "dami", "wuding", "xiukui", "lengjing",
        -- Rank 381-390
        "duocang", "wuqi", "shi", "shao", "maozi", "dasheng", "xiong", "fenhongse", "suo", "bizi",
        -- Rank 391-400
        "suliao", "bang", "mianbao", "tai", "jianbang", "lunzi", "guanmu", "dalie", "wen", "shouzhi",
        -- Rank 401-410
        "hui", "fengli", "gutou", "yifu", "damen", "yun", "jidan", "xi", "e", "shushu",
        -- Rank 411-420
        "shazi", "xian", "zhong", "erduo", "shengqi", "pidai", "hua", "wei", "biaoqin", "huichen",
        -- Rank 421-430
        "dao", "gen", "tou", "guo", "pingdiguo", "cao", "fengmi", "gouzi", "zhongzi", "jian",
        -- Rank 431-440
        "shetou", "waitao", "guozhi", "rufang", "chu", "pige", "lang", "ganran", "xigai", "xianjing",
        -- Rank 441-450
        "zise", "yao", "kouzhao", "wuye", "gong", "zaijian", "dunpai", "houlong", "moshengren", "zacao",
        -- Rank 451-460
        "qiutian", "huxi", "zidan", "caiji", "yeye", "xiezi", "shangkou", "shouzhang", "xiangjiao", "she",
        -- Rank 461-470
        "pa", "wa", "fashao", "yezi", "zhalan", "zhijia", "dingzi", "youyong", "shandong", "rou",
        -- Rank 471-480
        "xuezi", "kunhuo", "yang", "liangshi", "tong", "laoshu", "hui", "ayi", "chuizi", "zhuangjia",
        -- Rank 481-490
        "tang", "niu", "nainai", "zhu", "louti", "jian", "zuichun", "ni", "lu", "zhiliao",
        -- Rank 491-500
        "zhongwu", "duzi", "fei", "beitong", "duyao", "yachi", "lanzi", "tanzi", "shuitong", "jiaozhi",
        -- Rank 501-510
        "shengzi", "han", "deng", "jianguo", "bu", "rongqi", "chazi", "shouhuo", "tizi", "zhizi",
        -- Rank 511-520
        "muzhi", "shouwan", "xiaba", "zixingche", "xiaba", "zhen", "jiaohuai", "jiangguo", "lianjia", "dun",
        -- Rank 521-530
        "shucai", "guanzi", "madai", "lazhu", "shaozi", "etou", "gebozhou", "jiaogen", "zhinu", "futou",
        -- Rank 531-540
        "shangba", "chongzi", "ke", "huoba", "shoutao", "liuxue", "mao", "kuzi", "yinliao", "linju",
        -- Rank 541-550
        "gudu", "mogu", "yanwu", "xiongdijiemei", "wazi", "leigu", "chanzi", "zhong", "bengdai", "yuqing",
        -- Rank 551-551
        "duqi",
    },

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs. Toneless
    -- pinyin; multi-word l2 phrases are fine (the cultural pass substitutes
    -- whole phrases, not single tokens).
    cultural = {
        { en = "Take it slow, little by little",       l2 = "manman lai",     tags = {} },
        { en = "It is really no problem at all",       l2 = "mei guanxi",     tags = {} },
        { en = "Keep going, you can do it",            l2 = "jiayou",         tags = {"encouragement"} },
        { en = "Have you eaten yet, friend",           l2 = "chi le ma",      tags = {"greeting"} },
        { en = "Have a safe journey home",             l2 = "yilu ping an",   tags = {"farewell"} },
        { en = "Enjoy your meal, everyone",            l2 = "manman chi",     tags = {"meal"} },
    },
}

-- Self-register with the language system.
require("MC_LangRegistry").register("sinitic", sinitic)

return sinitic
