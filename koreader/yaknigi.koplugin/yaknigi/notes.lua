-- Bookmarks and highlights of the open book: a plain list with a clear way back.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local NotesLocal = require("yaknigi/notes_local")
local Notice = require("yaknigi/notice")

local NOTE_SHOWN_LETTERS = 300

local Notes = InputContainer:extend{
    name = "YaknigiNotes",
    covers_fullscreen = true,
    ui = nil,
    shell = nil,
    page = 1,
}

function Notes:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.ui.annotation:updatePageNumbers(true)
    self:build()
end

function Notes:row(item, width, height)
    local side = Kit.px(56)
    local text_w = width - 2 * side - Kit.px(8)
    local grey = Blitbuffer.COLOR_DARK_GRAY
    local face = Kit.face(17)
    local lines = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{
            text = item.drawer and (item.text or "") or "Закладка",
            face = face,
            bold = not item.drawer,
            width = text_w,
            height = math.floor(face.size * 1.3 * 2),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        },
    }
    if item.note and item.note ~= "" then
        lines[#lines + 1] = Kit.text(item.note, 15, { max_width = text_w })
    end
    local where = {}
    if item.chapter and item.chapter ~= "" then where[1] = item.chapter end
    -- A skeleton's page numbers say nothing about the book.
    if item.pageno and not self.shell:hasStubs() then where[#where + 1] = "стр. " .. item.pageno end
    lines[#lines + 1] = Kit.text(table.concat(where, " · "), 14, { color = grey, max_width = text_w })
    local tap = Kit.Tappable:new{
        callback = function() self:open(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = text_w, h = height },
            Kit.fixed(lines, text_w),
        },
    }
    -- A closed lock: only this reader sees it. Bookmarks are nobody's to see.
    local lock
    if item.drawer then
        local private = NotesLocal.is_private(item)
        lock = Kit.icon_button(private and "lock" or "lock.open", side, function() self:togglePrivate(item) end)
    end
    local remove = Kit.icon_button("close", side, function() self:askRemove(item) end, { edge = "right" })
    return HorizontalGroup:new{ align = "center", tap, HorizontalSpan:new{ width = Kit.px(8) },
        lock or HorizontalSpan:new{ width = side }, remove },
        tap, remove, lock
end

function Notes:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(Kit.PAGE_PAD)
    local inner = W - 2 * pad
    local header
    header, self.back = Kit.page_header(W, "Заметки", function() self:close() end)
    local header_h, footer_h, row_h = header:getSize().h, Kit.px(Kit.PAGE_PAGER_H), Kit.px(112)
    local line_h = Kit.px(1)
    local items = self.ui.annotation.annotations or {}
    local per_page = math.max(1, math.floor((H - header_h - footer_h) / (row_h + line_h)))
    local pages = math.max(1, math.ceil(#items / per_page))
    self.page = math.max(1, math.min(self.page, pages))
    self.pages = pages

    local body = VerticalGroup:new{ align = "left" }
    self.opens, self.removes, self.locks = {}, {}, {}
    if #items == 0 then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = H - header_h },
            Kit.text("Здесь будут закладки и выделенный текст", 18, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        }
    end
    local first = (self.page - 1) * per_page + 1
    for i = first, math.min(#items, first + per_page - 1) do
        local row, tap, remove, lock = self:row(items[i], inner, row_h)
        self.opens[#self.opens + 1] = tap
        self.removes[#self.removes + 1] = remove
        if lock then self.locks[#self.locks + 1] = lock end
        body[#body + 1] = row
        body[#body + 1] = Kit.line(inner)
    end

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        header,
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, header_h }, body },
    }
    self.prev_button, self.next_button = nil, nil
    if pages > 1 then
        local pager
        pager, self.prev_button, self.next_button = Kit.pager(self.page, pages, inner, footer_h,
            function(delta) self:turn(delta) end)
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - footer_h }, pager }
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function Notes:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    logger.info("yaknigi: notes page", page, "of", self.pages)
    self:build()
    UIManager:setDirty(self, "partial")
end

function Notes:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1) end
    return true
end

function Notes:onShow()
    logger.info("yaknigi: notes open")
    UIManager:setDirty(self, "ui")
    -- Whoever looks here wants what was made on the phone a minute ago.
    self.ui.yaknigi.notes_screen = self
    self.ui.yaknigi:syncNotes()
end

function Notes:onCloseWidget()
    if self.ui.yaknigi and self.ui.yaknigi.notes_screen == self then self.ui.yaknigi.notes_screen = nil end
end

--- The list has changed under it, by a comparison with Yandex.
function Notes:refresh()
    self.ui.annotation:updatePageNumbers(true)
    self:build()
    UIManager:setDirty(self, "ui")
end

function Notes:togglePrivate(item)
    NotesLocal.set_private(self.ui, item, not NotesLocal.is_private(item))
    logger.info("yaknigi: a highlight's privacy changed")
    self:build()
    UIManager:setDirty(self, "ui")
end

function Notes:close()
    logger.info("yaknigi: notes closed")
    UIManager:close(self, "ui")
end

function Notes:open(item)
    local ui = self.ui
    self:close()
    UIManager:nextTick(function()
        ui.link:addCurrentLocationToStack()
        ui.bookmark:gotoBookmark(item.page, item.pos0)
    end)
end

function Notes:askRemove(item)
    UIManager:show(Notice.confirm{
        title = item.drawer and "Удалить выделение?" or "Удалить закладку?",
        ok_text = "Удалить",
        cancel_text = "Отмена",
        ok_callback = function() self:remove(item) end,
    })
end

function Notes:remove(item)
    self.ui.bookmark:removeItem(item)
    -- A bookmark taken away here makes no event of its own.
    self.ui:handleEvent(require("ui/event"):new("YaknigiNotesChanged"))
    logger.info("yaknigi: note removed")
    self:build()
    UIManager:setDirty(self, "ui")
end

--- What a tap on a highlight in the text brings up. KOReader's own panel is behind "Ещё".
function Notes.showHighlightDialog(ui, index)
    local item = ui.annotation.annotations[index]
    local private = NotesLocal.is_private(item)
    local title = private and "Приватная" or "Публичная"
    if item.note and item.note ~= "" then
        local shown = NotesLocal.letters(item.note, NOTE_SHOWN_LETTERS)
        title = shown .. (#shown < #item.note and "…" or "") .. "\n\n" .. title
    end
    local dialog
    local function acting(work)
        return function()
            UIManager:close(dialog)
            work()
        end
    end
    dialog = ButtonDialog:new{
        name = "yaknigi_highlight",
        title = title,
        title_align = "left",
        buttons = {
            { {
                id = "private",
                text = private and "Сделать публичной" or "Сделать приватной",
                callback = acting(function() NotesLocal.set_private(ui, item, not private) end),
            } },
            { {
                id = "note",
                text = item.note and "Изменить заметку" or "Добавить заметку",
                callback = acting(function() ui.highlight:editNote(index) end),
            } },
            {
                { id = "delete", text = "Удалить", callback = acting(function() ui.highlight:deleteHighlight(index) end) },
                { id = "more", text = "Ещё", callback = acting(function() ui.highlight:showHighlightDialog(index) end) },
            },
        },
        anchor = function() return ui.highlight:_getDialogAnchor(dialog, index) end,
    }
    UIManager:show(dialog)
end

return Notes
