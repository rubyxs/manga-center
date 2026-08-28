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

    it("builds layout-specific cache keys", function()
        assert.are.equal("v2:abc:1000:1400:17", AutoCenter.cacheKey(17, 1000, 1400, "abc"))
    end)
end)
