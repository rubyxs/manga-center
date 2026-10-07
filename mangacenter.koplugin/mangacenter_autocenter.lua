local AutoCenter = {}
local CACHE_VERSION = "v12"

local function normalizeStrictness(strictness)
    strictness = tonumber(strictness) or 100
    return math.max(50, math.min(200, strictness))
end

-- Find the horizontal center of visible ink in an already-rendered page.
-- Sampling keeps this inexpensive on e-ink devices. Besides rejecting isolated
-- marks, distinguish an outer rule around an added white strip from a genuine
-- picture border by comparing the sampled content on both sides of the rule.
-- Given sampled positions and per-position dark coverage ratios, identify the
-- first/last boundaries that belong to a sustained content body. This is the
-- shared boundary rule for both EPUB rendered buffers and KOPT fixed-page
-- rasters: isolated marks such as page numbers may be dark, but they normally
-- do not remain active across a sufficiently wide inward band.
function AutoCenter.findSustainedBounds(positions, dark_ratios, active, span, strip_strictness)
    local count = #positions
    if count == 0 or #dark_ratios ~= count or #active ~= count then
        return nil, nil
    end
    local aggressiveness = 100 / normalizeStrictness(strip_strictness)

    local function band_stats(from, direction, length)
        local seen, active_count, darkness = 0, 0, 0
        for delta = 0, length - 1 do
            local i = from + direction * delta
            if i >= 1 and i <= count then
                seen = seen + 1
                darkness = darkness + dark_ratios[i]
                if active[i] then
                    active_count = active_count + 1
                end
            end
        end
        if seen == 0 then
            return 0, 0
        end
        return active_count / seen, darkness / seen
    end

    local function has_sustained_ink(from, direction)
        local active_ratio, darkness = band_stats(from, direction, 12)
        return active_ratio >= math.min(0.95, 0.34 * aggressiveness)
            and darkness >= math.min(0.40, 0.075 * aggressiveness)
    end

    local function is_outer_strip_rule(from, direction)
        if dark_ratios[from] < 0.7 then
            return false
        end

        -- A border may be anti-aliased or a few pixels wide. Follow only a
        -- narrow run of highly continuous sampled columns toward the center.
        local line_positions = 1
        while line_positions < 4 do
            local i = from + direction * line_positions
            if i < 1 or i > count or dark_ratios[i] < 0.55 then
                break
            end
            line_positions = line_positions + 1
        end
        if line_positions >= 4 then
            return false
        end

        local outside_active, outside_darkness = band_stats(
            from - direction, -direction, 10)
        local inside_active, inside_darkness = band_stats(
            from + direction * line_positions, direction, 12)
        local outside_is_empty = outside_active <= math.min(0.30, 0.10 * aggressiveness)
            and outside_darkness <= math.min(0.05, 0.015 * aggressiveness)
        local inside_is_white_strip = inside_active <= math.min(0.60, 0.25 * aggressiveness)
            and inside_darkness <= math.min(0.12, 0.04 * aggressiveness)
        return outside_is_empty and inside_is_white_strip
    end

    local left, right
    for i = 1, count do
        if active[i] and has_sustained_ink(i, 1) and not is_outer_strip_rule(i, 1) then
            left = positions[i]
            break
        end
    end
    for i = count, 1, -1 do
        if active[i] and has_sustained_ink(i, -1) and not is_outer_strip_rule(i, -1) then
            right = positions[i]
            break
        end
    end

    if not left or not right or right <= left
            or (span and right - left < span * 0.25) then
        return nil, nil
    end
    return left, right
end


-- Vertical margins need one extra safeguard that horizontal centering rarely
-- needs: a page number, scan watermark, or credits line may sit by itself in a
-- large top/bottom white strip. Such a satellite can be locally "sustained"
-- while still being unrelated to the main artwork. Group nearby active rows and
-- choose the dominant vertical body, bridging only small internal gutters.
function AutoCenter.findDominantBounds(positions, dark_ratios, active, span, strip_strictness)
    local count = #positions
    if count == 0 or #dark_ratios ~= count or #active ~= count then
        return nil, nil
    end
    local strictness_factor = normalizeStrictness(strip_strictness) / 100
    local aggressiveness = 1 / strictness_factor

    -- Vertical cropping must be conservative. A manga page may contain two or
    -- more legitimate panels separated by a very large white gutter. Choosing
    -- one single "dominant" run can therefore delete an entire smaller panel.
    -- Instead, split the page into vertical ink groups and remove only tiny
    -- *outer* satellites (page numbers, scan watermarks, credits lines). Every
    -- substantial group is kept, no matter how large the whitespace between
    -- it and another substantial group is.
    local max_gap = math.max(2, math.floor(count * 0.035 * strictness_factor + 0.5))
    local groups = {}
    local i = 1
    while i <= count do
        while i <= count and not active[i] do
            i = i + 1
        end
        if i > count then break end

        local first = i
        local last_active = i
        local active_count = 0
        local darkness = 0
        local j = i
        local gap = 0
        while j <= count do
            if active[j] then
                last_active = j
                active_count = active_count + 1
                darkness = darkness + (dark_ratios[j] or 0)
                gap = 0
            else
                gap = gap + 1
                if gap > max_gap then
                    break
                end
            end
            j = j + 1
        end

        local samples = math.max(1, last_active - first + 1)
        local pixel_span = math.max(0, positions[last_active] - positions[first])
        local active_ratio = active_count / samples
        local mean_darkness = darkness / math.max(1, active_count)
        local score = (pixel_span + 1)
            * (0.45 + math.min(1, active_ratio))
            * (0.35 + math.min(1, mean_darkness * 5))
        groups[#groups + 1] = {
            first = first,
            last = last_active,
            pixel_span = pixel_span,
            active_count = active_count,
            active_ratio = active_ratio,
            mean_darkness = mean_darkness,
            score = score,
        }
        i = math.max(j, last_active + 1)
    end

    if #groups == 0 then
        return nil, nil
    end

    local best_score = 0
    for _, group in ipairs(groups) do
        best_score = math.max(best_score, group.score)
    end

    -- A real outer panel can be smaller than the main panel, so span alone is
    -- enough to protect it. The relative-score rule additionally protects dense
    -- but short caption/panel regions. A watermark/page number normally fails
    -- both tests.
    local min_panel_span = span and span * (0.03 * aggressiveness) or 0
    local relative_score_floor = best_score * (0.12 * aggressiveness)
    local substantial = {}
    for index, group in ipairs(groups) do
        if group.pixel_span >= min_panel_span
                or group.score >= relative_score_floor then
            substantial[#substantial + 1] = index
        end
    end

    if #substantial == 0 then
        -- Sparse/unusual page: fall back to the old sustained-edge rule rather
        -- than making an aggressive crop from weak evidence.
        return AutoCenter.findSustainedBounds(positions, dark_ratios, active, span, strip_strictness)
    end

    local first_keep = substantial[1]
    local last_keep = substantial[#substantial]

    -- Preserve small groups that sit close to a protected body. These can be
    -- speech bubbles or captions protruding into an otherwise white margin. Only
    -- truly isolated outer groups are candidates for removal.
    local attach_gap = span and span * (0.06 * strictness_factor) or 0
    while first_keep > 1 do
        local previous = groups[first_keep - 1]
        local current = groups[first_keep]
        local gap_pixels = positions[current.first] - positions[previous.last]
        if gap_pixels > attach_gap then break end
        first_keep = first_keep - 1
    end
    while last_keep < #groups do
        local current = groups[last_keep]
        local following = groups[last_keep + 1]
        local gap_pixels = positions[following.first] - positions[current.last]
        if gap_pixels > attach_gap then break end
        last_keep = last_keep + 1
    end

    local top = positions[groups[first_keep].first]
    local bottom = positions[groups[last_keep].last]
    if not top or not bottom or bottom <= top then
        return nil, nil
    end
    if span and bottom - top < span * 0.25 then
        -- Never allow the special vertical classifier to collapse a page into a
        -- suspiciously small strip. The sustained rule is safer in that case.
        return AutoCenter.findSustainedBounds(positions, dark_ratios, active, span, strip_strictness)
    end
    return top, bottom
end

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

    local positions, active, dark_ratios = {}, {}, {}
    local sampled_rows = math.floor((y_last - y_first) / step_y) + 1
    local required_dark = math.max(3, math.floor(sampled_rows * 0.035))
    for px = x, x + w - 1, step_x do
        local dark = 0
        for py = y_first, y_last, step_y do
            -- CreDocument.buffer is a raw BlitBuffer FFI struct. getPixel()
            -- is part of its metatype API; getPixelRGB() is not.
            local gray = bb:getPixel(px, py):getColor8().a
            if gray < white_threshold then
                dark = dark + 1
            end
        end
        positions[#positions + 1] = px
        dark_ratios[#dark_ratios + 1] = dark / sampled_rows
        active[#active + 1] = dark >= required_dark
    end

    local left, right = AutoCenter.findSustainedBounds(
        positions, dark_ratios, active, w, options.strip_strictness)
    if not left or not right then
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

function AutoCenter.isFullWidthVisible(visible_area, page_area, epsilon)
    if not visible_area or not page_area then
        return false
    end
    epsilon = epsilon or 1
    local visible_left = visible_area.x or 0
    local visible_right = visible_left + (visible_area.w or 0)
    local page_left = page_area.x or 0
    local page_right = page_left + (page_area.w or 0)
    return visible_left <= page_left + epsilon
        and visible_right >= page_right - epsilon
end

local function getScreenAxes(content, reference_bbox, rotation)
    rotation = (tonumber(rotation) or 0) % 360
    if rotation == 0 then
        return {
            x = {
                reference_center = (reference_bbox.x0 + reference_bbox.x1) / 2,
                content_center = (content.x0 + content.x1) / 2,
                reference_span = reference_bbox.x1 - reference_bbox.x0,
                content_span = content.x1 - content.x0,
                sign = 1,
            },
            y = {
                reference_center = (reference_bbox.y0 + reference_bbox.y1) / 2,
                content_center = (content.y0 + content.y1) / 2,
                reference_span = reference_bbox.y1 - reference_bbox.y0,
                content_span = content.y1 - content.y0,
                sign = 1,
            },
        }
    elseif rotation == 180 then
        return {
            x = {
                reference_center = (reference_bbox.x0 + reference_bbox.x1) / 2,
                content_center = (content.x0 + content.x1) / 2,
                reference_span = reference_bbox.x1 - reference_bbox.x0,
                content_span = content.x1 - content.x0,
                sign = -1,
            },
            y = {
                reference_center = (reference_bbox.y0 + reference_bbox.y1) / 2,
                content_center = (content.y0 + content.y1) / 2,
                reference_span = reference_bbox.y1 - reference_bbox.y0,
                content_span = content.y1 - content.y0,
                sign = -1,
            },
        }
    elseif rotation == 90 then
        return {
            x = {
                reference_center = (reference_bbox.y0 + reference_bbox.y1) / 2,
                content_center = (content.y0 + content.y1) / 2,
                reference_span = reference_bbox.y1 - reference_bbox.y0,
                content_span = content.y1 - content.y0,
                sign = -1,
            },
            y = {
                reference_center = (reference_bbox.x0 + reference_bbox.x1) / 2,
                content_center = (content.x0 + content.x1) / 2,
                reference_span = reference_bbox.x1 - reference_bbox.x0,
                content_span = content.x1 - content.x0,
                sign = 1,
            },
        }
    elseif rotation == 270 then
        return {
            x = {
                reference_center = (reference_bbox.y0 + reference_bbox.y1) / 2,
                content_center = (content.y0 + content.y1) / 2,
                reference_span = reference_bbox.y1 - reference_bbox.y0,
                content_span = content.y1 - content.y0,
                sign = 1,
            },
            y = {
                reference_center = (reference_bbox.x0 + reference_bbox.x1) / 2,
                content_center = (content.x0 + content.x1) / 2,
                reference_span = reference_bbox.x1 - reference_bbox.x0,
                content_span = content.x1 - content.x0,
                sign = -1,
            },
        }
    end
end

local function axisOffset(axis, screen_span)
    if not axis or not screen_span or screen_span <= 0 then
        return 0
    end
    if not axis.reference_span or axis.reference_span <= 0 then
        return 0
    end
    local fraction = axis.sign * (axis.reference_center - axis.content_center) / axis.reference_span
    local offset = fraction * screen_span
    offset = offset >= 0 and math.floor(offset + 0.5) or math.ceil(offset - 0.5)
    local max_offset = math.floor(screen_span * 0.25)
    offset = math.max(-max_offset, math.min(max_offset, offset))
    if math.abs(offset) < math.max(2, math.floor(screen_span * 0.002)) then
        return 0
    end
    return offset
end

function AutoCenter.offsetFromContentBBox(content, reference_bbox, rotation, screen_width)
    if not content or not reference_bbox or not screen_width or screen_width <= 0 then
        return 0
    end
    local axes = getScreenAxes(content, reference_bbox, rotation)
    return axisOffset(axes and axes.x, screen_width)
end

function AutoCenter.verticalOffsetFromContentBBox(content, reference_bbox, rotation, screen_height)
    if not content or not reference_bbox or not screen_height or screen_height <= 0 then
        return 0
    end
    local axes = getScreenAxes(content, reference_bbox, rotation)
    return axisOffset(axes and axes.y, screen_height)
end

function AutoCenter.fitScaleFromContentBBox(content, reference_bbox, rotation, viewport_width, viewport_height)
    if not content or not reference_bbox
            or not viewport_width or viewport_width <= 0
            or not viewport_height or viewport_height <= 0 then
        return 1
    end

    local axes = getScreenAxes(content, reference_bbox, rotation)
    local axis_x = axes and axes.x
    local axis_y = axes and axes.y
    if not axis_x or not axis_y
            or not axis_x.reference_span or axis_x.reference_span <= 0
            or not axis_y.reference_span or axis_y.reference_span <= 0
            or not axis_x.content_span or axis_x.content_span <= 0
            or not axis_y.content_span or axis_y.content_span <= 0 then
        return 1
    end

    local width_limit = axis_x.reference_span / axis_x.content_span
    local height_target = viewport_height * axis_x.reference_span
        / (viewport_width * axis_y.content_span)
    local scale = math.min(width_limit, height_target)
    if not scale or scale ~= scale or scale < 1.02 then
        return 1
    end
    return scale
end


function AutoCenter.fitZoomFromContentBBox(content, reference_bbox, rotation, zoom_w, zoom_h, current_zoom)
    if not content or not reference_bbox
            or not zoom_w or zoom_w <= 0
            or not zoom_h or zoom_h <= 0 then
        return current_zoom
    end

    local axes = getScreenAxes(content, reference_bbox, rotation)
    local axis_x = axes and axes.x
    local axis_y = axes and axes.y
    if not axis_x or not axis_y
            or not axis_x.reference_span or axis_x.reference_span <= 0
            or not axis_y.reference_span or axis_y.reference_span <= 0
            or not axis_x.content_span or axis_x.content_span <= 0
            or not axis_y.content_span or axis_y.content_span <= 0 then
        return current_zoom
    end

    -- zoom_w/zoom_h are KOReader's native fit factors for the same reference
    -- box used by the current zoom mode. Expand toward fitting the detected
    -- artwork height, but never beyond the zoom that would make its width
    -- exceed the viewport.
    local width_limit_zoom = zoom_w * axis_x.reference_span / axis_x.content_span
    local height_target_zoom = zoom_h * axis_y.reference_span / axis_y.content_span
    local target = math.min(width_limit_zoom, height_target_zoom)
    if not target or target ~= target then
        return current_zoom
    end
    if current_zoom and target < current_zoom * 1.02 then
        return current_zoom
    end
    return target
end


function AutoCenter.contentCenterFraction(content, reference_bbox, rotation, axis_name)
    local axes = getScreenAxes(content, reference_bbox, rotation)
    local axis = axes and axes[axis_name]
    if not axis or not axis.reference_span or axis.reference_span <= 0 then
        return 0.5
    end
    local fraction
    if axis.sign >= 0 then
        fraction = (axis.content_center - (axis.reference_center - axis.reference_span / 2))
            / axis.reference_span
    else
        fraction = ((axis.reference_center + axis.reference_span / 2) - axis.content_center)
            / axis.reference_span
    end
    return math.max(0, math.min(1, fraction))
end


function AutoCenter.getScreenContentRect(content, rotation)
    if not content then return nil end
    local x0 = tonumber(content.x0) or 0
    local y0 = tonumber(content.y0) or 0
    local x1 = tonumber(content.x1) or 0
    local y1 = tonumber(content.y1) or 0
    local page_w = tonumber(content.page_w) or 0
    local page_h = tonumber(content.page_h) or 0
    if x1 <= x0 or y1 <= y0 or page_w <= 0 or page_h <= 0 then
        return nil
    end

    rotation = (tonumber(rotation) or 0) % 360
    if rotation == 0 then
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0,
            page_w = page_w, page_h = page_h }
    elseif rotation == 180 then
        return { x = page_w - x1, y = page_h - y1, w = x1 - x0, h = y1 - y0,
            page_w = page_w, page_h = page_h }
    elseif rotation == 90 then
        return { x = page_h - y1, y = x0, w = y1 - y0, h = x1 - x0,
            page_w = page_h, page_h = page_w }
    elseif rotation == 270 then
        return { x = y0, y = page_w - x1, w = y1 - y0, h = x1 - x0,
            page_w = page_h, page_h = page_w }
    end
    return nil
end


function AutoCenter.getEffectiveCropRect(content, rotation, crop_horizontal, crop_vertical)
    local rect = AutoCenter.getScreenContentRect(content, rotation)
    if not rect then return nil end
    return {
        x = crop_horizontal and rect.x or 0,
        y = crop_vertical and rect.y or 0,
        w = crop_horizontal and rect.w or rect.page_w,
        h = crop_vertical and rect.h or rect.page_h,
        page_w = rect.page_w,
        page_h = rect.page_h,
    }
end

function AutoCenter.getNativeFitZoom(crop_rect, viewport_width, viewport_height, mode)
    if not crop_rect or not viewport_width or viewport_width <= 0
            or not viewport_height or viewport_height <= 0
            or not crop_rect.w or crop_rect.w <= 0
            or not crop_rect.h or crop_rect.h <= 0 then
        return nil
    end
    local zoom_w = viewport_width / crop_rect.w
    local zoom_h = viewport_height / crop_rect.h
    local zoom
    if mode == "page" or mode == "content" then
        zoom = math.min(zoom_w, zoom_h)
    elseif mode == "pagewidth" or mode == "contentwidth" then
        zoom = zoom_w
    elseif mode == "pageheight" or mode == "contentheight" then
        zoom = zoom_h
    else
        return nil
    end
    return zoom, zoom_w, zoom_h
end

function AutoCenter.fitZoomToCroppedViewport(content, rotation, viewport_width, viewport_height,
        current_zoom, crop_horizontal)
    if not viewport_width or viewport_width <= 0
            or not viewport_height or viewport_height <= 0 then
        return current_zoom
    end
    local rect = AutoCenter.getScreenContentRect(content, rotation)
    if not rect then return current_zoom end

    local fit_w = crop_horizontal and rect.w or rect.page_w
    local fit_h = rect.h
    if fit_w <= 0 or fit_h <= 0 then return current_zoom end

    local target = math.min(viewport_width / fit_w, viewport_height / fit_h)
    if not target or target ~= target then return current_zoom end
    return target
end

function AutoCenter.fitZoomToViewport(content, rotation, viewport_width, viewport_height, current_zoom)
    if not content
            or not viewport_width or viewport_width <= 0
            or not viewport_height or viewport_height <= 0 then
        return current_zoom
    end
    rotation = (tonumber(rotation) or 0) % 360
    local content_w = (tonumber(content.x1) or 0) - (tonumber(content.x0) or 0)
    local content_h = (tonumber(content.y1) or 0) - (tonumber(content.y0) or 0)
    if content_w <= 0 or content_h <= 0 then
        return current_zoom
    end
    if rotation == 90 or rotation == 270 then
        content_w, content_h = content_h, content_w
    end
    local width_limit_zoom = viewport_width / content_w
    local height_target_zoom = viewport_height / content_h
    local target = math.min(width_limit_zoom, height_target_zoom)
    if not target or target ~= target then
        return current_zoom
    end
    if current_zoom and target < current_zoom * 1.01 then
        return current_zoom
    end
    return target
end

function AutoCenter.cacheKey(page, width, height, rendering_hash)
    return table.concat({ CACHE_VERSION, tostring(rendering_hash or 0), width, height, page }, ":")
end

return AutoCenter
