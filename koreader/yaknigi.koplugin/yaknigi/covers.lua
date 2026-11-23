-- Book covers on disk, fetched in a forked process so the library is never held up.
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Http = require("yaknigi/http")
local Net = require("yaknigi/net")

pcall(ffi.cdef, "int nice(int);")

local logger = require("logger")
local socket = require("socket")

local Covers = {}

-- KOReader recognises an image by its file name, so the name has to match the content.
local function extension(data)
    if data:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    return nil
end

local function base_path(root, card)
    local id = card.book and card.book.uuid
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    return root .. "/" .. id
end

local function readable(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- Keep older thumbnails available offline while the sharper list covers are downloaded.
local LIST = ".list"
-- Most of a picture's time is waiting for the server, so two go at more than twice the speed
-- of what a screen asks for. More would spend the device's one core on the TLS handshakes.
local WORKERS = 2

local function find_image(base)
    for _, ext in ipairs { ".jpg", ".png" } do
        if readable(base .. ext) then return base .. ext end
    end
end

--- Path of the list cover, with older cached sizes as a fallback.
function Covers.find(root, card)
    local base = base_path(root, card)
    if not base then return nil end
    return find_image(base .. LIST) or find_image(base .. ".preview") or find_image(base)
end

function Covers.is_list_cover(path)
    return path and path:match("%.list%.%w+$") ~= nil
end

local ipad_variants = { thumb = true, small = true, large = true, original = true }

-- Prefer the catalogue's tablet-size cover for grids and lists.
local function cover_urls(card)
    local cover = card.book and card.book.cover
    local urls, seen = {}, {}
    local function add(url)
        if type(url) == "string" and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end
    if type(cover) == "table" then
        local any = cover.large or cover.url or cover.small
        if type(any) == "string" then
            add((any:gsub("%-(%a+)(%.%w+%??[^/]*)$", function(size, suffix)
                if ipad_variants[size] then return "-ipad" .. suffix end
            end)))
        end
        add(cover.large)
        add(cover.url)
        add(cover.small)
    end
    return urls
end

-- A picture bigger than this is more than the device should decode on its way to sleep.
local BIGGEST_COVER = 6 * 1024 * 1024

--- Path of the cover for the whole screen, nil until it has arrived.
function Covers.find_best(root, uuid)
    local base = base_path(root, { book = { uuid = uuid } })
    return base and find_image(base .. ".large")
end

local function download_image(http, base, urls)
    local temporary = base .. ".tmp"
    for _, url in ipairs(urls) do
        local status, body = http:request("GET", url, { ["User-Agent"] = Http.USER_AGENT })
        local ext = status == 200 and #body <= BIGGEST_COVER and extension(body)
        if ext then
            local f = io.open(temporary, "wb")
            if not f then return end
            local written = f:write(body)
            local closed = f:close()
            if written and closed and os.rename(temporary, base .. ext) then return end
            os.remove(temporary)
            return
        end
    end
end

--- Downloads the first picture of urls that can be had. Returns the pid, or nil.
function Covers.fetch_best(root, uuid, urls)
    local base = base_path(root, { book = { uuid = uuid } })
    if not base or #urls == 0 then return nil end
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local http = Http.new(Net.connect)
        download_image(http, base .. ".large", urls)
        http:close()
        os.exit(0)
    end)
end

local function download(wanted)
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local started = socket.gettime()
        local http = Http.new(Net.connect)
        for _, item in ipairs(wanted) do
            download_image(http, item.base, item.urls)
        end
        http:close()
        logger.info("yaknigi: covers:", #wanted, "in", socket.gettime() - started, "s")
        os.exit(0)
    end)
end

--- Downloads what is missing, in the order asked. The covers' host gets no token. Returns
-- the pids; empty when there is nothing to do.
function Covers.fetch(root, cards)
    local shares = {}
    local count = 0
    for _, card in ipairs(cards) do
        local base, urls = base_path(root, card), cover_urls(card)
        if base and #urls > 0 and not find_image(base .. LIST) then
            local share = count % WORKERS + 1
            shares[share] = shares[share] or {}
            table.insert(shares[share], { base = base .. LIST, urls = urls })
            count = count + 1
        end
    end
    local pids = {}
    for _, wanted in ipairs(shares) do
        pids[#pids + 1] = download(wanted)
    end
    return pids
end

--- True when none of the pids is running. Asking is also what ends a finished process.
function Covers.done(pids)
    local done = true
    for _, pid in ipairs(pids) do
        if not ffiutil.isSubProcessDone(pid) then done = false end
    end
    return done
end

--- Stops the pids. Returns those to ask about until they are gone.
function Covers.stop(pids)
    for _, pid in ipairs(pids) do ffiutil.terminateSubProcess(pid) end
    return pids
end

return Covers
