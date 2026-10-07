local DataStorage = require("datastorage")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MangaCenterAutoCenter = require("mangacenter_autocenter")
local MangaCenterCSS = require("mangacenter_css")
local MangaCenterZoom = require("mangacenter_zoom")
local MangaCenterPagingDetector
local _ = require("mangacenter_i18n")
local T = FFIUtil.template

local function getPagingDetector()
    if not MangaCenterPagingDetector then
        MangaCenterPagingDetector = require("mangacenter_paging_detector")
    end
    return MangaCenterPagingDetector
end

local KEY_ENABLED = "manga_center_enabled"
local KEY_MODE = "manga_center_mode"
local KEY_SHIFT = "manga_center_shift_vw"
local KEY_AUTO_CENTER = "manga_center_auto_center"
local KEY_VERTICAL_FIT = "manga_center_vertical_fit"
local KEY_HORIZONTAL_STRIP_STRICTNESS = "manga_center_horizontal_strip_strictness"
local KEY_VERTICAL_STRIP_STRICTNESS = "manga_center_vertical_strip_strictness"
local KEY_AUTO_OFFSETS = "manga_center_auto_offsets" -- legacy/rolling EPUB offsets
local KEY_CROP_BOUNDS = "manga_center_crop_bounds_v1"
local CROP_FLUSH_DELAY = 2.0
local KEY_CONTINUOUS_WIDTH = "manga_center_continuous_width_percent"
local KEY_CONTINUOUS_OVERLAP = "manga_center_continuous_overlap_percent"
local KEY_PANEL_AWARE_PAGING = "manga_center_panel_aware_paging"
local KEY_ON_RELEASE_MULTIPLIER = "manga_center_on_release_scroll_multiplier"
local Screen = Device.screen
local PAGING_EXTENSIONS = {
    cbr = true,
    cbt = true,
    cbz = true,
    djv = true,
    djvu = true,
    pdf = true,
}

-- User-facing presets deliberately hide the detector's individual thresholds.
-- 100 is exactly the historical behavior. Higher values are more conservative
-- (crop less); lower values are more aggressive (crop more).
local STRIP_STRICTNESS_PRESETS = {
    { key = "very_loose", value = 50, label = "Very loose" },
    { key = "loose", value = 75, label = "Loose" },
    { key = "normal", value = 100, label = "Normal" },
    { key = "strict", value = 140, label = "Strict" },
    { key = "very_strict", value = 200, label = "Very strict" },
}
local STRIP_STRICTNESS_VALUES = {}
local STRIP_STRICTNESS_LABELS = {}
for _, preset in ipairs(STRIP_STRICTNESS_PRESETS) do
    STRIP_STRICTNESS_VALUES[preset.key] = preset.value
    STRIP_STRICTNESS_LABELS[preset.key] = preset.label
end

local function normalizeStripStrictnessPreset(value)
    if STRIP_STRICTNESS_VALUES[value] then
        return value
    end
    local numeric = tonumber(value)
    if numeric then
        local best_key, best_distance = "normal", math.huge
        for _, preset in ipairs(STRIP_STRICTNESS_PRESETS) do
            local distance = math.abs(numeric - preset.value)
            if distance < best_distance then
                best_key, best_distance = preset.key, distance
            end
        end
        return best_key
    end
    return "normal"
end

local function isNativeCropZoomMode(mode)
    return mode == "page" or mode == "content"
        or mode == "pagewidth" or mode == "contentwidth"
        or mode == "pageheight" or mode == "contentheight"
end

local MangaCenter = WidgetContainer:extend{
    name = "mangacenter",
    -- Load once in File Manager so bundled tweaks are copied before the first
    -- ReaderStyleTweak instance scans the user's styletweaks directory.
    is_doc_only = false,
    enabled = false,
    auto_center = false,
    vertical_fit = false,
    horizontal_strip_strictness = "normal",
    vertical_strip_strictness = "normal",
    auto_offsets = nil,
    crop_bounds = nil,
    mode = "constant",
    shift = 0,
    continuous_width = 100,
    continuous_overlap = nil, -- nil = KOReader native DOVERLAPPIXELS
    panel_aware_paging = false,
    on_release_scroll_multiplier = 1,
    panel_anchors = nil,
    _paging_crop_runtime_ready = false,
    _paging_aux_runtime_ready = false,
    _deferred_paging_setup_task = nil,
    _crop_flush_task = nil,
    _crop_bounds_dirty = false,
    _reader_ready = false,
}

function MangaCenter:installBundledStyleTweaks()
    local source_dir = self.path .. "/styletweaks"
    local user_tweaks_dir = DataStorage:getDataDir() .. "/styletweaks"
    local destination_dir = user_tweaks_dir .. "/Manga_page_shift"

    for _, directory in ipairs({ user_tweaks_dir, destination_dir }) do
        if lfs.attributes(directory, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(directory)
            if not ok then
                logger.warn("MangaCenter: cannot create style tweak directory", directory, err)
                return
            end
        end
    end

    for _, filename in ipairs({
        "manga-center-constant.css",
        "manga-center-alternating.css",
    }) do
        local source = source_dir .. "/" .. filename
        local destination = destination_dir .. "/" .. filename
        if lfs.attributes(destination, "mode") ~= "file" then
            local copy_error = FFIUtil.copyFile(source, destination)
            if copy_error ~= nil then
                logger.warn("MangaCenter: cannot install bundled style tweak", source, destination, copy_error)
            end
        end
    end
end

function MangaCenter:isRollingDocument()
    local document = self.ui and self.ui.document
    return document ~= nil
        and self.ui.styletweak ~= nil
        and self.ui.typeset ~= nil
end

function MangaCenter:isPagingDocument()
    local document = self.ui and self.ui.document
    if not document or not self.ui.paging then
        return false
    end
    local extension = util.getFileNameSuffix(document.file or "")
    return extension ~= nil and PAGING_EXTENSIONS[extension:lower()] == true
end

function MangaCenter:isSupportedDocument()
    return self:isRollingDocument() or self:isPagingDocument()
end

function MangaCenter:loadSettings()
    local settings = self.ui.doc_settings
    self.enabled = settings:isTrue(KEY_ENABLED)
    self.auto_center = settings:isTrue(KEY_AUTO_CENTER)
    self.vertical_fit = settings:isTrue(KEY_VERTICAL_FIT)
    self.horizontal_strip_strictness = normalizeStripStrictnessPreset(
        settings:readSetting(KEY_HORIZONTAL_STRIP_STRICTNESS))
    self.vertical_strip_strictness = normalizeStripStrictnessPreset(
        settings:readSetting(KEY_VERTICAL_STRIP_STRICTNESS))

    -- Rolling/EPUB keeps the original horizontal-offset store. Paging formats
    -- use a dedicated persistent crop-bounds table so detected x0/y0/x1/y1
    -- survives KOReader restarts independently of the rendered-page cache.
    self.auto_offsets = settings:readSetting(KEY_AUTO_OFFSETS)
    if type(self.auto_offsets) ~= "table" then
        self.auto_offsets = {}
    end
    self.crop_bounds = settings:readSetting(KEY_CROP_BOUNDS)
    if type(self.crop_bounds) ~= "table" then
        self.crop_bounds = {}
        if self:isPagingDocument() then
            -- v6 and earlier stored paging detector records in the historical
            -- auto_offsets table. Migrate table-valued records only; obsolete
            -- cache-version keys simply won't match future lookups.
            local migrated = false
            for key, value in pairs(self.auto_offsets) do
                if type(value) == "table" then
                    self.crop_bounds[key] = value
                    migrated = true
                end
            end
            if migrated then
                self._crop_bounds_dirty = true
            end
        end
    end
    self.mode = settings:readSetting(KEY_MODE) == "alternating" and "alternating" or "constant"
    self.shift = tonumber(settings:readSetting(KEY_SHIFT)) or 0
    self.continuous_width = MangaCenterZoom.normalizePercent(
        settings:readSetting(KEY_CONTINUOUS_WIDTH))
    local overlap = settings:readSetting(KEY_CONTINUOUS_OVERLAP)
    self.continuous_overlap = overlap ~= nil
        and MangaCenterZoom.normalizeOverlapPercent(overlap) or nil
    self.panel_aware_paging = settings:isTrue(KEY_PANEL_AWARE_PAGING)
    self.on_release_scroll_multiplier = MangaCenterZoom.normalizeScrollMultiplier(
        settings:readSetting(KEY_ON_RELEASE_MULTIPLIER))
    self.panel_anchors = {}
end

function MangaCenter:saveSettings()
    local settings = self.ui.doc_settings
    if self.enabled then
        settings:makeTrue(KEY_ENABLED)
    else
        settings:delSetting(KEY_ENABLED)
    end
    settings:saveSetting(KEY_MODE, self.mode)
    settings:saveSetting(KEY_SHIFT, self.shift)
    if self.continuous_width ~= 100 then
        settings:saveSetting(KEY_CONTINUOUS_WIDTH, self.continuous_width)
    else
        settings:delSetting(KEY_CONTINUOUS_WIDTH)
    end
    if self.continuous_overlap ~= nil then
        settings:saveSetting(KEY_CONTINUOUS_OVERLAP, self.continuous_overlap)
    else
        settings:delSetting(KEY_CONTINUOUS_OVERLAP)
    end
    if self.panel_aware_paging then
        settings:makeTrue(KEY_PANEL_AWARE_PAGING)
    else
        settings:delSetting(KEY_PANEL_AWARE_PAGING)
    end
    if math.abs(self.on_release_scroll_multiplier - 1) > 0.0001 then
        settings:saveSetting(KEY_ON_RELEASE_MULTIPLIER, self.on_release_scroll_multiplier)
    else
        settings:delSetting(KEY_ON_RELEASE_MULTIPLIER)
    end
    if self.auto_center then
        settings:makeTrue(KEY_AUTO_CENTER)
    else
        settings:delSetting(KEY_AUTO_CENTER)
    end
    if self.vertical_fit then
        settings:makeTrue(KEY_VERTICAL_FIT)
    else
        settings:delSetting(KEY_VERTICAL_FIT)
    end
    if self.horizontal_strip_strictness ~= "normal" then
        settings:saveSetting(KEY_HORIZONTAL_STRIP_STRICTNESS, self.horizontal_strip_strictness)
    else
        settings:delSetting(KEY_HORIZONTAL_STRIP_STRICTNESS)
    end
    if self.vertical_strip_strictness ~= "normal" then
        settings:saveSetting(KEY_VERTICAL_STRIP_STRICTNESS, self.vertical_strip_strictness)
    else
        settings:delSetting(KEY_VERTICAL_STRIP_STRICTNESS)
    end
    if self:isPagingDocument() then
        if next(self.crop_bounds or {}) then
            settings:saveSetting(KEY_CROP_BOUNDS, self.crop_bounds)
        else
            settings:delSetting(KEY_CROP_BOUNDS)
        end
        -- Paging detector records have been migrated to KEY_CROP_BOUNDS.
        -- Do not keep a duplicate legacy table in the sidecar.
        settings:delSetting(KEY_AUTO_OFFSETS)
    elseif next(self.auto_offsets or {}) then
        settings:saveSetting(KEY_AUTO_OFFSETS, self.auto_offsets)
    else
        settings:delSetting(KEY_AUTO_OFFSETS)
    end
end

function MangaCenter:flushCropBounds()
    if self._crop_flush_task then
        UIManager:unschedule(self._crop_flush_task)
        self._crop_flush_task = nil
    end
    if not self._crop_bounds_dirty or not self:isPagingDocument()
            or not self.ui or not self.ui.doc_settings then
        return
    end

    local settings = self.ui.doc_settings
    if next(self.crop_bounds or {}) then
        settings:saveSetting(KEY_CROP_BOUNDS, self.crop_bounds)
    else
        settings:delSetting(KEY_CROP_BOUNDS)
    end
    settings:delSetting(KEY_AUTO_OFFSETS)

    -- This is intentionally a direct per-book metadata flush, not a full
    -- ReaderUI SaveSettings cycle. Crop detections are derived display metadata
    -- and can be persisted independently after the reader becomes idle.
    local ok, err = pcall(settings.flush, settings)
    if ok then
        self._crop_bounds_dirty = false
        logger.dbg("MangaCenter: persisted crop bounds")
    else
        logger.warn("MangaCenter: failed to persist crop bounds", err)
    end
end

function MangaCenter:scheduleCropBoundsFlush()
    if not self:isPagingDocument() or not self._crop_bounds_dirty then
        return
    end
    if self._crop_flush_task then
        UIManager:unschedule(self._crop_flush_task)
    end
    self._crop_flush_task = function()
        self._crop_flush_task = nil
        if self.ui and self.ui.doc_settings then
            self:flushCropBounds()
        end
    end
    -- Debounce writes: a hinted next page often arrives immediately after the
    -- visible page. Waiting briefly lets both records be written in one sidecar
    -- update, while still making the data durable long before book close.
    UIManager:scheduleIn(CROP_FLUSH_DELAY, self._crop_flush_task)
end

function MangaCenter:markCropBoundsDirty()
    self._crop_bounds_dirty = true
    if self._reader_ready then
        self:scheduleCropBoundsFlush()
    end
end

function MangaCenter:getCssText()
    if self.auto_center or not self.enabled then
        return ""
    end
    return MangaCenterCSS.build(self.mode, self.shift)
end

function MangaCenter:installCssProvider()
    local styletweak = self.ui.styletweak
    if styletweak._manga_center_original_get_css_text then
        styletweak._manga_center_owner = self
        return
    end

    styletweak._manga_center_original_get_css_text = styletweak.getCssText
    styletweak._manga_center_owner = self
    styletweak.getCssText = function(component)
        local base_css = component._manga_center_original_get_css_text(component)
        local owner = component._manga_center_owner
        local manga_css = owner and owner:getCssText() or ""
        if manga_css == "" then
            return base_css
        end
        if not base_css or base_css == "" then
            return manga_css
        end
        return base_css .. "\n" .. manga_css
    end
end

function MangaCenter:apply()
    if self:isPagingDocument() then
        -- Continuous view stores geometry per page in page_states. Rebuild it
        -- when auto-centering changes so every visible page gets recalculated.
        local view = self.ui and self.ui.view
        if view and view.page_scroll then
            self.ui:handleEvent(Event:new("InitScrollPageStates"))
            UIManager:setDirty(view.dialog or nil, "full")
        elseif self.ui then
            self:refreshPagingZoom()
        else
            UIManager:setDirty(self.ui and self.ui.dialog or nil, "full")
        end
    else
        self.ui:handleEvent(Event:new("ApplyStyleSheet"))
    end
end

function MangaCenter:setEnabled(enabled)
    self.enabled = enabled
    if enabled then
        self.auto_center = false
    end
    self:saveSettings()
    self:apply()
end

function MangaCenter:setMode(mode)
    self.mode = mode == "alternating" and "alternating" or "constant"
    self:saveSettings()
    if self.enabled then
        self:apply()
    end
end

function MangaCenter:setShift(shift)
    shift = tonumber(shift) or 0
    self.shift = math.max(-25, math.min(25, shift))
    self.enabled = self.shift ~= 0
    self.auto_center = false
    self:saveSettings()
    self:apply()
end

function MangaCenter:setAutoCenter(enabled)
    self.auto_center = enabled == true
    self:saveSettings()
    self:apply()
end

function MangaCenter:setVerticalFit(enabled)
    self.vertical_fit = enabled == true
    self:saveSettings()
    self:apply()
end

function MangaCenter:getStripStrictnessValue(axis)
    local preset = axis == "vertical"
        and self.vertical_strip_strictness or self.horizontal_strip_strictness
    return STRIP_STRICTNESS_VALUES[preset] or 100
end

function MangaCenter:getStripStrictnessLabel(axis)
    local preset = axis == "vertical"
        and self.vertical_strip_strictness or self.horizontal_strip_strictness
    return STRIP_STRICTNESS_LABELS[preset] or "Normal"
end

function MangaCenter:setStripStrictness(axis, preset)
    preset = normalizeStripStrictnessPreset(preset)
    local field = axis == "vertical"
        and "vertical_strip_strictness" or "horizontal_strip_strictness"
    if self[field] == preset then
        return
    end
    self[field] = preset

    -- Crop detections are per-page derived data. Throw them away for this book
    -- so the new preset is visible immediately and cannot mix with old bounds.
    if self:isPagingDocument() then
        self.crop_bounds = {}
        self:markCropBoundsDirty()
    end
    self:saveSettings()
    if self:isPagingDocument() then
        self:scheduleCropBoundsFlush()
        self:apply()
    end
end

function MangaCenter:buildStripStrictnessMenu(axis)
    local items = {}
    -- Do not name the throwaway loop index `_`: `_` is KOReader's i18n function.
    for preset_index, preset in ipairs(STRIP_STRICTNESS_PRESETS) do
        local key = preset.key
        local label = preset.label
        items[#items + 1] = {
            text = _(label),
            radio = true,
            checked_func = function()
                local current = axis == "vertical"
                    and self.vertical_strip_strictness or self.horizontal_strip_strictness
                return current == key
            end,
            callback = function(touchmenu_instance)
                self:setStripStrictness(axis, key)
                touchmenu_instance:updateItems()
            end,
        }
    end
    return items
end

function MangaCenter:isPagingZoomOutActive(zooming)
    local view = self.ui and self.ui.view
    local configurable = self.ui and self.ui.document and self.ui.document.configurable
    return self:isPagingDocument()
        and self.continuous_width < 100
        and view
        and view.page_scroll
        and zooming
        and MangaCenterZoom.isWidthMode(zooming.zoom_mode)
        and (not configurable or configurable.text_wrap ~= 1)
end

function MangaCenter:isPagingNativeCropActive(zooming)
    local view = self.ui and self.ui.view
    local configurable = self.ui and self.ui.document and self.ui.document.configurable
    return (self.auto_center or self.vertical_fit)
        and self:isPagingDocument()
        and view
        and not view.page_scroll
        and zooming
        and isNativeCropZoomMode(zooming.zoom_mode)
        and (not configurable or configurable.text_wrap ~= 1)
end

function MangaCenter:getPagingNativeCropFit(zooming, page, rotation, verify_current_page)
    if not page then return nil end
    local detected = self:getPagingDetectedContent(page, verify_current_page)
    local crop_rect = detected and MangaCenterAutoCenter.getEffectiveCropRect(
        detected, rotation, self.auto_center, self.vertical_fit)
    if not crop_rect then return nil end

    local dimen = zooming and zooming.dimen
    local view = self.ui and self.ui.view
    local viewport_w = tonumber(dimen and dimen.w)
        or tonumber(view and view.dimen and view.dimen.w) or Screen:getWidth()
    local viewport_h = tonumber(dimen and dimen.h)
        or tonumber(view and view.dimen and view.dimen.h) or Screen:getHeight()
    if view and view.footer_visible and view.footer and view.footer.settings
            and not view.footer.settings.reclaim_height then
        viewport_h = viewport_h - (tonumber(view.footer:getHeight()) or 0)
    end
    if viewport_w <= 0 or viewport_h <= 0 then return nil end

    local mode = zooming.zoom_mode
    local zoom, zoom_w, zoom_h = MangaCenterAutoCenter.getNativeFitZoom(
        crop_rect, viewport_w, viewport_h, mode)
    if not zoom then return nil end

    logger.info("MangaCenter: native crop fit", page, mode,
        "zoom", zoom, "zoom_w", zoom_w, "zoom_h", zoom_h,
        "effective_native", crop_rect.w, crop_rect.h,
        "crop_x", self.auto_center and "yes" or "no",
        "crop_y", self.vertical_fit and "yes" or "no",
        "bbox", detected.x0, detected.y0, detected.x1, detected.y1,
        "method", detected.method or "unknown")
    return zoom, zoom_w, zoom_h
end

function MangaCenter:adjustPagingZoom(zooming, zoom, zoom_w, zoom_h, page)
    local adjusted, adjusted_w, adjusted_h = zoom, zoom_w, zoom_h
    if self:isPagingZoomOutActive(zooming) then
        adjusted = MangaCenterZoom.apply(adjusted, self.continuous_width)
    end
    if self:isPagingNativeCropActive(zooming) then
        local view = self.ui and self.ui.view
        page = page or zooming.current_page or (view and view.state and view.state.page)
        local rotation = zooming.rotation or (view and view.state and view.state.rotation) or 0
        if page then
            -- Once ReaderReady has installed the paging hooks, an explicit
            -- page argument is safe to inspect even when it is not the current
            -- page. KOReader's native ReaderHinting deliberately calls
            -- getZoom(next_page) before hintPage(next_page); allowing that call
            -- to populate our crop cache lets its normal one-page-ahead render
            -- use the crop-aware zoom too.
            local crop_zoom, crop_w, crop_h = self:getPagingNativeCropFit(
                zooming, page, rotation, false)
            if crop_zoom then
                adjusted, adjusted_w, adjusted_h = crop_zoom, crop_w, crop_h
            end
        end
    end
    return adjusted, adjusted_w, adjusted_h
end

function MangaCenter:refreshPagingZoom()
    if not self:isPagingDocument() or not self.ui then
        return
    end
    if self.ui.handleEvent then
        self.ui:handleEvent(Event:new("ReZoom"))
    end
    local view = self.ui.view
    if view and type(view.recalculate) == "function" then
        view:recalculate()
    else
        UIManager:setDirty(self.ui.dialog or nil, "full")
    end
end

function MangaCenter:setContinuousWidth(percent)
    self.continuous_width = MangaCenterZoom.normalizePercent(percent)
    self:saveSettings()
    self:refreshPagingZoom()
end

function MangaCenter:getContinuousOverlapPixels()
    local view = self.ui and self.ui.view
    local height = view and view.visible_area and tonumber(view.visible_area.h)
    if not height or height <= 0 then
        height = Screen:getHeight()
    end
    return MangaCenterZoom.overlapPixels(self.continuous_overlap, height)
end

function MangaCenter:applyContinuousOverlap()
    local paging = self.ui and self.ui.paging
    if not paging then return end
    if paging._manga_center_native_overlap == nil then
        paging._manga_center_native_overlap = paging.overlap
    end
    -- Keep KOReader's own fragment-relative overlap untouched. MangaCenter's
    -- percentage is implemented as a true visible-screen distance in our
    -- onScrollPageRel wrapper, avoiding tiny moves when the viewport contains
    -- only a short tail of the last underlying PDF page.
    paging.overlap = paging._manga_center_native_overlap
end

function MangaCenter:getContinuousFallbackDistance()
    if self.continuous_overlap == nil then return nil end
    local view = self.ui and self.ui.view
    local height = view and view.visible_area and tonumber(view.visible_area.h)
    if not height or height <= 0 then height = Screen:getHeight() end
    local overlap = MangaCenterZoom.overlapPixels(self.continuous_overlap, height) or 0
    return math.max(1, math.floor(height - overlap + 0.5))
end

function MangaCenter:setContinuousOverlap(percent)
    self.continuous_overlap = MangaCenterZoom.normalizeOverlapPercent(percent)
    self:saveSettings()
    self:applyContinuousOverlap()
end

function MangaCenter:resetContinuousOverlap()
    self.continuous_overlap = nil
    self:saveSettings()
    self:applyContinuousOverlap()
end

function MangaCenter:setPanelAwarePaging(enabled)
    self.panel_aware_paging = enabled == true
    self:saveSettings()
end

function MangaCenter:setOnReleaseScrollMultiplier(multiplier)
    self.on_release_scroll_multiplier = MangaCenterZoom.normalizeScrollMultiplier(multiplier)
    self:saveSettings()
end

function MangaCenter:scaleContinuousPanGesture(paging, ges)
    if not paging or not paging.view or not paging.view.page_scroll or not ges then
        return nil
    end
    -- This is specifically a touch-distance multiplier. Do not alter mouse-wheel
    -- pans, whose distance is generated by the input backend rather than a finger.
    if ges.mousewheel_direction then
        return nil
    end
    if ges.direction ~= "north" and ges.direction ~= "south" then
        return nil
    end
    if math.abs(self.on_release_scroll_multiplier - 1) <= 0.0001 then
        return nil
    end
    local relative = ges.relative
    local original_y = relative and tonumber(relative.y)
    if not original_y then
        return nil
    end
    relative.y = MangaCenterZoom.applyScrollMultiplier(
        original_y, self.on_release_scroll_multiplier)
    return original_y
end

function MangaCenter:getPanelAnchors(page, viewport_native_height)
    self.panel_anchors = self.panel_anchors or {}
    local ok_detector, detector = pcall(getPagingDetector)
    if not ok_detector or not detector or type(detector.detectPanelAnchors) ~= "function" then
        return nil
    end
    local ok_sig, signature, native = pcall(detector.getSignature, self.ui.document, page)
    if not ok_sig or not native then return nil end
    local bucket = math.floor((tonumber(viewport_native_height) or 0) / 25 + 0.5) * 25
    local key = tostring(page) .. "|" .. tostring(signature) .. "|panel-v4|" .. tostring(bucket)
    if self.panel_anchors[key] ~= nil then
        return self.panel_anchors[key], native
    end
    local ok, anchors = pcall(detector.detectPanelAnchors,
        self.ui.document, page, viewport_native_height)
    if not ok then
        logger.warn("MangaCenter: panel-anchor detection failed", page, anchors)
        anchors = {}
    end
    self.panel_anchors[key] = anchors or {}
    return self.panel_anchors[key], native
end

function MangaCenter:getPanelAwareForwardDistance()
    local view = self.ui and self.ui.view
    if not self.panel_aware_paging or not self:isPagingDocument()
            or not view or not view.page_scroll or not view.page_states then
        return nil
    end
    local viewport_h = tonumber(view.visible_area and view.visible_area.h) or Screen:getHeight()
    if viewport_h <= 0 then return nil end
    -- Ignore only an anchor already at the top. A genuine panel end/start even a
    -- few pixels below it must remain a valid reading stop.
    local ignore_top = math.max(4, math.min(8, viewport_h * 0.006))
    local screen_y = 0

    for index, state in ipairs(view.page_states) do
        local visible, area = state.visible_area, state.page_area
        if visible and area and state.rotation == 0 and visible.h > 0 and area.h > 0 then
            local ok_detector, detector = pcall(getPagingDetector)
            local native
            if ok_detector and detector then
                local ok_sig, _, n = pcall(detector.getSignature, self.ui.document, state.page)
                if ok_sig then native = n end
            end
            if native and native.h and native.h > 0 then
                local viewport_native_h = viewport_h * native.h / area.h
                local anchors = self:getPanelAnchors(state.page, viewport_native_h)
                for _, anchor in ipairs(anchors or {}) do
                    local native_y = tonumber(anchor.y)
                    if native_y then
                        local page_y = area.y + native_y * area.h / native.h
                        if page_y >= visible.y - 1 and page_y <= visible.y + visible.h + 1 then
                            local y = screen_y + (page_y - visible.y)
                            if y > ignore_top and y < viewport_h - 4 then
                                logger.dbg("MangaCenter: panel-aware snap", anchor.kind or "anchor",
                                    state.page, native_y, "screen y", y)
                                return math.floor(y + 0.5), anchor.kind
                            end
                        end
                    end
                end
            end
        end
        screen_y = screen_y + (tonumber(visible and visible.h) or 0)
        if index < #view.page_states then
            screen_y = screen_y + (tonumber(view.page_gap and view.page_gap.height) or 0)
        end
        if screen_y >= viewport_h then break end
    end
    return nil
end

function MangaCenter:clearAutoCenterCache()
    if self:isPagingDocument() then
        self.crop_bounds = {}
        self:markCropBoundsDirty()
        self:saveSettings()
        self:scheduleCropBoundsFlush()
        self:apply()
    else
        self.auto_offsets = {}
        self:saveSettings()
        UIManager:setDirty(nil, "full")
    end
end

function MangaCenter:isAutoCenterActive(view)
    return self.auto_center
        and view
        and view.view_mode == "page"
        and self.ui.document:getVisiblePageCount() == 1
        and not Screen.night_mode
end

function MangaCenter:isPagingAutoCenterActive(view)
    local configurable = self.ui.document.configurable
    -- In native fit modes, horizontal/vertical alignment is a consequence of
    -- the cropped page_area itself. Do not layer the legacy post-layout shift
    -- on top. Keep that legacy path only for modes we do not crop (e.g. manual).
    local zooming = self.ui and self.ui.zooming
    if self:isPagingNativeCropActive(zooming) then
        return false
    end
    return self.auto_center
        and self:isPagingDocument()
        and view
        and view.state
        and view.state.page ~= nil
        and view.visible_area
        and view.page_area
        and not view.page_scroll
        and (not configurable or configurable.text_wrap ~= 1)
        and MangaCenterAutoCenter.isFullWidthVisible(view.visible_area, view.page_area)
end

function MangaCenter:getPagingNativeCropPageArea(view, page, zoom, rotation)
    local zooming = self.ui and self.ui.zooming
    local configurable = self.ui and self.ui.document and self.ui.document.configurable
    if not (self.auto_center or self.vertical_fit) or not self:isPagingDocument()
            or not view or view.page_scroll or not zooming
            or not isNativeCropZoomMode(zooming.zoom_mode)
            or (configurable and configurable.text_wrap == 1) then
        return nil
    end

    local detected = self:getPagingDetectedContent(page, false)
    local crop_rect = detected and MangaCenterAutoCenter.getEffectiveCropRect(
        detected, rotation, self.auto_center, self.vertical_fit)
    if not crop_rect then return nil end

    zoom = tonumber(zoom) or 1
    if zoom <= 0 then return nil end

    -- This is the only page-geometry modification in single-page fit modes.
    -- Horizontal auto-center trims x; vertical fit trims y. KOReader then
    -- performs its ordinary full/width/height behavior on this effective page.
    local x, y, w, h = crop_rect.x, crop_rect.y, crop_rect.w, crop_rect.h

    local function scaled(v)
        return math.floor(v * zoom + 0.5)
    end
    local area = Geom:new{
        x = scaled(x),
        y = scaled(y),
        w = math.max(1, scaled(w)),
        h = math.max(1, scaled(h)),
    }
    logger.dbg("MangaCenter: native crop page_area", page,
        area.x, area.y, area.w, area.h, "zoom", zoom,
        "crop_x", self.auto_center and "yes" or "no",
        "crop_y", self.vertical_fit and "yes" or "no")
    return area
end

function MangaCenter:getPagingReferenceBBox(view, page, detected)
    local document = self.ui.document
    local full_bbox = {
        x0 = 0,
        y0 = 0,
        x1 = detected.page_w,
        y1 = detected.page_h,
    }
    if not view.use_bbox or type(document.getPageBBox) ~= "function" then
        return full_bbox
    end

    local ok, bbox = pcall(document.getPageBBox, document, page)
    if not ok or not bbox or not bbox.x0 or not bbox.y0 or not bbox.x1 or not bbox.y1
            or bbox.x1 <= bbox.x0 or bbox.y1 <= bbox.y0 then
        return full_bbox
    end
    return bbox
end

function MangaCenter:getPagingDetectedContent(page, verify_current_page)
    local document = self.ui.document

    if verify_current_page then
        local zooming = self.ui.zooming
        if zooming and zooming.current_page and zooming.current_page ~= page then
            return nil
        end
    end

    local detector_ok, detector = pcall(getPagingDetector)
    if not detector_ok or not detector then
        logger.warn("MangaCenter: cannot load paging detector", detector)
        return nil
    end

    local horizontal_strictness = self:getStripStrictnessValue("horizontal")
    local vertical_strictness = self:getStripStrictnessValue("vertical")
    local signature_ok, signature, native = pcall(
        detector.getSignature, document, page, horizontal_strictness, vertical_strictness)
    if not signature_ok or not native then
        logger.warn("MangaCenter: cannot build paging detector signature", page, signature)
        return nil
    end

    local cache_key = MangaCenterAutoCenter.cacheKey(page, native.w, native.h, signature)
    self.crop_bounds = self.crop_bounds or {}
    local detected = self.crop_bounds[cache_key]
    if type(detected) ~= "table" then
        local ok, result, detector_error = pcall(
            detector.detect, document, page, horizontal_strictness, vertical_strictness)
        if ok and result then
            detected = result
            logger.info("MangaCenter: paging content bbox", page, result.method or "unknown",
                result.x0, result.y0, result.x1, result.y1,
                "ignored satellites", result.ignored_satellites or 0)
        else
            if not ok then detector_error = result end
            logger.warn("MangaCenter: paging content detection failed", page, detector_error)
            detected = { failed = true, page_w = native.w, page_h = native.h }
        end
        self.crop_bounds[cache_key] = detected
        self:markCropBoundsDirty()
    end

    if detected.failed then
        return nil
    end
    return detected
end

function MangaCenter:getPagingDetectedOffsets(view, page, rotation, page_width, page_height, verify_current_page)
    local detected = self:getPagingDetectedContent(page, verify_current_page)
    if not detected then
        return 0, 0
    end

    local reference_bbox = self:getPagingReferenceBBox(view, page, detected)
    local offset_x = 0
    if self.auto_center then
        offset_x = MangaCenterAutoCenter.offsetFromContentBBox(
            detected, reference_bbox, rotation, page_width)
    end
    local offset_y = 0
    if self.vertical_fit and page_height and page_height > 0
            and self.ui and self.ui.zooming
            and MangaCenterZoom.isWidthMode(self.ui.zooming.zoom_mode) then
        offset_y = MangaCenterAutoCenter.verticalOffsetFromContentBBox(
            detected, reference_bbox, rotation, page_height)
    end
    logger.dbg("MangaCenter: paging auto-center page", page,
        "offset_x", offset_x, "offset_y", offset_y,
        "method", detected.method or "unknown")
    return offset_x, offset_y
end

function MangaCenter:getPagingAutoCenterOffsets(view)
    if not self:isPagingAutoCenterActive(view) then return 0, 0 end
    return self:getPagingDetectedOffsets(
        view, view.state.page, view.state.rotation, view.page_area.w, view.page_area.h, true)
end

function MangaCenter:isPagingScrollAutoCenterActive(state)
    local view = self.ui and self.ui.view
    local configurable = self.ui and self.ui.document and self.ui.document.configurable
    return self.auto_center
        and self:isPagingDocument()
        and view
        and view.page_scroll
        and state
        and state.page ~= nil
        and state.offset
        and state.visible_area
        and state.page_area
        and (not configurable or configurable.text_wrap ~= 1)
        and MangaCenterAutoCenter.isFullWidthVisible(state.visible_area, state.page_area)
end

function MangaCenter:applyPagingAutoCenterToScrollState(state)
    if not self:isPagingScrollAutoCenterActive(state) then return state end
    local view = self.ui.view
    local offset_x = self:getPagingDetectedOffsets(
        view, state.page, state.rotation, state.page_area.w, state.page_area.h, false)
    state._manga_center_applied_offset_x = offset_x
    if offset_x ~= 0 then
        state.offset.x = (tonumber(state.offset.x) or 0) + offset_x
    end
    return state
end

-- Rolling/EPUB auto-centering keeps the original rendered-buffer path. It is
-- intentionally separate from the KOPT detector used for PDF/comic documents.
function MangaCenter:paintAutoCenteredPage(view, target, x, y)
    if not self:isAutoCenterActive(view) then
        return
    end
    local buffer = self.ui.document.buffer
    if not buffer then
        return
    end
    local width, height = buffer:getWidth(), buffer:getHeight()
    local page = self.ui.document:getCurrentPage()
    if not page then
        return
    end
    local rendering_hash = self.ui.document:getDocumentRenderingHash(true)
    local cache_key = MangaCenterAutoCenter.cacheKey(page, width, height, rendering_hash)
    local offset = self.auto_offsets[cache_key]
    if offset == nil then
        local image_count, image_coverage = self.ui.document:getDrawnImagesStatistics()
        if (image_count or 0) > 0 and (image_coverage or 0) >= 0.2 then
            local detected_ok, detected_offset = pcall(MangaCenterAutoCenter.detectOffset, buffer)
            if detected_ok then
                offset = detected_offset
            else
                logger.warn("MangaCenter: automatic centering failed on page", page, detected_offset)
                offset = 0
            end
        else
            offset = 0
        end
        self.auto_offsets[cache_key] = offset
    end
    if offset == 0 then
        return
    end

    local dest_x = math.floor(x + view.state.offset.x)
    local dest_y = math.floor(y + view.state.offset.y)
    target:paintRect(dest_x, dest_y, width, height, view.page_bgcolor or Blitbuffer.COLOR_WHITE)
    local source_x = 0
    local copy_width = width - math.abs(offset)
    if offset > 0 then
        dest_x = dest_x + offset
    else
        source_x = -offset
    end
    if copy_width > 0 then
        target:blitFrom(buffer, dest_x, dest_y, source_x, 0, copy_width, height)
    end
end

function MangaCenter:installAutoCenterRenderer()
    local view = self.ui and self.ui.view
    if not view or type(view.drawPageView) ~= "function" then
        return
    end
    if view._manga_center_original_draw_page_view then
        view._manga_center_owner = self
        return
    end
    view._manga_center_original_draw_page_view = view.drawPageView
    view._manga_center_owner = self
    view.drawPageView = function(component, target, x, y)
        component._manga_center_original_draw_page_view(component, target, x, y)
        local owner = component._manga_center_owner
        if owner then
            owner:paintAutoCenteredPage(component, target, x, y)
        end
    end
end

function MangaCenter:applyPagingAutoCenterLayout(view)
    -- Native full/width/height modes are handled entirely by crop-first page
    -- geometry. This legacy path is kept only for horizontal centering in
    -- non-crop modes such as manual zoom.
    view._manga_center_base_offset_x = nil
    view._manga_center_base_offset_y = nil
    view._manga_center_applied_offset_x = 0
    view._manga_center_applied_offset_y = 0

    if not self:isPagingAutoCenterActive(view) then
        return
    end

    local page = view.state.page
    local detected = self:getPagingDetectedContent(page, true)
    if not detected then return end
    local reference_bbox = self:getPagingReferenceBBox(view, page, detected)
    local base_x = tonumber(view.state.offset.x) or 0
    view._manga_center_base_offset_x = base_x

    local fraction_x = MangaCenterAutoCenter.contentCenterFraction(
        detected, reference_bbox, view.state.rotation, "x")
    if view.page_area.w > view.visible_area.w + 1 then
        local desired_x = view.page_area.x + fraction_x * view.page_area.w - view.visible_area.w / 2
        local min_x = view.page_area.x
        local max_x = view.page_area.x + view.page_area.w - view.visible_area.w
        desired_x = math.max(min_x, math.min(max_x, desired_x))
        if math.abs(desired_x - view.visible_area.x) > 0.5 then
            view.visible_area.x = math.floor(desired_x + 0.5)
            if self.ui and self.ui.handleEvent then
                self.ui:handleEvent(Event:new("ViewRecalculate", view.visible_area, view.page_area))
            end
        end
    else
        local offset_x = (0.5 - fraction_x) * view.page_area.w
        offset_x = offset_x >= 0 and math.floor(offset_x + 0.5) or math.ceil(offset_x - 0.5)
        local max_offset = math.floor(view.dimen.w * 0.25)
        offset_x = math.max(-max_offset, math.min(max_offset, offset_x))
        view._manga_center_applied_offset_x = offset_x
        if offset_x ~= 0 then
            view.state.offset.x = base_x + offset_x
        end
    end
end

function MangaCenter:paintPagingAutoCenterSurround(view, target, x, y)
    local applied_x = tonumber(view._manga_center_applied_offset_x) or 0
    local applied_y = tonumber(view._manga_center_applied_offset_y) or 0
    if applied_x == 0 and applied_y == 0 then
        return false
    end

    -- ReaderView's stock drawPageSurround() assumes offset.x is symmetric on
    -- both sides. Auto-centering deliberately makes it asymmetric, and the
    -- height-fit mode may also shift the page vertically. Paint a clean outer
    -- background and then the shifted page rectangle; KOReader's untouched
    -- drawSinglePage() will paint the real page on top of this.
    target:paintRect(x, y, view.dimen.w, view.dimen.h, view.outer_page_color)

    local page_x = math.floor(x + view.state.offset.x)
    local page_y = math.floor(y + view.state.offset.y)
    local left = math.max(x, page_x)
    local top = math.max(y, page_y)
    local right = math.min(x + view.dimen.w, page_x + view.visible_area.w)
    local bottom = math.min(y + view.dimen.h, page_y + view.visible_area.h)
    if right > left and bottom > top then
        target:paintRect(
            left, top, right - left, bottom - top,
            view.page_bgcolor or Blitbuffer.COLOR_WHITE)
    end
    return true
end

function MangaCenter:installPagingAutoCenterLayout()
    local view = self.ui and self.ui.view
    if not view or type(view.recalculate) ~= "function"
            or type(view.drawPageSurround) ~= "function"
            or type(view.getPageArea) ~= "function" then
        logger.warn("MangaCenter: ReaderView layout hooks are unavailable")
        return
    end

    if view._manga_center_original_recalculate then
        view._manga_center_owner = self
        return
    end

    view._manga_center_original_recalculate = view.recalculate
    view._manga_center_original_draw_page_surround = view.drawPageSurround
    view._manga_center_original_get_page_area = view.getPageArea
    view._manga_center_owner = self

    view.getPageArea = function(component, page, zoom, rotation)
        local owner = component._manga_center_owner
        if owner then
            local ok, area = pcall(owner.getPagingNativeCropPageArea,
                owner, component, page, zoom, rotation)
            if ok and area then
                return area
            elseif not ok then
                logger.warn("MangaCenter: native crop page-area failed", area)
            end
        end
        return component._manga_center_original_get_page_area(component, page, zoom, rotation)
    end

    view.recalculate = function(component, ...)
        local result = component._manga_center_original_recalculate(component, ...)
        local owner = component._manga_center_owner
        if owner then
            local ok, err = pcall(owner.applyPagingAutoCenterLayout, owner, component)
            if not ok then
                component._manga_center_applied_offset_x = 0
                logger.warn("MangaCenter: paging layout adjustment failed", err)
            end
            local overlap_ok, overlap_err = pcall(owner.applyContinuousOverlap, owner)
            if not overlap_ok then
                logger.warn("MangaCenter: continuous overlap refresh failed", overlap_err)
            end
        end
        return result
    end

    view.drawPageSurround = function(component, target, x, y)
        local owner = component._manga_center_owner
        if owner then
            local ok, painted = pcall(
                owner.paintPagingAutoCenterSurround, owner, component, target, x, y)
            if ok and painted then
                return
            elseif not ok then
                logger.warn("MangaCenter: paging surround paint failed", painted)
            end
        end
        return component._manga_center_original_draw_page_surround(component, target, x, y)
    end
end


function MangaCenter:installPagingScrollAutoCenter()
    local paging = self.ui and self.ui.paging
    if not paging or type(paging.getNextPageState) ~= "function"
            or type(paging.getPrevPageState) ~= "function" then
        logger.warn("MangaCenter: ReaderPaging scroll-state hooks are unavailable")
        return
    end
    if paging._manga_center_original_get_next_page_state then
        paging._manga_center_owner = self
        return
    end
    paging._manga_center_original_get_next_page_state = paging.getNextPageState
    paging._manga_center_original_get_prev_page_state = paging.getPrevPageState
    paging._manga_center_owner = self
    paging.getNextPageState = function(component, ...)
        local state = component._manga_center_original_get_next_page_state(component, ...)
        local owner = component._manga_center_owner
        if owner and state then
            local ok, err = pcall(owner.applyPagingAutoCenterToScrollState, owner, state)
            if not ok then logger.warn("MangaCenter: continuous next-page centering failed", err) end
        end
        return state
    end
    paging.getPrevPageState = function(component, ...)
        local state = component._manga_center_original_get_prev_page_state(component, ...)
        local owner = component._manga_center_owner
        if owner and state then
            local ok, err = pcall(owner.applyPagingAutoCenterToScrollState, owner, state)
            if not ok then logger.warn("MangaCenter: continuous previous-page centering failed", err) end
        end
        return state
    end
    if type(paging.onScrollPageRel) == "function" then
        paging._manga_center_original_on_scroll_page_rel = paging.onScrollPageRel
        paging.onScrollPageRel = function(component, page_diff, no_page_turn)
            local owner = component._manga_center_owner
            if owner and page_diff and not no_page_turn then
                if owner.panel_aware_paging and page_diff > 0 and page_diff <= 1 then
                    local ok, distance = pcall(owner.getPanelAwareForwardDistance, owner)
                    if ok and distance and distance > 0 then
                        component:onScrollPanRel(distance)
                        return true
                    elseif not ok then
                        logger.warn("MangaCenter: panel-aware page-down failed", distance)
                    end
                end
                -- A custom overlap is a percentage of the whole visible screen,
                -- not KOReader's final PDF-page fragment. This is the fallback
                -- inside tall panels/separators and the ordinary one-screen move
                -- when panel-aware paging is disabled.
                if owner.continuous_overlap ~= nil and math.abs(page_diff) <= 1 then
                    local distance = owner:getContinuousFallbackDistance()
                    if distance and distance > 0 then
                        component:onScrollPanRel(page_diff < 0 and -distance or distance)
                        return true
                    end
                end
            end
            return component._manga_center_original_on_scroll_page_rel(component, page_diff, no_page_turn)
        end
    end

    -- Scale KOReader's vertical touch displacement before ReaderPaging:onPan()
    -- interprets it. This naturally covers all three native scrolling methods:
    -- Classic (incremental finger delta), Turbo (distance from initial touch used
    -- as scroll speed), and On-release (net distance committed on release).
    -- Restore ges.relative.y immediately afterwards so other gesture handlers see
    -- the unmodified native gesture.
    if type(paging.onPan) == "function" then
        paging._manga_center_original_on_pan = paging.onPan
        paging.onPan = function(component, ...)
            local owner = component._manga_center_owner
            local _, ges = ...
            local original_y
            if owner and ges then
                local ok, value = pcall(owner.scaleContinuousPanGesture, owner, component, ges)
                if ok then
                    original_y = value
                else
                    logger.warn("MangaCenter: continuous gesture amplification failed", value)
                end
            end
            local ok, result = pcall(component._manga_center_original_on_pan, component, ...)
            if original_y ~= nil and ges and ges.relative then
                ges.relative.y = original_y
            end
            if not ok then
                error(result)
            end
            return result
        end
    end
end

function MangaCenter:installPagingZoomOut()
    local zooming = self.ui and self.ui.zooming
    local view = self.ui and self.ui.view
    if not zooming or type(zooming.getZoom) ~= "function" then
        logger.warn("MangaCenter: ReaderZooming getZoom hook is unavailable")
        return
    end
    if not zooming._manga_center_original_get_zoom then
        zooming._manga_center_original_get_zoom = zooming.getZoom
        zooming.getZoom = function(component, ...)
            local page = select(1, ...)
            local zoom, zoom_w, zoom_h = component._manga_center_original_get_zoom(component, ...)
            local owner = component._manga_center_owner
            if owner and zoom then
                local ok, adjusted, adjusted_w, adjusted_h = pcall(
                    owner.adjustPagingZoom, owner, component, zoom, zoom_w, zoom_h, page)
                if ok then
                    zoom = adjusted or zoom
                    zoom_w = adjusted_w or zoom_w
                    zoom_h = adjusted_h or zoom_h
                else
                    logger.warn("MangaCenter: paging zoom adjustment failed", adjusted)
                end
            end
            return zoom, zoom_w, zoom_h
        end
    end
    zooming._manga_center_owner = self

    if view and type(view.onSetScrollMode) == "function" then
        if not view._manga_center_original_on_set_scroll_mode then
            view._manga_center_original_on_set_scroll_mode = view.onSetScrollMode
            view.onSetScrollMode = function(component, ...)
                local result = component._manga_center_original_on_set_scroll_mode(component, ...)
                local owner = component._manga_center_owner
                if owner then
                    local overlap_ok, overlap_err = pcall(owner.applyContinuousOverlap, owner)
                    if not overlap_ok then
                        logger.warn("MangaCenter: continuous-mode overlap refresh failed", overlap_err)
                    end
                    if owner.continuous_width < 100 or owner.vertical_fit or owner.auto_center then
                        local ok, err = pcall(owner.refreshPagingZoom, owner)
                        if not ok then logger.warn("MangaCenter: mode-change zoom refresh failed", err) end
                    end
                end
                return result
            end
        end
        view._manga_center_owner = self
    end
end

function MangaCenter:reverseShift()
    if self.shift ~= 0 then
        self:setShift(-self.shift)
    end
end

function MangaCenter:showShiftDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Manga horizontal shift"),
        description = _([[Positive values move constant-mode images right. Negative values move them left.
In alternating mode, odd spine pages receive the entered shift and even pages receive its opposite.
Applying a non-zero value enables the shift for this book.]]),
        input = string.format("%.2f", self.shift),
        input_hint = "-25 - 25%",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Apply and preview"),
                    is_enter_default = true,
                    callback = function()
                        local shift = tonumber(dialog:getInputText())
                        if not shift or shift < -25 or shift > 25 then
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid value. Please enter a valid value."),
                            })
                            return
                        end
                        self:setShift(shift)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function MangaCenter:showContinuousWidthDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Continuous manga width"),
        description = _([[Applies to PDF, DjVu, and comic archives in continuous view when zoom is set to page width or content width.
100% disables the extra zoom-out.]]),
        input = string.format("%g", self.continuous_width),
        input_hint = "50 - 100%",
        input_type = "number",
        buttons = {{
            {
                text = _("Close"), id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Apply and preview"), is_enter_default = true,
                callback = function()
                    local width = tonumber(dialog:getInputText())
                    if not width or width < 50 or width > 100 then
                        UIManager:show(InfoMessage:new{
                            text = _("Invalid value. Please enter a value from 50 to 100."),
                        })
                        return
                    end
                    self:setContinuousWidth(width)
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MangaCenter:showContinuousOverlapDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Fallback scroll overlap"),
        description = _([[Percentage of the visible screen height repeated when panel-aware paging has no structural anchor to snap to. It is also used for ordinary continuous page-down when panel-aware paging is off.
Enter 0 for no overlap. Leave the field blank to use KOReader's native overlap.]]),
        input = self.continuous_overlap ~= nil and string.format("%g", self.continuous_overlap) or "",
        input_hint = "0 - 90%",
        input_type = "number",
        buttons = {{
            {
                text = _("Close"), id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Apply and preview"), is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    if text == nil or text:match("^%s*$") then
                        self:resetContinuousOverlap()
                        UIManager:close(dialog)
                        return
                    end
                    local overlap = tonumber(text)
                    if not overlap or overlap < 0 or overlap > 90 then
                        UIManager:show(InfoMessage:new{
                            text = _("Invalid value. Please enter a value from 0 to 90, or leave it blank for KOReader default."),
                        })
                        return
                    end
                    self:setContinuousOverlap(overlap)
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MangaCenter:showScrollGestureMultiplierDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Continuous scroll gesture multiplier"),
        description = _([[Multiplies vertical finger movement in KOReader continuous scrolling.
1.0x keeps native behavior; 0.5x halves it; 2.0x doubles it. It applies to Classic, Turbo, and On-release scrolling.]]),
        input = string.format("%g", self.on_release_scroll_multiplier),
        input_hint = "0.25 - 10x",
        input_type = "number",
        buttons = {{
            {
                text = _("Close"), id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Apply and preview"), is_enter_default = true,
                callback = function()
                    local multiplier = tonumber(dialog:getInputText())
                    if not multiplier or multiplier < 0.25 or multiplier > 10 then
                        UIManager:show(InfoMessage:new{
                            text = _("Invalid value. Please enter a multiplier from 0.25 to 10."),
                        })
                        return
                    end
                    self:setOnReleaseScrollMultiplier(multiplier)
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MangaCenter:getMenuTitle()
    if self:isPagingDocument() and self.continuous_width < 100 then
        if self.auto_center then
            return T(_("Manga center (auto, %1% width)"), string.format("%g", self.continuous_width))
        end
        return T(_("Manga center (%1% width)"), string.format("%g", self.continuous_width))
    end
    if self.auto_center then
        return _("Manga page shift (auto)")
    end
    if self:isPagingDocument() or not self.enabled then
        return _("Manga page shift (off)")
    end
    return T(_("Manga page shift (%1%)"), string.format("%.2f", self.shift))
end

function MangaCenter:buildControlMenuItems()
    local items = {
        {
            text = _("Auto-center visible image content"),
            checked_func = function()
                return self.auto_center
            end,
            callback = function(touchmenu_instance)
                self:setAutoCenter(not self.auto_center)
                touchmenu_instance:updateItems()
            end,
        },
        {
            text = _("Fit detected image content vertically"),
            enabled_func = function()
                local view = self.ui and self.ui.view
                return self:isPagingDocument() and view and not view.page_scroll
            end,
            checked_func = function()
                return self.vertical_fit
            end,
            callback = function(touchmenu_instance)
                self:setVerticalFit(not self.vertical_fit)
                touchmenu_instance:updateItems()
            end,
        },
        {
            text_func = function()
                return T(_("Horizontal strip strictness: %1"),
                    _(self:getStripStrictnessLabel("horizontal")))
            end,
            enabled_func = function() return self:isPagingDocument() end,
            sub_item_table = self:buildStripStrictnessMenu("horizontal"),
        },
        {
            text_func = function()
                return T(_("Vertical strip strictness: %1"),
                    _(self:getStripStrictnessLabel("vertical")))
            end,
            enabled_func = function() return self:isPagingDocument() end,
            sub_item_table = self:buildStripStrictnessMenu("vertical"),
        },
        {
            text = _("Clear auto-center cache"),
            enabled_func = function()
                return (self.auto_center or self.vertical_fit) and next(self.crop_bounds or {}) ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:clearAutoCenterCache()
                touchmenu_instance:updateItems()
            end,
            separator = true,
        },
    }
    if self:isPagingDocument() then
        table.insert(items, 1, {
            text_func = function()
                return T(_("Continuous manga width: %1%"), string.format("%g", self.continuous_width))
            end,
            keep_menu_open = true,
            callback = function() self:showContinuousWidthDialog() end,
        })
        table.insert(items, 2, {
            text = _("Panel-aware page-down"),
            checked_func = function() return self.panel_aware_paging end,
            callback = function(touchmenu_instance)
                self:setPanelAwarePaging(not self.panel_aware_paging)
                touchmenu_instance:updateItems()
            end,
        })
        table.insert(items, 3, {
            text_func = function()
                if self.continuous_overlap == nil then
                    return _("Fallback scroll overlap: KOReader default")
                end
                return T(_("Fallback scroll overlap: %1%"), string.format("%g", self.continuous_overlap))
            end,
            keep_menu_open = true,
            callback = function() self:showContinuousOverlapDialog() end,
        })
        table.insert(items, 4, {
            text_func = function()
                return T(_("Continuous scroll gesture multiplier: %1x"),
                    string.format("%g", self.on_release_scroll_multiplier))
            end,
            keep_menu_open = true,
            callback = function() self:showScrollGestureMultiplierDialog() end,
            separator = true,
        })
        return items
    end
    for _, item in ipairs({
        {
            text = _("Enable adjustable shift for this book"),
            enabled_func = function()
                return not self.auto_center
            end,
            checked_func = function()
                return self.enabled
            end,
            callback = function(touchmenu_instance)
                self:setEnabled(not self.enabled)
                touchmenu_instance:updateItems()
            end,
        },
        {
            text = _("Adjustable mode: constant"),
            enabled_func = function()
                return not self.auto_center
            end,
            radio = true,
            checked_func = function()
                return self.mode == "constant"
            end,
            callback = function(touchmenu_instance)
                self:setMode("constant")
                touchmenu_instance:updateItems()
            end,
        },
        {
            text = _("Adjustable mode: alternating"),
            enabled_func = function()
                return not self.auto_center
            end,
            radio = true,
            checked_func = function()
                return self.mode == "alternating"
            end,
            callback = function(touchmenu_instance)
                self:setMode("alternating")
                touchmenu_instance:updateItems()
            end,
        },
        {
            text_func = function()
                return T(_("Adjust shift: %1% of page width"), string.format("%.2f", self.shift))
            end,
            keep_menu_open = true,
            enabled_func = function()
                return not self.auto_center
            end,
            callback = function()
                self:showShiftDialog()
            end,
        },
        {
            text = _("Reverse shift direction"),
            enabled_func = function()
                return not self.auto_center and self.shift ~= 0
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:reverseShift()
                touchmenu_instance:updateItems()
            end,
        },
    }) do
        table.insert(items, item)
    end
    return items
end

local function menuItemText(item)
    if item.text then
        return item.text
    end
    if item.text_func then
        local ok, item_text = pcall(item.text_func)
        if ok then
            return item_text
        end
    end
end

function MangaCenter:installStyleTweakMenuControls(root)
    for index = #root, 1, -1 do
        if root[index].manga_center_controls then
            table.remove(root, index)
        end
    end

    local menu_item = {
        manga_center_controls = true,
        text_func = function()
            return self:getMenuTitle()
        end,
        sub_item_table_func = function()
            return self:buildControlMenuItems()
        end,
        separator = true,
    }
    local insert_at = #root + 1
    local user_tweaks_text = _("User style tweaks")
    local book_tweak_text = _("Book-specific tweak")
    local edit_book_tweak_text = _("Book-specific tweak (long-press to edit)")
    for index, item in ipairs(root) do
        local item_text = menuItemText(item)
        if item_text == user_tweaks_text then
            insert_at = index + 1
            break
        elseif item_text == book_tweak_text or item_text == edit_book_tweak_text then
            insert_at = index
            break
        end
    end
    table.insert(root, insert_at, menu_item)
    logger.info("MangaCenter: inserted Style tweaks menu entry at", insert_at)
end

function MangaCenter:setupPagingCropRuntime()
    if self._paging_crop_runtime_ready or not self:isPagingDocument() then
        return
    end

    -- Do not install crop-aware page/zoom hooks during plugin init. KOReader may
    -- briefly hold page 1 while its saved location is still being restored;
    -- installing these there would make innocent getZoom()/layout/hint calls
    -- rasterize that transient page. ReaderReady is the first point at which the
    -- real initial page is established, while input is still inhibited.
    --
    -- Only install what is necessary to display that restored page correctly.
    self:installPagingAutoCenterLayout()
    self:installPagingZoomOut()
    self._paging_crop_runtime_ready = true
end

function MangaCenter:setupPagingAuxRuntime()
    if self._paging_aux_runtime_ready or not self:isPagingDocument() then
        return
    end
    -- Continuous-scroll state hooks, panel-aware helpers and custom overlap are
    -- not needed to form the first cropped page. Install them only after input
    -- has been restored so they cannot lengthen the synchronous open path.
    self:installPagingScrollAutoCenter()
    self:applyContinuousOverlap()
    self._paging_aux_runtime_ready = true
end

function MangaCenter:schedulePagingAuxRuntime()
    if self._paging_aux_runtime_ready or self._deferred_paging_setup_task then
        return
    end
    self._deferred_paging_setup_task = function()
        self._deferred_paging_setup_task = nil
        if not self._reader_ready or not self.ui or not self.ui.document then
            return
        end
        local ok, err = pcall(self.setupPagingAuxRuntime, self)
        if not ok then
            logger.warn("MangaCenter: deferred paging setup failed", err)
        end
    end
    -- ReaderUI calls Input:inhibitInputUntil(0.2) immediately after its
    -- ReaderReady/post-ReaderReady phase. Leave a small margin so this auxiliary
    -- setup runs after that startup input gate instead of extending it.
    UIManager:scheduleIn(0.30, self._deferred_paging_setup_task)
end

function MangaCenter:getRestoredPagingPage()
    local view = self.ui and self.ui.view
    local zooming = self.ui and self.ui.zooming
    local page = view and view.state and tonumber(view.state.page)
    if not page or page < 1 then
        page = zooming and tonumber(zooming.current_page)
    end
    if not page or page < 1 then
        return nil
    end
    return math.floor(page)
end

function MangaCenter:primeInitialPagingCrop()
    if not self:isPagingDocument() or not (self.auto_center or self.vertical_fit) then
        return
    end
    local page = self:getRestoredPagingPage()
    if not page then
        logger.warn("MangaCenter: restored page unavailable at ReaderReady; crop will be detected on first real zoom")
        return
    end
    logger.info("MangaCenter: detecting initial crop only for restored page", page)
    local ok, err = pcall(self.getPagingDetectedContent, self, page, false)
    if not ok then
        logger.warn("MangaCenter: initial restored-page crop detection failed", page, err)
    end
end

function MangaCenter:setup()
    if not self:isSupportedDocument() then
        return false
    end

    if not self._setup_done then
        self:loadSettings()
        if self:isPagingDocument() then
            -- Paging runtime setup is deliberately deferred to ReaderReady.
            -- Loading settings here is enough for menus/dispatcher actions and
            -- guarantees we cannot analyze KOReader's transient startup page.
            logger.dbg("MangaCenter: deferring paging hooks until ReaderReady")
        else
            self:installCssProvider()
            self:installAutoCenterRenderer()
        end
        self._setup_done = true
    end

    -- ReaderStyleTweak owns the actual Style tweaks submenu in tweaks_table.
    -- Inject directly into that table instead of relying on ReaderMenu's
    -- temporary menu_items.style_tweaks entry having already been built.
    if self:isRollingDocument() then
        local styletweak = self.ui.styletweak
        if styletweak and styletweak.tweaks_table then
            self:installStyleTweakMenuControls(styletweak.tweaks_table)
        else
            logger.warn("MangaCenter: ReaderStyleTweak tweaks_table is not available")
        end
    end

    return true
end

function MangaCenter:init()
    logger.info("MangaCenter: plugin initialized")
    self:installBundledStyleTweaks()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.document and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:setup()
end

function MangaCenter:onReaderReady()
    if not self:setup() then return end
    self._reader_ready = true
    if self:isPagingDocument() then
        if self._crop_bounds_dirty then
            self:scheduleCropBoundsFlush()
        end
        -- ReaderReady happens after KOReader has restored the actual book
        -- location, but before ReaderUI re-enables input. Do exactly the one
        -- synchronous analysis required to display that restored page correctly.
        self:primeInitialPagingCrop()
        self:setupPagingCropRuntime()

        -- Re-run native zoom/layout now that the crop-aware hooks exist. The
        -- crop lookup for this page is a cache hit, so there is no second raster
        -- analysis. After this page is painted, KOReader's own HintPage pipeline
        -- will ask getZoom(next_page) and pre-render it; our hook will populate
        -- the crop cache for that hinted page as part of the same native flow.
        if self.continuous_width < 100 or self.vertical_fit or self.auto_center then
            self:refreshPagingZoom()
        else
            UIManager:setDirty(self.ui.dialog or nil, "full")
        end
        self:schedulePagingAuxRuntime()
    elseif self.enabled or self.auto_center then
        self:apply()
    end
end

function MangaCenter:onSaveSettings()
    if self:isSupportedDocument() then
        self:saveSettings()
    end
end

function MangaCenter:onCloseDocument()
    if self.ui and self.ui.doc_settings then
        self:saveSettings()
        if self:isPagingDocument() and self._crop_bounds_dirty then
            self:flushCropBounds()
        end
    end
    if self._crop_flush_task then
        UIManager:unschedule(self._crop_flush_task)
        self._crop_flush_task = nil
    end
    self._reader_ready = false
    self._paging_crop_runtime_ready = false
    self._paging_aux_runtime_ready = false
    if self._deferred_paging_setup_task then
        UIManager:unschedule(self._deferred_paging_setup_task)
        self._deferred_paging_setup_task = nil
    end
    local view = self.ui and self.ui.view
    if view and view._manga_center_owner == self then
        view._manga_center_owner = nil
        if view._manga_center_original_draw_page_view then
            view.drawPageView = view._manga_center_original_draw_page_view
            view._manga_center_original_draw_page_view = nil
        end
        if view._manga_center_original_recalculate then
            view.recalculate = view._manga_center_original_recalculate
            view._manga_center_original_recalculate = nil
        end
        if view._manga_center_original_draw_page_surround then
            view.drawPageSurround = view._manga_center_original_draw_page_surround
            view._manga_center_original_draw_page_surround = nil
        end
        if view._manga_center_original_get_page_area then
            view.getPageArea = view._manga_center_original_get_page_area
            view._manga_center_original_get_page_area = nil
        end
        if view._manga_center_original_on_set_scroll_mode then
            view.onSetScrollMode = view._manga_center_original_on_set_scroll_mode
            view._manga_center_original_on_set_scroll_mode = nil
        end
        view._manga_center_base_offset_x = nil
        view._manga_center_base_offset_y = nil
        view._manga_center_applied_offset_x = nil
        view._manga_center_applied_offset_y = nil
    end

    local zooming = self.ui and self.ui.zooming
    if zooming and zooming._manga_center_owner == self then
        zooming._manga_center_owner = nil
        if zooming._manga_center_original_get_zoom then
            zooming.getZoom = zooming._manga_center_original_get_zoom
            zooming._manga_center_original_get_zoom = nil
        end
    end

    local paging = self.ui and self.ui.paging
    if paging and paging._manga_center_owner == self then
        paging._manga_center_owner = nil
        if paging._manga_center_original_get_next_page_state then
            paging.getNextPageState = paging._manga_center_original_get_next_page_state
            paging._manga_center_original_get_next_page_state = nil
        end
        if paging._manga_center_original_get_prev_page_state then
            paging.getPrevPageState = paging._manga_center_original_get_prev_page_state
            paging._manga_center_original_get_prev_page_state = nil
        end
        if paging._manga_center_original_on_scroll_page_rel then
            paging.onScrollPageRel = paging._manga_center_original_on_scroll_page_rel
            paging._manga_center_original_on_scroll_page_rel = nil
        end
        if paging._manga_center_original_on_pan then
            paging.onPan = paging._manga_center_original_on_pan
            paging._manga_center_original_on_pan = nil
        end
    end
    if paging and paging._manga_center_native_overlap ~= nil then
        paging.overlap = paging._manga_center_native_overlap
        paging._manga_center_native_overlap = nil
    end
end

function MangaCenter:onDispatcherRegisterActions()
    Dispatcher:registerAction("manga_center_set_enabled", {
        category = "string",
        event = "SetMangaCenterEnabled",
        title = _("Manga center: page shift"),
        args = { true, false },
        toggle = { _("On"), _("Off") },
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_toggle_enabled", {
        category = "none",
        event = "ToggleMangaCenterEnabled",
        title = _("Manga center: toggle page shift"),
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_set_mode", {
        category = "string",
        event = "SetMangaCenterMode",
        title = _("Manga center: page shift mode"),
        args = { "constant", "alternating" },
        toggle = { _("Constant"), _("Alternating") },
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_set_shift", {
        category = "absolutenumber",
        event = "SetMangaCenterShift",
        title = _("Manga center: horizontal shift"),
        min = -25,
        max = 25,
        step = 0.25,
        default = 0,
        unit = "%",
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_reverse_shift", {
        category = "none",
        event = "ReverseMangaCenterShift",
        title = _("Manga center: reverse shift direction"),
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_set_auto_center", {
        category = "string",
        event = "SetMangaCenterAutoCenter",
        title = _("Manga center: automatic visible-content centering"),
        args = { true, false },
        toggle = { _("On"), _("Off") },
        reader = true,
    })
    Dispatcher:registerAction("manga_center_toggle_auto_center", {
        category = "none",
        event = "ToggleMangaCenterAutoCenter",
        title = _("Manga center: toggle automatic centering"),
        reader = true,
    })
    Dispatcher:registerAction("manga_center_set_vertical_fit", {
        category = "string",
        event = "SetMangaCenterVerticalFit",
        title = _("Manga center: fit detected content vertically"),
        args = { true, false },
        toggle = { _("On"), _("Off") },
        paging = true,
    })
    Dispatcher:registerAction("manga_center_toggle_vertical_fit", {
        category = "none",
        event = "ToggleMangaCenterVerticalFit",
        title = _("Manga center: toggle vertical fit"),
        paging = true,
    })
    Dispatcher:registerAction("manga_center_set_continuous_width", {
        category = "absolutenumber",
        event = "SetMangaCenterContinuousWidth",
        title = _("Manga center: continuous manga width"),
        min = 50, max = 100, step = 0.1, default = 100, unit = "%",
        paging = true,
    })
    Dispatcher:registerAction("manga_center_set_continuous_overlap", {
        category = "absolutenumber",
        event = "SetMangaCenterContinuousOverlap",
        title = _("Manga center: fallback scroll overlap"),
        min = 0, max = 90, step = 0.1, default = 10, unit = "%",
        paging = true,
    })
    Dispatcher:registerAction("manga_center_reset_continuous_overlap", {
        category = "none",
        event = "ResetMangaCenterContinuousOverlap",
        title = _("Manga center: use KOReader default scroll overlap"),
        paging = true,
    })
    Dispatcher:registerAction("manga_center_set_panel_aware_paging", {
        category = "string",
        event = "SetMangaCenterPanelAwarePaging",
        title = _("Manga center: panel-aware page-down"),
        args = { true, false },
        toggle = { _("On"), _("Off") },
        paging = true,
    })
    Dispatcher:registerAction("manga_center_set_on_release_scroll_multiplier", {
        category = "absolutenumber",
        event = "SetMangaCenterOnReleaseScrollMultiplier",
        title = _("Manga center: continuous scroll gesture multiplier"),
        min = 0.25, max = 10, step = 0.05, default = 1, unit = "x",
        paging = true,
    })
end

function MangaCenter:onSetMangaCenterEnabled(enabled)
    if not self:isRollingDocument() then
        return true
    end
    self:setEnabled(enabled == true)
    return true
end

function MangaCenter:onToggleMangaCenterEnabled()
    if not self:isRollingDocument() then
        return true
    end
    self:setEnabled(not self.enabled)
    return true
end

function MangaCenter:onSetMangaCenterMode(mode)
    if not self:isRollingDocument() then
        return true
    end
    self:setMode(mode)
    return true
end

function MangaCenter:onSetMangaCenterShift(shift)
    if not self:isRollingDocument() then
        return true
    end
    self:setShift(shift)
    return true
end

function MangaCenter:onReverseMangaCenterShift()
    if not self:isRollingDocument() then
        return true
    end
    self:reverseShift()
    return true
end

function MangaCenter:onSetMangaCenterAutoCenter(enabled)
    if not self:isSupportedDocument() then
        return true
    end
    self:setAutoCenter(enabled == true)
    return true
end

function MangaCenter:onToggleMangaCenterAutoCenter()
    if not self:isSupportedDocument() then return true end
    self:setAutoCenter(not self.auto_center)
    return true
end

function MangaCenter:onSetMangaCenterVerticalFit(enabled)
    if not self:isPagingDocument() then return true end
    local view = self.ui and self.ui.view
    if view and view.page_scroll then return true end
    self:setVerticalFit(enabled == true)
    return true
end

function MangaCenter:onToggleMangaCenterVerticalFit()
    if not self:isPagingDocument() then return true end
    local view = self.ui and self.ui.view
    if view and view.page_scroll then return true end
    self:setVerticalFit(not self.vertical_fit)
    return true
end

function MangaCenter:onSetMangaCenterContinuousWidth(percent)
    if not self:isPagingDocument() then return true end
    self:setContinuousWidth(percent)
    return true
end

function MangaCenter:onSetMangaCenterContinuousOverlap(percent)
    if not self:isPagingDocument() then return true end
    self:setContinuousOverlap(percent)
    return true
end

function MangaCenter:onResetMangaCenterContinuousOverlap()
    if not self:isPagingDocument() then return true end
    self:resetContinuousOverlap()
    return true
end

function MangaCenter:onSetMangaCenterPanelAwarePaging(enabled)
    if not self:isPagingDocument() then return true end
    self:setPanelAwarePaging(enabled == true)
    return true
end

function MangaCenter:onSetMangaCenterOnReleaseScrollMultiplier(multiplier)
    if not self:isPagingDocument() then return true end
    self:setOnReleaseScrollMultiplier(multiplier)
    return true
end

function MangaCenter:addToMainMenu(menu_items)
    -- Rolling-document controls live in KOReader's native Style tweaks menu.
    -- Paging documents expose their auto controls in the Typesetting tab.
    if self:isSupportedDocument() and self.ui.styletweak and self.ui.styletweak.tweaks_table then
        self:installStyleTweakMenuControls(self.ui.styletweak.tweaks_table)
    elseif self:isPagingDocument() then
        menu_items.manga_center = {
            text_func = function()
                return self:getMenuTitle()
            end,
            sorting_hint = "typeset",
            sub_item_table_func = function()
                return self:buildControlMenuItems()
            end,
        }
    end
end

return MangaCenter
