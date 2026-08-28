local AutoCenter = {}
local CACHE_VERSION = "v2"

-- Find the horizontal center of visible ink in an already-rendered page.
-- Sampling keeps this inexpensive on e-ink devices. Besides rejecting isolated
-- marks, distinguish an outer rule around an added white strip from a genuine
-- picture border by comparing the sampled content on both sides of the rule.
function AutoCenter.detectOffset(bb, options)
    options = options or {}
    local x = options.x or 0
    local y = options.y or 0
    local w = options.w or bb:getWidth()
    local h = options.h or bb:getHeight()
    if w < 32 or h < 32 then
        return 0
    end

    local step_x = math.max(1, math.floor(w / (options.sample_columns or 240)))
    local step_y = math.max(1, math.floor(h / (options.sample_rows or 180)))
    local y_margin = math.floor(h * 0.04)
    local y_first = y + y_margin
    local y_last = y + h - y_margin - 1
    local white_threshold = options.white_threshold or 238

    local xs, active, dark_ratios = {}, {}, {}
    local sampled_rows = math.floor((y_last - y_first) / step_y) + 1
    local required_dark = math.max(3, math.floor(sampled_rows * 0.035))
    local index = 0
    for px = x, x + w - 1, step_x do
        index = index + 1
        xs[index] = px
        local dark = 0
        for py = y_first, y_last, step_y do
            -- CreDocument.buffer is a raw BlitBuffer FFI struct. getPixel()
            -- is part of its metatype API; getPixelRGB() is not.
            local gray = bb:getPixel(px, py):getColor8().a
            if gray < white_threshold then
                dark = dark + 1
            end
        end
        dark_ratios[index] = dark / sampled_rows
        active[index] = dark >= required_dark
    end

    local function band_stats(from, direction, length)
        local count, active_count, darkness = 0, 0, 0
        for delta = 0, length - 1 do
            local i = from + direction * delta
            if i >= 1 and i <= index then
                count = count + 1
                darkness = darkness + dark_ratios[i]
                if active[i] then
                    active_count = active_count + 1
                end
            end
        end
        if count == 0 then
            return 0, 0
        end
        return active_count / count, darkness / count
    end

    local function has_sustained_ink(from, direction)
        local active_ratio, darkness = band_stats(from, direction, 12)
        return active_ratio >= 0.34 and darkness >= 0.075
    end

    local function is_outer_strip_rule(from, direction)
        if dark_ratios[from] < 0.7 then
            return false
        end

        -- A border may be anti-aliased or a few pixels wide. Follow only a
        -- narrow run of highly continuous sampled columns toward the center.
        local line_columns = 1
        while line_columns < 4 do
            local i = from + direction * line_columns
            if i < 1 or i > index or dark_ratios[i] < 0.55 then
                break
            end
            line_columns = line_columns + 1
        end
        if line_columns >= 4 then
            return false
        end

        local outside_active, outside_darkness = band_stats(from - direction, -direction, 10)
        local inside_active, inside_darkness = band_stats(
            from + direction * line_columns, direction, 12)
        local outside_is_empty = outside_active <= 0.1 and outside_darkness <= 0.015
        local inside_is_white_strip = inside_active <= 0.25 and inside_darkness <= 0.04
        return outside_is_empty and inside_is_white_strip
    end

    local left, right
    for i = 1, index do
        if active[i] and has_sustained_ink(i, 1) and not is_outer_strip_rule(i, 1) then
            left = xs[i]
            break
        end
    end
    for i = index, 1, -1 do
        if active[i] and has_sustained_ink(i, -1) and not is_outer_strip_rule(i, -1) then
            right = xs[i]
            break
        end
    end
    if not left or not right or right <= left or right - left < w * 0.25 then
        return 0
    end

    local page_center = x + (w - 1) / 2
    local ink_center = (left + right) / 2
    local delta = page_center - ink_center
    local offset = delta >= 0 and math.floor(delta + 0.5) or math.ceil(delta - 0.5)
    local max_offset = math.floor(w * 0.25)
    offset = math.max(-max_offset, math.min(max_offset, offset))
    if math.abs(offset) < math.max(2, math.floor(w * 0.002)) then
        return 0
    end
    return offset
end

function AutoCenter.cacheKey(page, width, height, rendering_hash)
    return table.concat({ CACHE_VERSION, tostring(rendering_hash or 0), width, height, page }, ":")
end

return AutoCenter
