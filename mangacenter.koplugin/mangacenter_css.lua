local MangaCenterCSS = {}

local SELECTOR_ALL = "DocFragment:not(:first-child) > body"
local SELECTOR_ODD = "DocFragment:nth-child(odd):not(:first-child) > body"
local SELECTOR_EVEN = "DocFragment:nth-child(even) > body"

local function format_number(value)
    if math.abs(value) < 0.00005 then
        value = 0
    end
    local formatted = string.format("%.4f", value)
    formatted = formatted:gsub("0+$", ""):gsub("%.$", "")
    return formatted
end

local function rule(selector, shift)
    return string.format([[%s {
  margin-left: %svw !important;
  margin-right: %svw !important;
}]], selector, format_number(shift), format_number(-shift))
end

function MangaCenterCSS.build(mode, shift)
    shift = tonumber(shift) or 0
    if shift > 25 then
        shift = 25
    elseif shift < -25 then
        shift = -25
    end
    if shift == 0 then
        return ""
    end

    if mode == "alternating" then
        return rule(SELECTOR_ODD, shift) .. "\n" .. rule(SELECTOR_EVEN, -shift)
    end
    return rule(SELECTOR_ALL, shift)
end

return MangaCenterCSS
