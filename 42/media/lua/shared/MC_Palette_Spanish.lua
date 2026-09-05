-- MC_Babble palette: Spanish
-- Romance family. Phonological signature: gendered vowel endings (-o/-a/-os/-as),
-- the eñe and the double-ell, the rolled rr, and the Latinate suffix tail
-- (-cion/-dad/-mente/-on) plus verb infinitives (-ar/-er/-ir). Sits inside the
-- same family = "romance" as French, so the cross-language Connection bonus
-- rewards a French speaker learning Spanish (and vice versa).
--
-- Identity: standard modern (neutral) Spanish. Other Romance languages
-- (Italian, Portuguese, Romanian) would each be a separate palette within
-- family = "romance", auto-receiving the family bonus. Orthography is proper
-- Spanish with the enye and stress accents (a-acute .. u-acute); the multibyte
-- letters are byte-escaped (\NNN) here exactly as in the French/Turkish
-- palettes, so the file stays Kahlua-safe.

local spanish = {
    name   = "Spanish",
    family = "romance",

    -- Tuning dials -- see MC_Babble.lua header for the full schema.
    -- Notes on Spanish-specific choices vs the French defaults:
    --   - endingPoolChance is low (0.22): most Spanish words end in a plain
    --     gendered vowel (-o/-a/-e) or -s/-n/-r, so the distinctive Latinate
    --     suffix pool (-cion/-dad/-mente/-dor) is the minority ending, not the norm.
    --   - featuredSignatureCount is 1 and the boost is a gentle 2: the tells
    --     (rr/ll/enye, accents, suffixes) read best sprinkled, not stacked.
    --   - elisionPrefixChance is 0 -- Spanish does not apostrophe-elide.
    tuning = {
        lettersPerSyllable     = 3,
        onsetChance            = 0.7,
        midCodaChance          = 0.3,
        endingPoolChance       = 0.22,
        functionWordChance     = 0.4,
        elisionPrefixChance    = 0,     -- Spanish-specific: no elisions
        signatureBoostWeight   = 2,
        featuredSignatureCount = 1,
    },

    onsets = {
        "b", "c", "d", "f", "g", "h", "j", "l", "m", "n", "p", "r", "s", "t", "v", "z",
        "ch", "ll", "\195\177", "rr", "y",               -- ch, ll, enye, rolled rr, y ("qu" is orthographic-
                                                         --   only, valid solely before e/i, so it lives as the
                                                         --   "que" function word rather than a free onset)
        "pr", "tr", "br", "cr", "gr", "pl",              -- a few obstruent+liquid clusters, kept sparse
    },                                                   --   so they don't stack into non-Spanish knots

    nuclei = {
        -- Pure vowels form the core and dominate Spanish word finals; a/e/o
        -- weighted 4x, i/u 3x, so diphthongs stay ~16% and don't pile up.
        "a", "a", "a", "a", "e", "e", "e", "e", "i", "i", "i",
        "o", "o", "o", "o", "u", "u", "u",
        -- Common diphthongs (tiene, puede, bueno, hacia).
        "ie", "ue", "ia", "io",
        -- Stress accents -- a sparse visual tell (a-acute, o-acute).
        "\195\161", "\195\179",
    },

    codas = {
        -- Open syllables dominate (empty weighted 3x) so most words end in a
        -- gendered vowel; the real Spanish codas are the sibilant plural -s and
        -- -n / -r (a nucleus + -r also gives the -ar/-er/-ir infinitive tail).
        "", "", "", "s", "n", "r",
    },

    functionWords = {
        -- Articles, prepositions, conjunctions, clitics.
        "el", "la", "los", "las", "un", "una", "de", "del", "al",
        "y", "que", "en", "con", "por", "para", "es", "se", "lo", "su",
    },

    -- Hesitation fillers (see MC_Palette_Turkish for schema docs).
    fillers = {
        "este",          -- "um / uh" -- the universal Spanish filler
        "pues",          -- "well / so"
        "bueno",         -- "well / okay" -- trailing-off marker
    },

    -- Signature set: distinctive Spanish elements the per-utterance featuring
    -- system promotes. The coda-category signatures also feed the final-syllable
    -- ending pool, so -cion / -dad / -ar etc. attach cleanly to a preceding
    -- nucleus (na + cion -> "nacion", cali + dad -> "calidad").
    signatureSet = {
        -- Latinate suffix tail. Elements are consonant-initial so they attach
        -- cleanly onto a preceding nucleus (na + cion -> "nacion", e + dad ->
        -- "edad", a + dor -> "ador"). The -ar/-er/-ir infinitive endings are
        -- deliberately NOT listed here -- a vowel plus the plain -r coda already
        -- produces them, and vowel-initial suffixes (-on/-aje) would double the
        -- nucleus ("a"+"on" -> "aon").
        latinateSuffixes = { category = "coda",  elements = {"ci\195\179n", "dad", "mente", "dor"} },
        palatals         = { category = "onset", elements = {"\195\177", "ll", "ch"} },  -- enye, ll, ch
        trill            = { category = "onset", elements = {"rr"} },                    -- rolled rr
    },

    -- Mishearing rules (babble-resolve). How Spanish's distinctive features
    -- flatten in a generic non-native ear; consumed by MC_Babble.resolveWord.
    -- Ordered {from, to}; whole-cluster/multibyte rules run before single-letter
    -- ones. DRAFT -- for review. See docs/BABBLE_RESOLVE.md.
    mishearing = {
        { "\195\177", "n" },                              -- enye -> n
        { "ll", "y" }, { "rr", "r" },                     -- ll -> y, trill -> tap
        { "\195\161", "a" }, { "\195\169", "e" },         -- strip stress accents
        { "\195\173", "i" }, { "\195\179", "o" }, { "\195\186", "u" },
        { "v", "b" }, { "z", "s" },                       -- b/v merge, seseo
    },

    -- Output guard (consumed by MC_Babble): real Spanish vulgarities generated
    -- babble must never land on. Whole-word, lowercase, multibyte byte-escaped.
    -- See MC_Palette_Turkish for schema docs.
    babbleBlocklist = {
        "puta", "mierda", "co\195\177o", "joder", "culo", "teta", "polla",
        "verga", "carajo", "cabr\195\179n", "concha", "pija", "chingar",
    },

    -- INTEGRATION-LAYER DATA (optional, ignored by MC_Babble engine)
    -- Consumed by MC_Lang dictionary bleed + MC_Acquisition exposure.

    -- concept-keyed lex (CONCEPT_ID -> { l2 = "form" }), sourced from
    -- data/forms.tsv (the spanish column) via devtools/generate_palette_forms.py.
    -- Standard modern Spanish: verbs in the infinitive (-ar/-er/-ir); nouns in
    -- the singular base; adjectives in the masculine singular. These forms are
    -- DRAFTS pending native-speaker review (flagged in the TSV note column).
    lex = require("MC_PaletteFormsData").spanish,

    -- Zipf frequency order (rank-1 = most common). Generated by
    -- devtools/generate_rankings.py; Spanish never shipped, so it has no frozen
    -- 8.16.1 baseline and all forms flow through the English-frequency percentile
    -- (baseline-less) path. Regenerate after editing forms.tsv; do NOT hand-edit.
    zipf = {
        -- GENERATED by devtools/generate_rankings.py -- do NOT hand-edit.
        -- Order: frozen 8.16.1 baseline + frequency-anchored insertions
        -- (see generator docstring). Regenerate after editing forms.tsv.
        -- Rank 1-10
        "dentro", "yo", "ese", "t\195\186", "este", "no", "nosotros", "todo", "ellos", "uno",
        -- Rank 11-20
        "lata", "arriba", "fuera", "qu\195\169", "cu\195\161ndo", "no", "qui\195\169n", "nuevo", "c\195\179mo", "ahora",
        -- Rank 21-30
        "otro", "bueno", "despu\195\169s", "primero", "saber", "ver", "dos", "hacer", "pensar", "entonces",
        -- Rank 31-40
        "espalda", "querer", "ir", "sano", "d\195\179nde", "necesitar", "derecha", "trabajar", "a\195\177o", "d\195\173a",
        -- Rank 41-50
        "antes", "tomar", "mucho", "decir", "abajo", "amor", "hombre", "hogar", "largo", "mirar",
        -- Rank 51-60
        "algo", "usar", "mismo", "venir", "tres", "encontrar", "ayudar", "viejo", "juego", "dar",
        -- Rank 61-70
        "casa", "nuevamente", "mostrar", "grande", "sentir", "guardar", "familia", "alguien", "izquierdo", "nombre",
        -- Rank 71-80
        "noche", "jugar", "poco", "diferente", "cima", "empezar", "semana", "cualquiera", "persona", "hoy",
        -- Rank 81-90
        "todo", "lleno", "vivir", "leer", "malo", "cuatro", "duro", "contar", "parar", "agua",
        -- Rank 91-100
        "cabeza", "peque\195\177o", "blanco", "lejos", "trabajo", "lado", "intentar", "s\195\173", "correr", "abrir",
        -- Rank 101-110
        "estaci\195\179n", "gracias", "negro", "auto", "cara", "cinco", "quiz\195\161s", "historia", "esperanza", "importante",
        -- Rank 111-120
        "libro", "temprano", "joven", "mitad", "mano", "cuerpo", "comida", "sur", "habitaci\195\179n", "ganar",
        -- Rank 121-130
        "incorrecto", "recordar", "amigo", "golpear", "entender", "cerrar", "mover", "esperar", "mujer", "preguntar",
        -- Rank 131-140
        "tarde", "norte", "sierra", "luz", "ligero", "ma\195\177ana", "quedarse", "rojo", "pronto", "coraz\195\179n",
        -- Rank 141-150
        "ni\195\177o", "fuego", "detr\195\161s", "edificio", "f\195\161cil", "cerca", "plan", "seis", "oeste", "frente",
        -- Rank 151-160
        "listo", "hijo", "traer", "encontrar", "beb\195\169", "padre", "canci\195\179n", "mes", "cortar", "campo",
        -- Rank 161-170
        "madre", "camino", "pueblo", "pelear", "o\195\173r", "precio", "descansar", "verano", "esposa", "fuerte",
        -- Rank 171-180
        "garrote", "compartir", "muerto", "ocurrir", "sostener", "estrella", "romper", "hora", "centro", "perd\195\179n",
        -- Rank 181-190
        "responder", "aprender", "solo", "iglesia", "este", "caliente", "seguir", "levantarse", "azul", "conducir",
        -- Rank 191-200
        "comer", "caer", "r\195\161pido", "verde", "confiar", "llave", "intercambiar", "hermano", "taza", "odiar",
        -- Rank 201-210
        "enviar", "sangre", "perro", "aceite", "matar", "pobre", "cubrir", "puerta", "pelo", "perder",
        -- Rank 211-220
        "siete", "sencillo", "caminar", "hija", "morir", "papel", "seguro", "tierra", "olvidar", "mar",
        -- Rank 221-230
        "dormir", "diez", "caja", "construir", "oscuro", "pared", "dolor", "r\195\173o", "hablar", "escribir",
        -- Rank 231-240
        "fr\195\173o", "ocho", "ojo", "paz", "almacenar", "ma\195\177ana", "marr\195\179n", "radio", "esposo", "hielo",
        -- Rank 241-250
        "limpio", "sol", "pistola", "pesado", "buscar", "miedo", "l\195\173der", "carta", "material", "nadie",
        -- Rank 251-260
        "hermana", "cerebro", "suelo", "nada", "primavera", "vestir", "so\195\177ar", "terminar", "suerte", "rico",
        -- Rank 261-270
        "piel", "tocar", "ayer", "beber", "pez", "crecer", "sentar", "llevar", "planta", "invierno",
        -- Rank 271-280
        "enfermo", "atrapar", "pie", "nueve", "caf\195\169", "tarde", "vidrio", "lento", "\195\161rbol", "fondo",
        -- Rank 281-290
        "motor", "acostarse", "tristeza", "viento", "preocupaci\195\179n", "contar", "lago", "boca", "lanzar", "metal",
        -- Rank 291-300
        "tirar", "empujar", "animal", "entrar", "piedra", "ventana", "bolsa", "campamento", "gato", "decidir",
        -- Rank 301-310
        "regalo", "madera", "puente", "jard\195\173n", "vivo", "caballo", "mapa", "red", "veh\195\173culo", "despertar",
        -- Rank 311-320
        "esquina", "granja", "arreglar", "volar", "sorpresa", "seco", "borde", "lesi\195\179n", "brazo", "medicina",
        -- Rank 321-330
        "monta\195\177a", "disparar", "probar", "t\195\169", "combustible", "hola", "cielo", "barco", "cien", "sendero",
        -- Rank 331-340
        "prometer", "lluvia", "cansado", "enemigo", "bosque", "luna", "saltar", "amarillo", "blando", "humo",
        -- Rank 341-350
        "ense\195\177ar", "agujero", "pierna", "leche", "nieve", "d\195\169bil", "cadena", "cocinar", "cocina", "silencioso",
        -- Rank 351-360
        "extra\195\177o", "cami\195\179n", "p\195\161jaro", "cuenco", "gallina", "carne", "cuello", "camisa", "naranja", "alcohol",
        -- Rank 361-370
        "sal", "cuidadoso", "peligro", "vac\195\173o", "invitado", "botella", "queso", "fruta", "herramienta", "sucio",
        -- Rank 371-380
        "alegr\195\173a", "ruido", "plato", "alivio", "arroz", "techo", "verg\195\188enza", "tranquilo", "esconder", "arma",
        -- Rank 381-390
        "mojado", "quemar", "sombrero", "ruidoso", "pecho", "rosa", "cerradura", "nariz", "pl\195\161stico", "atar",
        -- Rank 391-400
        "pan", "levantar", "hombro", "rueda", "arbusto", "cazar", "oler", "dedo", "gris", "afilado",
        -- Rank 401-410
        "hueso", "ropa", "port\195\179n", "nube", "huevo", "lavar", "hambriento", "t\195\173o", "arena", "hilo",
        -- Rank 411-420
        "reloj", "oreja", "enojo", "cintur\195\179n", "flor", "est\195\179mago", "primo", "polvo", "cuchillo", "ra\195\173z",
        -- Rank 421-430
        "robar", "olla", "sart\195\169n", "hierba", "miel", "gancho", "semilla", "espada", "lengua", "abrigo",
        -- Rank 431-440
        "jugo", "seno", "salir", "cuero", "lobo", "infecci\195\179n", "rodilla", "trampa", "morado", "morder",
        -- Rank 441-450
        "m\195\161scara", "medianoche", "arco", "adi\195\179s", "escudo", "garganta", "desconocido", "maleza", "oto\195\177o", "respirar",
        -- Rank 451-460
        "bala", "recoger", "abuelo", "zapato", "herida", "palma", "goma", "serpiente", "trepar", "cavar",
        -- Rank 461-470
        "fiebre", "hoja", "valla", "u\195\177a", "clavo", "nadar", "cueva", "carne", "bota", "confusi\195\179n",
        -- Rank 471-480
        "oveja", "grano", "barril", "rata", "ceniza", "t\195\173a", "martillo", "cultivo", "sopa", "vaca",
        -- Rank 481-490
        "abuela", "cerdo", "escalera", "flecha", "labio", "barro", "ciervo", "curar", "mediod\195\173a", "barriga",
        -- Rank 491-500
        "pulm\195\179n", "duelo", "veneno", "diente", "cesta", "manta", "cubo", "dedo", "cuerda", "gritar",
        -- Rank 501-510
        "l\195\161mpara", "nuez", "tela", "recipiente", "tenedor", "cosechar", "escalera", "sobrino", "pulgar", "mu\195\177eca",
        -- Rank 511-520
        "barbilla", "bicicleta", "mand\195\173bula", "aguja", "tobillo", "baya", "mejilla", "desafilado", "verdura", "frasco",
        -- Rank 521-530
        "saco", "vela", "cuchara", "frente", "codo", "tal\195\179n", "sobrina", "hacha", "cicatriz", "insecto",
        -- Rank 531-540
        "sediento", "antorcha", "guante", "sangrar", "lanza", "pantal\195\179n", "bebida", "vecino", "soledad", "hongo",
        -- Rank 541-549
        "asco", "hermano", "calcet\195\173n", "costilla", "pala", "sembrar", "venda", "moret\195\179n", "ombligo",
    },

    -- lexicalSets are declared centrally in MC_Concepts.lua.

    -- CULTURAL BLOCK -- see MC_Palette_French for full schema docs.
    -- Set phrases a native uses by convention and that no lexical exposure
    -- teaches. Multibyte byte-escaped; multi-word l2 phrases are fine (the
    -- cultural pass substitutes whole phrases, not single tokens).
    cultural = {
        { en = "My house is your house",              l2 = "Mi casa es tu casa",              tags = {"welcome"} },
        { en = "It is nothing, do not worry about it",l2 = "No pasa nada",                    tags = {} },
        { en = "Little by little, one step at a time", l2 = "Poco a poco",                    tags = {} },
        { en = "Better late than never",              l2 = "M\195\161s vale tarde que nunca", tags = {} },
        { en = "God willing, I hope so",              l2 = "Ojal\195\161",                    tags = {"modal"} },
        { en = "Enjoy your meal",                     l2 = "Buen provecho",                   tags = {"meal"} },
    },
}

-- Self-register with the language system. Adding/removing this line is the
-- only integration touchpoint -- MC_Lang doesn't need to know we exist.
require("MC_LangRegistry").register("spanish", spanish)

return spanish
