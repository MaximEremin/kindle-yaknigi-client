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
local Covers = require("yaknigi/covers")
local Feed = require("yaknigi/feed")
local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")
local ReadMark = require("yaknigi/readmark")
local SearchBox = require("yaknigi/searchbox")
local Shelves = require("yaknigi/shelves")
local Status = require("yaknigi/status")
local Tabs = require("yaknigi/tabs")
local screen_text = Kit.screen_text

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
    view = "home", -- or a shelf's id, "catalogue", "feed" or "collection"
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
    self.feed = self.place.feed
    self.feed_page = self.place.feed_page or 1
    if self.view == "catalogue" and not self.catalogue then
        self.view, self.query = "home", nil
    end
    if self.view == "collection" and not self.collection then
        self.view, self.trail = "home", {}
    end
    if self.view == "feed" and not self.feed then
        self.view = "home"
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.stop_status = Status.watch(self)
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

local function folder_cover(w, h)
    return FrameContainer:new{
        background = Kit.paper_gray,
        bordersize = 0, padding = 0, radius = Kit.px(4),
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
            Kit.icon("folder", Kit.px(32), { alpha = true }),
        },
    }
end

local function plain_cover(item, w, h, translucent_edge)
    if item.cover then
        local ok, image = pcall(function()
            local widget = ImageWidget:new{
                file = item.cover,
                width = w,
                height = h,
                scale_factor = 0,
            }
            widget:getSize()
            return widget
        end)
        if ok then
            local inner_w, inner_h = image:getCurrentWidth(), image:getCurrentHeight()
            -- Align the border with the fitted image inside ImageWidget's larger box.
            image = Kit.Placed:new{ width = inner_w, height = inner_h,
                dx = math.floor((inner_w - w) / 2), dy = math.floor((inner_h - h) / 2), image }
            return Kit.RoundedPicture:new{
                inner_w = inner_w,
                inner_h = inner_h,
                radius = translucent_edge and Kit.px(4) or nil,
                border_opacity = translucent_edge and 0.18 or nil,
                CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, image },
            }
        end
    end
    if item.kind == "bookshelf" then
        return folder_cover(w, h)
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

local function percentage(item)
    return math.floor(math.max(0, math.min(100, item.percent or 0)))
end

local SHELF_LAYERS = { Blitbuffer.Color8(220), Blitbuffer.Color8(192) }

local function shelf_cover(item, w, h, translucent_edge)
    local layers = #SHELF_LAYERS
    local step = math.min(Kit.px(6), math.floor(h / 8))
    local front_h = h - layers * step
    if item.books_count == 0 then return folder_cover(w, front_h) end
    local front = plain_cover(item, w, front_h, translucent_edge)
    local size = front:getSize()
    step = math.min(step, math.floor(size.h / 4), math.floor(size.w / 6))
    if step == 0 then return front end

    local radius = math.min(Kit.px(4), step)
    front.overlap_offset = { 0, layers * step }
    return OverlapGroup:new{
        dimen = Geom:new{ w = size.w, h = size.h + layers * step },
        allow_mirroring = false,
        Kit.Drawn:new{
            width = size.w, height = size.h,
            draw = function(bb, x, y)
                for i, shade in ipairs(SHELF_LAYERS) do
                    local inset = math.floor(size.w * 0.075 * (layers - i + 1))
                    bb:paintRoundedRect(x + inset, y + (i - 1) * step,
                        size.w - 2 * inset, size.h, shade, radius)
                end
            end,
        },
        front,
    }
end

local function cover_box(item, w, h, translucent_edge, progress_item, show_zero)
    if item.kind == "bookshelf" then return shelf_cover(item, w, h, translucent_edge) end
    local cover = plain_cover(item, w, h, translucent_edge)
    local progress = progress_item or item
    if progress.shelf == "finished" or (progress.card and progress.card.state == "finished") then
        return ReadMark.over(cover)
    end
    local percent = percentage(progress)
    if show_zero or (progress_item and percent > 0) then
        return ReadMark.over(cover, percent)
    end
    return cover
end

local function cover_slot(cover, width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, cover }
end

local function title_box(text, width, size, lines)
    local face = Fonts.screen_face("body", size)
    return TextBoxWidget:new{
        text = text,
        face = face,
        bold = true,
        width = width,
        height = math.floor(face.size * 1.3 * lines),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
end

Library.cover_box = cover_box
Library.fit_cover = plain_cover

--- The picture at the right of a row, and what a tap on it does. A book of the library has its
-- menu; a book found is added, then saved, and then has its menu too.
function Library:rowButton(item, height, compact)
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
    elseif Catalogue.is_collection_link(item) then
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
        width = Kit.px(compact and 32 or ROW_BUTTON_W),
        edge = "right",
        margin = compact and Kit.px(4) or nil,
        icon_size = Kit.px(compact and 20 or ROW_ICON),
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
        lines[#lines + 1] = screen_text("body", item.authors, 15, { color = Kit.paper_muted, max_width = text_w })
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
        lines[#lines + 1] = screen_text("body", table.concat(state, " · "), 15,
            { color = Kit.paper_muted, max_width = text_w })
    end
    local row = Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = left_w, h = height },
            HorizontalGroup:new{ align = "center",
                cover_slot(cover_box(item, cover_w, cover_h), cover_w, cover_h),
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

local SEARCH_H, ROW_H = 56, 100
local STRIP_HEADING_H = 32
local CARD_LABEL_H, GRID_GAP = 66, 8
local CARD_LINE_H, CARD_ACTION_H, CARD_ACTION_GAP = 18, 22, 5
local FEED_SECTIONS = 3

function Library:bottomBar(width, selected, on_select, on_read)
    local item = not self.on_sign_in and Shelves.list(self.item_table or {}, "reading")[1]
    local resume = item and {
        title = item.title or item.text,
        author = item.authors,
        percent = percentage(item),
        cover = function(w, h) return cover_slot(cover_box(item, w, h), w, h) end,
        read = function()
            if on_read then on_read() end
            self:onMenuSelect(item)
        end,
    }
    local bar, cells, dock = Tabs.bar(width, selected, on_select, resume)
    return bar, cells, dock, item
end

-- The count and chevron sit by the name, with the full heading width tappable.
function Library.strip_heading(name, count, width, callback)
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

local function card_label_height(mode)
    if mode == "shelf" then
        return Kit.px(CARD_ACTION_GAP) + Kit.px(CARD_ACTION_H) + 2 * Kit.px(CARD_LINE_H)
    elseif mode == "collection" then
        return Kit.px(CARD_LABEL_H + 12)
    end
    return Kit.px(CARD_LABEL_H)
end

local function card_labels(item, width, button, show_collection_details)
    local labels = VerticalGroup:new{ align = "left", Kit.gap(Kit.px(button and CARD_ACTION_GAP or 8)) }
    local shelf = item.kind == "bookshelf"
    local subtitle = shelf and item.kind_text or item.authors
    local meta
    if subtitle and subtitle ~= "" then
        local text_w = button and width - button:getSize().w - Kit.px(4) or width
        meta = screen_text("body", subtitle, 11, { max_width = text_w, color = Kit.paper_muted })
    end
    if button then
        -- Keep the action by the subtitle, with a separate tap target within the column.
        local height = button:getSize().h
        local row = OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height },
            allow_mirroring = false,
            RightContainer:new{ dimen = Geom:new{ w = width, h = height }, button },
        }
        if meta then row[2] = LeftContainer:new{ dimen = Geom:new{ w = meta:getSize().w, h = height }, meta } end
        meta = row
    end
    if meta and not shelf then labels[#labels + 1] = meta end
    if item.title and item.title ~= "" then
        local face = Fonts.screen_face("body", 14)
        local line = Kit.px(CARD_LINE_H)
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
    if meta and shelf then labels[#labels + 1] = meta end
    if show_collection_details then
        local detail = item.kind_text
        if item.unavailable and item.mandatory then
            detail = detail and detail .. " · " .. item.mandatory or item.mandatory
        end
        if detail then
            labels[#labels + 1] = screen_text("body", detail, 11, { max_width = width, color = Kit.paper_muted })
        end
    end
    return labels
end

--- Equal-width columns with a shared cover baseline. Preview rows can omit book labels.
function Library:coverRow(books, width, max_height, columns, mode, first, gap)
    first, gap = first or 1, gap or Kit.px(GRID_GAP)
    local cover_w = cover_columns(width, columns, gap)
    local row = HorizontalGroup:new{ align = "top" }
    local last = math.min(#books, first + columns - 1)
    local with_actions = mode == "shelf"
    local labels_h = (mode == "details" or mode == "collection" or with_actions) and card_label_height(mode) or 0
    for i = first, last do
        local item = books[i]
        -- Each column gets its share of any rounding left over by the division.
        local x = math.floor((i - first) * (width + gap) / columns)
        local previous = math.floor((i - first - 1) * (width + gap) / columns)
        if i > first then row[#row + 1] = HorizontalSpan:new{ width = x - previous - cover_w } end
        local height_limit = item.cover and max_height or math.min(max_height, math.floor(cover_w * 1.45 + 0.5))
        local progress = mode == "shelf" and (not item.found and item
            or (not item.kind and item.card and self:inLibrary(item))) or nil
        local cover = cover_box(item, cover_w, height_limit, true, progress, mode == "reading")
        local h = cover:getSize().h
        local cell = VerticalGroup:new{ align = "left", Kit.gap(max_height - h), cover_slot(cover, cover_w, h) }
        if labels_h > 0 then
            local button = with_actions and item.kind ~= "bookshelf" and
                self:rowButton(item, Kit.px(CARD_ACTION_H), true)
            if button then self.row_buttons[item] = button end
            local labels = card_labels(item, cover_w, button, mode == "collection")
            cell[3] = labels
            cell[4] = Kit.gap(math.max(0, labels_h - labels:getSize().h))
        end
        local tile = Kit.Tappable:new{
            callback = function()
                if mode == "reading" or mode == "shelf"
                    or (mode == "collection" and (item.unavailable or Catalogue.is_collection_link(item))) then
                    self:onMenuSelect(item)
                else self.on_book_details(item) end
            end,
            cell,
        }
        row[#row + 1] = tile
        if with_actions and item.kind == "bookshelf" then self.row_buttons[item] = tile end
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
            Library.strip_heading(Shelves.name(strip.id), strip.count, width, open),
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
        local heading = Library.strip_heading(section.name, #section.items, width, open)
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

local function section_cover_size(width)
    local columns, gap = 4, Kit.px(GRID_GAP)
    return columns, gap, math.floor(cover_columns(width, columns, gap) * 1.34)
end

--- One row, in the same grid as a catalogue section.
function Library.relatedRow(books, width, available, on_book_details)
    local columns, gap, height = section_cover_size(width)
    local row = { rows = {}, on_book_details = on_book_details }
    return Library.coverRow(row, books, width, math.max(1, math.min(height, available - Kit.px(CARD_LABEL_H))),
        columns, "details", 1, gap)
end

function Library:sectionBody(width, area, books, mode, state, empty_text)
    local columns, gap, ideal_h = section_cover_size(width)
    local labels_h, row_gap = card_label_height(mode), Kit.px(20)
    local rows = area >= 2 * (labels_h + Kit.px(52)) + row_gap and 2 or 1
    local cover_h = math.max(1, math.min(ideal_h,
        math.floor((area - (rows - 1) * row_gap) / rows) - labels_h))
    local per_page = rows * columns
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    if state and #books > 0 and not state.finished and (#books % per_page == 0 or state.failed) then
        self.total_pages = self.total_pages + 1
    end
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local body = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page + 1
    for n = 0, rows - 1 do
        local start = first + n * columns
        if start > #books then break end
        if n > 0 then body[#body + 1] = Kit.gap(row_gap) end
        body[#body + 1] = self:coverRow(books, width, cover_h, columns, mode, start, gap)
    end
    if #body == 0 then
        local box = Geom:new{ w = width, h = math.max(1, area) }
        if state and state.failed then
            self.retry_button = Kit.button(retry_label(state.failed, width), width, box.h, function()
                self.on_catalogue(state)
                self:refreshScreen()
            end)
            return self.retry_button
        end
        return CenterContainer:new{ dimen = box,
            Kit.text(state and not state.finished and "Загружаю…" or empty_text, 18,
                { color = Blitbuffer.COLOR_DARK_GRAY, max_width = width }) }
    end
    return body
end

--- A box to tap for typing (see SearchBox), and a way to drop what was searched for.
function Library:searchBar(width)
    local height = Kit.px(44)
    local clear_w = self.query and height or 0
    local icon = Kit.px(26)
    local border = Kit.px(1)
    local left, gap, right = Kit.px(14), Kit.px(10), Kit.px(8)
    local text_w = width - clear_w - 2 * border - icon - left - gap - right
    local box = FrameContainer:new{
        bordersize = border,
        radius = math.floor(height / 2),
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - clear_w - 2 * border, h = height - 2 * border },
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = left },
                Kit.icon("tab.search", icon),
                HorizontalSpan:new{ width = gap },
                screen_text("body", self.query or "Поиск", 17, {
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
            if not state.query then text = "Введите название или автора"
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
    local collection = view == "collection" and self.collection or nil
    local local_shelf = Shelves.name(view)
    local shelf_index = collection and (collection.kind == "bookshelves" or collection.kind == "found_shelves")
    local remote_shelf = collection and collection.kind == "bookshelf"
    local grid = collection or local_shelf
    local shelf_grid = local_shelf or shelf_index or remote_shelf
    local top_level = home or in_feed or in_search
    local pad = Kit.px(Kit.PAGE_PAD)
    local inner = W - 2 * pad
    local footer_h = Kit.px(Kit.PAGE_PAGER_H)
    local header_h = Status.height() + Kit.px(Kit.PAGE_HEADER_H)
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
    local body, search_bar, grid_title, grid_count
    if self.on_sign_in then
        body = Kit.button(Kit.text("Войти в Яндекс", 22, { bold = true }), inner, free, self.on_sign_in)
    elseif in_search then
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:catalogueBody(inner, H - body_top - bottom_h - footer_h, self.catalogue)
    elseif grid then
        local books, empty_text, mode
        if local_shelf then
            search_bar = self:searchBar(inner)
            body_top = body_top + Kit.px(SEARCH_H)
            books = Shelves.list(self.item_table, view, self.query)
            grid_title, grid_count = local_shelf, #books
            empty_text = self.query and "Ничего не нашлось" or self.message or "Здесь пока пусто"
        else
            books = collection.items
            grid_title = collection.title
            local total = remote_shelf and collection.shelf and tonumber(collection.shelf.books_count)
            if shelf_grid then grid_count = total or #books end
            if shelf_index then
                empty_text = "Полок пока нет"
            elseif remote_shelf then
                empty_text = self:ownShelf() and "На полке пока нет книг" or "Здесь нет книг, которые можно читать"
            elseif collection.kind == "feed_section" or collection.kind == "related" then
                mode, empty_text = "details", "Здесь пока пусто"
            else
                mode, empty_text = "collection", "Здесь нет книг, которые можно читать"
            end
        end
        body_top = body_top + Kit.px(12)
        body = self:sectionBody(inner, H - body_top - bottom_h - footer_h, books,
            shelf_grid and "shelf" or mode, collection, empty_text)
    elseif in_feed then
        body = self:feedBody(inner, free - footer_h)
    elseif #self.item_table == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = free },
            Kit.text(self.message or "Загружаю библиотеку…", 18,
                { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        }
    else
        body = self:homeBody(inner, free)
    end

    self.back_button, self.search_button, self.upload_button, self.sync_button, self.shelf_button = nil, nil, nil, nil, nil
    local header_row
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
        header_row = Kit.page_header(W, title, nil, #actions > 0 and actions or nil)
    else
        if collection and collection.kind == "bookshelves" then
            self.shelf_button = Kit.round_button(Kit.icon("plus", icon_side, { alpha = true }),
                side, side, self.on_new_shelf)
        elseif remote_shelf and collection.shelf then
            self.shelf_button = Kit.round_button(Kit.icon("dots", icon_side, { alpha = true }),
                side, side, function() self.on_shelf_menu(collection) end)
        end
        header_row, self.back_button = Kit.page_header(W, grid_title, function() self:goBack() end,
            self.shelf_button, grid_count)
    end
    local header = VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, Status:new{ width = W }, header_row }

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
        pager, self.prev_button, self.next_button, self.first_button = Kit.pager(self.page, self.total_pages, inner,
            footer_h, function(delta) self:turn(delta) end)
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
    place.feed, place.feed_page = self.feed, self.feed_page
    place.collection, place.trail = self.collection, self.trail
end

--- Which tab this screen belongs to.
function Library:currentTab()
    -- A list belongs where it was opened from.
    local view = self.trail[1] and self.trail[1].view or self.view
    if view == "catalogue" then return "search" end
    if view == "feed" then return "feed" end
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
    local in_feed = self.view == "feed" or (self.view == "collection" and self.collection.kind == "feed_section")
    local page = in_feed and 1 or self.feed_page
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
    self:openCollection(Catalogue.collection("feed_section", nil, section.name, section.items))
    self.on_covers(Catalogue.cards(section.items))
end

--- Back leads to the screen and page where the collection was opened.
function Library:openCollection(state, on_back)
    table.insert(self.trail, { view = self.view, query = self.query, page = self.page,
        collection = self.collection, on_back = on_back })
    self.collection = state
    self:show("collection")
    if state.kind == "related" and #self.rows > 0 then self.on_covers(Catalogue.cards(self.rows)) end
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
        if back.on_back then back.on_back() end
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
    if Shelves.name(self.view) then
        self:show(self.view, query)
    else
        self.catalogue = Catalogue.new(query)
        self.place.catalogue = self.catalogue
        self:show("catalogue", query)
        if not query then self:showSearch() end -- the box comes empty, to type anew
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
        if item.card and not Covers.is_list_cover(item.cover) then missing[#missing + 1] = item.card end
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
