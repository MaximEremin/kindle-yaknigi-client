-- The screens outside the book: the shelves, Yandex's feed and the search over all its books,
-- with shared bottom navigation and a shortcut back to reading.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Catalogue = require("yaknigi/catalogue")
local Feed = require("yaknigi/feed")
local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")
local ReadMark = require("yaknigi/readmark")
local SearchBox = require("yaknigi/searchbox")
local Shelves = require("yaknigi/shelves")
local Status = require("yaknigi/status")
local Tabs = require("yaknigi/tabs")

local PROGRESS_BADGE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") .. "/progress-badge.svg"

-- item_table holds { text, title, authors, mandatory, card, sign_in, whole, cover, shelf }.
-- What went wrong and what to do about it, each on a line of its own: together they
-- would not fit the width of the screen.
local function retry_label(message, width)
    return VerticalGroup:new{ align = "center",
        Kit.text(message, 18, { max_width = width }),
        Kit.gap(Kit.px(6)),
        Kit.text("Нажмите, чтобы повторить", 16, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = width }),
    }
end

local ROW_BUTTON_W, ROW_ICON = 64, 32

local Library = InputContainer:extend{
    name = "YaknigiLibrary",
    covers_fullscreen = true,
    item_table = nil,
    page = 1,
    view = "home", -- or a shelf's id, "catalogue": all of Yandex's books, "feed" or "feed_section"
    query = nil,
    place = nil, -- a table that outlives this screen, for coming back from a book
    message = nil,
    on_sign_in = nil, -- set when nobody is signed in
    onMenuSelect = nil, -- function(self, item)
    close_callback = nil,
    on_refresh = nil,
    on_settings = nil,
    on_catalogue = nil, -- function(state): asks for the next books found
    on_feed = nil, -- function(state): asks for the next of the feed
    load_feed = nil, -- function(): the feed as it was saved, for showing at once
    on_covers = nil, -- function(cards): gets the covers that are missing
    on_bookshelves = nil, -- function(): Yandex's shelves, on a screen of their own
    on_book_details = nil, -- function(item): show the card of a book in a cover grid
    on_book_menu = nil, -- function(item): what can be done with a book
    on_add = nil, -- function(item): puts a book found into the library
    on_save = nil, -- function(item): saves a book on the device
    book_status = nil, -- function(item): "saving", "whole" or nil
}

function Library:init()
    self.place = self.place or {}
    -- Signed out, there is nothing but the first screen to come back to.
    self.view = not self.on_sign_in and self.place.view or "home"
    self.query = not self.on_sign_in and self.place.query or nil
    self.page = self.place.page or 1
    self.catalogue = self.place.catalogue
    self.collection, self.trail = self.place.collection, self.place.trail or {}
    self.feed, self.section = self.place.feed, self.place.section
    self.feed_page = self.place.feed_page or 1
    if self.view == "catalogue" and not self.catalogue then
        self.view, self.query = "home", nil
    end
    if self.view == "collection" and not self.collection then
        self.view, self.trail = "home", {}
    end
    if (self.view == "feed" or self.view == "feed_section") and not self.feed then
        self.view = "home"
    end
    if self.view == "feed_section" and not self.section then
        self.view, self.page = "feed", self.feed_page
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.stop_status = Status.watch(self)
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

-- How much to scale a picture for it to cover a cell, by file and cell: finding out takes
-- decoding the picture, and a screen is built anew for every cover that arrives.
local fill_factors = {}

--- The factor that makes the picture cover w x h, what stands out being cut off evenly.
local function fill_factor(file, w, h)
    local key = table.concat({ file, w, h }, "|")
    if fill_factors[key] then return fill_factors[key] end
    local fit = ImageWidget:new{ file = file, width = w, height = h, scale_factor = 0 }
    local size = fit:getSize() -- it decodes here: a bad file fails here
    -- A pixel over: the factor is rounded down on the way to a whole number of pixels.
    local factor = fit:getScaleFactor() * math.max((w + 1) / size.w, (h + 1) / size.h)
    fit:free()
    fill_factors[key] = factor
    return factor
end

local function plain_cover(item, w, h, translucent_edge)
    if item.cover then
        local ok, image = pcall(function()
            local widget = ImageWidget:new{
                file = item.cover,
                width = w,
                height = h,
                scale_factor = fill_factor(item.cover, w, h),
            }
            widget:getSize()
            return widget
        end)
        if ok then
            return Kit.RoundedPicture:new{
                inner_w = w,
                inner_h = h,
                radius = translucent_edge and Kit.px(4) or nil,
                border_opacity = translucent_edge and 0.18 or nil,
                CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, image },
            }
        end
    end
    -- No cover yet: a frame with the first letter of the title.
    local letter = (item.title or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
    return FrameContainer:new{
        bordersize = Kit.px(1),
        padding = 0,
        radius = Kit.cover_radius(),
        color = Blitbuffer.COLOR_DARK_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Kit.px(1), h = h - 2 * Kit.px(1) },
            Kit.text(letter, 26, { color = Blitbuffer.COLOR_DARK_GRAY }),
        },
    }
end

local function cover_box(item, w, h, translucent_edge)
    local cover = plain_cover(item, w, h, translucent_edge)
    if item.card and item.card.state == "finished" then return ReadMark.over(cover, w) end
    return cover
end

local function title_box(text, width, size, lines)
    return TextBoxWidget:new{
        text = text,
        face = Kit.face(size),
        bold = true,
        width = width,
        height = math.floor(Kit.face(size).size * 1.3 * lines),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
end

Library.cover_box = cover_box

--- The picture at the right of a row, and what a tap on it does. A book of the library has its
-- menu; a book found is added, then saved, and then has its menu too.
function Library:rowButton(item, height)
    if not item.card then return nil end
    local status = self.book_status and self.book_status(item)
    local name, action
    local function menu() self.on_book_menu(item) end
    if self:ownShelf() and not (item.adding or status == "saving") then
        name, action = "dots", menu -- a book that cannot be read can still be taken off
    elseif item.unavailable then
        name, action = "lock", function() self:onMenuSelect(item) end
    elseif item.adding or status == "saving" then
        name, action = "wait", function() end
    elseif item.kind == "author" or item.kind == "series" or item.kind == "bookshelf"
        or item.kind == "found_shelves" then
        name, action = "chevron.right", function() self:onMenuSelect(item) end
    elseif not item.found then
        name, action = "dots", menu
    elseif status == "whole" then
        name, action = "check", menu
    elseif self:inLibrary(item) or item.in_library then
        name, action = "cloud.down", function() self.on_save(item) end
    else
        name, action = "plus", function() self.on_add(item) end
    end
    return Kit.icon_button(name, height, action, {
        width = Kit.px(ROW_BUTTON_W),
        edge = "right",
        icon_size = Kit.px(ROW_ICON),
    })
end

function Library:row(item, width, height)
    local cover_h = height - Kit.px(16)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(14)
    local button = self:rowButton(item, height)
    local left_w = button and width - Kit.px(ROW_BUTTON_W) or width
    local text_w = left_w - cover_w - gap
    local lines = VerticalGroup:new{ align = "left",
        title_box(item.title or item.text, text_w, 19, 2),
    }
    if item.authors and item.authors ~= "" then
        lines[#lines + 1] = Kit.text(item.authors, 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    local state = {}
    -- A book of the feed may well be in the library.
    local mine = item.found and self:inLibrary(item)
    if item.kind_text then state[#state + 1] = item.kind_text end
    if item.mandatory then state[#state + 1] = item.mandatory
    elseif mine then state[#state + 1] = mine.mandatory or "в библиотеке" end
    if item.whole then state[#state + 1] = "скачана" end
    if #state > 0 then
        lines[#lines + 1] = Kit.gap(Kit.px(4))
        lines[#lines + 1] = Kit.text(table.concat(state, " · "), 15, { color = Blitbuffer.COLOR_DARK_GRAY })
    end
    local row = Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = left_w, h = height },
            HorizontalGroup:new{ align = "center",
                cover_box(item, cover_w, cover_h),
                HorizontalSpan:new{ width = gap },
                Kit.fixed(lines, text_w),
            },
        },
    }
    if not button then return row end
    self.row_buttons[item] = button
    -- Side by side: a tap on the picture is not a tap on the book.
    return HorizontalGroup:new{ align = "center", row, button }
end

--- This book as it stands in the library, if it does.
function Library:inLibrary(item)
    if not self.owned then
        self.owned = {}
        for _, mine in ipairs(self.item_table or {}) do
            local book = mine.card and mine.card.book
            if book and book.uuid then self.owned[book.uuid] = mine end
        end
    end
    return self.owned[item.card.book.uuid]
end

local HEADER_H, FOOTER_H, SEARCH_H, ROW_H = 60, 56, 56, 100
local DESIGN_HEADER_H, DESIGN_PAGER_H = 80, 76
local STRIP_HEADING_H = 32
local CARD_LABEL_H, GRID_GAP = 66, 8
local FEED_SECTIONS = 3

local function screen_text(style, text, size, opts)
    opts = opts or {}
    opts.face = Fonts.screen_face(style, size)
    return Kit.text(text, size, opts)
end

local function percentage(item)
    return math.floor(math.max(0, math.min(100, item.percent or 0)))
end

function Library:bottomBar(width, selected, on_select, on_read)
    local item = not self.on_sign_in and Shelves.list(self.item_table or {}, "reading")[1]
    local resume = item and {
        title = item.title or item.text,
        author = item.authors,
        percent = percentage(item),
        cover = function(w, h) return cover_box(item, w, h) end,
        read = function()
            if on_read then on_read() end
            self:onMenuSelect(item)
        end,
    }
    local bar, cells, dock = Tabs.bar(width, selected, on_select, resume)
    return bar, cells, dock, item
end

-- The count and chevron sit by the name, with the full heading width tappable.
local function strip_heading(name, count, width, callback)
    local gap = Kit.px(8)
    local number = screen_text("number", tostring(count), 28)
    local icon = Kit.icon("chevron.right", Kit.px(16))
    local max_width = width - number:getSize().w - icon:getSize().w - 2 * gap
    return Kit.Tappable:new{
        callback = callback,
        LeftContainer:new{ dimen = Geom:new{ w = width, h = Kit.px(STRIP_HEADING_H) },
            HorizontalGroup:new{ align = "center",
                screen_text("heading", name, 28, { max_width = max_width }),
                HorizontalSpan:new{ width = gap },
                number,
                HorizontalSpan:new{ width = gap },
                icon,
            },
        },
    }
end

local function cover_columns(width, count, gap)
    return math.max(1, math.floor((width - (count - 1) * gap) / count))
end

-- Preserve each image's proportions where it fits the row. Crop very tall images in
-- the reserved space so their neighbours can keep the same width and baseline.
local cover_ratios = {}

local function cover_height(item, width, limit)
    if not item.cover then return math.min(limit, math.floor(width * 1.45)) end
    local ratio = cover_ratios[item.cover]
    if not ratio then
        local image = ImageWidget:new{ file = item.cover, scale_factor = 1 }
        local ok = pcall(image.getSize, image)
        if ok then
            ratio = image:getOriginalHeight() / image:getOriginalWidth()
            cover_ratios[item.cover] = ratio
        end
        image:free()
    end
    return math.max(1, math.min(limit, math.floor(width * (ratio or 1.45) + 0.5)))
end

local function cover_with_progress(item, width, height)
    local cover = cover_box(item, width, height, true)
    local badge_w, badge_h = math.min(width, Kit.px(35)), math.min(height, Kit.px(20))
    local text_w, text_h = math.floor(badge_w * 31 / 35), math.floor(badge_h * 16 / 20)
    local label = screen_text("body", percentage(item) .. "%", 11,
        { color = Blitbuffer.Color8(128), max_width = text_w })
    local badge = OverlapGroup:new{
        dimen = Geom:new{ w = badge_w, h = badge_h },
        overlap_offset = { width - badge_w, height - badge_h },
        allow_mirroring = false,
        ImageWidget:new{ file = PROGRESS_BADGE, width = badge_w, height = badge_h, alpha = true, is_icon = true },
        CenterContainer:new{
            dimen = Geom:new{ w = text_w, h = text_h },
            overlap_offset = { badge_w - text_w, badge_h - text_h },
            label,
        },
    }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height },
        allow_mirroring = false, cover, badge }
end

local function card_labels(item, width)
    local labels = VerticalGroup:new{ align = "left", Kit.gap(Kit.px(8)) }
    if item.authors and item.authors ~= "" then
        labels[#labels + 1] = screen_text("body", item.authors, 11,
            { max_width = width, color = Kit.paper_muted })
    end
    if item.title and item.title ~= "" then
        local face = Fonts.screen_face("body", 14)
        local line = Kit.px(19)
        labels[#labels + 1] = TextBoxWidget:new{
            text = (item.title:gsub("[\r\n]+", " ")),
            face = face,
            width = width,
            line_height = line / face.size - 1,
            height = 2 * line,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    return labels
end

--- Equal-width covers with a shared baseline. Preview rows can omit book labels.
function Library:coverRow(books, width, max_height, columns, mode, first, gap)
    first, gap = first or 1, gap or Kit.px(GRID_GAP)
    local cover_w = cover_columns(width, columns, gap)
    local row = HorizontalGroup:new{ align = "top" }
    local heights = {}
    local last = math.min(#books, first + columns - 1)
    for i = first, last do
        heights[i] = cover_height(books[i], cover_w, max_height)
    end
    local labels_h = mode == "details" and Kit.px(CARD_LABEL_H) or 0
    for i = first, last do
        local item = books[i]
        local h = heights[i]
        -- Each column gets its share of any rounding left over by the division.
        local x = math.floor((i - first) * (width + gap) / columns)
        local previous = math.floor((i - first - 1) * (width + gap) / columns)
        if i > first then row[#row + 1] = HorizontalSpan:new{ width = x - previous - cover_w } end
        local cover = mode == "reading" and cover_with_progress(item, cover_w, h)
            or cover_box(item, cover_w, h, true)
        local cell = VerticalGroup:new{ align = "left", Kit.gap(max_height - h), cover }
        if labels_h > 0 then
            local labels = card_labels(item, cover_w)
            cell[3] = labels
            cell[4] = Kit.gap(math.max(0, labels_h - labels:getSize().h))
        end
        row[#row + 1] = Kit.Tappable:new{
            callback = function()
                if mode == "reading" then self:onMenuSelect(item)
                else self.on_book_details(item) end
            end,
            cell,
        }
        self.rows[#self.rows + 1] = item
    end
    return row
end

local function quick_link(name, count, width, callback)
    local height = Kit.px(44)
    local side, gap = Kit.px(12), Kit.px(4)
    return Kit.Tappable:new{
        callback = callback,
        LeftContainer:new{ dimen = Geom:new{ w = width, h = height },
            VerticalGroup:new{ align = "left",
                HorizontalGroup:new{ align = "center",
                    screen_text("body", name, 17, { bold = true, max_width = width - side - gap }),
                    HorizontalSpan:new{ width = gap },
                    Kit.icon("chevron.right", side),
                },
                Kit.gap(Kit.px(4)),
                screen_text("body", tostring(count or "–"), 14, { color = Kit.paper_muted }),
            },
        },
    }
end

function Library:homeBody(width, area)
    local body = VerticalGroup:new{ align = "left" }
    local gap = Kit.px(12)
    local columns, cover_gap = 5, Kit.px(15)
    local cover_w = cover_columns(width, columns, cover_gap)
    local free = area - 2 * Kit.px(44) - gap
    local strips, ideal_height = {}, 0
    for _, strip in ipairs {
        { id = "reading", mode = "reading", heading_gap = Kit.px(10), bottom_gap = Kit.px(20), ratio = 1.50 },
        { id = "want", mode = "details", heading_gap = Kit.px(4), bottom_gap = Kit.px(18), ratio = 1.39 },
    } do
        strip.books = Shelves.list(self.item_table, strip.id)
        strip.count = #strip.books
        if strip.id == "reading" then table.remove(strip.books, 1) end -- the latest is in the dock
        if strip.count > 0 then
            strips[#strips + 1] = strip
            free = free - Kit.px(STRIP_HEADING_H) - strip.bottom_gap
            if #strip.books > 0 then
                free = free - strip.heading_gap
                if strip.mode == "details" then free = free - Kit.px(CARD_LABEL_H) end
                strip.ideal = math.floor(cover_w * strip.ratio)
                ideal_height = ideal_height + strip.ideal
            end
        end
    end
    if #strips > 0 then free = free - gap end
    local scale = math.min(1, math.max(0, free) / math.max(1, ideal_height))
    for _, strip in ipairs(strips) do
        local open = function() self:openShelf(strip.id) end
        local group = VerticalGroup:new{ align = "left",
            strip_heading(Shelves.name(strip.id), strip.count, width, open),
        }
        local max_height = math.floor((strip.ideal or 0) * scale)
        if max_height >= Kit.px(45) then
            local row = self:coverRow(strip.books, width, max_height, columns, strip.mode, nil, cover_gap)
            self.strips[strip.id] = row
            group[2] = Kit.gap(strip.heading_gap)
            group[3] = row
        end
        body[#body + 1] = Kit.Tappable:new{ callback = open, group }
        body[#body + 1] = Kit.gap(strip.bottom_gap)
    end
    if #strips > 0 then body[#body + 1] = Kit.gap(Kit.px(12)) end
    local left = math.floor(width / 2)
    local function link(id, w)
        local row
        if id == "bookshelves" then
            row = quick_link("Полки", nil, w, function() self.on_bookshelves() end)
        else
            row = quick_link(Shelves.name(id), #Shelves.list(self.item_table, id), w,
                function() self:openShelf(id) end)
        end
        self.shelf_rows[id] = row
        return row
    end
    body[#body + 1] = HorizontalGroup:new{ link("all", left), link("finished", width - left) }
    body[#body + 1] = Kit.gap(gap)
    body[#body + 1] = HorizontalGroup:new{ link("device", left), link("bookshelves", width - left) }
    return body
end

--- Yandex's recommendations: a few sections to a page, each with a cover preview.
function Library:feedBody(width, area)
    local state = self.feed
    local sections = state.sections
    self.total_pages = math.max(1, math.ceil(#sections / FEED_SECTIONS))
    if #sections > 0 and not state.finished then self.total_pages = self.total_pages + 1 end
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local section_gap = Kit.px(23)
    local heading_gap = Kit.px(9)
    local cell = math.floor((area - (FEED_SECTIONS - 1) * section_gap) / FEED_SECTIONS)
    local heading_h = Kit.px(STRIP_HEADING_H) + heading_gap
    local gap = Kit.px(16)
    local columns = 6
    local cover_w = cover_columns(width, columns, gap)
    local cover_h = math.max(1, math.min(math.floor(cover_w * 1.48), cell - heading_h))
    local body = VerticalGroup:new{ align = "left" }
    self.feed_sections, self.feed_strips = {}, {}
    local start = (self.page - 1) * FEED_SECTIONS + 1
    for i = start, math.min(#sections, start + FEED_SECTIONS - 1) do
        if i > start then body[#body + 1] = Kit.gap(section_gap) end
        local section = sections[i]
        local open = function() self:openSection(section) end
        local heading = strip_heading(section.name, #section.items, width, open)
        local row = self:coverRow(section.items, width, cover_h, columns, "preview", nil, gap)
        self.feed_sections[#self.feed_sections + 1] = heading
        self.feed_strips[#self.feed_strips + 1] = row
        body[#body + 1] = Kit.Tappable:new{ callback = open,
            VerticalGroup:new{ align = "left",
                heading, Kit.gap(heading_gap), row,
            },
        }
    end
    self.retry_button = nil
    if #body == 0 then
        local box = Geom:new{ w = width, h = area }
        if state.failed then
            self.retry_button = Kit.button(
                retry_label(state.failed, width),
                width, Kit.px(2 * ROW_H), function()
                    self.on_feed(state)
                    self:refreshScreen()
                end)
            body[1] = CenterContainer:new{ dimen = box, self.retry_button }
        else
            local text = state.finished and "Здесь пока пусто" or "Загружаю…"
            body[1] = CenterContainer:new{ dimen = box, Kit.text(text, 18, { color = Blitbuffer.COLOR_DARK_GRAY }) }
        end
    end
    return body
end

function Library:sectionBody(width, area)
    local books = self.section.items
    local columns, gap = 4, Kit.px(GRID_GAP)
    local cover_w = cover_columns(width, columns, gap)
    local rows = area >= 2 * Kit.px(CARD_LABEL_H + 52) + Kit.px(20) and 2 or 1
    local cover_h = math.max(1, math.min(math.floor(cover_w * 1.34),
        math.floor((area - (rows - 1) * Kit.px(20)) / rows) - Kit.px(CARD_LABEL_H)))
    local per_page = rows * columns
    self.shown = #books
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local body = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page + 1
    for n = 0, rows - 1 do
        local start = first + n * columns
        if start > #books then break end
        if n > 0 then body[#body + 1] = Kit.gap(Kit.px(20)) end
        body[#body + 1] = self:coverRow(books, width, cover_h, columns, "details", start, gap)
    end
    return body
end

local function page_arrow(icon, width, height, action)
    local image = Kit.icon(icon, Kit.px(24), { alpha = true })
    if not action then
        return Kit.rounded(image, width, height)
    end
    return Kit.round_button(image, width, height, action)
end

function Library:sectionPager(width, height)
    local pill_h = Kit.px(56)
    local pill_w = math.min(Kit.px(120), math.floor(width / 4))
    local first_w = math.min(pill_h, math.floor(width / 8))
    local offset = math.min(Kit.px(10), math.floor(width / 20))
    local arrow_x = first_w + offset
    local box = Geom:new{ w = width, h = height }
    self.prev_button = page_arrow("chevron.left", pill_w, pill_h,
        self.page > 1 and function() self:turn(-1) end or nil)
    self.next_button = page_arrow("chevron.right", pill_w, pill_h,
        self.page < self.total_pages and function() self:turn(1) end or nil)
    local row = OverlapGroup:new{
        dimen = box:copy(),
        allow_mirroring = false,
        CenterContainer:new{ dimen = box:copy(), screen_text("number", tostring(self.page), 36) },
    }
    local function at(w, x, widget)
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = height }, overlap_offset = { x, 0 }, widget }
    end
    row[2] = at(pill_w, arrow_x, self.prev_button)
    row[3] = at(pill_w, width - arrow_x - pill_w, self.next_button)
    self.first_button = nil
    if self.page > 1 then
        self.first_button = Kit.round_button(HorizontalGroup:new{ align = "center",
            Kit.icon("chevron.left", Kit.px(18), { alpha = true }),
            Kit.icon("chevron.left", Kit.px(18), { alpha = true }),
        }, first_w, pill_h, function() self:turn(1 - self.page) end)
        row[4] = at(first_w, 0, self.first_button)
    end
    return row
end

--- A box to tap for typing (see SearchBox), and a way to drop what was searched for.
function Library:searchBar(width)
    local height = Kit.px(44)
    local clear_w = self.query and height or 0
    local icon = Kit.px(26)
    local text_w = width - clear_w - icon - Kit.px(32)
    local box = FrameContainer:new{
        bordersize = Kit.px(1),
        radius = math.floor(height / 2),
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - clear_w - 2 * Kit.px(1), h = height - 2 * Kit.px(1) },
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = Kit.px(14) },
                Kit.icon("tab.search", icon),
                HorizontalSpan:new{ width = Kit.px(10) },
                Kit.text(self.query or "Поиск", 17, {
                    color = not self.query and Blitbuffer.COLOR_DARK_GRAY or nil,
                    max_width = text_w,
                }),
            },
        },
    }
    self.search_bar = Kit.Tappable:new{ callback = function() self:showSearch() end, box }
    local row = HorizontalGroup:new{ align = "center", self.search_bar }
    self.clear_button = nil
    if self.query then
        self.clear_button = Kit.icon_button("close", height, function() self:search("") end, {
            width = clear_w,
            edge = "right",
            icon_size = Kit.px(ROW_ICON),
        })
        row[2] = self.clear_button
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = Kit.px(SEARCH_H) }, row }
end

function Library:listBody(width, area)
    local books = Shelves.list(self.item_table, self.view, self.query)
    self.shown = #books
    local row_h = Kit.px(ROW_H)
    local per_page = math.max(1, math.floor(area / row_h))
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local body = VerticalGroup:new{ align = "left" }
    if #books == 0 then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = width, h = area },
            Kit.text(self.query and "Ничего не нашлось" or "Здесь пока пусто", 18, { color = Blitbuffer.COLOR_DARK_GRAY }),
        }
    end
    local start = (self.page - 1) * per_page + 1
    for i = start, math.min(#books, start + per_page - 1) do
        body[#body + 1] = self:row(books[i], width, row_h)
        self.rows[#self.rows + 1] = books[i]
    end
    return body
end

--- What was found, with the next books asked for before the list runs out of them.
function Library:catalogueBody(width, area, state)
    local books = state.items
    local row_h = Kit.px(ROW_H)
    local per_page = math.max(1, math.floor(area / row_h))
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    -- A page to go on to, when the books for it are still to come.
    if #books > 0 and not state.finished and (#books % per_page == 0 or state.failed) then
        self.total_pages = self.total_pages + 1
    end
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local start = (self.page - 1) * per_page + 1
    local body = VerticalGroup:new{ align = "left" }
    for i = start, math.min(#books, start + per_page - 1) do
        body[#body + 1] = self:row(books[i], width, row_h)
        self.rows[#self.rows + 1] = books[i]
    end
    self.retry_button = nil
    if #self.rows == 0 then
        local box = Geom:new{ w = width, h = area }
        if state.failed then
            self.retry_button = Kit.button(
                retry_label(state.failed, width),
                width, Kit.px(2 * ROW_H), function()
                    self.on_catalogue(state)
                    self:refreshScreen()
                end)
            body[1] = CenterContainer:new{ dimen = box, self.retry_button }
        else
            local text = "Ничего не нашлось"
            if state.kind == "bookshelves" then
                text = state.finished and "Полок пока нет" or "Загружаю…"
            elseif state.kind then
                local nothing = self:ownShelf() and "На полке пока нет книг" or "Здесь нет книг, которые можно читать"
                text = state.finished and nothing or "Загружаю…"
            elseif not state.query then text = "Введите название или автора"
            elseif not state.finished then text = #books == 0 and "Ищу…" or "Загружаю…" end
            body[1] = CenterContainer:new{ dimen = box, Kit.text(text, 18, { color = Blitbuffer.COLOR_DARK_GRAY }) }
        end
    end
    return body
end

function Library:build()
    local W, H = self.dimen.w, self.dimen.h
    local view = self.view
    local home, in_feed, in_search = view == "home", view == "feed", view == "catalogue"
    local section = view == "feed_section"
    local top_level = home or in_feed or in_search
    local redesigned = top_level or section
    local pad = Kit.px(redesigned and 20 or 16)
    local inner = W - 2 * pad
    local row_h = Kit.px(redesigned and DESIGN_HEADER_H or HEADER_H)
    local footer_h = Kit.px((in_feed or section) and DESIGN_PAGER_H or FOOTER_H)
    local header_h = Status.height() + row_h
    self.item_table = self.item_table or {}
    self.rows, self.strips, self.shelf_rows = {}, {}, {}
    self.row_buttons = {}
    self.owned = nil
    self.feed_sections, self.feed_strips = nil, nil
    self.search_bar, self.clear_button, self.retry_button = nil, nil, nil
    self.total_pages = 1

    local tab_bar
    tab_bar, self.tab_cells, self.dock_widget, self.dock_item = self:bottomBar(
        W, self:currentTab(), function(id) self:selectTab(id) end)
    local bottom_h = Tabs.height()
    self.search_top = header_h + Kit.px(1)
    self.search_pad = pad
    local body_top = self.search_top
    local free = H - body_top - bottom_h
    local body, search_bar
    if self.on_sign_in then
        body = Kit.button(Kit.text("Войти в Яндекс", 22, { bold = true }), inner, free, self.on_sign_in)
    elseif in_search then
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:catalogueBody(inner, H - body_top - bottom_h - footer_h, self.catalogue)
    elseif view == "collection" then
        body = self:catalogueBody(inner, free - footer_h, self.collection)
    elseif in_feed then
        body = self:feedBody(inner, free - footer_h)
    elseif section then
        body_top = body_top + Kit.px(12)
        body = self:sectionBody(inner, H - body_top - bottom_h - footer_h)
    elseif #self.item_table == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = free },
            Kit.text(self.message or "Загружаю библиотеку…", 18,
                { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        }
    elseif home then
        body = self:homeBody(inner, free)
    else
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:listBody(inner, H - body_top - bottom_h - footer_h)
    end

    self.back_button, self.search_button, self.upload_button, self.sync_button, self.shelf_button = nil, nil, nil, nil, nil
    local header_row
    local box = Geom:new{ w = W, h = row_h }
    local side = Kit.px(56)
    local icon_side = Kit.px(24)
    if top_level then
        local title = home and "Ваша библиотека" or in_feed and "Яндекс Книги" or "Поиск"
        local actions = HorizontalGroup:new{ align = "center" }
        if not self.on_sign_in then
            local gap = Kit.px(8)
            if home then
                local sync_icon = self.sync_state == "busy" and "wait"
                    or self.sync_state == "failed" and "cloud.off" or nil
                if sync_icon then
                    self.sync_button = Kit.round_button(Kit.icon(sync_icon, icon_side, { alpha = true }),
                        side, side, function()
                            if self.sync_state == "failed" then self:refresh() end
                        end)
                    actions[1] = self.sync_button
                    actions[2] = HorizontalSpan:new{ width = gap }
                end
                if self.on_upload then
                    self.upload_button = Kit.round_button(Kit.icon("plus", icon_side, { alpha = true }),
                        side, side, self.on_upload)
                    actions[#actions + 1] = self.upload_button
                    actions[#actions + 1] = HorizontalSpan:new{ width = gap }
                end
            end
            self.search_button = Kit.round_button(Kit.icon("tab.search", icon_side, { alpha = true }), side, side,
                function() self:openSearch() end, in_search)
            actions[#actions + 1] = self.search_button
        end
        actions[#actions + 1] = HorizontalSpan:new{ width = pad }
        header_row = OverlapGroup:new{
            dimen = box:copy(),
            allow_mirroring = false,
            LeftContainer:new{ dimen = box:copy(),
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = pad },
                    screen_text("heading", title, 38, { max_width = W - actions:getSize().w - pad - Kit.px(8) }),
                },
            },
            RightContainer:new{ dimen = box:copy(), actions },
        }
    elseif section then
        self.back_button = Kit.round_button(Kit.icon("chevron.left", icon_side, { alpha = true }), side, side,
            function() self:goBack() end)
        header_row = OverlapGroup:new{
            dimen = box:copy(),
            allow_mirroring = false,
            CenterContainer:new{ dimen = box:copy(),
                screen_text("heading", self.section.name, 38, { max_width = W - 2 * (side + pad + Kit.px(8)) }) },
            CenterContainer:new{ dimen = Geom:new{ w = side, h = row_h }, overlap_offset = { pad, 0 }, self.back_button },
        }
    else
        self.back_button = Kit.icon_button("chevron.left", side, function() self:goBack() end, { edge = "left", margin = pad })
        local title = view == "collection" and self.collection.title
            or ("%s · %d"):format(Shelves.name(view), self.shown or 0)
        header_row = HorizontalGroup:new{ align = "center",
            Kit.fixed(self.back_button, side),
            CenterContainer:new{
                dimen = Geom:new{ w = W - 2 * side, h = row_h },
                Kit.text(title, 20, { bold = true, max_width = W - 2 * side }),
            },
        }
        local list = view == "collection" and self.collection
        if list and list.kind == "bookshelves" then
            self.shelf_button = Kit.icon_button("plus", side, function() self.on_new_shelf() end,
                { edge = "right", margin = pad })
        elseif list and list.kind == "bookshelf" and list.shelf then
            self.shelf_button = Kit.icon_button("dots", side, function() self.on_shelf_menu(list) end,
                { edge = "right", margin = pad })
        end
        if self.shelf_button then header_row[3] = Kit.fixed(self.shelf_button, side) end
    end
    local header = VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, Status:new{ width = W }, header_row }
    if not redesigned then header[3] = Kit.line(W) end

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        header,
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, body_top }, body },
    }
    if search_bar then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, self.search_top }, search_bar }
    end
    self.prev_button, self.next_button, self.first_button = nil, nil, nil
    if self.total_pages > 1 then
        local pager
        if in_feed or section then
            pager = self:sectionPager(inner, footer_h)
        else
            pager, self.prev_button, self.next_button = Kit.pager(self.page, self.total_pages, inner, footer_h,
                function(delta) self:turn(delta) end)
        end
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - bottom_h - footer_h }, pager }
    end
    frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
        overlap_offset = { 0, H - bottom_h }, tab_bar }
    -- Covers take memory until freed, and a long session turns many pages.
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
    if in_feed then self.feed_page = self.page end
    local place = self.place
    place.view, place.query, place.page = self.view, self.query, self.page
    place.feed, place.section, place.feed_page = self.feed, self.section, self.feed_page
    place.collection, place.trail = self.collection, self.trail
end

--- Which tab this screen belongs to.
function Library:currentTab()
    -- A list belongs where it was opened from.
    local view = self.trail[1] and self.trail[1].view or self.view
    if view == "catalogue" then return "search" end
    if view == "feed" or view == "feed_section" then return "feed" end
    return "library"
end

function Library:selectTab(id)
    logger.info("yaknigi: tab", id)
    if id == "settings" then
        self.on_settings()
    elseif id == "feed" then
        self:openFeed()
    else
        self:goHome()
    end
end

--- Coming to the feed finds it as it was left; a tap on its tab while in it goes to its start.
function Library:openFeed()
    if self.on_sign_in then return self:show("feed") end
    local page = self.view ~= "feed" and self.view ~= "feed_section" and self.feed_page or 1
    local first_time = not self.feed
    if first_time then self.feed = self.load_feed() end
    self:show("feed", nil, page)
    if first_time then self.on_covers(Feed.cards(self.feed.sections, Feed.ROW_COVERS)) end
end

--- Keep any previous query and open the keyboard from the top-level search button.
function Library:openSearch()
    if self.on_sign_in then return end
    if self.view ~= "catalogue" then
        self.catalogue = self.catalogue or Catalogue.new(nil)
        self.place.catalogue = self.catalogue
        self:show("catalogue", self.catalogue.query)
    end
    self:showSearch()
end

--- A section of the feed as a paginated cover grid.
function Library:openSection(section)
    self.section = section
    self:show("feed_section")
    self.on_covers(Catalogue.cards(section.items))
end

--- A series, an author or a serial, on a screen of its own. Back leads to where it was opened from.
function Library:openCollection(state)
    table.insert(self.trail, { view = self.view, query = self.query, page = self.page, collection = self.collection })
    self.collection = state
    self:show("collection")
end

--- The shelf on the screen, if it is one's own.
function Library:ownShelf()
    local state = self.view == "collection" and self.collection
    if state and state.kind == "bookshelf" and type(state.shelf) == "table" and state.shelf.editable == true then
        return state
    end
end

--- Shelves have changed: all that shows them is asked for anew, the one on the screen at once.
-- With leave, the one on the screen is gone, and the way leads back from it.
function Library:reloadShelves(leave)
    local function is_shelves(state) return state and (state.kind == "bookshelves" or state.kind == "bookshelf") end
    for _, step in ipairs(self.trail) do
        if is_shelves(step.collection) then Catalogue.renew(step.collection) end
    end
    if self.view ~= "collection" or not is_shelves(self.collection) then return end
    if leave then
        self:goBack()
    else
        Catalogue.renew(self.collection)
        self:show("collection", nil, self.page)
    end
end

function Library:goBack()
    if self.view == "collection" then
        local back = table.remove(self.trail) or { view = "home" }
        self.collection = back.collection
        self:show(back.view, back.query, back.page)
    elseif self.view == "feed_section" then
        self.section = nil
        self:show("feed", nil, self.feed_page)
    else
        self:goHome()
    end
end

function Library:refresh()
    if self.view == "feed" then
        Feed.renew(self.feed)
        self.on_feed(self.feed)
    else
        self.on_refresh()
    end
end

--- Goes to another screen of the library, without keeping the old one's page.
function Library:show(view, query, page)
    self.view, self.query, self.page = view, query, page or 1
    -- Every other screen is reached by its tab, or is the first of the way back.
    if view ~= "collection" then self.trail, self.collection = {}, nil end
    self:build()
    UIManager:setDirty(self, "partial")
    self:askForMore()
end

--- Near the end of what was found, gets the next books, for the next page to be there.
function Library:askForMore()
    if self.on_sign_in then return end
    local near_end = self.page >= self.total_pages - 1
    if self.view == "catalogue" and near_end then
        self.on_catalogue(self.catalogue)
    elseif self.view == "collection" and near_end then
        self.on_catalogue(self.collection)
    elseif self.view == "feed" and (near_end or self.feed.stale) then
        self.on_feed(self.feed)
    end
end

function Library:openShelf(id)
    logger.info("yaknigi: library shelf", id)
    self:show(id)
end

function Library:goHome()
    self:show("home")
end

--- On a shelf, looks through that shelf; on the search tab, through all of Yandex's books.
function Library:search(query)
    query = query:match("^%s*(.-)%s*$")
    query = query ~= "" and query or nil
    if self.view == "home" or self.view == "feed" or self.view == "feed_section" or self.view == "catalogue" then
        self.catalogue = Catalogue.new(query)
        self.place.catalogue = self.catalogue
        self:show("catalogue", query)
        if not query then self:showSearch() end -- the box comes empty, to type anew
    else
        self:show(self.view, query)
    end
end

function Library:showSearch()
    if self.search_box then return end
    -- The books are mostly in Russian, and the sign-in code leaves the Latin keyboard on.
    if #(G_reader_settings:readSetting("keyboard_layouts") or {}) == 0 then
        G_reader_settings:saveSetting("keyboard_layouts", { "ru", "en" })
    end
    G_reader_settings:saveSetting("keyboard_layout", "ru")
    self.search_box = SearchBox:new{
        text = self.query or "",
        hint = self.view == "catalogue" and "Поиск по всем книгам" or "Поиск по библиотеке",
        top = self.search_top,
        side = self.search_pad,
        height = Kit.px(44),
        strip_h = Kit.px(SEARCH_H),
        on_find = function(text)
            if not self.query and not text:find("%S") then return false end
            UIManager:nextTick(function() self:search(text) end)
        end,
        on_close = function() self.search_box = nil end,
    }
    self.search_box:open()
end

function Library:onCloseWidget()
    self.stop_status()
    if self.search_box then self.search_box:dismiss() end
end

function Library:refreshScreen()
    self:build()
    UIManager:setDirty(self, "ui")
end

--- Same call as KOReader's Menu, used when new data arrives.
function Library:switchItemTable(_, items)
    self.item_table = items
    self:refreshScreen()
end

function Library:setMessage(text)
    self.message = text
    self:refreshScreen()
end

function Library:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.total_pages then return end
    self.page = page
    logger.info("yaknigi: library page", page, "of", self.total_pages)
    self:build()
    UIManager:setDirty(self, "partial")
    self:askForMore()
    -- This page's covers before those of the pages not being looked at.
    local missing = {}
    for _, item in ipairs(self.rows or {}) do
        if item.card and not item.cover then missing[#missing + 1] = item.card end
    end
    if #missing > 0 then self.on_covers(missing) end
end

function Library:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1)
    elseif ges.direction == "south" and (self.view == "home" or self.view == "feed") and not self.on_sign_in then
        -- Pulled down, as on the phone: the library or the feed again from Yandex. In the app the
        -- swipe opens the panel instead, and its sync does the same.
        self:refresh()
    end
    return true
end

--- "busy" while the library syncs, "failed" when it last could not, nil otherwise.
function Library:setSyncState(state)
    if self.sync_state == state then return end
    self.sync_state = state
    if self.view == "home" then self:refreshScreen() end
end

function Library:onClose()
    self.close_callback()
    return true
end

return Library
