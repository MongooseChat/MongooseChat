-- Deterministic, engine-free approximate shade names for /hue feedback.
-- Entries are ordered: an exact distance tie always keeps the first label.

local MC_HueNames = {}

local ATLAS = {
    {184,201,106,"Mongoose Lichen"}, {255,105,97,"Coral"},
    {251,243,227,"Ivory Cream"}, {122,166,255,"Cornflower Blue"},

    {0,0,0,"Black"}, {32,32,32,"Near Black"}, {64,64,64,"Charcoal"},
    {96,96,96,"Graphite"}, {128,128,128,"Grey"}, {160,160,160,"Silver Grey"},
    {192,192,192,"Silver"}, {224,224,224,"Pearl Grey"}, {245,245,245,"Soft White"},
    {255,255,255,"White"}, {245,240,230,"Linen"}, {255,248,220,"Cornsilk"},
    {250,235,215,"Antique White"}, {255,250,240,"Floral White"},

    {128,0,0,"Maroon"}, {165,42,42,"Brown Red"}, {178,34,34,"Firebrick"},
    {200,30,40,"Crimson"}, {220,20,60,"Ruby Red"}, {239,68,68,"Bright Red"},
    {255,0,0,"Red"}, {255,99,71,"Tomato"}, {205,92,92,"Dusty Rose"},
    {240,128,128,"Light Coral"}, {255,160,150,"Salmon Pink"},

    {120,60,20,"Umber"}, {139,69,19,"Saddle Brown"}, {160,82,45,"Sienna"},
    {184,115,51,"Copper"}, {210,105,30,"Burnt Orange"}, {230,126,34,"Pumpkin"},
    {255,140,0,"Dark Orange"}, {255,165,0,"Orange"}, {255,179,71,"Apricot Orange"},
    {244,164,96,"Sandy Orange"}, {222,184,135,"Tan"}, {210,180,140,"Khaki Tan"},
    {188,143,143,"Rose Taupe"}, {128,96,72,"Walnut"},

    {128,128,0,"Olive"}, {170,150,40,"Mustard"}, {218,165,32,"Goldenrod"},
    {255,191,0,"Amber"}, {255,215,0,"Gold"}, {255,225,53,"Sunflower Yellow"},
    {255,255,0,"Yellow"}, {240,230,140,"Pale Khaki"}, {255,250,130,"Butter Yellow"},
    {255,255,224,"Ivory"},

    {0,64,32,"Pine Green"}, {0,100,0,"Dark Green"}, {34,139,34,"Forest Green"},
    {46,125,50,"Fern Green"}, {85,107,47,"Olive Green"}, {107,142,35,"Moss Green"},
    {124,152,58,"Lichen Green"}, {128,160,90,"Sage Green"}, {46,139,87,"Sea Green"},
    {60,179,113,"Medium Sea Green"}, {0,168,107,"Jade"}, {0,170,90,"Emerald"},
    {0,200,83,"Bright Green"}, {50,205,50,"Lime Green"},
    {127,255,0,"Chartreuse"}, {152,251,152,"Pale Green"}, {189,252,201,"Mint Green"},

    {0,80,80,"Deep Teal"}, {0,128,128,"Teal"}, {32,178,170,"Light Sea Green"},
    {64,224,208,"Turquoise"}, {0,255,255,"Cyan"}, {127,255,212,"Aquamarine"},
    {175,238,238,"Pale Turquoise"}, {176,224,230,"Powder Cyan"},

    {0,0,128,"Navy"}, {25,25,112,"Midnight Blue"}, {0,64,128,"Deep Blue"},
    {0,102,204,"Ocean Blue"}, {0,120,215,"Azure Blue"}, {30,144,255,"Dodger Blue"},
    {0,160,230,"Sky Blue"}, {65,105,225,"Royal Blue"}, {70,130,180,"Steel Blue"},
    {100,149,237,"Cornflower"}, {135,206,235,"Light Sky Blue"},
    {173,216,230,"Powder Blue"}, {0,0,255,"Blue"},

    {48,25,82,"Blackberry"}, {75,0,130,"Indigo"}, {72,61,139,"Dark Slate Blue"},
    {106,90,205,"Slate Purple"}, {128,0,128,"Purple"}, {138,43,226,"Blue Violet"},
    {148,0,211,"Dark Violet"}, {186,85,211,"Orchid"}, {177,156,217,"Lavender Purple"},
    {216,191,216,"Thistle"}, {230,230,250,"Lavender"},

    {128,0,64,"Wine"}, {176,48,96,"Berry Pink"}, {199,21,133,"Deep Pink"},
    {219,112,147,"Pale Violet Red"}, {255,20,147,"Hot Pink"}, {255,105,180,"Rose Pink"},
    {255,182,193,"Light Pink"}, {255,192,203,"Blush Pink"}, {255,228,225,"Rose Mist"},

    {112,128,144,"Slate Grey"}, {119,136,153,"Blue Grey"}, {143,151,121,"Moss Grey"},
    {169,169,140,"Warm Grey"}, {195,176,145,"Sand"}, {222,196,176,"Warm Beige"},
    {245,222,179,"Wheat"}, {255,218,185,"Peach"}, {255,228,196,"Bisque"},
}

local function validByte(value)
    return type(value) == "number" and value >= 0 and value <= 255
        and value == math.floor(value)
end

local function readColor(color)
    if type(color) ~= "table" then return nil end
    local r, g, b = color[1], color[2], color[3]
    if not validByte(r) or not validByte(g) or not validByte(b) then return nil end
    return r, g, b
end

-- Internal contract: MC_Server names owner-only /hue feedback through this seam.
function MC_HueNames._approximate(color)
    local r, g, b = readColor(color)
    if not r then return nil end
    local bestName, bestDistance = nil, nil
    for i = 1, #ATLAS do
        local entry = ATLAS[i]
        local dr, dg, db = r - entry[1], g - entry[2], b - entry[3]
        -- Green carries the most visual weight, then red, then blue.
        local distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
        if bestDistance == nil or distance < bestDistance then
            bestDistance = distance
            bestName = entry[4]
        end
    end
    return bestName
end

-- Internal contract: offline tests inspect a fresh copy of the fixed atlas.
function MC_HueNames._atlasCopy()
    local copy = {}
    for i = 1, #ATLAS do
        local entry = ATLAS[i]
        copy[i] = { entry[1], entry[2], entry[3], entry[4] }
    end
    return copy
end

return MC_HueNames
