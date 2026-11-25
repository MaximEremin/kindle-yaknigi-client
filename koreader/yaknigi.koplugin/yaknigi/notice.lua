-- The app's transient notifications and system dialogs.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Fonts = require("yaknigi/fonts")
local Kit = require("yaknigi/kit")
local Status = require("yaknigi/status")
local Screen = Device.screen

local Notice = {}

local function surface(content, pad, vertical_pad)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Kit.paper_muted,
        bordersize = Kit.px(1),
        radius = Kit.px(22),
        padding = pad,
        padding_top = vertical_pad,
        padding_bottom = vertical_pad,
        content,
    }
end

local function place(owner, frame, screen, y)
    local size = frame:getSize()
    owner.area = Geom:new{ x = math.floor((screen.w - size.w) / 2), y = y, w = size.w, h = size.h }
    frame.overlap_offset = { owner.area.x, y }
    frame.dimen = owner.area:copy()
    owner[1] = OverlapGroup:new{ dimen = screen, allow_mirroring = false, frame }
end

local function text_box(text, width, style, size, line_height, lines)
    local face = Fonts.screen_face(style, size)
    local line = Kit.px(line_height)
    return TextBoxWidget:new{
        text = text, width = width, face = face,
        line_height = line / face.size - 1,
        height = lines and lines * line,
        height_adjust = lines ~= nil,
        height_overflow_show_ellipsis = lines ~= nil,
    }
end

local Toast = Notification:extend{ name = "YaknigiToast", icon = "check" }

local function fitted_width(text, limit, size)
    local widest = 1
    for line in text:gmatch("[^\r\n]+") do
        local label = Kit.screen_text("body", line, size, { max_width = limit })
        local width = label:isTruncated() and limit or math.min(limit, label:getSize().w + Kit.px(2))
        widest = math.max(widest, width)
        label:free()
    end
    return widest
end

function Toast:init()
    local screen = Screen:getSize()
    local pad, gap, icon = Kit.px(16), Kit.px(10), Kit.px(22)
    local limit = math.min(screen.w - 2 * Kit.px(Kit.PAGE_PAD), Kit.px(440))
    local max_width = math.max(1, limit - 2 * (pad + Kit.px(1)) - gap - icon)
    local width = fitted_width(self.text, max_width, 15)
    self.frame = surface(HorizontalGroup:new{ align = "center",
        Kit.icon(self.icon, icon, { alpha = true }), HorizontalSpan:new{ width = gap },
        text_box(self.text, width, "body", 15, 21, 3),
    }, pad, Kit.px(11))
    place(self, self.frame, screen, Status.height() + Kit.px(Kit.PAGE_HEADER_H))
end

local current_toast
function Notice.toast(text, icon, timeout)
    if current_toast and UIManager:isWidgetShown(current_toast) then UIManager:close(current_toast) end
    current_toast = Toast:new{ text = text, icon = icon, timeout = timeout }
    UIManager:show(current_toast)
end

local Panel = FocusManager:extend{
    name = "YaknigiNotice",
    modal = true,
    text = "",
    dismissable = true,
}

function Panel:actionRows(width)
    local rows = VerticalGroup:new{}
    local gap, height = Kit.px(8), Kit.px(46)
    self.buttons, self.layout = {}, self.actions and {} or nil
    for i, actions in ipairs(self.actions or {}) do
        local row = HorizontalGroup:new{ align = "center" }
        local each = math.floor((width - gap * (#actions - 1)) / #actions)
        self.layout[i] = {}
        for j, action in ipairs(actions) do
            local w = j == #actions and width - (each + gap) * (j - 1) or each
            local button = Button:new{
                text = action.text,
                width = w, height = height,
                radius = math.floor(height / 2), bordersize = 0,
                padding_v = 0, padding_h = Kit.px(8),
                background = action.primary and Blitbuffer.COLOR_BLACK or Kit.paper_gray,
                text_font_face = Fonts.screen_face("body", 16).orig_font,
                text_font_size = 16,
                callback = function()
                    UIManager:close(self)
                    if action.callback then action.callback() end
                end,
            }
            if action.primary then button.label_widget.fgcolor = Blitbuffer.COLOR_WHITE end
            self.buttons[action.id] = button
            self.layout[i][j] = button
            if j > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = button
        end
        if i > 1 then rows[#rows + 1] = Kit.gap(gap) end
        rows[#rows + 1] = row
    end
    return rows
end

function Panel:init()
    local screen = Screen:getSize()
    local edge, pad, border = Kit.px(16), Kit.px(24), Kit.px(1)
    local width = math.max(1, math.min(Kit.px(432), screen.w - 2 * edge) - 2 * (pad + border))
    local gap = Kit.px(10)
    local content = VerticalGroup:new{ align = "left" }
    local heading = self.title and text_box(self.title, width, "heading", 30, 34, 2)
    if heading then content[1] = heading end
    local buttons = self:actionRows(width)
    local action_space = #buttons > 0 and buttons:getSize().h + Kit.px(22) or 0
    local heading_space = heading and heading:getSize().h + gap or 0

    if self.text ~= "" then
        local icon_size = self.icon and Kit.px(26) or 0
        local icon_gap = self.icon and gap or 0
        local body_width = math.max(1, width - icon_size - icon_gap)
        if self.icon and not heading and action_space == 0 then
            body_width = fitted_width(self.text, body_width, 17)
        end
        local label = text_box(self.text, body_width, "body", 17, 24)
        local max_height = math.max(Kit.px(24), screen.h - 2 * (edge + pad + border) - action_space - heading_space)
        if label:getSize().h > max_height then
            label:free()
            label = ScrollTextWidget:new{
                text = self.text, width = body_width, height = max_height,
                face = Fonts.screen_face("body", 17), dialog = self,
            }
        end
        if #content > 0 then content[#content + 1] = Kit.gap(gap) end
        if self.icon then
            label = HorizontalGroup:new{ align = "center",
                Kit.icon(self.icon, icon_size, { alpha = true }), HorizontalSpan:new{ width = icon_gap }, label,
            }
        end
        content[#content + 1] = label
    end
    if #buttons > 0 then
        content[#content + 1] = Kit.gap(Kit.px(22))
        content[#content + 1] = buttons
    end
    local frame = surface(content, pad)
    place(self, frame, screen, math.max(0, math.floor((screen.h - frame:getSize().h) / 2)))
    self.ges_events.TapClose = { GestureRange:new{ ges = "tap", range = screen } }
    if self.dismissable and Device:hasKeys() then
        local group = self.close_on_tap and Device.input.group.Any or Device.input.group.Back
        self.key_events.Close = { { group } }
    end
end

function Panel:getVisibleArea()
    return self.area
end

function Panel:onShow()
    UIManager:setDirty(self, "ui", self.area)
    if self.timeout then
        self.close_on_timeout = function()
            self.close_on_timeout = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(self.timeout, self.close_on_timeout)
    end
end

function Panel:onCloseWidget()
    if self.close_on_timeout then
        UIManager:unschedule(self.close_on_timeout)
        self.close_on_timeout = nil
    end
    UIManager:setDirty(nil, "ui", self.area)
end

function Panel:onClose()
    if self.dismissable then
        UIManager:close(self)
        if self.dismiss_callback then self.dismiss_callback() end
    end
    return true
end

function Panel:onTapClose(_, ges)
    if self.close_on_tap or not ges.pos:intersectWith(self.area) then return self:onClose() end
    return true
end

Notice.Panel = Panel

function Notice.message(text, timeout)
    UIManager:show(Panel:new{
        text = text, timeout = timeout, close_on_tap = timeout ~= nil,
        honor_silent_mode = true,
        actions = not timeout and {{ { id = "close", text = "Понятно", primary = true } }} or nil,
    })
end

function Notice.busy(text, timeout)
    return Panel:new{
        text = text, icon = "wait", timeout = timeout, close_on_tap = true, honor_silent_mode = true,
    }
end

function Notice.confirm(options)
    options.actions = {{
        { id = "cancel", text = options.cancel_text or "Отмена", callback = options.cancel_callback },
        { id = "ok", text = options.ok_text or "Подтвердить", callback = options.ok_callback, primary = true },
    }}
    options.dismiss_callback = options.cancel_callback
    return Panel:new(options)
end

return Notice
