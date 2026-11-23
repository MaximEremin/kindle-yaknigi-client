-- Information about a book, with the catalogue's typography and bottom navigation.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")
local Library = require("yaknigi/library")
local Status = require("yaknigi/status")
local Tabs = require("yaknigi/tabs")

local HEADER_H, PAGER_H, CONTROL_H = 72, 76, 56

-- Arrow buttons are the only controls that move the viewport. The container also clips
-- touches so a link scrolled out of view cannot be tapped through the footer.
local PageViewport = ScrollableContainer:extend{
    scroll_bar_width = 0,
    ignore_events = { "touch", "swipe", "hold", "hold_pan", "hold_release", "pan", "pan_release",
        "key_pg_back", "key_pg_fwd" },
}

function PageViewport:initState()
    ScrollableContainer.initState(self)
    self._v_scroll_bar, self._h_scroll_bar = nil, nil
end

function PageViewport:free(full)
    self:reset()
    ScrollableContainer.free(self, full)
end

local function text(style, value, size, opts)
    opts = opts or {}
    opts.face = Fonts.screen_face(style, size)
    return Kit.text(value, size, opts)
end

local function wrapped(face, value, width, alignment, spacing, color)
    return TextBoxWidget:new{
        text = value, face = face, width = width, alignment = alignment,
        line_height = spacing, fgcolor = color,
    }
end

local function rule(width)
    return LineWidget:new{ dimen = Geom:new{ w = width, h = Kit.px(1) }, background = Kit.paper_line }
end

local function place(widget, x, y)
    widget.overlap_offset = { x, y }
    return widget
end

local function centered(widget, width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height or widget:getSize().h }, widget }
end

local function outlined(content, width, height, callback)
    local border = Kit.px(1)
    return Kit.Tappable:new{
        callback = callback,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE, color = Kit.paper_line,
            padding = 0, bordersize = border, radius = math.floor(height / 2),
            centered(content, width - 2 * border, height - 2 * border),
        },
    }
end

local BookCard = InputContainer:extend{
    name = "YaknigiBookCard",
    covers_fullscreen = true,
    item = nil,
    owned = nil,
    bottom_bar = nil,
    page = 1,
    offset = 0,
}

function BookCard:init()
    self.section_screens = self.section_screens or {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.stop_status = Status.watch(self)
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    self:build()
end

function BookCard:hero(width, available)
    local item = self.item
    local names = VerticalGroup:new{ align = "center" }
    if item.authors and item.authors ~= "" then
        names[1] = wrapped(Fonts.screen_face("body", 21), item.authors, width, "center", 0.15, Kit.paper_muted)
        names[2] = Kit.gap(Kit.px(4))
    end
    names[#names + 1] = wrapped(Fonts.screen_face("heading", 50), item.title, width, "center", 0.1)

    self.series_button = nil
    local series = item.series
    if series and self.on_link then
        local title = series.label and (series.title .. " · " .. series.label) or series.title
        local arrow, space = Kit.px(15), Kit.px(7)
        local inset = Kit.px(32)
        local row = HorizontalGroup:new{ align = "center",
            text("body", title, 17, { max_width = math.max(1, width - arrow - space - inset) }),
            HorizontalSpan:new{ width = space }, Kit.icon("chevron.right", arrow, { alpha = true }),
        }
        self.series_button = outlined(row, row:getSize().w + inset, Kit.px(44), function()
            self.on_link("series", series.uuid, series.title)
        end)
        names[#names + 1] = Kit.gap(Kit.px(9))
        names[#names + 1] = self.series_button
    end

    local side = Kit.px(CONTROL_H)
    local actions = HorizontalGroup:new{ align = "center" }
    local gap = Kit.px(8)
    local read_w = math.min(Kit.px(174), width - side - gap)
    self.read_button = Kit.pill("Читать", read_w, side, self.on_read)
    actions[1] = self.read_button
    self.add_button = nil
    if self.on_add or self.owned then
        local icon = self.owned and "check" or "plus"
        local widget = Kit.icon(icon, Kit.px(24), { alpha = true })
        local add = not self.owned and self.on_add
        self.add_button = add and Kit.round_button(widget, side, side, add) or Kit.rounded(widget, side, side, self.owned)
        actions[2] = HorizontalSpan:new{ width = gap }
        actions[3] = self.add_button
    end

    local cover_top, cover_gap = Kit.px(10), Kit.px(16)
    local actions_gap, bottom = Kit.px(16), Kit.px(7)
    local room = available - cover_top - cover_gap - actions_gap - bottom - names:getSize().h - side
    local cover_w = math.max(1, math.min(Kit.px(280), width - 2 * Kit.px(58)))
    local cover_h = math.min(Kit.px(387), math.max(Kit.px(88), room))
    local cover = Library.fit_cover(item, cover_w, cover_h)
    return VerticalGroup:new{ align = "center",
        Kit.gap(cover_top), cover, Kit.gap(cover_gap), names, Kit.gap(actions_gap), actions, Kit.gap(bottom),
    }
end

local function field(label, value, width)
    return VerticalGroup:new{ align = "left",
        text("body", label, 15, { color = Kit.paper_muted, max_width = width }),
        Kit.gap(Kit.px(5)),
        wrapped(Fonts.screen_face("body", 19), value, width, "left", 0.2),
    }
end

function BookCard:details(width)
    local item = self.item
    local body = VerticalGroup:new{ align = "left", Kit.gap(Kit.px(20)) }
    if item.annotation and item.annotation ~= "" then
        local face = Font:getFace("NotoSerif-Regular.ttf", 19) or Kit.face(19)
        body[#body + 1] = wrapped(face, item.annotation, width, "left", 0.32)
        body[#body + 1] = Kit.gap(Kit.px(24))
    end

    if item.year or item.publisher then
        local gap = Kit.px(20)
        local year_w = item.publisher and math.floor((width - gap) / 3) or width
        local fields = HorizontalGroup:new{ align = "top" }
        if item.year then fields[1] = field("Год издания", item.year, year_w) end
        if item.publisher then
            if item.year then fields[#fields + 1] = HorizontalSpan:new{ width = gap } end
            fields[#fields + 1] = field("Издательство", item.publisher, item.year and width - year_w - gap or width)
        end
        body[#body + 1] = rule(width)
        body[#body + 1] = Kit.gap(Kit.px(17))
        body[#body + 1] = fields
        body[#body + 1] = Kit.gap(Kit.px(18))
        body[#body + 1] = rule(width)
    end

    if #item.topics > 0 and self.on_link then
        if item.year or item.publisher then body[#body + 1] = Kit.gap(Kit.px(18)) end
        body[#body + 1] = text("heading", "Жанры", 28)
        body[#body + 1] = Kit.gap(Kit.px(10))
        local gap, inset, height = Kit.px(8), Kit.px(28), Kit.px(44)
        local row, used = HorizontalGroup:new{ align = "center" }, 0
        for _, topic in ipairs(item.topics) do
            local label = text("body", topic.title, 16, { max_width = width - inset })
            local tag_w = label:getSize().w + inset
            if used > 0 and used + gap + tag_w > width then
                body[#body + 1] = row
                body[#body + 1] = Kit.gap(gap)
                row, used = HorizontalGroup:new{ align = "center" }, 0
            end
            if used > 0 then
                row[#row + 1] = HorizontalSpan:new{ width = gap }
                used = used + gap
            end
            local button = outlined(label, tag_w, height, function()
                self.on_link("topic", topic.uuid, topic.title)
            end)
            self.tag_buttons[topic.uuid] = button
            row[#row + 1] = button
            used = used + tag_w
        end
        body[#body + 1] = row
    end
    body[#body + 1] = Kit.gap(Kit.px(16))
    return body
end

function BookCard:relatedBody(width, available)
    local related = self.related
    local count = tostring(#related.items) .. (related.finished and "" or "+")
    self.related_button = Library.strip_heading(related.title, count, width, self.on_related)
    local heading_h = self.related_button:getSize().h + Kit.px(29)
    return VerticalGroup:new{ align = "left",
        Kit.gap(Kit.px(20)), self.related_button, Kit.gap(Kit.px(9)),
        Library.relatedRow(related.items, width, available - heading_h, self.on_book_details),
    }
end

local function page_arrow(rotation, side, height, action)
    local icon = Kit.icon(action and "chevron.right" or "chevron.right.idle", Kit.px(24),
        { alpha = true, rotation_angle = rotation })
    return action and Kit.round_button(icon, side, height, action) or Kit.rounded(icon, side, height)
end

function BookCard:pager(width)
    local height = Kit.px(PAGER_H)
    local side = math.min(Kit.px(120), math.floor(width / 4))
    local left = math.max(0, math.floor((width - 2 * side - Kit.px(172)) / 2))
    local prev = (self.page > 1 or self.offset > 0) and function() self:turn(-1) end
    local next_page = (self.page < self.page_count or self.offset < self.limit) and function() self:turn(1) end
    self.prev_button = page_arrow(90, side, Kit.px(CONTROL_H), prev)
    self.next_button = page_arrow(270, side, Kit.px(CONTROL_H), next_page)
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        centered(text("number", tostring(self.screen_number), 36), width, height),
        place(centered(self.prev_button, side, height), left, 0),
        place(centered(self.next_button, side, height), width - left - side, 0),
    }
end

function BookCard:build()
    local W, H = self.dimen.w, self.dimen.h
    local pad, status_h = Kit.px(20), Status.height()
    local inner = W - 2 * pad
    local header_h, side = Kit.px(HEADER_H), Kit.px(CONTROL_H)
    local bottom_h = self.bottom_bar and Tabs.height() or 0
    local pager_top = H - bottom_h - Kit.px(PAGER_H)
    local item = self.item
    local pages = { self.hero }
    if (item.annotation and item.annotation ~= "") or item.year or item.publisher or #item.topics > 0 then
        pages[#pages + 1] = self.details
    end
    if self.on_related and self.related and #self.related.items > 0 then pages[#pages + 1] = self.relatedBody end
    self.page = math.min(self.page, #pages)
    self.page_count = #pages
    self.read_button, self.add_button, self.series_button, self.related_button = nil, nil, nil, nil
    self.tag_buttons = {}

    local top = self.page == 1 and status_h or status_h + header_h
    local available = math.max(1, pager_top - top)
    local content = pages[self.page](self, inner, available)
    self.limit = math.max(0, content:getSize().h - available)
    self.step = math.max(1, available - Kit.px(24))
    self.offset = math.min(self.offset, self.limit)
    -- A section can take several screens. Count the earlier sections as they were laid out.
    self.section_screens[pages[self.page]] = 1 + math.ceil(self.limit / self.step)
    self.screen_number = 1 + math.ceil(self.offset / self.step)
    for i = 1, self.page - 1 do
        self.screen_number = self.screen_number + (self.section_screens[pages[i]] or 1)
    end
    local viewport = PageViewport:new{ dimen = Geom:new{ x = 0, y = 0, w = inner, h = available }, content }
    viewport:setScrolledOffset(Geom:new{ x = 0, y = self.offset })
    self.cropping_widget = viewport

    self.back_button = Kit.round_button(Kit.icon("chevron.left", Kit.px(24), { alpha = true }),
        side, side, function() self:onClose() end)
    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(), allow_mirroring = false,
        place(viewport, pad, top), Status:new{ width = W },
        place(centered(self.back_button, side, header_h), pad, status_h),
        place(self:pager(inner), pad, pager_top),
    }
    if self.page > 1 then
        local title = text("heading", item.title, 38, { max_width = W - 2 * (side + pad + Kit.px(8)) })
        frame[#frame + 1] = place(centered(title, W, header_h), 0, status_h)
    end
    if self.bottom_bar then
        local bar
        bar, self.tab_cells, self.dock_widget = self.bottom_bar(W)
        frame[#frame + 1] = place(bar, 0, H - bottom_h)
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function BookCard:refresh()
    self:build()
    if UIManager:isWidgetShown(self) then UIManager:setDirty(self, "partial") end
end

function BookCard:turn(direction)
    if direction > 0 and self.offset < self.limit then
        self.offset = math.min(self.offset + self.step, self.limit)
    elseif direction < 0 and self.offset > 0 then
        self.offset = (math.ceil(self.offset / self.step) - 1) * self.step
    else
        local page = self.page + direction
        if page < 1 or page > self.page_count then return end
        self.page, self.offset = page, direction < 0 and math.huge or 0
    end
    self:refresh()
end

function BookCard:onSwipe()
    return true
end

function BookCard:onClose()
    UIManager:close(self)
    if self.on_back then self.on_back() end
    return true
end

function BookCard:onShow()
    UIManager:setDirty(self, "partial")
end

function BookCard:onCloseWidget()
    self.stop_status()
    self[1]:free()
    if self.on_dismiss then self.on_dismiss() end
    UIManager:setDirty(nil, "partial")
end

return BookCard
