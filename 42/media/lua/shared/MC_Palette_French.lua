-- MC_Babble palette: French
-- Romance family. Phonological signature: nasal endings, apostrophe elisions,
-- accented vowels, function-word pool, soft endings.

local french = {
    name   = "French",
    family = "romance",

    -- Tuning dials -- adjust to refine French's rhythm without engine edits.
    -- See MC_Babble.lua header for the full schema. All fields optional;
    -- omitted values fall back to engine defaults.
    tuning = {
        lettersPerSyllable     = 3,    -- French syllables roughly track 3 input letters
        onsetChance            = 0.7,
        midCodaChance          = 0.5,
        endingPoolChance       = 0.7,  -- bias toward the nasal/soft signature endings
        functionWordChance     = 0.4,  -- French is dense with function words
        elisionPrefixChance    = 0.2,  -- moderate apostrophe-elision rate
        signatureBoostWeight   = 3,
        featuredSignatureCount = 2,
    },

    onsets = {
        "b", "p", "m", "v", "f", "t", "d", "n", "r", "s", "l", "z",
        "j", "ch", "qu", "gn",
        "br", "pr", "tr", "cr", "fr", "fl", "pl", "cl",
    },

    nuclei = {
        "a", "e", "i", "o", "u",
        "ou", "eu", "ai", "oi", "ui", "ie", "au",
        "\195\169", "\195\168", "\195\170", "\195\160",
    },

    codas = {
        "", "t", "r", "s", "n", "m", "nt", "rd", "nd", "ne", "te", "re",
        "on", "eau", "ant",      -- nasalEndings signature elements
        "elle", "eux", "oir",    -- softEndings signature elements
    },

    functionWords = {
        "le", "la", "les", "de", "des", "un", "une",
        "et", "est", "que", "qui", "en", "\195\160",
    },

    elisionPrefixes = {
        "j'", "l'", "d'", "c'", "qu'", "n'",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    fillers = {
        "euh",           -- "uh/um" -- the universal French filler
        "enfin",         -- "well / anyway / I mean"
        "bref",          -- "in short" -- trailing-off filler
    },

    -- Signature set: distinctive phonological elements. Per-utterance featuring picks
    -- `tuning.featuredSignatureCount` of these; the picker for each entry's category
    -- gets `tuning.signatureBoostWeight` weight on those elements. Non-featured
    -- signatures still appear at base rate via the general pools above.
    signatureSet = {
        nasalEndings       = { category = "coda",          elements = {"on", "eau", "ant"} },
        apostropheElisions = { category = "elisionPrefix", elements = {"j'", "l'", "qu'", "n'"} },
        accentSprinkle     = { category = "nucleus",       elements = {"\195\169", "\195\168", "\195\170", "\195\160"} },
        functionWordPool   = { category = "functionWord",  elements = {"le", "la", "de", "et", "est", "que", "en"} },
        softEndings        = { category = "coda",          elements = {"elle", "eux", "oir"} },
    },

    -- Mishearing rules (babble-resolve). How French's distinctive features
    -- flatten in a generic non-native ear; consumed by MC_Babble.resolveWord
    -- for the "misheard" resolution state. Ordered {from, to}; whole-cluster
    -- rules run before single-letter ones. DRAFT -- for review (nasal coverage
    -- is partial: -ain/-oin and bare oi/oe are left feature-less for now).
    -- (The design doc this once cited, docs/BABBLE_RESOLVE.md, was lost with
    -- an ephemeral workspace and never recovered -- see docs/ARCHITECTURE.md.)
    mishearing = {
        { "eau", "o" }, { "au", "o" }, { "ou", "u" }, { "eu", "e" },   -- vowel digraphs (eau before au)
        { "on", "o" }, { "an", "a" }, { "en", "a" },                   -- nasals denasalised
        { "\195\169", "e" }, { "\195\168", "e" }, { "\195\170", "e" }, { "\195\171", "e" },  -- e-accents
        { "\195\160", "a" }, { "\195\162", "a" }, { "\195\180", "o" },                          -- a-accents, o-circ
        { "\195\174", "i" }, { "\195\175", "i" }, { "\195\187", "u" }, { "\195\185", "u" },  -- i/u-accents
        { "\195\167", "s" }, { "gn", "n" }, { "qu", "k" }, { "rr", "r" },                          -- consonants
    },

    -- Output guard (consumed by MC_Babble): real French vulgarities that
    -- generated babble must never land on. Whole-word, all lowercase.
    -- See MC_Palette_Turkish for schema docs.
    babbleBlocklist = {
        "pute", "merde", "con", "salope",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)
    -- Consumed by MC_Lang dictionary bleed + MC_Acquisition exposure.
    -- See MC_Babble.lua palette schema docs for field shapes.

    -- concept-keyed lex schema: concept-keyed (CONCEPT_ID -> { l2 = "form" }).
    -- The render path resolves English tokens through MC_Concepts/MC_Resolve;
    -- entries here are claims of the form "this palette's L2 lexicalization
    -- of the universal concept CONCEPT_ID is the given form."
    --
    -- The forms are sourced from data/forms.tsv (the french column) via
    -- devtools/generate_palette_forms.py -- the same data-source pattern as
    -- MC_Concepts. Edit the TSV, then regenerate + escape (see the
    -- MC_PaletteFormsData.lua header). Coverage today is Tier 1 (213 concepts);
    -- Tier 2 forms are pending lexicalisation.
    --
    -- Translation choices: standard modern French. Verbs use infinitive
    -- forms; adjectives use masculine singular base; nouns use singular
    -- base form. Where the universal concept has no clean French single-
    -- word equivalent (e.g. THIRSTY -- French uses periphrasis "avoir
    -- soif"), the closest natural adjective is used (assoiffé) rather
    -- than leaving it English-out.
    --
    -- Disambiguation choices worth knowing:
    --   STAND = lever, LIFT = soulever  -- the bare "lever" carries the
    --                                      rise/stand sense; "soulever"
    --                                      is the dedicated raise/lift
    --   SMELL = sentir, FEEL = ressentir -- French sentir doubles as
    --                                      both senses; ressentir
    --                                      reserves emotion
    --   FRONT = devant, BEFORE = avant  -- French avant is spatial+
    --                                      temporal; devant is spatial-
    --                                      only, leaving avant for time
    --   DARK = obscurité, BLACK = noir  -- absence-of-light vs colour
    --   SIBLING = frère                 -- French has no neutral term;
    --                                      masculine default
    lex = require("MC_PaletteFormsData").french,

    -- Zipf frequency order: rank-1 = most common in the language at large.
    -- MC_Acquisition reverse-looks-up to give common words a head start
    -- (rank-1..10 acquired from first exposure; rare words need repetition).
    -- Forms here are the L2 (French) lowercased.
    --
    -- Entries are a subset of lex L2 forms. Forms outside the lex have
    -- no rank-lookup effect (production resolves through the concept
    -- tree, so orphan zipf entries never see queries). The order is
    -- corpus-grounded (wordfreq) and survival-first -- see the GENERATED
    -- header below; regenerate via devtools rather than hand-editing.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "non", "oui", "aide", "bonjour", "arr\195\170ter", "attendre", "d\195\169sol\195\169", "s'il vous pla\195\174t", "courir", "mort",
        -- Rank 11-20
        "eau", "feu", "ami", "sang", "danger", "arme", "nourriture", "ennemi", "cacher", "t\195\170te",
        -- Rank 21-30
        "autre", "premier", "main", "oeil", "fatigu\195\169", "mordre", "affam\195\169", "un", "tout", "deux",
        -- Rank 31-40
        "peu", "beaucoup", "trois", "besoin", "quatre", "cinq", "six", "dix", "sept", "huit",
        -- Rank 41-50
        "neuf", "est", "aller", "bas", "haut", "regarder", "utiliser", "truc", "long", "foyer",
        -- Rank 51-60
        "nord", "sud", "jeu", "venir", "ouest", "ressentir", "garder", "montrer", "pas", "quelquun",
        -- Rank 61-70
        "dans", "je", "qui", "tu", "commencer", "aujourdhui", "nimporte", "diff\195\169rent", "nous", "ils",
        -- Rank 71-80
        "raconter", "faire", "m\195\170me", "\195\169t\195\169", "quand", "apr\195\168s", "o\195\185", "encore", "essayer", "c\195\180t\195\169",
        -- Rank 81-90
        "m\195\169tier", "alors", "rien", "dire", "voir", "bon", "histoire", "peutetre", "avant", "important",
        -- Rank 91-100
        "jeune", "t\195\180t", "espoir", "quoi", "grand", "jour", "gagner", "faux", "comment", "personne",
        -- Rank 101-110
        "cela", "homme", "petit", "bouger", "ville", "pourquoi", "tard", "mois", "nouveau", "rester",
        -- Rank 111-120
        "prendre", "merci", "bient\195\180t", "nom", "femme", "maison", "maintenant", "plan", "facile", "famille",
        -- Rank 121-130
        "parler", "savoir", "soir", "pr\195\170t", "devant", "apporter", "porte", "chanson", "m\195\168re", "p\195\168re",
        -- Rank 131-140
        "trouver", "fille", "semaine", "donner", "fils", "prix", "reposer", "loin", "heure", "nuit",
        -- Rank 141-150
        "fort", "partager", "arriver", "an", "corps", "terre", "milieu", "matin", "saison", "apprendre",
        -- Rank 151-160
        "amour", "\195\169glise", "seul", "pierre", "enfant", "livre", "confiance", "gauche", "peur", "plein",
        -- Rank 161-170
        "jouer", "lire", "vivre", "hier", "droite", "voiture", "envoyer", "sortir", "fr\195\168re", "route",
        -- Rank 171-180
        "derri\195\168re", "bois", "pauvre", "simple", "demander", "demain", "comprendre", "blanc", "noir", "rouge",
        -- Rank 181-190
        "s\195\187r", "langue", "vieux", "mer", "joue", "penser", "chercher", "sein", "pied", "mauvais",
        -- Rank 191-200
        "soleil", "travailler", "bras", "manger", "perdre", "r\195\169pondre", "suivre", "proche", "stocker", "sol",
        -- Rank 201-210
        "moiti\195\169", "coeur", "midi", "pi\195\168ce", "radio", "porter", "entendre", "porter", "propre", "paix",
        -- Rank 211-220
        "dur", "dehors", "dos", "lettre", "s\197\147ur", "chef", "lumi\195\168re", "ceci", "tomber", "tenir",
        -- Rank 221-230
        "ciel", "vouloir", "visage", "r\195\170ver", "chance", "riche", "finir", "\195\169crire", "calme", "chien",
        -- Rank 231-240
        "cheveux", "ouvrir", "hiver", "oublier", "cha\195\174ne", "froid", "attraper", "rapide", "malade", "fil",
        -- Rank 241-250
        "b\195\169b\195\169", "c\195\180te", "peau", "sac", "compter", "mari", "sac", "surprise", "vent", "chaud",
        -- Rank 251-260
        "rencontrer", "bouche", "front", "papier", "entrer", "tuer", "pont", "chat", "caf\195\169", "tirer",
        -- Rank 261-270
        "tirer", "lance", "bleu", "bleu", "camp", "cadeau", "d\195\169cider", "mourir", "jardin", "champ",
        -- Rank 271-280
        "carte", "verre", "vide", "vert", "mur", "rose", "ferme", "coin", "vivant", "bo\195\174te",
        -- Rank 281-290
        "bord", "cheval", "construire", "moteur", "souvenir", "cerveau", "b\195\162timent", "sentir", "alcool", "lac",
        -- Rank 291-300
        "joie", "promettre", "nez", "col\195\168re", "cent", "dormir", "jaune", "pain", "v\195\170tements", "\195\169chelle",
        -- Rank 301-310
        "glace", "boire", "cl\195\169", "montagne", "animal", "enseigner", "trou", "faible", "bateau", "lait",
        -- Rank 311-320
        "lune", "cuisine", "tranquille", "douleur", "printemps", "\195\169trange", "v\195\169hicule", "balle", "for\195\170t", "orange",
        -- Rank 321-330
        "honte", "huile", "rivi\195\168re", "toucher", "haine", "\195\169pouse", "arbre", "prudent", "v\195\169lo", "conduire",
        -- Rank 331-340
        "invit\195\169", "pluie", "neige", "marcher", "doux", "sale", "bruit", "lever", "fermer", "couper",
        -- Rank 341-350
        "doigt", "fen\195\170tre", "viande", "poisson", "jeter", "automne", "os", "l\195\169ger", "bruyant", "lourd",
        -- Rank 351-360
        "sec", "pousser", "outil", "ventre", "bouteille", "voler", "feuille", "cou", "combattre", "plante",
        -- Rank 361-370
        "arc", "oreille", "toit", "fruit", "sel", "sable", "\195\169toile", "cousin", "casser", "chapeau",
        -- Rank 371-380
        "oncle", "loup", "fleur", "gris", "m\195\169tal", "th\195\169", "gorge", "couteau", "oiseau", "frapper",
        -- Rank 381-390
        "jus", "sauter", "plastique", "fromage", "blessure", "masque", "blessure", "ceinture", "couvrir", "minuit",
        -- Rank 391-400
        "camion", "tissu", "riz", "baie", "poitrine", "poulet", "chair", "\195\169paule", "crier", "escalier",
        -- Rank 401-410
        "roue", "fum\195\169e", "\195\169p\195\169e", "bol", "jambe", "r\195\169veiller", "herbe", "cuir", "soupe", "confusion",
        -- Rank 411-420
        "r\195\169parer", "laver", "tante", "miel", "pi\195\168ge", "vache", "fi\195\168vre", "portail", "chemise", "adieu",
        -- Rank 421-430
        "brun", "tristesse", "pouce", "\195\169tranger", "pantalon", "manteau", "poussi\195\168re", "papi", "cl\195\180ture", "corde",
        -- Rank 431-440
        "mauvaise herbe", "br\195\187ler", "fusil", "go\195\187ter", "r\195\169colte", "asseoir", "solitude", "m\195\169dicament", "racine", "\195\169changer",
        -- Rank 441-450
        "inqui\195\169tude", "carburant", "neveu", "assiette", "dent", "panier", "sain", "infection", "boisson", "respirer",
        -- Rank 451-460
        "grandir", "genou", "lampe", "filet", "rassembler", "serpent", "nuage", "grain", "chasser", "estomac",
        -- Rank 461-470
        "noix", "fl\195\168che", "lent", "mamie", "attacher", "grotte", "gu\195\169rir", "creuser", "mouton", "horloge",
        -- Rank 471-480
        "tasse", "cochon", "violet", "chaussure", "cuire", "boue", "aiguille", "sentier", "rat", "coude",
        -- Rank 481-490
        "couverture", "cheville", "soulever", "bouclier", "marteau", "menton", "obscurit\195\169", "oeuf", "mat\195\169riau", "ni\195\168ce",
        -- Rank 491-500
        "poison", "chagrin", "soulagement", "caoutchouc", "poignet", "cerf", "grimper", "talon", "r\195\169colter", "crochet",
        -- Rank 501-510
        "fourchette", "nager", "cuill\195\168re", "hache", "graine", "pelle", "buisson", "insecte", "m\195\162choire", "poumon",
        -- Rank 511-520
        "clou", "allonger", "mouill\195\169", "bougie", "po\195\170le", "scie", "semer", "botte", "d\195\169go\195\187t", "l\195\168vre",
        -- Rank 521-530
        "serrure", "champignon", "gant", "torche", "seau", "tranchant", "paume", "tonneau", "saigner", "cicatrice",
        -- Rank 531-540
        "l\195\169gume", "voisin", "ongle", "nombril", "orteil", "r\195\169cipient", "chaussette", "bocal", "marmite", "cendre",
        -- Rank 541-545
        "canette", "massue", "bandage", "assoiff\195\169", "\195\169mouss\195\169",
    },

    -- lexicalSets are declared centrally in MC_Concepts.lua as
    -- concept-keyed semantic neighborhoods. Palettes no longer declare
    -- their own. The cross-language Connection set-neighbor bonus reads
    -- MC_Concepts.lexicalSets and counts acquired concepts across all
    -- the user's languages.

    -- CULTURAL BLOCK (v8.6)
    -- 
    -- Idioms, customs, and culturally-loaded phrases that natives use AND
    -- that no amount of lexical exposure lets a non-native acquire. The
    -- gated tier in the fluency model.
    -- 
    -- For native listeners: the speaker's English literal gets substituted
    -- with the L2 cultural phrase (clean render -- natives don't need help).
    -- For non-native listeners: the L1 literal is preserved but marked as
    -- inherited (INHERITED_GREY at alpha 0.65) -- they see the meaning, miss
    -- the register, can RP awareness of the cultural gap.
    -- 
    -- Schema (extensible):
    --   en           required -- the English form to detect in speaker input
    --   l2           required -- the L2 cultural phrase to substitute for natives
    --   tags         optional -- register/region/era markers (declared, not yet
    --                consumed; reserved for context-aware filtering in v8.7+)
    -- 
    -- Fields reserved by the schema:
    --   variants     alternate L2 forms (regional/dialect)
    --   en_pattern   parameterised English templates with slot binding
    --   l2_pattern   parameterised L2 templates with slot binding
    --   teachable    if true, cultural phrase becomes acquisition-trackable
    --   notes        author commentary / etymology for palette readers
    -- 
    -- Authoring rule: keep phrases specific enough that they don't false-
    -- trigger on common substrings. "going to" as a phrase substitutes on
    -- every "I'm going to..." -- bad. Five-plus words is a safer floor.
    cultural = {
        { en = "It's all going to work out perfectly",
          l2 = "\195\135a va aller comme sur des roulettes",
          tags = {} },
        { en = "Don't put all your eggs in one basket",
          l2 = "Il ne faut pas mettre tous ses \197\147ufs dans le m\195\170me panier",
          tags = {} },
        { en = "It's not the end of the world",
          l2 = "Ce n'est pas la fin du monde",
          tags = {} },
        { en = "I've had it up to here",
          l2 = "J'en ai ras-le-bol",
          tags = { "informal" } },
        { en = "Let's call it a day",
          l2 = "On va appeler \195\167a une journ\195\169e",
          tags = {} },
        { en = "That's the last straw",
          l2 = "C'est la goutte d'eau qui fait d\195\169border le vase",
          tags = {} },
    },
}

-- Self-register with the language system. Adding/removing this line is the
-- only integration touchpoint -- MC_Lang doesn't need to know we exist.
require("MC_LangRegistry").register("french", french)

return french
