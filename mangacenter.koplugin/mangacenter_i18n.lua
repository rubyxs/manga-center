local core_gettext = require("gettext")

local DESCRIPTION = [[Center visible manga artwork automatically in EPUB, PDF, DjVu, and comic archives, or shift fixed-layout EPUB images manually.
Manual shifts can be constant or reversed automatically on alternating spine pages.]]
local SHIFT_HELP = [[Positive values move constant-mode images right. Negative values move them left.
In alternating mode, odd spine pages receive the entered shift and even pages receive its opposite.
Applying a non-zero value enables the shift for this book.]]
local WIDTH_HELP = [[Applies to PDF, DjVu, and comic archives in continuous view when zoom is set to page width or content width.
100% disables the extra zoom-out.]]
local OVERLAP_HELP = [[Percentage of the visible screen height repeated when panel-aware paging has no structural anchor to snap to. It is also used for ordinary continuous page-down when panel-aware paging is off.
Enter 0 for no overlap. Leave the field blank to use KOReader's native overlap.]]
local ON_RELEASE_HELP = [[Multiplies vertical finger movement in KOReader continuous scrolling.
1.0x keeps native behavior; 0.5x halves it; 2.0x doubles it. It applies to Classic, Turbo, and On-release scrolling.]]

local translations = {
    zh_CN = {
        ["Manga page shift"] = "漫画页面偏移",
        [DESCRIPTION] =
            "在 EPUB、PDF、DjVu 和漫画归档中自动居中可见的漫画画面，或手动移动固定版式 EPUB 图像。\n手动偏移可以保持恒定，也可以在相邻书脊页面上自动反向。",
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
        ["Fit detected image content vertically"] = "纵向适配检测到的图像内容",
        ["Horizontal strip strictness: %1"] = "水平边条严格度：%1",
        ["Vertical strip strictness: %1"] = "垂直边条严格度：%1",
        ["Very loose"] = "很宽松",
        ["Loose"] = "宽松",
        ["Normal"] = "正常",
        ["Strict"] = "严格",
        ["Very strict"] = "很严格",
        ["Manga center: fit detected content vertically"] = "漫画居中：纵向适配检测内容",
        ["Manga center: toggle vertical fit"] = "漫画居中：切换纵向适配",
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
        ["Continuous manga width"] = "连续漫画宽度",
        [WIDTH_HELP] = "适用于连续模式下的 PDF、DjVu 和漫画归档；缩放模式需设为页面宽度或内容宽度。\n100% 表示关闭额外缩小。",
        ["Invalid value. Please enter a value from 50 to 100."] = "数值无效。请输入 50 到 100 之间的数值。",
        ["Continuous manga width: %1%"] = "连续漫画宽度：%1%",
        ["Fallback scroll overlap"] = "后备滚动重叠",
        [OVERLAP_HELP] = "面板感知翻页没有新的结构锚点可对齐时，重复显示的可见屏幕高度百分比；关闭面板感知翻页时，也用于普通连续模式整屏翻页。\n输入 0 表示不重叠；留空则使用 KOReader 原生重叠值。",
        ["Invalid value. Please enter a value from 0 to 90, or leave it blank for KOReader default."] = "数值无效。请输入 0 到 90 之间的数值，或留空以使用 KOReader 默认值。",
        ["Fallback scroll overlap: KOReader default"] = "后备滚动重叠：KOReader 默认值",
        ["Fallback scroll overlap: %1%"] = "后备滚动重叠：%1%",
        ["Manga center (%1% width)"] = "漫画居中（宽度 %1%）",
        ["Manga center (auto, %1% width)"] = "漫画居中（自动，宽度 %1%）",
        ["Manga center: continuous manga width"] = "漫画居中：连续漫画宽度",
        ["Manga center: fallback scroll overlap"] = "漫画居中：后备滚动重叠",
        ["Manga center: use KOReader default scroll overlap"] = "漫画居中：使用 KOReader 默认滚动重叠",
        ["Panel-aware page-down"] = "面板感知向下翻页",
        ["Manga center: panel-aware page-down"] = "漫画居中：面板感知向下翻页",
        ["Continuous scroll gesture multiplier"] = "连续滚动手势倍率",
        [ON_RELEASE_HELP] = "将 KOReader 连续滚动中的纵向手指移动乘以该倍率。\n1.0x 保持原生行为；0.5x 减半；2.0x 加倍。适用于经典滚动、高速滚动和松手时滚动。",
        ["Invalid value. Please enter a multiplier from 0.25 to 10."] = "数值无效。请输入 0.25 到 10 之间的倍率。",
        ["Continuous scroll gesture multiplier: %1x"] = "连续滚动手势倍率：%1x",
        ["Manga center: continuous scroll gesture multiplier"] = "漫画居中：连续滚动手势倍率",
    },
    zh_TW = {
        ["Manga page shift"] = "漫畫頁面偏移",
        [DESCRIPTION] =
            "在 EPUB、PDF、DjVu 和漫畫封裝檔中自動置中可見的漫畫畫面，或手動移動固定版面 EPUB 圖像。\n手動偏移可以保持固定，也可以在相鄰書脊頁面上自動反向。",
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
        ["Fit detected image content vertically"] = "縱向適配偵測到的圖像內容",
        ["Horizontal strip strictness: %1"] = "水平邊條嚴格度：%1",
        ["Vertical strip strictness: %1"] = "垂直邊條嚴格度：%1",
        ["Very loose"] = "很寬鬆",
        ["Loose"] = "寬鬆",
        ["Normal"] = "正常",
        ["Strict"] = "嚴格",
        ["Very strict"] = "很嚴格",
        ["Manga center: fit detected content vertically"] = "漫畫置中：縱向適配偵測內容",
        ["Manga center: toggle vertical fit"] = "漫畫置中：切換縱向適配",
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
        ["Continuous manga width"] = "連續漫畫寬度",
        [WIDTH_HELP] = "適用於連續模式下的 PDF、DjVu 和漫畫封裝檔；縮放模式需設為頁面寬度或內容寬度。\n100% 表示關閉額外縮小。",
        ["Invalid value. Please enter a value from 50 to 100."] = "數值無效。請輸入 50 到 100 之間的數值。",
        ["Continuous manga width: %1%"] = "連續漫畫寬度：%1%",
        ["Fallback scroll overlap"] = "後備捲動重疊",
        [OVERLAP_HELP] = "面板感知翻頁沒有新的結構錨點可對齊時，重複顯示的可見螢幕高度百分比；關閉面板感知翻頁時，也用於一般連續模式整屏翻頁。\n輸入 0 表示不重疊；留空則使用 KOReader 原生重疊值。",
        ["Invalid value. Please enter a value from 0 to 90, or leave it blank for KOReader default."] = "數值無效。請輸入 0 到 90 之間的數值，或留空以使用 KOReader 預設值。",
        ["Fallback scroll overlap: KOReader default"] = "後備捲動重疊：KOReader 預設值",
        ["Fallback scroll overlap: %1%"] = "後備捲動重疊：%1%",
        ["Manga center (%1% width)"] = "漫畫置中（寬度 %1%）",
        ["Manga center (auto, %1% width)"] = "漫畫置中（自動，寬度 %1%）",
        ["Manga center: continuous manga width"] = "漫畫置中：連續漫畫寬度",
        ["Manga center: fallback scroll overlap"] = "漫畫置中：後備捲動重疊",
        ["Manga center: use KOReader default scroll overlap"] = "漫畫置中：使用 KOReader 預設捲動重疊",
        ["Panel-aware page-down"] = "面板感知向下翻頁",
        ["Manga center: panel-aware page-down"] = "漫畫置中：面板感知向下翻頁",
        ["Continuous scroll gesture multiplier"] = "連續捲動手勢倍率",
        [ON_RELEASE_HELP] = "將 KOReader 連續捲動中的縱向手指移動乘以此倍率。\n1.0x 保持原生行為；0.5x 減半；2.0x 加倍。適用於經典捲動、高速捲動和放開時捲動。",
        ["Invalid value. Please enter a multiplier from 0.25 to 10."] = "數值無效。請輸入 0.25 到 10 之間的倍率。",
        ["Continuous scroll gesture multiplier: %1x"] = "連續捲動手勢倍率：%1x",
        ["Manga center: continuous scroll gesture multiplier"] = "漫畫置中：連續捲動手勢倍率",
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
