-- Portions of this detector are inspired by Crop Enhancer by tachibana-shin:
-- https://github.com/tachibana-shin/crop_enhancer.koplugin
-- Crop Enhancer is licensed under the Mozilla Public License 2.0.
-- This file is distributed under the MPL 2.0; obtain the license at
-- https://mozilla.org/MPL/2.0/.
--
-- MangaCenter renders a source page into a KOPTContext, then applies the same
-- sustained-boundary rule used by its EPUB detector to Leptonica column/row
-- projections. Connected components are retained only as a fallback. It never
-- changes KOReader's crop box or page zoom.

local ffi = require("ffi")
local Document = require("document/document")
local KOPTContext = require("ffi/koptcontext")
local AutoCenter = require("mangacenter_autocenter")

-- KOReader's compact leptonica_h binding does not currently expose the two
-- projection helpers, although bundled Leptonica provides them. Declare only
-- these missing APIs locally; pcall also keeps this harmless if KOReader adds
-- them to its generated binding later.
pcall(ffi.cdef, [[
NUMA *pixCountPixelsByColumn(PIX *pix);
NUMA *pixCountPixelsByRow(PIX *pix, l_int32 *tab8);
]])

local Detector = {}

local DEFAULT_THRESHOLD = 180
local DEFAULT_BORDER_WIDTH = 5
local DEFAULT_MIN_AREA = 50
local TARGET_LONG_EDGE = 1800
local PROJECTION_WHITE_THRESHOLD = 238
local PROJECTION_MARGIN_FRACTION = 0.04
local PROJECTION_DARK_FRACTION = 0.035
local PROJECTION_X_SAMPLES = 240
local PROJECTION_Y_SAMPLES = 180

-- Page numbers, running headers and similar marginal marks are legitimate ink,
-- but they should not influence manga artwork centering. Build the final bbox
-- around the dominant body of substantial components, then absorb only smaller
-- components that actually overlap that body.
local DOMINANT_RELATIVE_AREA = 0.02
local DOMINANT_WIDTH_FRACTION = 0.08
local DOMINANT_HEIGHT_FRACTION = 0.08
local MIN_CORE_WIDTH_FRACTION = 0.20
local MIN_CORE_HEIGHT_FRACTION = 0.20

local leptonica
local leptonica_checked = false

local function loadLeptonica()
    if leptonica_checked then
        return leptonica
    end
    leptonica_checked = true
    local ok, lib = pcall(ffi.loadlib, "leptonica", "6")
    if ok then
        leptonica = lib
    end
    return leptonica
end

local function gcPtr(ptr, destructor)
    if ptr == nil then
        return nil
    end
    return ffi.gc(ptr, destructor)
end

local function detectorOptions(document, zoom)
    local configurable = document.configurable or {}
    local threshold = tonumber(configurable.crop_threshold) or DEFAULT_THRESHOLD
    local border_width = tonumber(configurable.crop_border_max_width) or DEFAULT_BORDER_WIDTH
    local min_area = tonumber(configurable.crop_min_content_area) or DEFAULT_MIN_AREA

    -- Connected-component geometry is measured in the temporary raster, so
    -- scale the geometric filters together with that raster.
    border_width = math.max(0, math.floor(border_width * zoom + 0.5))
    min_area = math.max(4, math.floor(min_area * zoom * zoom + 0.5))

    return {
        threshold = math.max(0, math.min(255, threshold)),
        border_width = border_width,
        min_area = min_area,
    }
end

local function pixDestroy(lev, pix)
    lev.pixDestroy(ffi.new("PIX *[1]", pix))
    ffi.gc(pix, nil)
end

local function boxDestroy(lev, box)
    lev.boxDestroy(ffi.new("BOX *[1]", box))
    ffi.gc(box, nil)
end

local function boxCreate(lev, x, y, w, h)
    return gcPtr(lev.boxCreate(x, y, w, h), function(ptr) boxDestroy(lev, ptr) end)
end

local function numaDestroy(lev, numa)
    lev.numaDestroy(ffi.new("NUMA *[1]", numa))
    ffi.gc(numa, nil)
end

local function boxaDestroy(lev, boxa)
    lev.boxaDestroy(ffi.new("BOXA *[1]", boxa))
    ffi.gc(boxa, nil)
end

local function getBoxGeometry(lev, box)
    local geometry = ffi.new("l_int32[4]")
    lev.boxGetGeometry(box, geometry, geometry + 1, geometry + 2, geometry + 3)
    return tonumber(geometry[0]), tonumber(geometry[1]),
        tonumber(geometry[2]), tonumber(geometry[3])
end

local function unionComponents(components)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for _, component in ipairs(components) do
        min_x = math.min(min_x, component.x)
        min_y = math.min(min_y, component.y)
        max_x = math.max(max_x, component.x + component.w)
        max_y = math.max(max_y, component.y + component.h)
    end
    if min_x == math.huge then
        return nil
    end
    return { x0 = min_x, y0 = min_y, x1 = max_x, y1 = max_y }
end

local function overlapsBox(component, box)
    return component.x < box.x1
        and component.x + component.w > box.x0
        and component.y < box.y1
        and component.y + component.h > box.y0
end

-- Keep the dominant artwork body while dropping small disconnected satellites.
-- This is deliberately geometry-based rather than a larger global min-area
-- threshold: small lettering and fine line art *inside* the picture are kept,
-- while a page number sitting in the outer margin is ignored.
function Detector.selectArtworkBounds(components, width, height, min_area)
    if not components or #components == 0 then
        return nil, 0
    end

    local max_area = 0
    for _, component in ipairs(components) do
        max_area = math.max(max_area, component.area or (component.w * component.h))
    end

    local dominant_area = math.max((min_area or DEFAULT_MIN_AREA) * 4,
        max_area * DOMINANT_RELATIVE_AREA)
    local dominant = {}
    for _, component in ipairs(components) do
        local area = component.area or (component.w * component.h)
        if area >= dominant_area
                or component.w >= width * DOMINANT_WIDTH_FRACTION
                or component.h >= height * DOMINANT_HEIGHT_FRACTION then
            dominant[#dominant + 1] = component
        end
    end

    local core = unionComponents(dominant)
    if not core
            or core.x1 - core.x0 < width * MIN_CORE_WIDTH_FRACTION
            or core.y1 - core.y0 < height * MIN_CORE_HEIGHT_FRACTION then
        -- Unusual sparse page: retaining every valid component is safer than
        -- inventing a dominant body from insufficient evidence.
        return unionComponents(components), 0
    end

    local kept = {}
    local ignored = 0
    for _, component in ipairs(components) do
        if overlapsBox(component, core) then
            kept[#kept + 1] = component
        else
            ignored = ignored + 1
        end
    end

    -- Re-union after absorbing small components that overlap the body. Those
    -- components may extend the artwork edge slightly, but disconnected page
    -- numbers/headers cannot pull the bbox outward.
    return unionComponents(kept) or core, ignored
end

local function grayPixFromContext(kc, lev)
    local width = tonumber(kc.src.width)
    local height = tonumber(kc.src.height)
    if not width or not height or width < 16 or height < 16 then
        return nil, nil, nil, "invalid-raster"
    end

    local pix = gcPtr(
        KOPTContext.k2pdfopt.bitmap2pix(kc.src, 0, 0, width, height),
        function(ptr) pixDestroy(lev, ptr) end)
    if not pix then
        return nil, nil, nil, "bitmap2pix-failed"
    end

    local depth = tonumber(lev.pixGetDepth(pix))
    local gray
    if depth == 32 then
        gray = gcPtr(lev.pixConvertRGBToGrayFast(pix), function(ptr) pixDestroy(lev, ptr) end)
    elseif depth == 8 then
        gray = gcPtr(lev.pixClone(pix), function(ptr) pixDestroy(lev, ptr) end)
    else
        gray = gcPtr(lev.pixClone(pix), function(ptr) pixDestroy(lev, ptr) end)
    end
    if not gray then
        return nil, nil, nil, "grayscale-failed"
    end
    return gray, width, height
end

local function numaInteger(lev, numa, index)
    local value = ffi.new("l_int32[1]")
    local status = lev.numaGetIValue(numa, index, value)
    if status ~= 0 then
        return nil
    end
    return tonumber(value[0])
end

-- Build one-dimensional darkness samples from a thresholded KOPT raster and
-- hand them to the exact same sustained-boundary classifier used by EPUB.
-- axis="x" finds left/right content edges; axis="y" does the analogous work
-- for rotated pages so coordinate conversion remains correct at 90/270°.
local function projectionAxisBounds(lev, binary, width, height, axis, strip_strictness)
    local axis_length = axis == "x" and width or height
    local cross_length = axis == "x" and height or width
    local margin = math.floor(cross_length * PROJECTION_MARGIN_FRACTION)
    local clipped_cross = cross_length - 2 * margin
    if axis_length < 32 or clipped_cross < 32 then
        return nil, nil
    end

    local box
    if axis == "x" then
        box = boxCreate(lev, 0, margin, width, clipped_cross)
    else
        box = boxCreate(lev, margin, 0, clipped_cross, height)
    end
    if not box then
        return nil, nil
    end

    local clipped = gcPtr(
        lev.pixClipRectangle(binary, box, nil),
        function(ptr) pixDestroy(lev, ptr) end)
    if not clipped then
        return nil, nil
    end

    local counts
    if axis == "x" then
        counts = gcPtr(lev.pixCountPixelsByColumn(clipped), function(ptr) numaDestroy(lev, ptr) end)
    else
        counts = gcPtr(lev.pixCountPixelsByRow(clipped, nil), function(ptr) numaDestroy(lev, ptr) end)
    end
    if not counts then
        return nil, nil
    end

    local target_samples = axis == "x" and PROJECTION_X_SAMPLES or PROJECTION_Y_SAMPLES
    local step = math.max(1, math.floor(axis_length / target_samples))
    strip_strictness = math.max(50, math.min(200, tonumber(strip_strictness) or 100))
    local required_dark = math.max(3, math.floor(
        clipped_cross * PROJECTION_DARK_FRACTION * 100 / strip_strictness))
    local positions, dark_ratios, active = {}, {}, {}
    for pos = 0, axis_length - 1, step do
        local dark = numaInteger(lev, counts, pos)
        if dark == nil then
            return nil, nil
        end
        positions[#positions + 1] = pos
        dark_ratios[#dark_ratios + 1] = dark / clipped_cross
        active[#active + 1] = dark >= required_dark
    end

    if axis == "y" then
        return AutoCenter.findDominantBounds(
            positions, dark_ratios, active, axis_length, strip_strictness)
    end
    return AutoCenter.findSustainedBounds(
        positions, dark_ratios, active, axis_length, strip_strictness)
end

local function detectSustainedProjection(kc, zoom, horizontal_strictness, vertical_strictness)
    local lev = loadLeptonica()
    if not lev then
        return nil, "leptonica-unavailable"
    end

    local gray, width, height, gray_error = grayPixFromContext(kc, lev)
    if not gray then
        return nil, gray_error
    end

    -- Leptonica's pixThresholdToBinary() sets dark pixels (< threshold) to 1.
    -- Do not invert here: the projection counters should count actual ink.
    local binary = gcPtr(
        lev.pixThresholdToBinary(gray, PROJECTION_WHITE_THRESHOLD),
        function(ptr) pixDestroy(lev, ptr) end)
    if not binary then
        return nil, "threshold-failed"
    end

    local left, right = projectionAxisBounds(lev, binary, width, height, "x", horizontal_strictness)
    if not left or not right then
        return nil, "no-sustained-horizontal-body"
    end

    local top, bottom = projectionAxisBounds(lev, binary, width, height, "y", vertical_strictness)
    if not top or not bottom then
        -- Horizontal centering at normal rotation only needs x0/x1. Preserve a
        -- sane full-height range so 0/180° pages can still use the projection;
        -- 90/270° pages will naturally get no useful y correction and can fall
        -- back to the later detector if required.
        top, bottom = 0, height - 1
    end

    return {
        x0 = left / zoom,
        y0 = top / zoom,
        x1 = right / zoom,
        y1 = bottom / zoom,
        method = "sustained-projection",
    }
end

local function detectConnectedComponents(kc, options, zoom)
    local lev = loadLeptonica()
    if not lev then
        return nil, "leptonica-unavailable"
    end

    local width = tonumber(kc.src.width)
    local height = tonumber(kc.src.height)
    if not width or not height or width < 16 or height < 16 then
        return nil, "invalid-raster"
    end

    local pix = gcPtr(
        KOPTContext.k2pdfopt.bitmap2pix(kc.src, 0, 0, width, height),
        function(ptr) pixDestroy(lev, ptr) end)
    if not pix then
        return nil, "bitmap2pix-failed"
    end

    local depth = tonumber(lev.pixGetDepth(pix))
    local gray
    if depth == 32 then
        gray = gcPtr(lev.pixConvertRGBToGrayFast(pix), function(ptr) pixDestroy(lev, ptr) end)
    elseif depth == 8 then
        gray = pix
    else
        gray = gcPtr(lev.pixClone(pix), function(ptr) pixDestroy(lev, ptr) end)
    end
    if not gray then
        return nil, "grayscale-failed"
    end

    local binary = gcPtr(
        lev.pixThresholdToBinary(gray, options.threshold),
        function(ptr) pixDestroy(lev, ptr) end)
    if not binary then
        return nil, "threshold-failed"
    end

    -- Mirror Crop Enhancer's binary polarity before connected-component
    -- analysis so foreground content is what Leptonica groups into boxes.
    lev.pixInvert(binary, binary)
    local boxes = gcPtr(
        lev.pixConnCompBB(binary, 8),
        function(ptr) boxaDestroy(lev, ptr) end)
    if not boxes then
        return nil, "connected-components-failed"
    end

    local components = {}
    local count = tonumber(lev.boxaGetCount(boxes)) or 0
    for index = 0, count - 1 do
        local box = gcPtr(
            lev.boxaGetBox(boxes, index, lev.L_CLONE),
            function(ptr) boxDestroy(lev, ptr) end)
        if box then
            local x, y, w, h = getBoxGeometry(lev, box)
            local touches_edge = x <= options.border_width
                or y <= options.border_width
                or x + w >= width - options.border_width
                or y + h >= height - options.border_width
            if not touches_edge and w * h >= options.min_area then
                components[#components + 1] = {
                    x = x, y = y, w = w, h = h, area = w * h,
                }
            end
        end
    end

    if #components == 0 then
        return nil, "no-components"
    end

    local bounds, ignored = Detector.selectArtworkBounds(
        components, width, height, options.min_area)
    if not bounds then
        return nil, "no-artwork-body"
    end

    return {
        x0 = bounds.x0 / zoom,
        y0 = bounds.y0 / zoom,
        x1 = bounds.x1 / zoom,
        y1 = bounds.y1 / zoom,
        method = ignored > 0 and "leptonica-body" or "leptonica",
        ignored_satellites = ignored,
    }
end

local function fallbackAutoBBox(kc)
    local ok, x0, y0, x1, y1 = pcall(kc.getAutoBBox, kc)
    if not ok or not x0 or not y0 or not x1 or not y1 then
        return nil
    end
    return {
        x0 = tonumber(x0), y0 = tonumber(y0),
        x1 = tonumber(x1), y1 = tonumber(y1),
        method = "kopt-autobbox",
    }
end

local function saneBBox(bbox, page_w, page_h)
    if not bbox then
        return false
    end
    local x0 = math.max(0, math.min(page_w, tonumber(bbox.x0) or 0))
    local y0 = math.max(0, math.min(page_h, tonumber(bbox.y0) or 0))
    local x1 = math.max(0, math.min(page_w, tonumber(bbox.x1) or page_w))
    local y1 = math.max(0, math.min(page_h, tonumber(bbox.y1) or page_h))
    if x1 <= x0 or y1 <= y0 then
        return false
    end
    if (x1 - x0) / page_w < 0.1 and (y1 - y0) / page_h < 0.1 then
        return false
    end
    bbox.x0, bbox.y0, bbox.x1, bbox.y1 = x0, y0, x1, y1
    return true
end

function Detector.getSignature(document, pageno, horizontal_strictness, vertical_strictness)
    local native = Document.getNativePageDimensions(document, pageno)
    local full_bbox = { x0 = 0, y0 = 0, x1 = native.w, y1 = native.h }
    local hash = { "mangacenter-projection-v2" }
    local kopt = document.koptinterface
    if kopt and type(kopt.getContextHash) == "function" then
        kopt:getContextHash(document, pageno, full_bbox, hash)
    else
        table.insert(hash, document.file or "")
        table.insert(hash, document.mod_time or 0)
        table.insert(hash, pageno)
        table.insert(hash, native.w)
        table.insert(hash, native.h)
    end
    local configurable = document.configurable or {}
    table.insert(hash, configurable.crop_threshold or DEFAULT_THRESHOLD)
    table.insert(hash, configurable.crop_border_max_width or DEFAULT_BORDER_WIDTH)
    table.insert(hash, configurable.crop_min_content_area or DEFAULT_MIN_AREA)
    local horizontal = tonumber(horizontal_strictness) or 100
    local vertical = tonumber(vertical_strictness) or 100
    -- Keep the Normal signature byte-for-byte compatible with the existing
    -- plugin, so updating does not throw away good saved crop results.
    if horizontal ~= 100 or vertical ~= 100 then
        table.insert(hash, "edge-strictness")
        table.insert(hash, horizontal)
        table.insert(hash, vertical)
    end
    return table.concat(hash, "|"), native
end

function Detector.detect(document, pageno, horizontal_strictness, vertical_strictness)
    local kopt = document.koptinterface
    if not kopt or type(kopt.createContext) ~= "function"
            or not document._document or type(document._document.openPage) ~= "function" then
        return nil, "kopt-unavailable"
    end

    local native = Document.getNativePageDimensions(document, pageno)
    if not native or not native.w or not native.h or native.w <= 0 or native.h <= 0 then
        return nil, "invalid-page-size"
    end

    local full_bbox = { x0 = 0, y0 = 0, x1 = native.w, y1 = native.h }
    local longest = math.max(native.w, native.h)
    local zoom = longest > TARGET_LONG_EDGE and TARGET_LONG_EDGE / longest or 1.0
    local kc = kopt:createContext(document, pageno, full_bbox)
    if not kc then
        return nil, "context-failed"
    end
    kc:setZoom(zoom)

    local page
    local ok, err = pcall(function()
        page = document._document:openPage(pageno)
        page:getPagePix(kc, document.render_mode, (document.configurable and document.configurable.background_cleanup) or 0)
    end)
    if page then
        pcall(page.close, page)
    end
    if not ok then
        pcall(kc.free, kc)
        return nil, "page-raster-failed:" .. tostring(err)
    end

    local bbox
    local projection_ok, projection_result, projection_error = pcall(
        detectSustainedProjection, kc, zoom, horizontal_strictness, vertical_strictness)
    if projection_ok then
        bbox = projection_result
    else
        projection_error = projection_result
    end

    local fallback_error
    if not saneBBox(bbox, native.w, native.h) then
        local options = detectorOptions(document, zoom)
        local connected_ok, connected_result, connected_error = pcall(
            detectConnectedComponents, kc, options, zoom)
        if connected_ok then
            bbox = connected_result
            fallback_error = connected_error
        else
            fallback_error = connected_result
        end
    end
    if not saneBBox(bbox, native.w, native.h) then
        bbox = fallbackAutoBBox(kc)
    end
    pcall(kc.free, kc)

    if not saneBBox(bbox, native.w, native.h) then
        return nil, projection_error or fallback_error or "no-content-bbox"
    end

    bbox.page_w = native.w
    bbox.page_h = native.h
    return bbox
end


-- Panel-aware page-down detector -------------------------------------------------
-- Korean webtoons commonly use a dark horizontal rule as the structural start/end
-- of a panel. The rule is only an anchor: speech bubbles and caption boxes may
-- protrude above it. Detection therefore has two distinct jobs:
--   1. find the structural horizontal rule without letting one detector suppress
--      another; and
--   2. move the effective start upward only for a *single substantial object that
--      actually touches/crosses that rule*.
--
-- The second point matters: the older v1.7.1 row-activity scan could walk through
-- several bits of text in a separator and accidentally join two panels together.
local PANEL_BLACK_THRESHOLD = 118
local PANEL_INK_THRESHOLD = 218
local PANEL_MIN_BLACK_FRACTION = 0.20
local PANEL_LINE_COMPONENT_MIN_WIDTH_FRACTION = 0.065
local PANEL_LINE_GROUP_MIN_COVERAGE_FRACTION = 0.115
local PANEL_LINE_COMPONENT_MIN_ASPECT = 4.5
local PANEL_LINE_GROUP_Y_TOLERANCE_VIEWPORT = 0.007
local PANEL_MAX_LINE_HEIGHT_VIEWPORT = 0.025
local PANEL_MERGE_DISTANCE_VIEWPORT = 0.012
local PANEL_DARK_GUTTER_FRACTION = 0.86
local PANEL_DARK_GUTTER_MIN_VIEWPORT = 0.025
local PANEL_PROTRUSION_MAX_UP_VIEWPORT = 0.42
local PANEL_PROTRUSION_TOUCH_GAP_VIEWPORT = 0.025
local PANEL_PROTRUSION_MIN_WIDTH_FRACTION = 0.08
local PANEL_PROTRUSION_MIN_HEIGHT_VIEWPORT = 0.018
local PANEL_PROTRUSION_MAX_HEIGHT_VIEWPORT = 0.30
local PANEL_PROTRUSION_MAX_WIDTH_FRACTION = 0.92
local PANEL_PROTRUSION_MAX_BELOW_VIEWPORT = 0.08
local PANEL_SAFETY_MARGIN_VIEWPORT = 0.008
local PANEL_END_WINDOW_VIEWPORT = 0.18
local PANEL_END_GAP_VIEWPORT = 0.012
local PANEL_TARGET_WIDTH = 700
local PANEL_MAX_RASTER_HEIGHT = 6000

local function collectRowCounts(lev, gray, threshold, height)
    local binary = gcPtr(
        lev.pixThresholdToBinary(gray, threshold),
        function(ptr) pixDestroy(lev, ptr) end)
    if not binary then return nil end
    local rows = gcPtr(
        lev.pixCountPixelsByRow(binary, nil),
        function(ptr) numaDestroy(lev, ptr) end)
    if not rows then return nil end
    local counts = {}
    for y = 0, height - 1 do
        counts[y + 1] = numaInteger(lev, rows, y) or 0
    end
    return counts
end

local function unionHorizontalCoverage(segments)
    if not segments or #segments == 0 then return 0 end
    table.sort(segments, function(a, b) return a.x0 < b.x0 end)
    local coverage = 0
    local x0, x1 = segments[1].x0, segments[1].x1
    for index = 2, #segments do
        local segment = segments[index]
        if segment.x0 <= x1 + 2 then
            x1 = math.max(x1, segment.x1)
        else
            coverage = coverage + math.max(0, x1 - x0)
            x0, x1 = segment.x0, segment.x1
        end
    end
    return coverage + math.max(0, x1 - x0)
end

-- Convert wide/thin dark connected components into structural horizontal-rule
-- candidates. Korean-webtoon panel rules are often partial-width or interrupted,
-- so aligned fragments are grouped before their horizontal coverage is tested.
-- Text normally breaks into many small components, while speech-bubble outlines
-- tend to be too tall/curved to survive the wide+thin aspect filter.
function Detector.findPanelLineCandidatesFromComponents(components, width, viewport_h)
    width = tonumber(width) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or 0)
    if width < 16 or not components then return {} end

    local max_h = math.max(3, math.floor(viewport_h * PANEL_MAX_LINE_HEIGHT_VIEWPORT + 0.5))
    local min_w = math.max(8, width * PANEL_LINE_COMPONENT_MIN_WIDTH_FRACTION)
    local y_tol = math.max(2, math.floor(viewport_h * PANEL_LINE_GROUP_Y_TOLERANCE_VIEWPORT + 0.5))
    local line_like = {}
    for _, component in ipairs(components) do
        local w = tonumber(component.w) or 0
        local h = tonumber(component.h) or 0
        if w >= min_w and h >= 1 and h <= max_h
                and w / h >= PANEL_LINE_COMPONENT_MIN_ASPECT then
            line_like[#line_like + 1] = {
                x0 = tonumber(component.x) or 0,
                x1 = (tonumber(component.x) or 0) + w,
                y = (tonumber(component.y) or 0) + h / 2,
                w = w,
                h = h,
            }
        end
    end
    table.sort(line_like, function(a, b)
        if a.y == b.y then return a.x0 < b.x0 end
        return a.y < b.y
    end)

    local groups = {}
    for _, component in ipairs(line_like) do
        local group = groups[#groups]
        if not group or math.abs(component.y - group.mean_y) > y_tol then
            group = { segments = {}, weighted_y = 0, weight = 0, mean_y = component.y }
            groups[#groups + 1] = group
        end
        group.segments[#group.segments + 1] = { x0 = component.x0, x1 = component.x1 }
        group.weighted_y = group.weighted_y + component.y * component.w
        group.weight = group.weight + component.w
        group.mean_y = group.weighted_y / math.max(1, group.weight)
    end

    local candidates = {}
    local min_coverage = width * PANEL_LINE_GROUP_MIN_COVERAGE_FRACTION
    for _, group in ipairs(groups) do
        local coverage = unionHorizontalCoverage(group.segments)
        if coverage >= min_coverage then
            candidates[#candidates + 1] = {
                y = math.floor(group.mean_y + 0.5),
                score = math.min(1, coverage / width),
                kind = "component",
            }
        end
    end
    return candidates
end

local function collectDarkComponents(lev, gray)
    local binary = gcPtr(
        lev.pixThresholdToBinary(gray, PANEL_BLACK_THRESHOLD),
        function(ptr) pixDestroy(lev, ptr) end)
    if not binary then return nil end
    lev.pixInvert(binary, binary)
    local boxes = gcPtr(
        lev.pixConnCompBB(binary, 8),
        function(ptr) boxaDestroy(lev, ptr) end)
    if not boxes then return nil end
    local components = {}
    local count = tonumber(lev.boxaGetCount(boxes)) or 0
    for index = 0, count - 1 do
        local box = gcPtr(
            lev.boxaGetBox(boxes, index, lev.L_CLONE),
            function(ptr) boxDestroy(lev, ptr) end)
        if box then
            local x, y, w, h = getBoxGeometry(lev, box)
            components[#components + 1] = { x = x, y = y, w = w, h = h }
        end
    end
    return components
end

local function rowStd(counts, first_y, last_y, width)
    first_y = math.max(0, math.floor(first_y))
    last_y = math.min(#counts - 1, math.floor(last_y))
    if last_y < first_y or width <= 0 then return nil end
    local n, sum, sumsq = 0, 0, 0
    for y = first_y, last_y do
        local value = (counts[y + 1] or 0) / width
        n = n + 1
        sum = sum + value
        sumsq = sumsq + value * value
    end
    if n < 8 then return nil end
    local mean = sum / n
    return math.sqrt(math.max(0, sumsq / n - mean * mean))
end

local function rowRegionStats(black_counts, ink_counts, first_y, last_y, width)
    first_y = math.max(0, math.floor(first_y))
    last_y = math.min(#black_counts - 1, math.floor(last_y))
    if last_y < first_y or width <= 0 or last_y - first_y + 1 < 8 then return nil end
    local black_values, ink_values = {}, {}
    local black_sum, black_sumsq = 0, 0
    local ink_sum, ink_sumsq = 0, 0
    for y = first_y, last_y do
        local black = (black_counts[y + 1] or 0) / width
        local ink = (ink_counts[y + 1] or 0) / width
        black_values[#black_values + 1] = black
        ink_values[#ink_values + 1] = ink
        black_sum = black_sum + black
        black_sumsq = black_sumsq + black * black
        ink_sum = ink_sum + ink
        ink_sumsq = ink_sumsq + ink * ink
    end
    table.sort(black_values)
    table.sort(ink_values)
    local n = #black_values
    local middle = math.floor((n + 1) / 2)
    local black_median, ink_median
    if n % 2 == 0 then
        black_median = (black_values[n / 2] + black_values[n / 2 + 1]) / 2
        ink_median = (ink_values[n / 2] + ink_values[n / 2 + 1]) / 2
    else
        black_median = black_values[middle]
        ink_median = ink_values[middle]
    end
    local black_mean = black_sum / n
    local ink_mean = ink_sum / n
    return {
        black_median = black_median,
        ink_median = ink_median,
        black_std = math.sqrt(math.max(0, black_sumsq / n - black_mean * black_mean)),
        ink_std = math.sqrt(math.max(0, ink_sumsq / n - ink_mean * ink_mean)),
    }
end

local function isSeparatorLikeRegion(stats)
    if not stats then return false end
    -- Sparse text on a flat light/gray/colored background may cause a few busy
    -- rows, so median occupancy is more useful than demanding pure whitespace.
    local uniform_light = stats.black_median < 0.018
        and (stats.ink_median < 0.12 or stats.ink_median > 0.88)
    local low_texture = stats.black_std < 0.018 and stats.ink_std < 0.025
    return uniform_light or low_texture
end

-- This is intentionally a *very* conservative direction filter. It only rejects
-- an unmistakable artwork -> flat separator transition. Ambiguous borders remain
-- candidates, because dropping a true panel start is worse than falling back to
-- the ordinary overlap once in a while.
function Detector.isObviousPanelEnd(line_y, black_counts, ink_counts, width, height, viewport_h)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or height)
    if width <= 0 or height <= 0 then return false end
    local gap = math.max(4, math.floor(viewport_h * PANEL_END_GAP_VIEWPORT + 0.5))
    local window = math.max(24, math.floor(viewport_h * PANEL_END_WINDOW_VIEWPORT + 0.5))
    local y = math.floor(tonumber(line_y) or 0)
    local pre_ink = rowStd(ink_counts, y - gap - window, y - gap - 1, width)
    local post_ink = rowStd(ink_counts, y + gap, y + gap + window - 1, width)
    local pre_black = rowStd(black_counts, y - gap - window, y - gap - 1, width)
    local post_black = rowStd(black_counts, y + gap, y + gap + window - 1, width)
    if not pre_ink or not post_ink or not pre_black or not post_black then return false end
    local flat_after = post_ink < 0.022 and post_black < 0.018
    return flat_after
        and (pre_ink > post_ink + 0.055 or pre_black > post_black + 0.045)
end

-- Classify a structural horizontal rule by the texture transition around it.
-- A separator may be white, gray, colored, or black and may contain sparse text;
-- what makes it separator-like is its low row-to-row texture compared with
-- artwork. This lets us keep both sides of a separator as navigation anchors:
-- artwork -> separator is a panel END, separator -> artwork is a panel START.
-- A line with flat regions on both sides is usually a caption/narration box
-- inside the separator and is deliberately ignored.
function Detector.classifyPanelBoundary(line_y, black_counts, ink_counts, width, height, viewport_h, score)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or height)
    if width <= 0 or height <= 0 then return nil end
    local gap = math.max(4, math.floor(viewport_h * PANEL_END_GAP_VIEWPORT + 0.5))
    local window = math.max(24, math.floor(viewport_h * PANEL_END_WINDOW_VIEWPORT + 0.5))
    local y = math.floor(tonumber(line_y) or 0)
    local before = rowRegionStats(black_counts, ink_counts,
        y - gap - window, y - gap - 1, width)
    local after = rowRegionStats(black_counts, ink_counts,
        y + gap, y + gap + window - 1, width)
    if not before or not after then return nil end

    local before_separator = isSeparatorLikeRegion(before)
    local after_separator = isSeparatorLikeRegion(after)
    if not before_separator and after_separator then
        return "end"
    elseif before_separator and not after_separator then
        return "start"
    elseif before_separator and after_separator then
        -- Caption/narration-box edges inside a separator are not panel anchors.
        return nil
    end

    -- Both sides are artwork-like. Only a particularly strong structural rule
    -- is allowed to represent a direct panel-to-panel transition. This is much
    -- less eager than v1.7.x and avoids turning ordinary lines inside artwork
    -- into tiny page-down snaps.
    if (tonumber(score) or 0) >= 0.72 then return "start" end
    return nil
end

-- Expand a structural panel line upward only when a substantial dark component
-- actually touches/crosses the line (or ends just above it). This captures a
-- square/circular speech bubble or narration box protruding above the border,
-- but it does NOT chain through unrelated text elsewhere in the separator.
function Detector.expandPanelStartForProtrusions(line_y, components, width, height, viewport_h)
    line_y = math.floor(tonumber(line_y) or 0)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or height)
    if line_y <= 0 or width <= 0 or height <= 0 or not components then return line_y end

    local max_up = math.max(25, math.floor(viewport_h * PANEL_PROTRUSION_MAX_UP_VIEWPORT + 0.5))
    local touch_gap = math.max(5, math.floor(viewport_h * PANEL_PROTRUSION_TOUCH_GAP_VIEWPORT + 0.5))
    local min_w = math.max(18, width * PANEL_PROTRUSION_MIN_WIDTH_FRACTION)
    local min_h = math.max(8, math.floor(viewport_h * PANEL_PROTRUSION_MIN_HEIGHT_VIEWPORT + 0.5))
    local max_h = math.max(min_h + 1,
        math.floor(viewport_h * PANEL_PROTRUSION_MAX_HEIGHT_VIEWPORT + 0.5))
    local max_w = width * PANEL_PROTRUSION_MAX_WIDTH_FRACTION
    local max_below = math.max(8,
        math.floor(viewport_h * PANEL_PROTRUSION_MAX_BELOW_VIEWPORT + 0.5))
    local safety = math.max(2, math.floor(viewport_h * PANEL_SAFETY_MARGIN_VIEWPORT + 0.5))
    local min_y = math.max(0, line_y - max_up)
    local top = line_y

    for _, component in ipairs(components) do
        local x = tonumber(component.x) or 0
        local y = tonumber(component.y) or 0
        local w = tonumber(component.w) or 0
        local h = tonumber(component.h) or 0
        local bottom = y + h
        if w >= min_w and w <= max_w and h >= min_h and h <= max_h
                and y < line_y and y >= min_y
                and bottom >= line_y - touch_gap
                and bottom <= line_y + max_below then
            -- Ignore degenerate off-page boxes while otherwise allowing partial-
            -- width bubbles: horizontal position is deliberately unrestricted.
            if x + w > 0 and x < width then
                top = math.min(top, y)
            end
        end
    end

    if top < line_y then
        return math.max(0, top - safety)
    end
    return line_y
end

-- Narration/caption boxes in Korean webtoons can have long black top/bottom
-- borders that look exactly like panel rules in a one-dimensional projection.
-- A reliable clue is a moderately tall, wide connected rectangle whose top AND
-- bottom both coincide with rule candidates. Once identified, suppress rule
-- candidates throughout that box (plus a small margin), so its text and SFX are
-- treated as readable separator content rather than fake panels.
function Detector.markCaptionBoxCandidates(candidates, components, width, viewport_h)
    width = tonumber(width) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or 0)
    if not candidates or not components or width <= 0 then return candidates or {} end
    local tolerance = math.max(3, math.floor(viewport_h * 0.012 + 0.5))
    local margin = math.max(6, math.floor(viewport_h * 0.05 + 0.5))
    local min_w = width * 0.35
    local min_h = math.max(18, math.floor(viewport_h * 0.035 + 0.5))
    local max_h = math.max(min_h + 1, math.floor(viewport_h * 0.46 + 0.5))
    local ranges = {}

    for _, component in ipairs(components) do
        local x = tonumber(component.x) or 0
        local y = tonumber(component.y) or 0
        local w = tonumber(component.w) or 0
        local h = tonumber(component.h) or 0
        if w >= min_w and h >= min_h and h <= max_h and w / math.max(1, h) >= 1.2
                and x + w > 0 and x < width then
            local bottom = y + h - 1
            local top_rule, bottom_rule = false, false
            for _, candidate in ipairs(candidates) do
                if candidate.kind ~= "gutter_end" and candidate.kind ~= "gutter_start" then
                    if math.abs(candidate.y - y) <= tolerance then top_rule = true end
                    if math.abs(candidate.y - bottom) <= tolerance then bottom_rule = true end
                end
            end
            if top_rule and bottom_rule then
                ranges[#ranges + 1] = { y0 = y - margin, y1 = bottom + margin }
            end
        end
    end

    for _, candidate in ipairs(candidates) do
        if candidate.kind ~= "gutter_end" and candidate.kind ~= "gutter_start" then
            for _, range in ipairs(ranges) do
                if candidate.y >= range.y0 and candidate.y <= range.y1 then
                    candidate.caption_box = true
                    break
                end
            end
        end
    end
    return candidates
end

-- Pure helper used by specs as well as the raster path below.
function Detector.findPanelAnchorsFromRows(black_counts, ink_counts, width, height, viewport_h, line_candidates, components)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    viewport_h = math.max(32, tonumber(viewport_h) or height)
    if width < 16 or height < 16 then return {} end
    local min_black = math.max(8, width * PANEL_MIN_BLACK_FRACTION)
    local max_line_h = math.max(3, math.floor(viewport_h * PANEL_MAX_LINE_HEIGHT_VIEWPORT + 0.5))
    local candidates = {}

    -- Structural components and row projection are complementary. Always combine
    -- both sources; a candidate in one part of a page must never suppress a real
    -- panel rule elsewhere.
    for _, candidate in ipairs(line_candidates or {}) do
        candidates[#candidates + 1] = {
            y = candidate.y,
            score = candidate.score or 0,
            kind = candidate.kind or "component",
        }
    end

    local y = 1
    while y <= height do
        if (black_counts[y] or 0) >= min_black then
            local y0, y1, peak = y - 1, y - 1, black_counts[y] or 0
            local gap = 0
            y = y + 1
            while y <= height do
                local count = black_counts[y] or 0
                if count >= min_black then
                    y1 = y - 1
                    peak = math.max(peak, count)
                    gap = 0
                else
                    gap = gap + 1
                    if gap > 1 then break end
                end
                y = y + 1
            end
            local band_h = y1 - y0 + 1
            if band_h <= max_line_h and peak >= min_black then
                candidates[#candidates + 1] = {
                    y = math.floor((y0 + y1) / 2 + 0.5),
                    score = peak / width,
                    kind = "row",
                }
            end
        else
            y = y + 1
        end
    end

    -- Broad black gutters are separator regions too. Preserve BOTH edges: the
    -- top is the previous panel's END (show the gutter/text first), while the
    -- bottom is the next panel's START.
    local solid_black = width * PANEL_DARK_GUTTER_FRACTION
    local min_gutter_h = math.max(10,
        math.floor(viewport_h * PANEL_DARK_GUTTER_MIN_VIEWPORT + 0.5))
    y = 1
    while y <= height do
        if (black_counts[y] or 0) >= solid_black then
            local run_start = y
            while y <= height and (black_counts[y] or 0) >= solid_black do
                y = y + 1
            end
            if y - run_start >= min_gutter_h then
                if run_start > 1 then
                    candidates[#candidates + 1] = {
                        y = run_start - 1,
                        score = 1.25,
                        kind = "gutter_end",
                    }
                end
                if y <= height then
                    candidates[#candidates + 1] = {
                        y = y - 1,
                        score = 1.25,
                        kind = "gutter_start",
                    }
                end
            end
        else
            y = y + 1
        end
    end

    Detector.markCaptionBoxCandidates(candidates, components, width, viewport_h)
    table.sort(candidates, function(a, b)
        if a.y == b.y then return (a.score or 0) > (b.score or 0) end
        return a.y < b.y
    end)

    -- Classify BEFORE merging. Nearby END and START anchors may represent a
    -- genuinely short separator and must both survive; only duplicate anchors of
    -- the same kind are merged.
    local classified = {}
    for _, candidate in ipairs(candidates) do
        if candidate.y > 3 and candidate.y < height - 3 and not candidate.caption_box then
            local boundary_kind
            if candidate.kind == "gutter_end" then
                boundary_kind = "end"
            elseif candidate.kind == "gutter_start" then
                boundary_kind = "start"
            else
                boundary_kind = Detector.classifyPanelBoundary(
                    candidate.y, black_counts, ink_counts,
                    width, height, viewport_h, candidate.score)
            end
            if boundary_kind then
                candidate.boundary_kind = boundary_kind
                classified[#classified + 1] = candidate
            end
        end
    end

    local merge_dist = math.max(4, math.floor(viewport_h * 0.025 + 0.5))
    local merged = {}
    for _, candidate in ipairs(classified) do
        local previous = merged[#merged]
        if previous and candidate.boundary_kind == previous.boundary_kind
                and candidate.y - previous.y <= merge_dist then
            if candidate.boundary_kind == "end" then
                -- For an end cluster, the lowest rule is closest to the actual
                -- separator and is the useful reading anchor.
                merged[#merged] = candidate
            elseif candidate.kind == "gutter_start" and previous.kind ~= "gutter_start" then
                merged[#merged] = candidate
            end
            -- For ordinary START clusters keep the earliest rule.
        else
            merged[#merged + 1] = candidate
        end
    end

    local anchors = {}
    for _, candidate in ipairs(merged) do
        local anchor_y = candidate.y
        if candidate.boundary_kind == "start" then
            anchor_y = Detector.expandPanelStartForProtrusions(
                candidate.y, components, width, height, viewport_h)
        end
        anchors[#anchors + 1] = {
            y = anchor_y,
            structural_y = candidate.y,
            kind = candidate.boundary_kind,
        }
    end
    table.sort(anchors, function(a, b)
        if a.y == b.y then return a.kind == "end" and b.kind ~= "end" end
        return a.y < b.y
    end)
    return anchors
end

-- Backward-compatible helper retained for tests/older callers that only want
-- panel starts.
function Detector.findPanelStartsFromRows(black_counts, ink_counts, width, height, viewport_h, line_candidates, components)
    local starts = {}
    for _, anchor in ipairs(Detector.findPanelAnchorsFromRows(
            black_counts, ink_counts, width, height, viewport_h, line_candidates, components)) do
        if anchor.kind == "start" then starts[#starts + 1] = anchor.y end
    end
    return starts
end

function Detector.detectPanelAnchors(document, pageno, viewport_native_height)
    local kopt = document.koptinterface
    if not kopt or type(kopt.createContext) ~= "function"
            or not document._document or type(document._document.openPage) ~= "function" then
        return nil, "kopt-unavailable"
    end
    local native = Document.getNativePageDimensions(document, pageno)
    if not native or not native.w or not native.h or native.w <= 0 or native.h <= 0 then
        return nil, "invalid-page-size"
    end
    local zoom = math.min(1.0,
        PANEL_TARGET_WIDTH / native.w,
        PANEL_MAX_RASTER_HEIGHT / native.h)
    if zoom <= 0 then return nil, "invalid-zoom" end
    local full_bbox = { x0 = 0, y0 = 0, x1 = native.w, y1 = native.h }
    local kc = kopt:createContext(document, pageno, full_bbox)
    if not kc then return nil, "context-failed" end
    kc:setZoom(zoom)

    local page
    local ok, err = pcall(function()
        page = document._document:openPage(pageno)
        page:getPagePix(kc, document.render_mode,
            (document.configurable and document.configurable.background_cleanup) or 0)
    end)
    if page then pcall(page.close, page) end
    if not ok then
        pcall(kc.free, kc)
        return nil, "page-raster-failed:" .. tostring(err)
    end

    local lev = loadLeptonica()
    if not lev then pcall(kc.free, kc); return nil, "leptonica-unavailable" end
    local gray, width, height, gray_error = grayPixFromContext(kc, lev)
    if not gray then pcall(kc.free, kc); return nil, gray_error end
    local black = collectRowCounts(lev, gray, PANEL_BLACK_THRESHOLD, height)
    local ink = collectRowCounts(lev, gray, PANEL_INK_THRESHOLD, height)
    local dark_components = collectDarkComponents(lev, gray)
    pcall(kc.free, kc)
    if not black or not ink then return nil, "row-projection-failed" end

    local viewport_raster_h = math.max(32,
        (tonumber(viewport_native_height) or native.h) * zoom)
    local line_candidates = Detector.findPanelLineCandidatesFromComponents(
        dark_components, width, viewport_raster_h)
    local raster_anchors = Detector.findPanelAnchorsFromRows(
        black, ink, width, height, viewport_raster_h, line_candidates, dark_components)
    local anchors = {}
    for _, anchor in ipairs(raster_anchors) do
        anchors[#anchors + 1] = {
            y = anchor.y / zoom,
            structural_y = anchor.structural_y and anchor.structural_y / zoom or nil,
            kind = anchor.kind,
        }
    end
    return anchors
end

function Detector.detectPanelStarts(document, pageno, viewport_native_height)
    local anchors, err = Detector.detectPanelAnchors(document, pageno, viewport_native_height)
    if not anchors then return nil, err end
    local starts = {}
    for _, anchor in ipairs(anchors) do
        if anchor.kind == "start" then starts[#starts + 1] = anchor.y end
    end
    return starts
end

return Detector
