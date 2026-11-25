-- Said when Yandex refuses to open a book: what is known of why, and what can be done.
local Notice = require("yaknigi/notice")

local NoAccess = Notice.Panel:extend{
    name = "YaknigiNoAccess",
    verdict = "unknown", -- as in yaknigi/access
    book_title = nil,
}

local TEXTS = {
    none = {
        title = "Нет активной подписки",
        text = "Оформите подписку в приложении Яндекс Книг на телефоне и попробуйте открыть книгу снова.",
    },
    active = {
        title = "Книга недоступна",
        text = "Подписка активна. Возможно, книга не входит в неё или недоступна в вашей стране.",
    },
    unknown = {
        title = "Книга недоступна",
        text = "Проверьте подписку и доступность книги в приложении Яндекс Книг на телефоне.",
    },
}

function NoAccess:init()
    local words = TEXTS[self.verdict] or TEXTS.unknown
    local book = self.book_title and self.book_title ~= "" and ("«" .. self.book_title .. "»\n\n") or ""
    self.title, self.text = words.title, book .. words.text
    self.actions = {{ { id = "close", text = "Понятно", primary = true } }}
    Notice.Panel.init(self)
    self.close_button = self.buttons.close
end

return NoAccess
