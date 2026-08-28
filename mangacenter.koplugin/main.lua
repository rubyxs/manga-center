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
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MangaCenterAutoCenter = require("mangacenter_autocenter")
local MangaCenterCSS = require("mangacenter_css")
local _ = require("mangacenter_i18n")
local T = FFIUtil.template

local KEY_ENABLED = "manga_center_enabled"
local KEY_MODE = "manga_center_mode"
local KEY_SHIFT = "manga_center_shift_vw"
local KEY_AUTO_CENTER = "manga_center_auto_center"
local KEY_AUTO_OFFSETS = "manga_center_auto_offsets"
local Screen = Device.screen

local MangaCenter = WidgetContainer:extend{
    name = "mangacenter",
    -- Load once in File Manager so bundled tweaks are copied before the first
    -- ReaderStyleTweak instance scans the user's styletweaks directory.
    is_doc_only = false,
    enabled = false,
    auto_center = false,
    auto_offsets = nil,
    mode = "constant",
    shift = 0,
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

function MangaCenter:isSupportedDocument()
    local document = self.ui and self.ui.document
    return document ~= nil
        and self.ui.styletweak ~= nil
        and self.ui.typeset ~= nil
end

function MangaCenter:loadSettings()
    local settings = self.ui.doc_settings
    self.enabled = settings:isTrue(KEY_ENABLED)
    self.auto_center = settings:isTrue(KEY_AUTO_CENTER)
    self.auto_offsets = settings:readSetting(KEY_AUTO_OFFSETS)
    if type(self.auto_offsets) ~= "table" then
        self.auto_offsets = {}
    end
    self.mode = settings:readSetting(KEY_MODE) == "alternating" and "alternating" or "constant"
    self.shift = tonumber(settings:readSetting(KEY_SHIFT)) or 0
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
    if self.auto_center then
        settings:makeTrue(KEY_AUTO_CENTER)
    else
        settings:delSetting(KEY_AUTO_CENTER)
    end
    if next(self.auto_offsets or {}) then
        settings:saveSetting(KEY_AUTO_OFFSETS, self.auto_offsets)
    else
        settings:delSetting(KEY_AUTO_OFFSETS)
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
    self.ui:handleEvent(Event:new("ApplyStyleSheet"))
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

function MangaCenter:clearAutoCenterCache()
    self.auto_offsets = {}
    self:saveSettings()
    UIManager:setDirty(nil, "full")
end

function MangaCenter:isAutoCenterActive(view)
    return self.auto_center
        and view
        and view.view_mode == "page"
        and self.ui.document:getVisiblePageCount() == 1
        and not Screen.night_mode
end

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
            local detected, detected_offset = pcall(MangaCenterAutoCenter.detectOffset, buffer)
            if detected then
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

function MangaCenter:getMenuTitle()
    if self.auto_center then
        return _("Manga page shift (auto)")
    end
    if not self.enabled then
        return _("Manga page shift (off)")
    end
    return T(_("Manga page shift (%1%)"), string.format("%.2f", self.shift))
end

function MangaCenter:buildControlMenuItems()
    return {
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
            text = _("Clear auto-center cache"),
            enabled_func = function()
                return self.auto_center and next(self.auto_offsets or {}) ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:clearAutoCenterCache()
                touchmenu_instance:updateItems()
            end,
            separator = true,
        },
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
    }
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

function MangaCenter:setup()
    if not self:isSupportedDocument() then
        return false
    end

    if not self._setup_done then
        self:loadSettings()
        self:installCssProvider()
        self:installAutoCenterRenderer()
        self._setup_done = true
    end

    -- ReaderStyleTweak owns the actual Style tweaks submenu in tweaks_table.
    -- Inject directly into that table instead of relying on ReaderMenu's
    -- temporary menu_items.style_tweaks entry having already been built.
    local styletweak = self.ui.styletweak
    if styletweak and styletweak.tweaks_table then
        self:installStyleTweakMenuControls(styletweak.tweaks_table)
    else
        logger.warn("MangaCenter: ReaderStyleTweak tweaks_table is not available")
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
    if self:setup() and self.enabled then
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
    end
    local view = self.ui and self.ui.view
    if view and view._manga_center_owner == self then
        view._manga_center_owner = nil
        if view._manga_center_original_draw_page_view then
            view.drawPageView = view._manga_center_original_draw_page_view
            view._manga_center_original_draw_page_view = nil
        end
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
        rolling = true,
    })
    Dispatcher:registerAction("manga_center_toggle_auto_center", {
        category = "none",
        event = "ToggleMangaCenterAutoCenter",
        title = _("Manga center: toggle automatic centering"),
        rolling = true,
    })
end

function MangaCenter:onSetMangaCenterEnabled(enabled)
    if not self:isSupportedDocument() then
        return true
    end
    self:setEnabled(enabled == true)
    return true
end

function MangaCenter:onToggleMangaCenterEnabled()
    if not self:isSupportedDocument() then
        return true
    end
    self:setEnabled(not self.enabled)
    return true
end

function MangaCenter:onSetMangaCenterMode(mode)
    if not self:isSupportedDocument() then
        return true
    end
    self:setMode(mode)
    return true
end

function MangaCenter:onSetMangaCenterShift(shift)
    if not self:isSupportedDocument() then
        return true
    end
    self:setShift(shift)
    return true
end

function MangaCenter:onReverseMangaCenterShift()
    if not self:isSupportedDocument() then
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
    if not self:isSupportedDocument() then
        return true
    end
    self:setAutoCenter(not self.auto_center)
    return true
end

function MangaCenter:addToMainMenu(menu_items)
    -- No separate top-level menu item. The controls are installed directly
    -- into ReaderStyleTweak.tweaks_table by setup(), so they live inside
    -- KOReader's native Style tweaks menu.
    if self:isSupportedDocument() and self.ui.styletweak and self.ui.styletweak.tweaks_table then
        self:installStyleTweakMenuControls(self.ui.styletweak.tweaks_table)
    end
end

return MangaCenter
