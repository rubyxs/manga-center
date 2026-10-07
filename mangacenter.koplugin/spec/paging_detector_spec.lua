package.preload["ffi"] = package.preload["ffi"] or function()
    return { loadlib = function() return nil end }
end
package.preload["document/document"] = package.preload["document/document"] or function()
    return {}
end
package.preload["ffi/koptcontext"] = package.preload["ffi/koptcontext"] or function()
    return {}
end

local Detector = require("mangacenter_paging_detector")

describe("MangaCenter fixed-page artwork body", function()
    it("ignores a small left-margin page number", function()
        local components = {
            { x = 160, y = 100, w = 680, h = 1120, area = 761600 },
            { x = 55, y = 1280, w = 22, h = 30, area = 660 },
        }
        local bbox, ignored = Detector.selectArtworkBounds(components, 1000, 1400, 50)
        assert.are.equal(160, bbox.x0)
        assert.are.equal(840, bbox.x1)
        assert.are.equal(1, ignored)
    end)

    it("ignores a small right-margin page number", function()
        local components = {
            { x = 160, y = 100, w = 680, h = 1120, area = 761600 },
            { x = 925, y = 1280, w = 22, h = 30, area = 660 },
        }
        local bbox, ignored = Detector.selectArtworkBounds(components, 1000, 1400, 50)
        assert.are.equal(160, bbox.x0)
        assert.are.equal(840, bbox.x1)
        assert.are.equal(1, ignored)
    end)

    it("keeps small details that overlap the artwork body", function()
        local components = {
            { x = 170, y = 100, w = 660, h = 1120, area = 739200 },
            { x = 160, y = 500, w = 20, h = 18, area = 360 },
            { x = 925, y = 1280, w = 22, h = 30, area = 660 },
        }
        local bbox, ignored = Detector.selectArtworkBounds(components, 1000, 1400, 50)
        assert.are.equal(160, bbox.x0)
        assert.are.equal(830, bbox.x1)
        assert.are.equal(1, ignored)
    end)
end)


describe("MangaCenter Korean-webtoon panel rules", function()
    it("accepts a partial-width thin horizontal rule", function()
        local candidates = Detector.findPanelLineCandidatesFromComponents({
            { x = 120, y = 400, w = 180, h = 3 },
        }, 1000, 1200)
        assert.are.equal(1, #candidates)
        assert.are.equal(402, candidates[1].y)
    end)

    it("combines aligned fragments of one interrupted rule", function()
        local candidates = Detector.findPanelLineCandidatesFromComponents({
            { x = 80, y = 500, w = 65, h = 2 },
            { x = 170, y = 501, w = 70, h = 2 },
        }, 1000, 1200)
        assert.are.equal(1, #candidates)
    end)

    it("rejects fragmented text-like short components", function()
        local candidates = Detector.findPanelLineCandidatesFromComponents({
            { x = 80, y = 500, w = 20, h = 3 },
            { x = 120, y = 500, w = 18, h = 3 },
            { x = 160, y = 501, w = 22, h = 4 },
            { x = 210, y = 500, w = 25, h = 3 },
        }, 1000, 1200)
        assert.are.equal(0, #candidates)
    end)

    it("rejects a wide but tall bubble-like component", function()
        local candidates = Detector.findPanelLineCandidatesFromComponents({
            { x = 120, y = 400, w = 220, h = 70 },
        }, 1000, 1200)
        assert.are.equal(0, #candidates)
    end)


    it("keeps a row-projection start even when component candidates exist elsewhere", function()
        local width, height, viewport = 1000, 1200, 900
        local black, ink = {}, {}
        for y = 1, height do
            black[y], ink[y] = 0, 0
        end
        -- Flat separator before y=300, textured artwork after it.
        black[301] = 240
        for y = 330, 520 do
            black[y] = (y % 2 == 0) and 100 or 20
            ink[y] = (y % 3 == 0) and 650 or 120
        end
        local starts = Detector.findPanelStartsFromRows(
            black, ink, width, height, viewport,
            { { y = 800, score = 0.20, kind = "component" } }, {})
        assert.is_true(#starts >= 1)
        assert.is_true(starts[1] >= 295 and starts[1] <= 305)
    end)

    it("keeps panel end and panel start as separate ordered anchors", function()
        local width, height, viewport = 1000, 1400, 900
        local black, ink = {}, {}
        for y = 1, height do black[y], ink[y] = 0, 0 end
        -- Artwork -> separator at 500.
        for y = 250, 470 do
            black[y] = (y % 2 == 0) and 120 or 20
            ink[y] = (y % 3 == 0) and 700 or 150
        end
        black[501] = 900
        -- Separator -> artwork at 800.
        black[801] = 900
        for y = 830, 1100 do
            black[y] = (y % 2 == 0) and 140 or 25
            ink[y] = (y % 3 == 0) and 720 or 180
        end
        local anchors = Detector.findPanelAnchorsFromRows(
            black, ink, width, height, viewport, {}, {})
        assert.is_true(#anchors >= 2)
        assert.are.equal("end", anchors[1].kind)
        assert.are.equal("start", anchors[2].kind)
    end)

    it("suppresses horizontal rules inside a rectangular narration box", function()
        local candidates = {
            { y = 400, score = 0.8, kind = "row" },
            { y = 455, score = 0.25, kind = "row" },
            { y = 500, score = 0.8, kind = "row" },
            { y = 720, score = 0.8, kind = "row" },
        }
        Detector.markCaptionBoxCandidates(candidates, {
            { x = 120, y = 400, w = 700, h = 101 },
        }, 1000, 900)
        assert.is_true(candidates[1].caption_box)
        assert.is_true(candidates[2].caption_box)
        assert.is_true(candidates[3].caption_box)
        assert.is_nil(candidates[4].caption_box)
    end)

    it("expands only to a substantial protrusion touching the panel rule", function()
        local start = Detector.expandPanelStartForProtrusions(600, {
            -- small unrelated text: ignored
            { x = 100, y = 520, w = 30, h = 12 },
            -- speech/caption shape touching the rule: included
            { x = 250, y = 500, w = 260, h = 92 },
        }, 1000, 1400, 900)
        assert.is_true(start < 500)
        assert.is_true(start > 485)
    end)

    it("does not drag a start upward through a tall artwork component", function()
        local start = Detector.expandPanelStartForProtrusions(600, {
            { x = 120, y = 180, w = 700, h = 420 },
        }, 1000, 1400, 900)
        assert.are.equal(600, start)
    end)
end)
