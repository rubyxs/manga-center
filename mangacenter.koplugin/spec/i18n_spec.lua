local GetText = require("gettext")

describe("MangaCenter localization", function()
    local original_language
    local original_reader_settings
    local plugin_messages = {
        "Manga page shift",
        [[Center visible manga artwork automatically in EPUB, PDF, DjVu, and comic archives, or shift fixed-layout EPUB images manually.
Manual shifts can be constant or reversed automatically on alternating spine pages.]],
        "Manga horizontal shift",
        [[Positive values move constant-mode images right. Negative values move them left.
In alternating mode, odd spine pages receive the entered shift and even pages receive its opposite.
Applying a non-zero value enables the shift for this book.]],
        "No shift",
        "Apply and preview",
        "Close",
        "Enable adjustable shift for this book",
        "Adjustable mode: constant",
        "Adjustable mode: alternating",
        "Adjust shift: %1% of page width",
        "Reverse shift direction",
        "Auto-center visible image content",
        "Clear auto-center cache",
        "Manga page shift (auto)",
        "Manga center: page shift",
        "Manga center: toggle page shift",
        "Manga center: page shift mode",
        "Manga center: horizontal shift",
        "Manga center: reverse shift direction",
        "Manga center: automatic visible-content centering",
        "Manga center: toggle automatic centering",
        "Manga page shift (off)",
        "Manga page shift (%1%)",
        "Toggle manga page shift",
        "Manga page shift mode",
        "On",
        "Off",
        "Constant",
        "Alternating",
        "Constant shift (static CSS)",
        "Alternating shift (static CSS)",
        "Continuous manga width",
        [[Applies to PDF, DjVu, and comic archives in continuous view when zoom is set to page width or content width.
100% disables the extra zoom-out.]],
        "Invalid value. Please enter a value from 50 to 100.",
        "Continuous manga width: %1%",
        "Fallback scroll overlap",
        [[Percentage of the visible screen height repeated when panel-aware paging has no structural anchor to snap to. It is also used for ordinary continuous page-down when panel-aware paging is off.
Enter 0 for no overlap. Leave the field blank to use KOReader's native overlap.]],
        "Invalid value. Please enter a value from 0 to 90, or leave it blank for KOReader default.",
        "Fallback scroll overlap: KOReader default",
        "Fallback scroll overlap: %1%",
        "Manga center (%1% width)",
        "Manga center (auto, %1% width)",
        "Manga center: continuous manga width",
        "Manga center: fallback scroll overlap",
        "Manga center: use KOReader default scroll overlap",
        "Panel-aware page-down",
        "Manga center: panel-aware page-down",
        "Continuous scroll gesture multiplier",
        [[Multiplies vertical finger movement in KOReader continuous scrolling.
1.0x keeps native behavior; 0.5x halves it; 2.0x doubles it. It applies to Classic, Turbo, and On-release scrolling.]],
        "Invalid value. Please enter a multiplier from 0.25 to 10.",
        "Continuous scroll gesture multiplier: %1x",
        "Manga center: continuous scroll gesture multiplier",
    }

    local function load_translation(language)
        GetText.current_lang = language
        G_reader_settings = nil
        package.loaded.mangacenter_i18n = nil
        return require("mangacenter_i18n")
    end

    before_each(function()
        original_language = GetText.current_lang
        original_reader_settings = G_reader_settings
    end)

    after_each(function()
        GetText.current_lang = original_language
        G_reader_settings = original_reader_settings
        package.loaded.mangacenter_i18n = nil
    end)

    it("translates the Simplified Chinese UI", function()
        local _ = load_translation("zh_CN")
        local expected = {
            ["Manga page shift"] = "漫画页面偏移",
            ["Manga horizontal shift"] = "漫画水平偏移",
            ["No shift"] = "无偏移",
            ["Apply and preview"] = "应用并预览",
            ["Close"] = "关闭",
            ["Enable adjustable shift for this book"] = "为本书启用可调偏移",
            ["Adjustable mode: constant"] = "可调模式：恒定",
            ["Adjustable mode: alternating"] = "可调模式：交替",
            ["Adjust shift: %1% of page width"] = "调整偏移：页面宽度的 %1%",
            ["Reverse shift direction"] = "反转偏移方向",
            ["Auto-center visible image content"] = "自动居中可见图像内容",
            ["Clear auto-center cache"] = "清除自动居中缓存",
            ["Manga page shift (auto)"] = "漫画页面偏移（自动）",
            ["Manga center: page shift"] = "漫画居中：页面偏移",
            ["Manga center: toggle page shift"] = "漫画居中：切换页面偏移",
            ["Manga center: page shift mode"] = "漫画居中：页面偏移模式",
            ["Manga center: horizontal shift"] = "漫画居中：水平偏移",
            ["Manga center: reverse shift direction"] = "漫画居中：反转偏移方向",
            ["Manga center: automatic visible-content centering"] = "漫画居中：自动居中可见内容",
            ["Manga center: toggle automatic centering"] = "漫画居中：切换自动居中",
            ["Manga page shift (off)"] = "漫画页面偏移（关闭）",
            ["Manga page shift (%1%)"] = "漫画页面偏移（%1%）",
            ["Toggle manga page shift"] = "切换漫画页面偏移",
            ["Manga page shift mode"] = "漫画页面偏移模式",
            ["On"] = "开启",
            ["Off"] = "关闭",
            ["Constant"] = "固定",
            ["Alternating"] = "交替",
            ["Constant shift (static CSS)"] = "恒定偏移（静态 CSS）",
            ["Alternating shift (static CSS)"] = "交替偏移（静态 CSS）",
        }

        for source, translation in pairs(expected) do
            assert.are.equal(translation, _(source), source)
        end
    end)

    it("covers every plugin-owned message in both Chinese catalogues", function()
        for _, language in ipairs({ "zh_CN", "zh_TW" }) do
            local translate = load_translation(language)
            for _, message in ipairs(plugin_messages) do
                assert.are_not.equals(message, translate(message), language .. ": " .. message)
            end
        end
    end)

    it("uses Traditional Chinese for Taiwan and other Hant locales", function()
        for _, language in ipairs({ "zh_TW", "zh-HK", "zh_Hant" }) do
            local _ = load_translation(language)
            assert.are.equal("漫畫頁面偏移", _("Manga page shift"))
            assert.are.equal("關閉", _("Close"))
        end
    end)

    it("uses Simplified Chinese for generic and Hans locales", function()
        for _, language in ipairs({ "zh", "zh-CN.UTF-8", "zh_Hans" }) do
            local _ = load_translation(language)
            assert.are.equal("漫画页面偏移", _("Manga page shift"))
        end
    end)

    it("falls back to KOReader gettext for other languages", function()
        local _ = load_translation("C")
        assert.are.equal("Manga page shift", _("Manga page shift"))
    end)
end)
