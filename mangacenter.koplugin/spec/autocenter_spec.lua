local AutoCenter = require("mangacenter_autocenter")

local function grayPixel(value)
    local pixel = { a = value }
    pixel.getColor8 = function(self) return self end
    return pixel
end

local BLACK = grayPixel(0)
local TRANSLUCENT = grayPixel(220)
local WHITE = grayPixel(255)

local function fakeBuffer(width, height, ink_left, ink_right)
    return {
        getWidth = function() return width end,
        getHeight = function() return height end,
        getPixel = function(_, x)
            if x >= ink_left and x <= ink_right then
                return BLACK
            end
            return WHITE
        end,
    }
end

local function classifiedEdgeBuffer(width, height, options)
    return {
        getWidth = function() return width end,
        getHeight = function() return height end,
        getPixel = function(_, x, y)
            if options.outer_line_left and x >= options.outer_line_left
                    and x <= options.outer_line_left + 7 then
                return BLACK
            end
            if options.outer_line_right and x >= options.outer_line_right - 7
                    and x <= options.outer_line_right then
                return BLACK
            end
            if options.translator_left and x >= options.translator_left
                    and x <= options.translator_left + 60
                    and ((y >= 280 and y <= 320) or (y >= 900 and y <= 940)) then
                return TRANSLUCENT
            end
            if options.translator_right and x >= options.translator_right - 60
                    and x <= options.translator_right
                    and ((y >= 280 and y <= 320) or (y >= 900 and y <= 940)) then
                return TRANSLUCENT
            end
            if x >= options.ink_left and x <= options.ink_right then
                return BLACK
            end
            return WHITE
        end,
    }
end

describe("MangaCenter auto centering", function()
    it("moves right when the visible ink leans left", function()
        local bb = fakeBuffer(1000, 1400, 100, 700)
        assert.is_true(AutoCenter.detectOffset(bb) > 90)
    end)

    it("moves left when the visible ink leans right", function()
        local bb = fakeBuffer(1000, 1400, 300, 900)
        assert.is_true(AutoCenter.detectOffset(bb) < -90)
    end)

    it("leaves already centered ink unchanged", function()
        local bb = fakeBuffer(1000, 1400, 200, 800)
        assert.are.equal(0, AutoCenter.detectOffset(bb))
    end)

    it("ignores a straight outer rule around an otherwise white strip", function()
        local bb = classifiedEdgeBuffer(1000, 1400, {
            outer_line_left = 20,
            translator_left = 80,
            ink_left = 200,
            ink_right = 800,
        })
        assert.are.equal(0, AutoCenter.detectOffset(bb))
    end)

    it("keeps a straight border when its inside contains the picture", function()
        local bb = classifiedEdgeBuffer(1000, 1400, {
            ink_left = 200,
            ink_right = 800,
        })
        assert.are.equal(0, AutoCenter.detectOffset(bb))
    end)

    it("applies the same outer-rule test on the right edge", function()
        local bb = classifiedEdgeBuffer(1000, 1400, {
            outer_line_right = 980,
            translator_right = 920,
            ink_left = 200,
            ink_right = 800,
        })
        assert.are.equal(0, AutoCenter.detectOffset(bb))
    end)


    it("ignores a short marginal mark when finding sustained boundaries", function()
        local positions, ratios, active = {}, {}, {}
        for x = 0, 996, 4 do
            positions[#positions + 1] = x
            local ratio = 0
            -- Simulate a page number at the far left: locally dark, but too
            -- short vertically to establish a sustained artwork boundary.
            if x >= 48 and x <= 68 then
                ratio = 0.05
            elseif x >= 160 and x <= 840 then
                ratio = 0.65
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local left, right = AutoCenter.findSustainedBounds(
            positions, ratios, active, 1000)
        assert.are.equal(160, left)
        assert.are.equal(840, right)
    end)

    it("uses the same sustained rule for a right-side marginal mark", function()
        local positions, ratios, active = {}, {}, {}
        for x = 0, 996, 4 do
            positions[#positions + 1] = x
            local ratio = 0
            if x >= 160 and x <= 840 then
                ratio = 0.65
            elseif x >= 928 and x <= 948 then
                ratio = 0.05
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local left, right = AutoCenter.findSustainedBounds(
            positions, ratios, active, 1000)
        assert.are.equal(160, left)
        assert.are.equal(840, right)
    end)

    it("keeps multiple real vertical panels separated by a large white gutter", function()
        local positions, ratios, active = {}, {}, {}
        for y = 0, 990, 10 do
            positions[#positions + 1] = y
            local ratio = 0
            if (y >= 100 and y <= 400) or (y >= 650 and y <= 900) then
                ratio = 0.55
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local top, bottom = AutoCenter.findDominantBounds(positions, ratios, active, 1000)
        assert.are.equal(100, top)
        assert.are.equal(900, bottom)
    end)

    it("drops a tiny isolated footer watermark without dropping a real panel", function()
        local positions, ratios, active = {}, {}, {}
        for y = 0, 990, 10 do
            positions[#positions + 1] = y
            local ratio = 0
            if y >= 100 and y <= 720 then
                ratio = 0.55
            elseif y >= 920 and y <= 930 then
                ratio = 0.20
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local top, bottom = AutoCenter.findDominantBounds(positions, ratios, active, 1000)
        assert.are.equal(100, top)
        assert.are.equal(720, bottom)
    end)

    it("protects a smaller outer panel even when the main panel is much larger", function()
        local positions, ratios, active = {}, {}, {}
        for y = 0, 990, 10 do
            positions[#positions + 1] = y
            local ratio = 0
            if y >= 100 and y <= 600 then
                ratio = 0.60
            elseif y >= 820 and y <= 880 then
                ratio = 0.60
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local top, bottom = AutoCenter.findDominantBounds(positions, ratios, active, 1000)
        assert.are.equal(100, top)
        assert.are.equal(880, bottom)
    end)

    it("lets stricter horizontal rejection preserve faint sustained edge content", function()
        local positions, ratios, active = {}, {}, {}
        for x = 0, 990, 10 do
            positions[#positions + 1] = x
            local ratio = 0
            if x >= 40 and x <= 90 then
                ratio = 0.08
            elseif x >= 200 and x <= 800 then
                ratio = 0.55
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local normal_left = AutoCenter.findSustainedBounds(
            positions, ratios, active, 1000, 100)
        local strict_left = AutoCenter.findSustainedBounds(
            positions, ratios, active, 1000, 200)
        assert.are.equal(200, normal_left)
        assert.are.equal(40, strict_left)
    end)

    it("lets stricter vertical rejection protect a small isolated outer panel", function()
        local positions, ratios, active = {}, {}, {}
        for y = 0, 990, 10 do
            positions[#positions + 1] = y
            local ratio = 0
            if y >= 100 and y <= 700 then
                ratio = 0.60
            elseif y >= 900 and y <= 920 then
                ratio = 0.60
            end
            ratios[#ratios + 1] = ratio
            active[#active + 1] = ratio >= 0.035
        end
        local _, normal_bottom = AutoCenter.findDominantBounds(
            positions, ratios, active, 1000, 100)
        local _, strict_bottom = AutoCenter.findDominantBounds(
            positions, ratios, active, 1000, 200)
        assert.are.equal(700, normal_bottom)
        assert.are.equal(920, strict_bottom)
    end)

    it("builds layout-specific cache keys", function()
        assert.are.equal("v12:abc:1000:1400:17", AutoCenter.cacheKey(17, 1000, 1400, "abc"))
    end)


    it("converts a detected content bbox into a native layout shift", function()
        local content = { x0 = 50, y0 = 100, x1 = 850, y1 = 1300 }
        local page = { x0 = 0, y0 = 0, x1 = 1000, y1 = 1400 }
        assert.are.equal(50, AutoCenter.offsetFromContentBBox(content, page, 0, 1000))
        assert.are.equal(-50, AutoCenter.offsetFromContentBBox(content, page, 180, 1000))
    end)

    it("uses the displayed bbox as the centering reference when a page is cropped", function()
        local content = { x0 = 100, y0 = 100, x1 = 800, y1 = 1300 }
        local displayed = { x0 = 50, y0 = 0, x1 = 850, y1 = 1400 }
        assert.are.equal(0, AutoCenter.offsetFromContentBBox(content, displayed, 0, 1000))
    end)

    it("accepts a page whose complete width is visible", function()
        assert.is_true(AutoCenter.isFullWidthVisible(
            { x = 0, w = 1000 }, { x = 0, w = 1000 }))
        assert.is_true(AutoCenter.isFullWidthVisible(
            { x = 100, w = 800 }, { x = 100, w = 800 }))
    end)

    it("rejects horizontally panned or cropped page width", function()
        assert.is_false(AutoCenter.isFullWidthVisible(
            { x = 100, w = 800 }, { x = 0, w = 1000 }))
    end)

    it("builds independent horizontal and vertical crop rectangles", function()
        local content = { x0 = 100, y0 = 80, x1 = 900, y1 = 1280, page_w = 1000, page_h = 1600 }
        local vertical = AutoCenter.getEffectiveCropRect(content, 0, false, true)
        assert.are.same({ x = 0, y = 80, w = 1000, h = 1200, page_w = 1000, page_h = 1600 }, vertical)
        local horizontal = AutoCenter.getEffectiveCropRect(content, 0, true, false)
        assert.are.same({ x = 100, y = 0, w = 800, h = 1600, page_w = 1000, page_h = 1600 }, horizontal)
        local both = AutoCenter.getEffectiveCropRect(content, 0, true, true)
        assert.are.same({ x = 100, y = 80, w = 800, h = 1200, page_w = 1000, page_h = 1600 }, both)
    end)

    it("lets native full width and height modes fit the cropped rectangle", function()
        local crop = { x = 100, y = 80, w = 800, h = 1200 }
        local zoom, zoom_w, zoom_h = AutoCenter.getNativeFitZoom(crop, 800, 1200, "page")
        assert.are.equal(1, zoom)
        assert.are.equal(1, zoom_w)
        assert.are.equal(1, zoom_h)
        assert.are.equal(1, AutoCenter.getNativeFitZoom(crop, 800, 1200, "pagewidth"))
        assert.are.equal(1, AutoCenter.getNativeFitZoom(crop, 800, 1200, "pageheight"))
    end)

    it("allows width mode to be taller than the viewport without restoring cropped footer", function()
        local crop = { x = 100, y = 50, w = 800, h = 1450 }
        local zoom = AutoCenter.getNativeFitZoom(crop, 800, 1200, "pagewidth")
        assert.are.equal(1, zoom)
        assert.is_true(crop.h * zoom > 1200)
    end)
end)
