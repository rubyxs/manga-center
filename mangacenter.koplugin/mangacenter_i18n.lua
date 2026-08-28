local core_gettext = require("gettext")

local DESCRIPTION = [[Center visible manga artwork automatically or shift fixed-layout EPUB images manually.
Manual shifts can be constant or reversed automatically on alternating spine pages.]]
local SHIFT_HELP = [[Positive values move constant-mode images right. Negative values move them left.
In alternating mode, odd spine pages receive the entered shift and even pages receive its opposite.
Applying a non-zero value enables the shift for this book.]]

local translations = {
    zh_CN = {
        ["Manga page shift"] = "漫画页面偏移",
        [DESCRIPTION] =
            "自动居中可见的漫画画面，或手动移动固定版式 EPUB 图像。\n手动偏移可以保持恒定，也可以在相邻书脊页面上自动反向。",
        ["Manga horizontal shift"] = "漫画水平偏移",
        [SHIFT_HELP] =
            "正值将恒定模式的图像向右移动，负值向左移动。\n交替模式下，奇数书脊页面使用输入值，偶数页面使用相反值。\n应用非零值会为本书启用偏移。",
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
    },
    zh_TW = {
        ["Manga page shift"] = "漫畫頁面偏移",
        [DESCRIPTION] =
            "自動置中可見的漫畫畫面，或手動移動固定版面 EPUB 圖像。\n手動偏移可以保持固定，也可以在相鄰書脊頁面上自動反向。",
        ["Manga horizontal shift"] = "漫畫水平偏移",
        [SHIFT_HELP] =
            "正值會將固定模式的圖像向右移動，負值則向左移動。\n交替模式下，奇數書脊頁面使用輸入值，偶數頁面使用相反值。\n套用非零值會為本書啟用偏移。",
        ["No shift"] = "無偏移",
        ["Apply and preview"] = "套用並預覽",
        ["Close"] = "關閉",
        ["Enable adjustable shift for this book"] = "為本書啟用可調偏移",
        ["Adjustable mode: constant"] = "可調模式：固定",
        ["Adjustable mode: alternating"] = "可調模式：交替",
        ["Adjust shift: %1% of page width"] = "調整偏移：頁面寬度的 %1%",
        ["Reverse shift direction"] = "反轉偏移方向",
        ["Auto-center visible image content"] = "自動置中可見圖像內容",
        ["Clear auto-center cache"] = "清除自動置中快取",
        ["Manga page shift (auto)"] = "漫畫頁面偏移（自動）",
        ["Manga center: page shift"] = "漫畫置中：頁面偏移",
        ["Manga center: toggle page shift"] = "漫畫置中：切換頁面偏移",
        ["Manga center: page shift mode"] = "漫畫置中：頁面偏移模式",
        ["Manga center: horizontal shift"] = "漫畫置中：水平偏移",
        ["Manga center: reverse shift direction"] = "漫畫置中：反轉偏移方向",
        ["Manga center: automatic visible-content centering"] = "漫畫置中：自動置中可見內容",
        ["Manga center: toggle automatic centering"] = "漫畫置中：切換自動置中",
        ["Manga page shift (off)"] = "漫畫頁面偏移（關閉）",
        ["Manga page shift (%1%)"] = "漫畫頁面偏移（%1%）",
        ["Toggle manga page shift"] = "切換漫畫頁面偏移",
        ["Manga page shift mode"] = "漫畫頁面偏移模式",
        ["On"] = "開啟",
        ["Off"] = "關閉",
        ["Constant"] = "固定",
        ["Alternating"] = "交替",
        ["Constant shift (static CSS)"] = "固定偏移（靜態 CSS）",
        ["Alternating shift (static CSS)"] = "交替偏移（靜態 CSS）",
    },
}

local language = core_gettext.current_lang
if G_reader_settings and G_reader_settings.readSetting then
    language = G_reader_settings:readSetting("language") or language
end
if type(language) == "string" then
    language = language:match("^[^%.:]+")
    language = language and language:gsub("%-", "_")
end

local normalized_language = language and language:lower()
if normalized_language == "zh"
    or normalized_language == "zh_cn"
    or normalized_language == "zh_sg"
    or (normalized_language and normalized_language:match("^zh_hans"))
then
    language = "zh_CN"
elseif normalized_language == "zh_tw"
    or normalized_language == "zh_hk"
    or normalized_language == "zh_mo"
    or (normalized_language and normalized_language:match("^zh_hant"))
then
    language = "zh_TW"
end

local catalogue = translations[language]

return function(message)
    return catalogue and catalogue[message] or core_gettext(message)
end
