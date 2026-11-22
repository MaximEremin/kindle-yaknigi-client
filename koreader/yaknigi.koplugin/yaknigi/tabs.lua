-- Shared bottom navigation and current book on screens outside the reader.
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")

local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")

local Tabs = {}

local DESTINATIONS = {
    { id = "library", icon = "tab.library" },
    { id = "feed", icon = "yandex-books" },
    { id = "settings", icon = "tab.settings" },
}

local function body_text(text, size, opts)
    opts = opts or {}
    opts.face = Fonts.screen_face("body", size)
    return Kit.text(text, size, opts)
end

local function row_height() return Kit.px(60) end

function Tabs.height()
    return row_height() + 2 * Kit.px(16) + Kit.px(1)
end

local function book_widget(width, resume)
    local box = Geom:new{ w = width, h = row_height() }
    if not resume then
        return LeftContainer:new{ dimen = box,
            body_text("Вы ещё не начали читать", 14, { max_width = width, color = Kit.paper_muted }) }
    end

    local gap = Kit.px(8)
    local cover_w = Kit.px(40)
    local label = body_text("Читать", 14, { bold = true })
    local pill_w = label:getSize().w + Kit.px(28)
    local text_w = width - cover_w - pill_w - 2 * gap
    -- Make room for book text first on a narrow screen.
    if text_w < Kit.px(60) then
        text_w = text_w + cover_w + gap
        cover_w = 0
    end
    local row = HorizontalGroup:new{ align = "center" }
    if cover_w > 0 then
        row[1] = resume.cover(cover_w, box.h)
        row[2] = HorizontalSpan:new{ width = gap }
    end
    if text_w >= Kit.px(24) then
        local lines = VerticalGroup:new{ align = "left" }
        if resume.author and resume.author ~= "" then
            lines[1] = body_text(resume.author, 14, { max_width = text_w, color = Kit.paper_muted })
        end
        lines[#lines + 1] = body_text(resume.title, 16, { bold = true, max_width = text_w })
        lines[#lines + 1] = body_text(resume.percent .. "%", 11, { max_width = text_w, color = Kit.paper_muted })
        row[#row + 1] = Kit.fixed(lines, text_w)
        row[#row + 1] = HorizontalSpan:new{ width = gap }
    end
    row[#row + 1] = Kit.rounded(label, math.min(pill_w, width), Kit.px(36))
    local dock = Kit.Tappable:new{ callback = resume.read, LeftContainer:new{ dimen = box, row } }
    return dock, dock
end

function Tabs.bar(width, selected, on_select, resume)
    local pad = math.min(Kit.px(20), math.floor(width / 16))
    local inner = width - 2 * pad
    local side = math.min(Kit.px(56), math.floor(inner / 6))
    local gap = Kit.px(4)
    local divider_w = Kit.px(1)
    local separation = math.min(Kit.px(28), math.floor(inner / 20))
    local dock_w = inner - #DESTINATIONS * side - (#DESTINATIONS - 1) * gap - 2 * separation - divider_w
    local book, dock = book_widget(dock_w, resume)
    local row = HorizontalGroup:new{ align = "center",
        book,
        HorizontalSpan:new{ width = separation },
        LineWidget:new{ dimen = Geom:new{ w = divider_w, h = Kit.px(40) }, background = Kit.paper_line },
        HorizontalSpan:new{ width = separation },
    }
    local cells = {}
    for i, tab in ipairs(DESTINATIONS) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local cell = Kit.round_button(Kit.icon(tab.icon, math.min(Kit.px(24), math.floor(side / 2)), { alpha = true }), side, side,
            function() on_select(tab.id) end, tab.id == selected)
        cells[tab.id] = cell
        row[#row + 1] = cell
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = Tabs.height() },
        VerticalGroup:new{ align = "left",
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Kit.px(1) }, background = Kit.paper_line },
            Kit.gap(Kit.px(16)),
            row,
            Kit.gap(Kit.px(16)),
        },
    }, cells, dock
end

return Tabs
