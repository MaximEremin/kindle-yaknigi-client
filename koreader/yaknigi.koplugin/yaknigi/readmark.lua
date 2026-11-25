-- Progress and completion share the bottom-right corner of a fitted cover.
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")

local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")

local ReadMark = {}
local ASSETS = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/"

function ReadMark.over(cover, percent)
    local size = cover:getSize()
    local finished = percent == nil
    local height = math.min(size.w, size.h, Kit.px(20))
    local width = finished and height or math.min(size.w, math.floor(height * 35 / 20))
    local badge = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height },
        overlap_offset = { size.w - width, size.h - height },
        allow_mirroring = false,
        ImageWidget:new{
            file = ASSETS .. (finished and "finished-badge.svg" or "progress-badge.svg"),
            width = width, height = height, alpha = true, is_icon = true,
        },
    }
    if not finished then
        local text_w, text_h = math.floor(width * 31 / 35), math.floor(height * 16 / 20)
        badge[2] = CenterContainer:new{
            dimen = Geom:new{ w = text_w, h = text_h },
            overlap_offset = { width - text_w, height - text_h },
            Kit.text(percent .. "%", 11, {
                face = Fonts.screen_face("body", 11), color = Kit.paper_muted, max_width = text_w,
            }),
        }
    end
    return OverlapGroup:new{
        name = finished and "YaknigiReadTag" or nil,
        dimen = Geom:new{ w = size.w, h = size.h },
        allow_mirroring = false,
        cover, badge,
    }
end

return ReadMark
