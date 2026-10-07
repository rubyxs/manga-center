local Zoom = {}

Zoom.MIN_PERCENT = 50
Zoom.MAX_PERCENT = 100
Zoom.MIN_OVERLAP_PERCENT = 0
Zoom.MAX_OVERLAP_PERCENT = 90
Zoom.MIN_SCROLL_MULTIPLIER = 0.25
Zoom.MAX_SCROLL_MULTIPLIER = 10

function Zoom.normalizePercent(value)
    value = tonumber(value) or Zoom.MAX_PERCENT
    if value < Zoom.MIN_PERCENT then return Zoom.MIN_PERCENT end
    if value > Zoom.MAX_PERCENT then return Zoom.MAX_PERCENT end
    return value
end

function Zoom.normalizeOverlapPercent(value)
    value = tonumber(value) or 0
    if value < Zoom.MIN_OVERLAP_PERCENT then return Zoom.MIN_OVERLAP_PERCENT end
    if value > Zoom.MAX_OVERLAP_PERCENT then return Zoom.MAX_OVERLAP_PERCENT end
    return value
end

function Zoom.normalizeScrollMultiplier(value)
    value = tonumber(value) or 1
    if value < Zoom.MIN_SCROLL_MULTIPLIER then return Zoom.MIN_SCROLL_MULTIPLIER end
    if value > Zoom.MAX_SCROLL_MULTIPLIER then return Zoom.MAX_SCROLL_MULTIPLIER end
    return value
end

function Zoom.applyScrollMultiplier(distance, multiplier)
    if type(distance) ~= "number" then return distance end
    return distance * Zoom.normalizeScrollMultiplier(multiplier)
end

function Zoom.isWidthMode(mode)
    return mode == "pagewidth" or mode == "contentwidth"
end

function Zoom.apply(zoom, percent)
    if type(zoom) ~= "number" then return zoom end
    return zoom * Zoom.normalizePercent(percent) / 100
end

function Zoom.overlapPixels(percent, height)
    if percent == nil then return nil end
    height = tonumber(height) or 0
    if height <= 0 then return 0 end
    return math.floor(height * Zoom.normalizeOverlapPercent(percent) / 100 + 0.5)
end

return Zoom
