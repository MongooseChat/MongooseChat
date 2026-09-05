-- MC_ConceptsData -- GENERATED from data/concepts.tsv
--
-- DO NOT EDIT BY HAND. Run `python3 devtools/generate_concepts.py` to
-- regenerate from the source-of-truth TSV.
--
-- The TSV lives in data/concepts.tsv and is versioned alongside this file.

local M = {}

M.concepts = {
    AFTER = { tier = 1, en = {"after"}, parents = {} },
    AGAIN = { tier = 1, en = {"again"}, parents = {} },
    ALCOHOL = { tier = 2, en = {"alcohol"}, parents = {"BEVERAGE"} },  -- booze; PZ + social
    ALIVE = { tier = 1, en = {"alive", "living"}, parents = {} },
    ALL = { tier = 1, en = {"all"}, parents = {} },
    ALONE = { tier = 3, en = {"alone"}, parents = {} },
    ANGER = { tier = 1, en = {"anger", "angry", "mad"}, parents = {} },
    ANIMAL = { tier = 2, en = {"animal"}, parents = {} },  -- non-human creature; Tier 1 has none
    ANKLE = { tier = 2, en = {"ankle"}, parents = {"FOOT"} },
    ANSWER = { tier = 1, en = {"answer", "reply"}, parents = {"SAY"} },
    ANYTHING = { tier = 3, en = {"anything"}, parents = {} },  -- tr herhangi loanword (Persian origin) harmony-exempt, approximation flagged for native review; sl lyuboe=any/whatever
    ARM = { tier = 1, en = {"arm"}, parents = {"BODY"} },
    ARROW = { tier = 2, en = {"arrow"}, parents = {"WEAPON"} },
    ASH = { tier = 2, en = {"ash"}, parents = {"MATERIAL", "FIRE"} },
    ASK = { tier = 1, en = {"ask"}, parents = {"SAY"} },
    AUNT = { tier = 2, en = {"aunt"}, parents = {"KIN"} },
    AUTUMN = { tier = 2, en = {"autumn"}, parents = {"SEASON"} },
    AXE = { tier = 2, en = {"axe"}, parents = {"TOOL"} },  -- dual-use weapon
    BABY = { tier = 1, en = {"baby", "infant"}, parents = {"CHILD"} },
    BACK = { tier = 1, en = {"back"}, parents = {"BODY"} },
    BAD = { tier = 1, en = {"bad"}, parents = {} },
    BAG = { tier = 2, en = {"bag"}, parents = {"CONTAINER"} },
    BANDAGE = { tier = 2, en = {"bandage"}, parents = {"TOOL"} },
    BARREL = { tier = 2, en = {"barrel"}, parents = {"CONTAINER"} },
    BASKET = { tier = 2, en = {"basket"}, parents = {"CONTAINER"} },
    BEFORE = { tier = 1, en = {"before"}, parents = {} },
    BEHIND = { tier = 1, en = {"behind", "back-of"}, parents = {} },
    BELLY = { tier = 1, en = {"belly", "stomach"}, parents = {"BODY"} },
    BELT = { tier = 2, en = {"belt"}, parents = {"CLOTHING"} },
    BERRY = { tier = 2, en = {"berry"}, parents = {"FRUIT"} },  -- forageable
    BEVERAGE = { tier = 1, en = {"beverage", "drink"}, parents = {} },  -- Anchor for Tier 2 drink specifics. Named BEVERAGE rather than DRINK to disambiguate from the verb DRINK in Bodily Actions
    BICYCLE = { tier = 2, en = {"bicycle"}, parents = {"VEHICLE"} },
    BIG = { tier = 1, en = {"big", "large"}, parents = {} },
    BIRD = { tier = 2, en = {"bird"}, parents = {"ANIMAL"} },  -- (the bird/fish/snake the doc assumed but Tier 1 lacks)
    BITE = { tier = 1, en = {"bite"}, parents = {} },
    BLACK = { tier = 1, en = {"black", "dark"}, parents = {} },
    BLANKET = { tier = 3, en = {"blanket"}, parents = {"TOOL"} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    BLEED = { tier = 2, en = {"bleed"}, parents = {"BLOOD"} },  -- verb
    BLOOD = { tier = 1, en = {"blood"}, parents = {"BODY"} },
    BLUE = { tier = 2, en = {"blue"}, parents = {} },  -- stage V
    BOAT = { tier = 2, en = {"boat"}, parents = {"VEHICLE"} },
    BODY = { tier = 1, en = {"body"}, parents = {} },  -- The whole, as opposed to parts
    BONE = { tier = 1, en = {"bone"}, parents = {"BODY"} },
    BOOK = { tier = 2, en = {"book"}, parents = {"TOOL"} },  -- record/knowledge object
    BOOT = { tier = 2, en = {"boot"}, parents = {"CLOTHING"} },
    BOTTLE = { tier = 2, en = {"bottle"}, parents = {"CONTAINER"} },
    BOTTOM = { tier = 3, en = {"bottom"}, parents = {} },
    BOW = { tier = 2, en = {"bow"}, parents = {"WEAPON"} },
    BOWL = { tier = 2, en = {"bowl"}, parents = {"CONTAINER"} },
    BOX = { tier = 2, en = {"box"}, parents = {"CONTAINER"} },
    BRAIN = { tier = 2, en = {"brain"}, parents = {"HEAD"} },  -- organ
    BREAD = { tier = 2, en = {"bread"}, parents = {"FOOD"} },  -- grain cultures — count/mass varies by language
    BREAK = { tier = 1, en = {"break"}, parents = {} },
    BREAST = { tier = 1, en = {"breast"}, parents = {"CHEST"} },
    BREATHE = { tier = 1, en = {"breathe"}, parents = {} },
    BRIDGE = { tier = 2, en = {"bridge"}, parents = {} },
    BRING = { tier = 3, en = {"bring"}, parents = {"TAKE"} },
    BROTHER = { tier = 3, en = {"brother"}, parents = {"SIBLING"} },  -- tr/fr/sl conflate with SIBLING forms - real lexical fact, FINGER=TOE pattern | tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    BROWN = { tier = 2, en = {"brown"}, parents = {} },
    BRUISE = { tier = 2, en = {"bruise"}, parents = {"WOUND"} },
    BUCKET = { tier = 2, en = {"bucket"}, parents = {"CONTAINER"} },
    BUILD = { tier = 2, en = {"build"}, parents = {"MAKE"} },
    BUILDING = { tier = 2, en = {"building"}, parents = {} },  -- made structure / its parts
    BULLET = { tier = 2, en = {"bullet"}, parents = {"WEAPON"} },  -- ammunition — count/mass varies by language
    BURN = { tier = 1, en = {"burn"}, parents = {"FIRE"} },  -- Operational: action involving fire
    BUSH = { tier = 2, en = {"bush"}, parents = {"PLANT"} },
    CALM = { tier = 2, en = {"calm"}, parents = {"PEACE"} },
    CAMP = { tier = 3, en = {"camp"}, parents = {} },
    CAN = { tier = 2, en = {"can"}, parents = {"CONTAINER"} },
    CANDLE = { tier = 3, en = {"candle"}, parents = {"TOOL"} },
    CAR = { tier = 2, en = {"car"}, parents = {"VEHICLE"} },  -- very PZ
    CAREFUL = { tier = 3, en = {"careful"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    CARRY = { tier = 1, en = {"carry"}, parents = {"HOLD"} },
    CAT = { tier = 2, en = {"cat"}, parents = {"ANIMAL"} },
    CATCH = { tier = 3, en = {"catch"}, parents = {"TAKE"} },
    CAVE = { tier = 2, en = {"cave"}, parents = {} },  -- shelter
    CHAIN = { tier = 2, en = {"chain"}, parents = {"TOOL"} },
    CHEEK = { tier = 2, en = {"cheek"}, parents = {"FACE"} },
    CHEESE = { tier = 2, en = {"cheese"}, parents = {"FOOD"} },
    CHEST = { tier = 1, en = {"chest"}, parents = {"BODY"} },
    CHICKEN = { tier = 2, en = {"chicken"}, parents = {"BIRD"} },
    CHILD = { tier = 1, en = {"child"}, parents = {"PERSON"} },  -- Young person
    CHIN = { tier = 2, en = {"chin"}, parents = {"FACE"} },
    CHURCH = { tier = 3, en = {"church"}, parents = {} },
    CLEAN_ADJ = { tier = 3, en = {"clean"}, parents = {} },
    CLIMB = { tier = 1, en = {"climb"}, parents = {} },
    CLOCK = { tier = 2, en = {"clock"}, parents = {"TOOL"} },  -- time-telling (pairs with extended time)
    CLOSE = { tier = 1, en = {"close", "shut"}, parents = {} },
    CLOTH = { tier = 2, en = {"cloth"}, parents = {"MATERIAL"} },  -- fabric
    CLOTHING = { tier = 2, en = {"clothing", "clothes"}, parents = {} },  -- worn item
    CLOUD = { tier = 1, en = {"cloud"}, parents = {"SKY"} },
    CLUB = { tier = 2, en = {"club"}, parents = {"WEAPON"} },  -- bat/blunt
    COAT = { tier = 2, en = {"coat"}, parents = {"CLOTHING"} },  -- warmth
    COFFEE = { tier = 2, en = {"coffee"}, parents = {"BEVERAGE"} },
    COLD = { tier = 1, en = {"cold"}, parents = {} },
    COME = { tier = 1, en = {"come"}, parents = {} },
    CONFUSION = { tier = 2, en = {"confusion"}, parents = {} },
    CONTAINER = { tier = 2, en = {"container"}, parents = {} },  -- vessel that holds
    COOK = { tier = 2, en = {"cook"}, parents = {"MAKE"} },
    CORNER = { tier = 3, en = {"corner"}, parents = {} },
    COUNT = { tier = 2, en = {"count"}, parents = {} },
    COUSIN = { tier = 2, en = {"cousin"}, parents = {"KIN"} },
    COVER = { tier = 2, en = {"cover"}, parents = {} },
    COW = { tier = 2, en = {"cow"}, parents = {"ANIMAL"} },  -- pastoralist
    CROP = { tier = 2, en = {"crop"}, parents = {"PLANT"} },  -- cultivated
    CUP = { tier = 2, en = {"cup"}, parents = {"CONTAINER"} },  -- drinking
    CUT = { tier = 1, en = {"cut"}, parents = {} },
    DANGER = { tier = 2, en = {"danger"}, parents = {} },  -- flagged Tier 2
    DARK = { tier = 1, en = {"dark", "darkness"}, parents = {} },  -- Absence of light
    DAUGHTER = { tier = 2, en = {"daughter"}, parents = {"KIN", "CHILD"} },
    DAY = { tier = 1, en = {"day"}, parents = {} },  -- Light-period
    DEAD = { tier = 1, en = {"dead"}, parents = {} },
    DECIDE = { tier = 3, en = {"decide"}, parents = {"THINK"} },  -- tr noun (karar vermek is 2 tokens)
    DEER = { tier = 2, en = {"deer"}, parents = {"ANIMAL"} },  -- game
    DIE = { tier = 1, en = {"die"}, parents = {} },
    DIFFERENT = { tier = 3, en = {"different"}, parents = {} },
    DIG = { tier = 1, en = {"dig"}, parents = {} },
    DIRTY = { tier = 3, en = {"dirty"}, parents = {} },
    DISGUST = { tier = 1, en = {"disgust", "disgusted"}, parents = {} },  -- Ekman universal
    DOG = { tier = 2, en = {"dog"}, parents = {"ANIMAL"} },  -- pet/stray
    DOOR = { tier = 2, en = {"door"}, parents = {"BUILDING"} },
    DOWN = { tier = 1, en = {"down"}, parents = {} },
    DREAM = { tier = 3, en = {"dream"}, parents = {"SLEEP"} },  -- tr noun | tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    DRINK = { tier = 1, en = {"drink"}, parents = {} },
    DRIVE = { tier = 2, en = {"drive"}, parents = {} },  -- pairs with CAR
    DRY = { tier = 1, en = {"dry"}, parents = {} },
    DULL = { tier = 1, en = {"dull", "blunt"}, parents = {} },
    DUST = { tier = 2, en = {"dust"}, parents = {"MATERIAL"} },
    EAR = { tier = 1, en = {"ear"}, parents = {"HEAD"} },
    EARLY = { tier = 3, en = {"early"}, parents = {} },
    EARTH = { tier = 1, en = {"earth", "ground", "soil"}, parents = {} },  -- The substance/surface
    EAST = { tier = 2, en = {"east"}, parents = {} },
    EASY = { tier = 3, en = {"easy"}, parents = {} },
    EAT = { tier = 1, en = {"eat"}, parents = {} },
    EDGE = { tier = 3, en = {"edge"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    EGG = { tier = 2, en = {"egg"}, parents = {"FOOD"} },
    EIGHT = { tier = 2, en = {"eight"}, parents = {} },
    ELBOW = { tier = 2, en = {"elbow"}, parents = {"ARM"} },
    EMPTY = { tier = 1, en = {"empty"}, parents = {} },
    ENEMY = { tier = 1, en = {"enemy"}, parents = {"PERSON"} },
    ENGINE = { tier = 2, en = {"engine"}, parents = {"VEHICLE"} },  -- part
    ENTER = { tier = 1, en = {"enter", "go in"}, parents = {"GO"} },
    EVENING = { tier = 2, en = {"evening"}, parents = {"DAY"} },
    EVERYTHING = { tier = 3, en = {"everything"}, parents = {} },  -- tr informal single-token spelling
    EXIT = { tier = 1, en = {"exit", "leave"}, parents = {"GO"} },
    EYE = { tier = 1, en = {"eye"}, parents = {"HEAD"} },
    FACE = { tier = 1, en = {"face"}, parents = {"HEAD"} },
    FALL = { tier = 1, en = {"fall"}, parents = {} },
    FAR = { tier = 1, en = {"far", "distant"}, parents = {} },
    FARM = { tier = 3, en = {"farm"}, parents = {} },
    FAST = { tier = 1, en = {"fast", "quick"}, parents = {} },
    FATHER = { tier = 1, en = {"father"}, parents = {"KIN"} },
    FEAR = { tier = 1, en = {"fear", "afraid"}, parents = {} },
    FEEL = { tier = 1, en = {"feel"}, parents = {} },  -- Emotional sense; splits with TOUCH (physical)
    FENCE = { tier = 2, en = {"fence"}, parents = {} },
    FEVER = { tier = 2, en = {"fever"}, parents = {"SICK"} },
    FEW = { tier = 1, en = {"few"}, parents = {} },
    FIELD = { tier = 2, en = {"field"}, parents = {} },  -- open cultivated/grass land
    FIGHT = { tier = 1, en = {"fight"}, parents = {"HIT"} },
    FIND = { tier = 2, en = {"find"}, parents = {} },
    FINGER = { tier = 1, en = {"finger"}, parents = {"HAND"} },  -- Splits with TOE in some languages
    FINISH = { tier = 3, en = {"finish", "end"}, parents = {} },
    FIRE = { tier = 1, en = {"fire"}, parents = {} },
    FIRST = { tier = 3, en = {"first"}, parents = {} },
    FISH = { tier = 2, en = {"fish"}, parents = {"ANIMAL", "FOOD"} },  -- creature; FISH-as-food resolves via FOOD too
    FIVE = { tier = 2, en = {"five"}, parents = {} },
    FIX = { tier = 2, en = {"fix"}, parents = {"MAKE"} },  -- repair
    FLESH = { tier = 1, en = {"flesh", "meat"}, parents = {"BODY"} },  -- Some langs distinguish body-flesh from food-meat
    FLOOR = { tier = 2, en = {"floor"}, parents = {"BUILDING"} },
    FLOWER = { tier = 2, en = {"flower"}, parents = {"PLANT"} },
    FLY = { tier = 1, en = {"fly"}, parents = {} },
    FOLLOW = { tier = 1, en = {"follow"}, parents = {"GO"} },
    FOOD = { tier = 1, en = {"food"}, parents = {} },  -- Anchor for Tier 2 food specifics
    FOOT = { tier = 1, en = {"foot"}, parents = {"LEG"} },
    FOREHEAD = { tier = 2, en = {"forehead"}, parents = {"FACE"} },
    FOREST = { tier = 2, en = {"forest"}, parents = {} },  -- collection of TREE
    FORGET = { tier = 1, en = {"forget"}, parents = {} },
    FORK = { tier = 2, en = {"fork"}, parents = {"TOOL"} },  -- eating implement
    FOUR = { tier = 2, en = {"four"}, parents = {} },
    FRIEND = { tier = 1, en = {"friend"}, parents = {"PERSON"} },
    FRONT = { tier = 1, en = {"front"}, parents = {} },
    FRUIT = { tier = 2, en = {"fruit"}, parents = {"FOOD", "PLANT"} },  -- category-ish
    FUEL = { tier = 2, en = {"fuel"}, parents = {"MATERIAL"} },  -- gasoline; PZ-critical
    FULL = { tier = 1, en = {"full"}, parents = {} },
    GAME = { tier = 3, en = {"game"}, parents = {} },
    GARDEN = { tier = 3, en = {"garden"}, parents = {"HOUSE"} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    GATE = { tier = 2, en = {"gate"}, parents = {"BUILDING"} },
    GATHER = { tier = 2, en = {"gather"}, parents = {"TAKE"} },  -- forage/collect
    GIFT = { tier = 3, en = {"gift", "present"}, parents = {"GIVE"} },
    GIVE = { tier = 1, en = {"give"}, parents = {} },
    GLASS = { tier = 2, en = {"glass"}, parents = {"MATERIAL"} },
    GLOVE = { tier = 2, en = {"glove"}, parents = {"CLOTHING"} },
    GO = { tier = 1, en = {"go"}, parents = {} },
    GOOD = { tier = 1, en = {"good"}, parents = {} },
    GOODBYE = { tier = 2, en = {"goodbye"}, parents = {} },
    GRAIN = { tier = 2, en = {"grain"}, parents = {"FOOD", "PLANT"} },  -- wheat/rice anchor
    GRANDFATHER = { tier = 2, en = {"grandfather"}, parents = {"KIN"} },
    GRANDMOTHER = { tier = 2, en = {"grandmother"}, parents = {"KIN"} },
    GRASS = { tier = 1, en = {"grass"}, parents = {} },
    GREEN = { tier = 2, en = {"green"}, parents = {} },  -- Berlin-Kay stage IV — not in Tier 1's 3
    GREY = { tier = 2, en = {"grey"}, parents = {} },
    GRIEF = { tier = 2, en = {"grief"}, parents = {"SADNESS"} },
    GROW = { tier = 2, en = {"grow"}, parents = {} },
    GUEST = { tier = 3, en = {"guest", "visitor"}, parents = {"PERSON"} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    GUN = { tier = 2, en = {"gun"}, parents = {"WEAPON"} },  -- very PZ
    HAIR = { tier = 1, en = {"hair"}, parents = {"HEAD"} },
    HALF = { tier = 1, en = {"half"}, parents = {} },
    HAMMER = { tier = 2, en = {"hammer"}, parents = {"TOOL"} },
    HAND = { tier = 1, en = {"hand"}, parents = {"ARM"} },
    HAPPEN = { tier = 3, en = {"happen", "occur"}, parents = {} },  -- fr arriver also=arrive; conflation flagged
    HARD = { tier = 1, en = {"hard"}, parents = {} },
    HARVEST = { tier = 2, en = {"harvest"}, parents = {"TAKE"} },
    HAT = { tier = 2, en = {"hat"}, parents = {"CLOTHING"} },
    HATE = { tier = 2, en = {"hate"}, parents = {} },
    HEAD = { tier = 1, en = {"head"}, parents = {"BODY"} },
    HEAL = { tier = 2, en = {"heal"}, parents = {"WELL"} },  -- verb
    HEAR = { tier = 1, en = {"hear"}, parents = {}, splits = {"LISTEN"} },  -- Splits with LISTEN (intentional)
    HEART = { tier = 1, en = {"heart"}, parents = {"BODY"} },  -- Physical organ; metaphor varies
    HEAVY = { tier = 1, en = {"heavy"}, parents = {} },
    HEEL = { tier = 2, en = {"heel"}, parents = {"FOOT"} },  -- flagged Tier 2 in CONCEPT_TREE
    HELLO = { tier = 2, en = {"hello"}, parents = {} },  -- flagged Tier 2 in MC_Concepts (social set)
    HELP = { tier = 2, en = {"help"}, parents = {} },  -- flagged Tier 2 (survival set)
    HIDE = { tier = 1, en = {"hide"}, parents = {} },
    HIT = { tier = 1, en = {"hit", "strike"}, parents = {} },
    HOLD = { tier = 1, en = {"hold"}, parents = {} },
    HOLE = { tier = 3, en = {"hole"}, parents = {} },
    HOME = { tier = 2, en = {"home"}, parents = {"BUILDING"} },  -- one's own dwelling (felt sense) — boundary w/ HOUSE
    HONEY = { tier = 2, en = {"honey"}, parents = {"FOOD"} },
    HOOK = { tier = 2, en = {"hook"}, parents = {"TOOL"} },
    HOPE = { tier = 2, en = {"hope"}, parents = {} },
    HORSE = { tier = 2, en = {"horse"}, parents = {"ANIMAL"} },
    HOT = { tier = 1, en = {"hot"}, parents = {} },
    HOUR = { tier = 2, en = {"hour"}, parents = {} },  -- unit
    HOUSE = { tier = 2, en = {"house"}, parents = {"BUILDING"} },  -- dwelling
    HOW = { tier = 1, en = {"how"}, parents = {} },
    HUNDRED = { tier = 2, en = {"hundred"}, parents = {} },  -- highest cardinal — number reach locked here (FOUR–TEN + HUNDRED)
    HUNGRY = { tier = 1, en = {"hungry"}, parents = {} },
    HUNT = { tier = 2, en = {"hunt"}, parents = {} },
    HUSBAND = { tier = 2, en = {"husband"}, parents = {"KIN"} },
    I = { tier = 1, en = {"I", "me"}, parents = {} },  -- First person singular
    ICE = { tier = 1, en = {"ice"}, parents = {} },
    IMPORTANT = { tier = 3, en = {"important"}, parents = {} },
    IN = { tier = 1, en = {"in", "inside"}, parents = {} },
    INFECTION = { tier = 2, en = {"infection"}, parents = {"SICK"} },  -- PZ-central
    INJURY = { tier = 2, en = {"injury"}, parents = {"WOUND"} },
    INSECT = { tier = 2, en = {"insect"}, parents = {"ANIMAL"} },  -- bug
    JAR = { tier = 2, en = {"jar"}, parents = {"CONTAINER"} },
    JAW = { tier = 2, en = {"jaw"}, parents = {"FACE"} },
    JOB = { tier = 3, en = {"job", "task"}, parents = {"WORK"} },  -- sl rabota noun vs rabotat verb - distinct tokens
    JOY = { tier = 1, en = {"joy", "happy"}, parents = {} },  -- Happy as emotion-state
    JUICE = { tier = 2, en = {"juice"}, parents = {"BEVERAGE"} },
    JUMP = { tier = 1, en = {"jump"}, parents = {} },
    KEEP = { tier = 3, en = {"keep"}, parents = {"TAKE"} },  -- tr tutmak conflates HOLD - real Turkish polysemy.
    KEY = { tier = 2, en = {"key"}, parents = {"TOOL"} },
    KILL = { tier = 1, en = {"kill"}, parents = {} },
    KIN = { tier = 1, en = {"family", "relative"}, parents = {"PERSON"} },  -- Generic family member
    KITCHEN = { tier = 3, en = {"kitchen"}, parents = {"HOUSE"} },
    KNEE = { tier = 1, en = {"knee"}, parents = {"LEG"} },
    KNIFE = { tier = 2, en = {"knife"}, parents = {"TOOL"} },  -- blade; dual-use weapon
    KNOW = { tier = 1, en = {"know"}, parents = {}, splits = {"KNOW_FACT", "KNOW_PERSON"} },  -- Splits saber/conocer (Sp), wissen/kennen (Ger)
    LADDER = { tier = 2, en = {"ladder"}, parents = {"TOOL"} },
    LAKE = { tier = 1, en = {"lake"}, parents = {"WATER"} },  -- Operational: fallback via WATER
    LAMP = { tier = 2, en = {"lamp"}, parents = {"TOOL"} },
    LATE = { tier = 3, en = {"late"}, parents = {} },
    LEADER = { tier = 3, en = {"leader", "boss"}, parents = {"PERSON"} },  -- fr chef also=cook in EN loan sense; acceptable
    LEAF = { tier = 1, en = {"leaf"}, parents = {"TREE"} },
    LEARN = { tier = 3, en = {"learn"}, parents = {"KNOW"} },
    LEATHER = { tier = 2, en = {"leather"}, parents = {"MATERIAL"} },
    LEFT = { tier = 2, en = {"left"}, parents = {} },  -- body-relative — Tier 1 lacks it
    LEG = { tier = 1, en = {"leg"}, parents = {"BODY"} },
    LETTER = { tier = 3, en = {"letter", "message"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    LIE_DOWN = { tier = 1, en = {"lie", "lie down"}, parents = {} },
    LIFT = { tier = 1, en = {"lift", "raise"}, parents = {} },
    LIGHT = { tier = 1, en = {"light"}, parents = {} },  -- Illumination -- NOT the quality 'light'
    LIGHT_WEIGHT = { tier = 1, en = {"light"}, parents = {} },  -- Distinct from LIGHT (illumination)
    LIP = { tier = 1, en = {"lip", "lips"}, parents = {"MOUTH"} },  -- Some languages collapse with MOUTH
    LIVE = { tier = 1, en = {"live"}, parents = {} },  -- Be alive
    LOCK = { tier = 2, en = {"lock"}, parents = {"TOOL"} },
    LONELINESS = { tier = 2, en = {"loneliness"}, parents = {"SADNESS"} },
    LONG_ADJ = { tier = 3, en = {"long"}, parents = {"BIG"} },
    LOOK = { tier = 3, en = {"look", "watch"}, parents = {"SEE"} },
    LOSE = { tier = 2, en = {"lose"}, parents = {} },  -- opposite FIND
    LOUD = { tier = 3, en = {"loud"}, parents = {"HEAR"} },  -- tr derived from gürültü - real morphology family
    LOVE = { tier = 2, en = {"love"}, parents = {} },  -- felt — Tier 2 (vs evaluative ones → Tier 3)
    LUCK = { tier = 3, en = {"luck"}, parents = {} },
    LUNG = { tier = 2, en = {"lung"}, parents = {"CHEST"} },  -- organ
    MAKE = { tier = 1, en = {"make", "create"}, parents = {} },
    MAN = { tier = 1, en = {"man"}, parents = {"PERSON"} },  -- Adult male
    MANY = { tier = 1, en = {"many"}, parents = {} },
    MAP = { tier = 3, en = {"map"}, parents = {"TOOL"} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    MASK = { tier = 2, en = {"mask"}, parents = {"CLOTHING"} },  -- protection
    MATERIAL = { tier = 2, en = {"material"}, parents = {} },  -- substance / stuff
    MAYBE = { tier = 3, en = {"maybe", "perhaps"}, parents = {} },  -- fr hyphen dropped (peut-être) - single-token constraint
    MEAT = { tier = 2, en = {"meat"}, parents = {"FOOD"} },  -- distinct from Tier 1 FLESH (body)
    MEDICINE = { tier = 2, en = {"medicine"}, parents = {} },
    MEET = { tier = 2, en = {"meet"}, parents = {} },
    METAL = { tier = 2, en = {"metal"}, parents = {"MATERIAL"} },  -- flagged Tier 2 in CONCEPT_TREE
    MIDDLE = { tier = 3, en = {"middle", "center"}, parents = {} },
    MIDNIGHT = { tier = 2, en = {"midnight"}, parents = {"NIGHT"} },
    MILK = { tier = 2, en = {"milk"}, parents = {"BEVERAGE"} },
    MONTH = { tier = 2, en = {"month"}, parents = {} },  -- unit
    MOON = { tier = 1, en = {"moon"}, parents = {} },
    MORNING = { tier = 2, en = {"morning"}, parents = {"DAY"} },
    MOTHER = { tier = 1, en = {"mother"}, parents = {"KIN"} },
    MOUNTAIN = { tier = 1, en = {"mountain"}, parents = {"EARTH"} },
    MOUTH = { tier = 1, en = {"mouth"}, parents = {"HEAD"} },
    MOVE = { tier = 3, en = {"move"}, parents = {"GO"} },  -- tr noun loan; flag for native review | tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    MUD = { tier = 2, en = {"mud"}, parents = {"MATERIAL", "EARTH"} },
    MUSHROOM = { tier = 2, en = {"mushroom"}, parents = {"FOOD", "PLANT"} },  -- forage; poison risk → medical
    NAIL = { tier = 1, en = {"nail", "fingernail"}, parents = {"FINGER"} },  -- Many langs collapse finger/toenail
    NAIL_FASTENER = { tier = 2, en = {"nail", "nails"}, parents = {"MATERIAL"} },  -- metal fastener; homonym with NAIL=fingernail (byEnglish returns both)
    NAME = { tier = 2, en = {"name"}, parents = {} },  -- "what is your name"
    NAVEL = { tier = 1, en = {"navel", "bellybutton"}, parents = {"BELLY"} },
    NEAR = { tier = 1, en = {"near", "close"}, parents = {} },
    NECK = { tier = 1, en = {"neck"}, parents = {"BODY"} },
    NEED = { tier = 3, en = {"need"}, parents = {"WANT"} },  -- fr/sl lexicalize as noun/adverbial - natural conversational forms
    NEEDLE = { tier = 2, en = {"needle"}, parents = {"TOOL"} },  -- sew/mend
    NEIGHBOUR = { tier = 3, en = {"neighbour", "neighbor"}, parents = {"PERSON"} },
    NEPHEW = { tier = 2, en = {"nephew"}, parents = {"KIN"} },
    NET = { tier = 2, en = {"net"}, parents = {"TOOL"} },
    NEW = { tier = 1, en = {"new"}, parents = {} },
    NIECE = { tier = 2, en = {"niece"}, parents = {"KIN"} },
    NIGHT = { tier = 1, en = {"night"}, parents = {} },  -- Dark-period
    NINE = { tier = 2, en = {"nine"}, parents = {} },
    NO = { tier = 1, en = {"no"}, parents = {} },  -- Refusal/disagreement (vs NONE)
    NOBODY = { tier = 3, en = {"nobody"}, parents = {"PERSON"} },  -- fr personne conflates with PERSON - real French negative-concord fact, loud flag
    NOISE = { tier = 3, en = {"noise", "sound"}, parents = {"HEAR"} },
    NONE = { tier = 1, en = {"none", "nothing"}, parents = {} },  -- Distinct from NO (refusal)
    NOON = { tier = 2, en = {"noon"}, parents = {"DAY"} },
    NORTH = { tier = 2, en = {"north"}, parents = {} },  -- cardinal
    NOSE = { tier = 1, en = {"nose"}, parents = {"HEAD"} },
    NOT = { tier = 1, en = {"not"}, parents = {} },  -- Negation marker -- distinct from NO in many langs
    NOW = { tier = 1, en = {"now"}, parents = {} },
    NUT = { tier = 2, en = {"nut"}, parents = {"FOOD", "PLANT"} },  -- forageable
    OIL = { tier = 2, en = {"oil"}, parents = {"MATERIAL"} },
    OLD = { tier = 1, en = {"old"}, parents = {} },
    ONE = { tier = 1, en = {"one"}, parents = {} },
    OPEN = { tier = 1, en = {"open"}, parents = {} },
    ORANGE = { tier = 2, en = {"orange"}, parents = {} },
    OTHER = { tier = 3, en = {"other"}, parents = {} },
    OUT = { tier = 1, en = {"out", "outside"}, parents = {} },
    PAIN = { tier = 1, en = {"pain", "hurt"}, parents = {} },
    PALM = { tier = 2, en = {"palm"}, parents = {"HAND"} },
    PAN = { tier = 2, en = {"pan"}, parents = {"CONTAINER"} },  -- cooking
    PAPER = { tier = 2, en = {"paper"}, parents = {"MATERIAL"} },
    PATH = { tier = 2, en = {"path"}, parents = {"ROAD"} },
    PEACE = { tier = 1, en = {"peace", "peaceful", "calm"}, parents = {} },
    PERSON = { tier = 1, en = {"person", "people"}, parents = {} },
    PIG = { tier = 2, en = {"pig"}, parents = {"ANIMAL"} },
    PINK = { tier = 2, en = {"pink"}, parents = {} },
    PLAN = { tier = 3, en = {"plan"}, parents = {"THINK"} },  -- tr/fr loan-cognate triple - real in all three; tr loanword harmony-exempt
    PLANT = { tier = 2, en = {"plant"}, parents = {} },  -- rooted growing thing
    PLASTIC = { tier = 2, en = {"plastic"}, parents = {"MATERIAL"} },  -- modern; PZ-era
    PLATE = { tier = 2, en = {"plate"}, parents = {"CONTAINER"} },
    PLAY = { tier = 1, en = {"play"}, parents = {} },
    PLEASE = { tier = 2, en = {"please"}, parents = {} },
    POISON = { tier = 2, en = {"poison"}, parents = {} },
    POOR = { tier = 3, en = {"poor"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    POT = { tier = 2, en = {"pot"}, parents = {"CONTAINER"} },  -- cooking
    PRICE = { tier = 3, en = {"price", "cost"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    PROMISE = { tier = 3, en = {"promise"}, parents = {"SAY"} },  -- tr noun (söz vermek is 2 tokens)
    PULL = { tier = 1, en = {"pull"}, parents = {} },
    PURPLE = { tier = 2, en = {"purple"}, parents = {} },
    PUSH = { tier = 1, en = {"push"}, parents = {} },
    QUIET = { tier = 3, en = {"quiet"}, parents = {} },
    RADIO = { tier = 3, en = {"radio"}, parents = {"TOOL"} },  -- loan triple - real in all three; tr loanword harmony-exempt
    RAIN = { tier = 1, en = {"rain"}, parents = {} },
    RAT = { tier = 2, en = {"rat"}, parents = {"ANIMAL"} },  -- vermin
    READ = { tier = 2, en = {"read"}, parents = {} },  -- pairs with BOOK
    READY = { tier = 3, en = {"ready"}, parents = {} },
    RED = { tier = 1, en = {"red"}, parents = {} },
    RELIEF = { tier = 1, en = {"relief", "relieved"}, parents = {} },
    REMEMBER = { tier = 1, en = {"remember"}, parents = {"KNOW"} },
    REST = { tier = 3, en = {"rest", "relax"}, parents = {"SLEEP"} },
    RIB = { tier = 2, en = {"rib"}, parents = {"CHEST"} },
    RICE = { tier = 2, en = {"rice"}, parents = {"GRAIN"} },  -- rice cultures
    RICH = { tier = 3, en = {"rich"}, parents = {} },
    RIGHT = { tier = 2, en = {"right"}, parents = {} },  -- body-relative — Tier 1 lacks it
    RIVER = { tier = 1, en = {"river"}, parents = {"WATER"} },  -- 'Flowing water'
    ROAD = { tier = 2, en = {"road"}, parents = {} },
    ROOF = { tier = 2, en = {"roof"}, parents = {"BUILDING"} },
    ROOM = { tier = 2, en = {"room"}, parents = {"BUILDING"} },
    ROOT = { tier = 2, en = {"root"}, parents = {"PLANT"} },
    ROPE = { tier = 2, en = {"rope"}, parents = {"TOOL"} },  -- binding/cordage
    RUBBER = { tier = 2, en = {"rubber"}, parents = {"MATERIAL"} },
    RUN = { tier = 1, en = {"run"}, parents = {"WALK"} },  -- Operational: faster-than-walk
    SACK = { tier = 2, en = {"sack"}, parents = {"CONTAINER"} },
    SADNESS = { tier = 1, en = {"sad", "sadness"}, parents = {} },
    SAFE = { tier = 3, en = {"safe"}, parents = {"GOOD"} },  -- tr derives güvenmek - real morphology family; fr sûr also=sure, real polysemy
    SALT = { tier = 2, en = {"salt"}, parents = {"MATERIAL", "FOOD"} },  -- seasoning/preserve — boundary w/ FOOD
    SAME = { tier = 1, en = {"same"}, parents = {} },
    SAND = { tier = 1, en = {"sand"}, parents = {"EARTH"} },
    SAW = { tier = 2, en = {"saw"}, parents = {"TOOL"} },
    SAY = { tier = 1, en = {"say"}, parents = {} },
    SCAR = { tier = 2, en = {"scar"}, parents = {} },
    SEA = { tier = 1, en = {"sea", "ocean"}, parents = {"WATER"} },  -- Inland langs may conflate with LAKE
    SEARCH = { tier = 2, en = {"search"}, parents = {} },  -- look-for
    SEASON = { tier = 2, en = {"season"}, parents = {} },
    SEE = { tier = 1, en = {"see"}, parents = {}, splits = {"LOOK"} },  -- Splits with LOOK (intentional) in many langs
    SEED = { tier = 2, en = {"seed"}, parents = {"PLANT"} },  -- sow
    SEND = { tier = 3, en = {"send"}, parents = {"GIVE"} },
    SEVEN = { tier = 2, en = {"seven"}, parents = {} },
    SHAME = { tier = 1, en = {"shame"}, parents = {} },
    SHARE = { tier = 3, en = {"share"}, parents = {"GIVE"} },
    SHARP = { tier = 1, en = {"sharp"}, parents = {} },
    SHEEP = { tier = 2, en = {"sheep"}, parents = {"ANIMAL"} },
    SHIELD = { tier = 2, en = {"shield"}, parents = {"WEAPON"} },  -- defensive
    SHIRT = { tier = 2, en = {"shirt"}, parents = {"CLOTHING"} },
    SHOE = { tier = 2, en = {"shoe"}, parents = {"CLOTHING"} },
    SHOOT = { tier = 2, en = {"shoot"}, parents = {"THROW"} },  -- pairs with GUN
    SHOULDER = { tier = 1, en = {"shoulder"}, parents = {"BODY"} },
    SHOUT = { tier = 1, en = {"shout", "yell"}, parents = {"SPEAK"} },
    SHOVEL = { tier = 2, en = {"shovel"}, parents = {"TOOL"} },  -- dig implement
    SHOW = { tier = 3, en = {"show"}, parents = {"SEE"} },
    SIBLING = { tier = 1, en = {"sibling"}, parents = {"KIN"}, splits = {"OLDER_BROTHER", "YOUNGER_BROTHER", "OLDER_SISTER", "YOUNGER_SISTER"} },  -- Splits older/younger in Mandarin, Japanese | v8.16.1: brother/sister moved to child concepts
    SICK = { tier = 1, en = {"sick", "ill"}, parents = {} },
    SIDE = { tier = 3, en = {"side"}, parents = {} },
    SIMPLE = { tier = 3, en = {"simple"}, parents = {"EASY"} },  -- tr loanword harmony-exempt
    SISTER = { tier = 3, en = {"sister"}, parents = {"SIBLING"} },  -- tr abla=older sister, commonest address form
    SIT = { tier = 1, en = {"sit"}, parents = {} },
    SIX = { tier = 2, en = {"six"}, parents = {} },
    SKIN = { tier = 1, en = {"skin"}, parents = {"BODY"} },
    SKY = { tier = 1, en = {"sky"}, parents = {} },
    SLEEP = { tier = 1, en = {"sleep"}, parents = {} },
    SLOW = { tier = 1, en = {"slow"}, parents = {} },
    SMALL = { tier = 1, en = {"small", "little"}, parents = {} },
    SMELL = { tier = 1, en = {"smell"}, parents = {} },  -- Verb sense -- to perceive smell
    SMOKE = { tier = 1, en = {"smoke"}, parents = {"FIRE"} },
    SNAKE = { tier = 2, en = {"snake"}, parents = {"ANIMAL"} },
    SNOW = { tier = 1, en = {"snow"}, parents = {} },  -- Conflated with ICE in tropical langs
    SOCK = { tier = 2, en = {"sock"}, parents = {"CLOTHING"} },
    SOFT = { tier = 1, en = {"soft"}, parents = {} },
    SOMEONE = { tier = 3, en = {"someone", "somebody"}, parents = {"PERSON"} },  -- fr apostrophe dropped (quelqu'un) - single-token constraint
    SOMETHING = { tier = 3, en = {"something"}, parents = {} },  -- tr informal single-token; fr truc = colloquial register, the word people actually say
    SON = { tier = 2, en = {"son"}, parents = {"KIN", "CHILD"} },
    SONG = { tier = 3, en = {"song"}, parents = {} },
    SOON = { tier = 3, en = {"soon"}, parents = {} },
    SORRY = { tier = 2, en = {"sorry"}, parents = {} },
    SOUP = { tier = 2, en = {"soup"}, parents = {"FOOD"} },  -- prepared
    SOUTH = { tier = 2, en = {"south"}, parents = {} },
    SOW = { tier = 2, en = {"sow", "plant"}, parents = {} },  -- sow; pairs with SEED
    SPEAK = { tier = 1, en = {"speak", "talk"}, parents = {"SAY"} },
    SPEAR = { tier = 2, en = {"spear"}, parents = {"WEAPON"} },
    SPOON = { tier = 2, en = {"spoon"}, parents = {"TOOL"} },  -- eating implement
    SPRING = { tier = 2, en = {"spring"}, parents = {"SEASON"} },
    STAIRS = { tier = 2, en = {"stairs"}, parents = {"BUILDING"} },
    STAND = { tier = 1, en = {"stand"}, parents = {} },
    STAR = { tier = 1, en = {"star"}, parents = {} },
    START = { tier = 3, en = {"start", "begin"}, parents = {} },
    STAY = { tier = 3, en = {"stay", "remain"}, parents = {} },
    STEAL = { tier = 3, en = {"steal"}, parents = {"TAKE"} },  -- tr çalmak also=play instrument; fr voler also=fly - both real polysemy, conflation flagged
    STOMACH = { tier = 2, en = {"stomach"}, parents = {"BELLY"} },  -- organ (vs BELLY exterior)
    STONE = { tier = 1, en = {"stone", "rock"}, parents = {"EARTH"} },
    STOP = { tier = 2, en = {"stop"}, parents = {} },
    STORE_V = { tier = 3, en = {"store", "stockpile"}, parents = {"KEEP"} },  -- tr depolamak: depo is a French loanword root (dépôt), harmony-exempt
    STORY = { tier = 3, en = {"story", "tale"}, parents = {"SAY"} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    STRANGE = { tier = 3, en = {"strange", "weird"}, parents = {} },  -- tr loanword (Arabic/Persian/French origin), harmony-exempt per palette header
    STRANGER = { tier = 3, en = {"stranger", "outsider"}, parents = {"PERSON"} },
    STRONG = { tier = 3, en = {"strong"}, parents = {} },
    SUMMER = { tier = 2, en = {"summer"}, parents = {"SEASON"} },
    SUN = { tier = 1, en = {"sun"}, parents = {} },
    SURPRISE = { tier = 1, en = {"surprise", "surprised"}, parents = {} },
    SWIM = { tier = 1, en = {"swim"}, parents = {} },
    SWORD = { tier = 2, en = {"sword"}, parents = {"WEAPON"} },
    TAKE = { tier = 1, en = {"take"}, parents = {} },
    TASTE = { tier = 1, en = {"taste"}, parents = {} },  -- Verb sense
    TEA = { tier = 2, en = {"tea"}, parents = {"BEVERAGE"} },
    TEACH = { tier = 3, en = {"teach"}, parents = {"KNOW", "SAY"} },
    TELL = { tier = 3, en = {"tell"}, parents = {"SAY"} },
    TEN = { tier = 2, en = {"ten"}, parents = {} },
    THANK_YOU = { tier = 2, en = {"thank you", "thanks", "thank"}, parents = {} },  -- flagged Tier 2
    THAT = { tier = 1, en = {"that"}, parents = {} },  -- Distal demonstrative
    THEN = { tier = 1, en = {"then"}, parents = {} },  -- Past or future (split in some langs)
    THEY = { tier = 1, en = {"they"}, parents = {} },  -- Third person plural
    THINK = { tier = 1, en = {"think"}, parents = {} },
    THIRSTY = { tier = 1, en = {"thirsty"}, parents = {} },
    THIS = { tier = 1, en = {"this"}, parents = {} },  -- Proximal demonstrative
    THREAD = { tier = 2, en = {"thread"}, parents = {"MATERIAL"} },  -- pairs with NEEDLE; cordage-fine
    THREE = { tier = 1, en = {"three"}, parents = {} },  -- Some langs (Piraha) stop at TWO
    THROAT = { tier = 2, en = {"throat"}, parents = {"NECK"} },
    THROW = { tier = 1, en = {"throw"}, parents = {} },
    THUMB = { tier = 2, en = {"thumb"}, parents = {"HAND"} },
    TIE = { tier = 1, en = {"tie", "bind"}, parents = {} },
    TIRED = { tier = 1, en = {"tired"}, parents = {} },
    TODAY = { tier = 1, en = {"today"}, parents = {} },
    TOE = { tier = 1, en = {"toe"}, parents = {"FOOT", "FINGER"} },  -- Fallback to FINGER in many langs (see notes)
    TOMORROW = { tier = 1, en = {"tomorrow"}, parents = {} },
    TONGUE = { tier = 1, en = {"tongue"}, parents = {"MOUTH"} },
    TOOL = { tier = 2, en = {"tool"}, parents = {} },  -- implement for a task
    TOOTH = { tier = 1, en = {"tooth", "teeth"}, parents = {"MOUTH"} },
    TOP = { tier = 3, en = {"top"}, parents = {} },
    TORCH = { tier = 2, en = {"torch"}, parents = {"TOOL", "LIGHT"} },  -- portable light source — implement + illumination (dual-parent)
    TOUCH = { tier = 1, en = {"touch", "feel"}, parents = {} },  -- Verb sense; splits with FEEL (emotion)
    TOWN = { tier = 2, en = {"town"}, parents = {} },  -- settlement
    TRADE = { tier = 2, en = {"trade"}, parents = {"GIVE"} },  -- exchange
    TRAP = { tier = 2, en = {"trap"}, parents = {"WEAPON", "TOOL"} },  -- dual
    TREE = { tier = 1, en = {"tree"}, parents = {} },
    TROUSERS = { tier = 2, en = {"trousers", "pants"}, parents = {"CLOTHING"} },  -- pants
    TRUCK = { tier = 2, en = {"truck"}, parents = {"VEHICLE"} },
    TRUST = { tier = 3, en = {"trust"}, parents = {"KNOW"} },  -- fr noun (faire confiance is multi-token)
    TRY = { tier = 3, en = {"try", "attempt"}, parents = {} },
    TWO = { tier = 1, en = {"two"}, parents = {} },
    UNCLE = { tier = 2, en = {"uncle"}, parents = {"KIN"} },
    UNDERSTAND = { tier = 1, en = {"understand"}, parents = {"KNOW"} },
    UP = { tier = 1, en = {"up"}, parents = {} },
    USE = { tier = 3, en = {"use"}, parents = {} },
    VEGETABLE = { tier = 2, en = {"vegetable"}, parents = {"FOOD", "PLANT"} },  -- category-ish
    VEHICLE = { tier = 2, en = {"vehicle"}, parents = {} },  -- thing that carries you
    WAIT = { tier = 2, en = {"wait"}, parents = {} },
    WAKE = { tier = 1, en = {"wake", "wake up"}, parents = {} },
    WALK = { tier = 1, en = {"walk"}, parents = {} },
    WALL = { tier = 2, en = {"wall"}, parents = {"BUILDING"} },
    WANT = { tier = 1, en = {"want"}, parents = {} },
    WASH = { tier = 1, en = {"wash"}, parents = {} },
    WATER = { tier = 1, en = {"water"}, parents = {} },
    WE = { tier = 1, en = {"we"}, parents = {}, splits = {"WE_INCLUSIVE", "WE_EXCLUSIVE"} },  -- Inclusive/exclusive splits (Austronesian, etc.)
    WEAK = { tier = 3, en = {"weak"}, parents = {} },
    WEAPON = { tier = 2, en = {"weapon"}, parents = {} },  -- implement for harm; dual-use KNIFE/AXE sit under TOOL
    WEAR = { tier = 2, en = {"wear"}, parents = {} },  -- pairs with CLOTHING
    WEED = { tier = 2, en = {"weed"}, parents = {"PLANT"} },
    WEEK = { tier = 2, en = {"week"}, parents = {} },  -- unit
    WELL = { tier = 1, en = {"well", "healthy"}, parents = {} },
    WEST = { tier = 2, en = {"west"}, parents = {} },
    WET = { tier = 1, en = {"wet"}, parents = {} },
    WHAT = { tier = 1, en = {"what"}, parents = {} },
    WHEEL = { tier = 2, en = {"wheel"}, parents = {"VEHICLE"} },  -- part
    WHEN = { tier = 1, en = {"when"}, parents = {} },
    WHERE = { tier = 1, en = {"where"}, parents = {} },
    WHITE = { tier = 1, en = {"white", "light"}, parents = {} },
    WHO = { tier = 1, en = {"who"}, parents = {} },
    WHY = { tier = 1, en = {"why"}, parents = {} },
    WIFE = { tier = 2, en = {"wife"}, parents = {"KIN"} },
    WIN = { tier = 3, en = {"win"}, parents = {} },
    WIND = { tier = 1, en = {"wind"}, parents = {} },
    WINDOW = { tier = 2, en = {"window"}, parents = {"BUILDING"} },
    WINTER = { tier = 2, en = {"winter"}, parents = {"SEASON"} },  -- PZ cold
    WOLF = { tier = 2, en = {"wolf"}, parents = {"ANIMAL"} },  -- predator
    WOMAN = { tier = 1, en = {"woman"}, parents = {"PERSON"} },  -- Adult female
    WOOD = { tier = 2, en = {"wood"}, parents = {"MATERIAL"} },  -- Tier 1 has TREE, not the material
    WORK = { tier = 1, en = {"work"}, parents = {} },
    WORRY = { tier = 2, en = {"worry"}, parents = {"FEAR"} },  -- anxiety
    WOUND = { tier = 2, en = {"wound"}, parents = {} },
    WRIST = { tier = 2, en = {"wrist"}, parents = {"ARM"} },
    WRITE = { tier = 2, en = {"write"}, parents = {} },
    WRONG = { tier = 3, en = {"wrong"}, parents = {"BAD"} },
    YEAR = { tier = 2, en = {"year"}, parents = {} },  -- unit
    YELLOW = { tier = 2, en = {"yellow"}, parents = {} },  -- stage III
    YES = { tier = 1, en = {"yes"}, parents = {} },  -- Mandarin echoes verb instead
    YESTERDAY = { tier = 1, en = {"yesterday"}, parents = {} },
    YOU = { tier = 1, en = {"you"}, parents = {}, splits = {"YOU_SINGULAR", "YOU_PLURAL"} },  -- Second person; singular/plural splits in many langs
    YOUNG = { tier = 3, en = {"young"}, parents = {} },
}

M.lexicalSets = {
    body = {"BLOOD", "EYE", "FOOT", "HAND", "HEAD", "MOUTH"},
    motion = {"BRING", "CATCH", "CLIMB", "COME", "ENTER", "EXIT", "FALL", "FOLLOW", "GO", "JUMP", "MOVE", "RUN", "WALK"},
    sensation = {"DREAM", "HUNGRY", "LOUD", "NOISE", "PAIN", "QUIET", "SICK", "THIRSTY", "TIRED", "WELL"},
    social = {"ALONE", "ANSWER", "ASK", "BROTHER", "ENEMY", "FRIEND", "GAME", "GIFT", "GUEST", "LEADER", "LEARN", "LETTER", "NEIGHBOUR", "NO", "NOBODY", "POOR", "PRICE", "PROMISE", "RICH", "SAY", "SHARE", "SHOW", "SISTER", "SONG", "STEAL", "STORY", "STRANGER", "TEACH", "TELL", "TRUST", "WIN", "YES"},
    survival = {"BLANKET", "CAMP", "CANDLE", "CAREFUL", "COLD", "DIE", "FARM", "FEAR", "FIGHT", "FIRE", "FOOD", "GARDEN", "HIDE", "KITCHEN", "MAP", "NEED", "PLAN", "RADIO", "READY", "REST", "RUN", "SAFE", "STAY", "STORE_V", "STRONG", "WATER", "WEAK"},
}

return M
