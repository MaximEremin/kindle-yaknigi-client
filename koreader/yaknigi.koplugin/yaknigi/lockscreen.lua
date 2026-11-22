-- A full-screen picture for KOReader's usual image screensaver.
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FontList = require("fontlist")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local TextBoxWidget = require("ui/widget/textboxwidget")

local Kit = require("yaknigi/kit")

local Lockscreen = {}

-- Font:getFace resolves bundled files relative to KOReader's fonts directory.
local FONTS = "../plugins/yaknigi.koplugin/yaknigi/lockscreen-fonts/"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local MUTED = Blitbuffer.Color8(128)
local TRACK = Blitbuffer.Color8(214)
local EDGE = Blitbuffer.Color8(235)

local function title_face(size)
    for _, path in ipairs(FontList:getFontList()) do
        local name = path:match("([^/]+)$")
        if name == "PPRightGothic-CompactDark.otf" or name == "PPRightGothic-CompactDark.ttf" then
            local face = Font:getFace(name, size)
            if face then return face end
        end
    end
    return Font:getFace(FONTS .. "Oranienbaum-Regular.ttf", size) or Font:getFace("cfont", size)
end

local function caption_face(size)
    return Font:getFace(FONTS .. "Onest-Regular.otf", size) or Font:getFace("cfont", size)
end

local function text(content, width, face, line_height, lines, color)
    return TextBoxWidget:new{
        text = content,
        width = width,
        face = face,
        alignment = "center",
        fgcolor = color,
        line_height = line_height / face.size - 1,
        height = lines * line_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
end

local function paint_cover(canvas, cover, width, height, top, radius, border_width)
    local scale = math.min(width / cover:getWidth(), height / cover:getHeight())
    local w = math.max(1, math.floor(cover:getWidth() * scale))
    local h = math.max(1, math.floor(cover:getHeight() * scale))
    radius = math.min(radius, math.floor(math.min(w, h) / 2))
    local picture = Kit.RoundedPicture:new{
        inner_w = w,
        inner_h = h,
        radius = radius,
        border_width = border_width,
        border_color = EDGE,
        ImageWidget:new{
            image = cover,
            width = w,
            height = h,
            alpha = true,
            original_in_nightmode = false,
        },
    }
    picture:paintTo(canvas, math.floor((canvas:getWidth() - w) / 2), top + math.floor((height - h) / 2))
    picture:free()
end

function Lockscreen.render(book)
    local w, h = Screen:getWidth(), Screen:getHeight()
    -- KOReader turns image screensavers to portrait before showing them.
    if Screen:getRotationMode() % 2 == 1 then w, h = h, w end

    -- Paper's reference canvas is 600 × 780. Extra screen height goes to the cover.
    local scale = math.min(w / 600, h / 780)
    local function px(value) return math.max(1, math.floor(value * scale + 0.5)) end
    local dpi_scale = Screen:scaleBySize(1000) / 1000
    local function font_size(value) return px(value) / dpi_scale end
    local width = px(540)
    local left = math.floor((w - width) / 2)
    local title = text(book.title, width, title_face(font_size(44)), px(48), 3, BLACK)
    local title_height = math.min(3, title:getAllLineCount()) * px(48)
    local author = book.author ~= "" and text(book.author, width, caption_face(font_size(24)), px(32), 1, MUTED)
    local author_height = author and px(32) + px(4) or 0

    local percent = math.floor(math.max(0, math.min(1, book.ratio)) * 100 + 0.5)
    local bar_height, caption_height = px(4), px(24)
    local caption = text(("Прочитано %d%%"):format(percent),
        width, caption_face(font_size(16)), caption_height, 1, MUTED)
    local info_height = author_height + title_height + px(12) + bar_height + px(4) + caption_height
    local cover = book.cover and RenderImage:renderImageFile(book.cover, false)

    local canvas = Blitbuffer.new(w, h, Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
    canvas:fill(WHITE)
    local top = math.floor((h - info_height) / 2)
    if cover then
        top = h - px(24) - info_height
        paint_cover(canvas, cover, width, top - px(24) * 2, px(24), px(4), px(1))
    end
    if author then
        author:paintTo(canvas, left, top)
        author:free(true)
    end
    title:paintTo(canvas, left, top + author_height)
    title:free(true)

    local bar_top = top + author_height + title_height + px(12)
    local radius = math.floor(bar_height / 2)
    canvas:paintRoundedRect(left, bar_top, width, bar_height, TRACK, radius)
    local filled = math.floor(width * percent / 100 + 0.5)
    if filled > 0 then
        canvas:paintRoundedRect(left, bar_top, filled, bar_height, BLACK, math.min(radius, math.floor(filled / 2)))
    end
    caption:paintTo(canvas, left, bar_top + bar_height + px(4))
    caption:free(true)
    return canvas
end

return Lockscreen
