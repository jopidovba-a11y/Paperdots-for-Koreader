local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local TILE = 256
local SEED = 12345
local WHITE_THRESHOLD = 0xF0 -- dots are only drawn over pixels at least this light
local PALETTE_SIZE = 16
local LINEN_SEG = 8
local LINEN_PRESENCE = 65

local GLOBAL_DEFAULTS = {
    enabled = true,
    book_only = false,
    hide_on_menus = false,
    style = "random",
}

local STYLE_DEFAULTS = {
    random = { density = 3, dot_size = 1, dot_min = 0x60, dot_max = 0xA0 },
    newsprint = { density = 8, dot_size = 2, dot_min = 0x60, dot_max = 0xA0 },
    fibers = { density = 4, dot_size = 1, dot_min = 0x60, dot_max = 0xA0, fiber_length = 8 },
    linen = { density = 6, dot_size = 1, dot_min = 0x70, dot_max = 0xB0 },
}

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/paperdots.lua")

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local cfg = {}
for key, default in pairs(GLOBAL_DEFAULTS) do
    local value = settings:readSetting(key)
    if value == nil then value = default end
    cfg[key] = value
end
if not STYLE_DEFAULTS[cfg.style] then cfg.style = "random" end

local saved_styles = settings:readSetting("styles") or {}
cfg.styles = {}
for name, defaults in pairs(STYLE_DEFAULTS) do
    local entry = copy(defaults)
    local saved = saved_styles[name]
    if type(saved) == "table" then
        for key in pairs(defaults) do
            if type(saved[key]) == "number" then entry[key] = saved[key] end
        end
    end
    cfg.styles[name] = entry
end

-- migrate settings saved by older versions (one set shared by all styles)
for _idx, key in ipairs({ "density", "dot_size", "dot_min", "dot_max", "fiber_length" }) do
    local legacy = settings:readSetting(key)
    if type(legacy) == "number" and saved_styles[cfg.style] == nil
        and cfg.styles[cfg.style][key] ~= nil then
        cfg.styles[cfg.style][key] = legacy
    end
    if legacy ~= nil then settings:delSetting(key) end
end

for _idx, entry in pairs(cfg.styles) do
    if entry.dot_max > 239 then entry.dot_max = 239 end
    if entry.dot_min > entry.dot_max then entry.dot_min = entry.dot_max end
end

local function S()
    return cfg.styles[cfg.style]
end

local function saveSettings()
    for key in pairs(GLOBAL_DEFAULTS) do
        settings:saveSetting(key, cfg[key])
    end
    settings:saveSetting("styles", cfg.styles)
    settings:flush()
end

local function round(v)
    return math.floor(v + 0.5)
end

local function makePalette()
    local s = S()
    local palette = {}
    for i = 1, PALETTE_SIZE do
        palette[i] = Blitbuffer.Color8(math.floor(s.dot_min + (s.dot_max - s.dot_min) * (i - 1) / (PALETTE_SIZE - 1)))
    end
    return palette
end

-- deterministic, so each element looks the same on every refresh
local function hash(r, c)
    local s = (r * 7919 + c * 104729 + 1) % 2147483647
    s = (s * 16807) % 2147483647
    s = (s * 16807) % 2147483647
    return s
end

local function lowerBound(ys, n, target)
    local lo, hi = 1, n + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ys[mid] < target then lo = mid + 1 else hi = mid end
    end
    return lo
end

local tile, ordered, fibers, linen

local function buildTile()
    local s = S()
    local size = s.dot_size
    local n = math.max(1, math.floor(TILE * TILE * (s.density / 100) / (size * size)))
    local seed = SEED
    local function rand()
        seed = (seed * 16807) % 2147483647
        return seed / 2147483647
    end
    local pts = {}
    for i = 1, n do
        pts[i] = {
            x = math.floor(rand() * TILE),
            y = math.floor(rand() * TILE),
            c = Blitbuffer.Color8(math.floor(s.dot_min + rand() * (s.dot_max - s.dot_min))),
        }
    end
    table.sort(pts, function(a, b) return a.y < b.y end)
    local xs, ys, cs = {}, {}, {}
    for i = 1, n do
        xs[i], ys[i], cs[i] = pts[i].x, pts[i].y, pts[i].c
    end
    tile = { n = n, xs = xs, ys = ys, cs = cs }
end

local function buildOrdered()
    local s = S()
    local size = s.dot_size
    -- staggered grid: coverage = size^2 / (2 * step^2)
    local step = math.max(size, round(size * math.sqrt(50 / s.density)))
    ordered = { step = step, palette = makePalette() }
end

local function bresenham(ex, ey)
    local xs, ys = {}, {}
    local x, y = 0, 0
    local dx, dy = math.abs(ex), ey
    local sx = ex >= 0 and 1 or -1
    local err = dx - dy
    for _g = 1, 64 do
        xs[#xs + 1], ys[#ys + 1] = x, y
        if x == ex and y == ey then break end
        local e2 = 2 * err
        if e2 >= -dy then err = err - dy; x = x + sx end
        if e2 <= dx then err = err + dx; y = y + 1 end
    end
    return xs, ys
end

local function buildFibers()
    local s = S()
    local size = s.dot_size
    local maxlen = s.fiber_length
    local minlen = math.max(2, math.floor(maxlen / 2))
    local avg = (minlen + maxlen) / 2
    local n = math.max(1, math.floor(TILE * TILE * (s.density / 100) / (avg * size)))
    local seed = SEED
    local function rand()
        seed = (seed * 16807) % 2147483647
        return seed / 2147483647
    end
    local list = {}
    for i = 1, n do
        local fx = math.floor(rand() * TILE)
        local fy = math.floor(rand() * TILE)
        local len = minlen + math.floor(rand() * (maxlen - minlen + 1))
        local ang = rand() * math.pi -- [0, pi): fibers always go downwards
        local ex = round(math.cos(ang) * (len - 1))
        local ey = round(math.sin(ang) * (len - 1))
        local pxs, pys = bresenham(ex, ey)
        list[i] = {
            x = fx, y = fy, px = pxs, py = pys,
            c = Blitbuffer.Color8(math.floor(s.dot_min + rand() * (s.dot_max - s.dot_min))),
        }
    end
    table.sort(list, function(a, b) return a.y < b.y end)
    local xs, ys, pxs, pys, cs = {}, {}, {}, {}, {}
    for i = 1, n do
        xs[i], ys[i], pxs[i], pys[i], cs[i] = list[i].x, list[i].y, list[i].px, list[i].py, list[i].c
    end
    fibers = { n = n, xs = xs, ys = ys, pxs = pxs, pys = pys, cs = cs, margin = maxlen + size }
end

local function buildLinen()
    local s = S()
    local size = s.dot_size
    -- coverage is about 2 * size / spacing * presence
    local spacing = math.max(size * 2, round(130 * size / s.density))
    linen = { spacing = spacing, palette = makePalette() }
end

local function rebuild()
    if cfg.style == "newsprint" then
        buildOrdered()
    elseif cfg.style == "fibers" then
        buildFibers()
    elseif cfg.style == "linen" then
        buildLinen()
    else
        buildTile()
    end
end

local use_paintrect = false
local verified = false

-- some framebuffers may not store the exact shade; fall back to paintRect
local function verifyFirstPaint(bb, px, py, color)
    verified = true
    local back = bb:getPixel(px, py):getColor8().a
    if math.abs(back - color.a) > 24 then
        use_paintrect = true
        bb:paintRect(px, py, 1, 1, color)
        logger.info("paperdots: setPixel mismatch (wanted", color.a, "got", back, "), using paintRect")
    end
end

local function paintAt(bb, px, py, color)
    if bb:getPixel(px, py):getColor8().a < WHITE_THRESHOLD then return end
    if use_paintrect then
        bb:paintRect(px, py, 1, 1, color)
    else
        bb:setPixel(px, py, color)
        if not verified then verifyFirstPaint(bb, px, py, color) end
    end
end

local function paintRectClipped(bb, rx, ry, rw, rh, x1, y1, x2, y2, color)
    local ax, ay = math.max(rx, x1), math.max(ry, y1)
    local bx, by = math.min(rx + rw, x2), math.min(ry + rh, y2)
    for py = ay, by - 1 do
        for px = ax, bx - 1 do
            paintAt(bb, px, py, color)
        end
    end
end

local function applyRandom(bb, x1, y1, x2, y2, size)
    local n, xs, ys, cs = tile.n, tile.xs, tile.ys, tile.cs

    local tx0, tx1 = math.floor((x1 - size + 1) / TILE), math.floor((x2 - 1) / TILE)
    local ty0, ty1 = math.floor((y1 - size + 1) / TILE), math.floor((y2 - 1) / TILE)

    for ty = ty0, ty1 do
        local oy = ty * TILE
        for tx = tx0, tx1 do
            local ox = tx * TILE
            if ox >= x1 and oy >= y1
                and ox + TILE + size - 1 <= x2 and oy + TILE + size - 1 <= y2 then
                for i = 1, n do
                    local dx, dy, color = ox + xs[i], oy + ys[i], cs[i]
                    for j = 0, size - 1 do
                        for k = 0, size - 1 do
                            paintAt(bb, dx + k, dy + j, color)
                        end
                    end
                end
            else
                local last_y = y2 - 1 - oy
                for i = lowerBound(ys, n, y1 - oy - size + 1), n do
                    local ry = ys[i]
                    if ry > last_y then break end
                    local dx, dy = ox + xs[i], oy + ry
                    if dx < x2 and dx + size > x1 then
                        local color = cs[i]
                        for j = 0, size - 1 do
                            local py = dy + j
                            if py >= y1 and py < y2 then
                                for k = 0, size - 1 do
                                    local px = dx + k
                                    if px >= x1 and px < x2 then
                                        paintAt(bb, px, py, color)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function applyOrdered(bb, x1, y1, x2, y2, size)
    local step, palette = ordered.step, ordered.palette
    local col_step = step * 2

    local r0 = math.max(0, math.ceil((y1 - size + 1) / step))
    local r1 = math.floor((y2 - 1) / step)
    for r = r0, r1 do
        local dy = r * step
        local off = (r % 2 == 1) and step or 0
        local c0 = math.max(0, math.ceil((x1 - size + 1 - off) / col_step))
        local c1 = math.floor((x2 - 1 - off) / col_step)
        for c = c0, c1 do
            local dx = c * col_step + off
            local color = palette[hash(r, c) % PALETTE_SIZE + 1]
            for j = 0, size - 1 do
                local py = dy + j
                if py >= y1 and py < y2 then
                    for k = 0, size - 1 do
                        local px = dx + k
                        if px >= x1 and px < x2 then
                            paintAt(bb, px, py, color)
                        end
                    end
                end
            end
        end
    end
end

local function applyFibers(bb, x1, y1, x2, y2, size)
    local n, xs, ys = fibers.n, fibers.xs, fibers.ys
    local pxs, pys, cs, M = fibers.pxs, fibers.pys, fibers.cs, fibers.margin

    local tx0, tx1 = math.floor((x1 - M) / TILE), math.floor((x2 - 1 + M) / TILE)
    local ty0, ty1 = math.floor((y1 - M) / TILE), math.floor((y2 - 1) / TILE)

    for ty = ty0, ty1 do
        local oy = ty * TILE
        local last_y = y2 - 1 - oy
        for tx = tx0, tx1 do
            local ox = tx * TILE
            for i = lowerBound(ys, n, y1 - oy - M), n do
                local fy = ys[i]
                if fy > last_y then break end
                local dx, dy = ox + xs[i], oy + fy
                if dx + M > x1 and dx - M < x2 then
                    local color = cs[i]
                    local fpx, fpy = pxs[i], pys[i]
                    for k = 1, #fpx do
                        local bx, by = dx + fpx[k], dy + fpy[k]
                        for j = 0, size - 1 do
                            local py = by + j
                            if py >= y1 and py < y2 then
                                for a = 0, size - 1 do
                                    local px = bx + a
                                    if px >= x1 and px < x2 then
                                        paintAt(bb, px, py, color)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function applyLinen(bb, x1, y1, x2, y2, size)
    local sp, palette = linen.spacing, linen.palette

    local r0 = math.max(0, math.ceil((y1 - size + 1) / sp))
    local r1 = math.floor((y2 - 1) / sp)
    local m0, m1 = math.floor(x1 / LINEN_SEG), math.floor((x2 - 1) / LINEN_SEG)
    for r = r0, r1 do
        local ty = r * sp
        for m = m0, m1 do
            local h = hash(r, m)
            if h % 100 < LINEN_PRESENCE then
                local color = palette[math.floor(h / 100) % PALETTE_SIZE + 1]
                paintRectClipped(bb, m * LINEN_SEG, ty, LINEN_SEG, size, x1, y1, x2, y2, color)
            end
        end
    end

    local c0 = math.max(0, math.ceil((x1 - size + 1) / sp))
    local c1 = math.floor((x2 - 1) / sp)
    local n0, n1 = math.floor(y1 / LINEN_SEG), math.floor((y2 - 1) / LINEN_SEG)
    for c = c0, c1 do
        local tx = c * sp
        for m = n0, n1 do
            local h = hash(c + 50000, m)
            if h % 100 < LINEN_PRESENCE then
                local color = palette[math.floor(h / 100) % PALETTE_SIZE + 1]
                paintRectClipped(bb, tx, m * LINEN_SEG, size, LINEN_SEG, x1, y1, x2, y2, color)
            end
        end
    end
end

local function applyDots(x, y, w, h)
    local bb = Screen.bb
    if not bb then return end
    local bw, bh = bb:getWidth(), bb:getHeight()

    x = x or 0
    y = y or 0
    w = w or bw
    h = h or bh

    local x1, y1 = math.max(x, 0), math.max(y, 0)
    local x2, y2 = math.min(x + w, bw), math.min(y + h, bh)
    if x2 <= x1 or y2 <= y1 then return end

    local style, size = cfg.style, S().dot_size
    if style == "newsprint" then
        applyOrdered(bb, x1, y1, x2, y2, size)
    elseif style == "fibers" then
        applyFibers(bb, x1, y1, x2, y2, size)
    elseif style == "linen" then
        applyLinen(bb, x1, y1, x2, y2, size)
    else
        applyRandom(bb, x1, y1, x2, y2, size)
    end
end

rebuild()

local active_reader = nil

local function refreshHookActive()
    if not cfg.enabled then return false end
    if not cfg.book_only then return true end
    return active_reader ~= nil and not cfg.hide_on_menus
end

local BASE_METHODS = {
    "refreshFull", "refreshPartial", "refreshFlashPartial",
    "refreshUI", "refreshFlashUI", "refreshFast", "refreshA2",
    "refreshNoMergePartial",
}

-- avoids painting twice when a refresh function calls another one
local in_refresh = false

if not Screen._paper_dots_hooked then
    Screen._paper_dots_hooked = true
    local hooked = 0
    for _idx, base in ipairs(BASE_METHODS) do
        -- the Imp variants cover drivers that do the real work there
        for _idx2, name in ipairs({ base, base .. "Imp" }) do
            local orig = Screen[name]
            if type(orig) == "function" then
                Screen[name] = function(self, x, y, w, h, ...)
                    if in_refresh then return orig(self, x, y, w, h, ...) end
                    in_refresh = true
                    if refreshHookActive() then
                        local ok, err = pcall(applyDots, x, y, w, h)
                        if not ok then logger.warn("paperdots: error", err) end
                    end
                    local ok2, a, b = pcall(orig, self, x, y, w, h, ...)
                    in_refresh = false
                    if not ok2 then error(a, 0) end
                    return a, b
                end
                hooked = hooked + 1
            end
        end
    end
    logger.info("paperdots: hooked", hooked, "refresh functions")
end

-- dots are painted right after the page, so menus drawn later cover them
local ok_rv, ReaderView = pcall(require, "apps/reader/modules/readerview")
if ok_rv and type(ReaderView) == "table" and not ReaderView._paper_dots_hooked then
    ReaderView._paper_dots_hooked = true
    local orig_paintTo = ReaderView.paintTo
    ReaderView.paintTo = function(self, bb, x, y)
        local res = orig_paintTo(self, bb, x, y)
        if cfg.enabled and cfg.book_only and cfg.hide_on_menus and bb == Screen.bb then
            local ok, err = pcall(applyDots)
            if not ok then logger.warn("paperdots: error", err) end
        end
        return res
    end
    logger.info("paperdots: hooked ReaderView.paintTo")
end

local function onChanged()
    rebuild()
    saveSettings()
    UIManager:setDirty("all", "full")
end

local PaperDots = WidgetContainer:extend{
    name = "paperdots",
    is_doc_only = true,
}

function PaperDots:init()
    active_reader = self
    self.ui.menu:registerToMainMenu(self)
end

function PaperDots:onCloseDocument()
    if active_reader == self then active_reader = nil end
end

function PaperDots:onCloseWidget()
    if active_reader == self then active_reader = nil end
end

local function showSpin(touchmenu_instance, title, key, min, max, step, hold)
    local style = cfg.style
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = cfg.styles[style][key],
        value_min = min,
        value_max = max,
        value_step = step,
        value_hold_step = hold,
        default_value = STYLE_DEFAULTS[style][key],
        ok_text = _("Set"),
        callback = function(spin)
            local s = cfg.styles[style]
            s[key] = spin.value
            if key == "dot_min" and s.dot_min > s.dot_max then
                s.dot_max = s.dot_min
            elseif key == "dot_max" and s.dot_max < s.dot_min then
                s.dot_min = s.dot_max
            end
            onChanged()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

local STYLE_LIST = {
    { id = "random", label = _("Random") },
    { id = "newsprint", label = _("Newsprint (ordered grid)") },
    { id = "fibers", label = _("Fibers (paper fibers)") },
    { id = "linen", label = _("Linen (woven threads)") },
}

local function styleName()
    for _idx, s in ipairs(STYLE_LIST) do
        if s.id == cfg.style then return s.label end
    end
    return _("Random")
end

local function styleItems()
    local items = {}
    for _idx, s in ipairs(STYLE_LIST) do
        local id = s.id
        items[#items + 1] = {
            text = s.label,
            radio = true,
            keep_menu_open = true,
            checked_func = function() return cfg.style == id end,
            callback = function(inst)
                cfg.style = id
                onChanged()
                if inst then inst:updateItems() end
            end,
        }
    end
    return items
end

function PaperDots:addToMainMenu(menu_items)
    menu_items.paper_dots = {
        text = _("Paper dots"),
        sorting_hint = "typeset", -- "Document" tab
        sub_item_table = {
            {
                text = _("Enable"),
                checked_func = function() return cfg.enabled end,
                callback = function()
                    cfg.enabled = not cfg.enabled
                    onChanged()
                end,
            },
            {
                text = _("Only inside books"),
                help_text = _("Dots are only drawn while a book is open, not in the file browser or other screens."),
                checked_func = function() return cfg.book_only end,
                callback = function()
                    cfg.book_only = not cfg.book_only
                    onChanged()
                end,
            },
            {
                text = _("Hide dots on menus"),
                help_text = _("Keeps dots on the book page only, without dots on menus and dialogs shown over it. Requires 'Only inside books'."),
                enabled_func = function() return cfg.book_only end,
                checked_func = function() return cfg.hide_on_menus end,
                callback = function()
                    cfg.hide_on_menus = not cfg.hide_on_menus
                    onChanged()
                end,
                separator = true,
            },
            {
                text_func = function() return T(_("Style: %1"), styleName()) end,
                help_text = _("Density, size, and shades are saved separately for each style."),
                sub_item_table = styleItems(),
            },
            {
                text_func = function() return T(_("Density: %1%"), S().density) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Density (% of pixels)"), "density", 1, 30, 1, 5)
                end,
            },
            {
                text_func = function() return T(_("Dot size: %1 px"), S().dot_size) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Dot size / line thickness (px)"), "dot_size", 1, 4, 1, 1)
                end,
            },
            {
                text_func = function() return T(_("Fiber length: %1 px"), S().fiber_length or 0) end,
                enabled_func = function() return cfg.style == "fibers" end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Longest fiber (px)"), "fiber_length", 3, 20, 1, 5)
                end,
            },
            {
                text_func = function() return T(_("Darkest dot: %1"), S().dot_min) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Darkest shade (0 = black)"), "dot_min", 0, 239, 8, 32)
                end,
            },
            {
                text_func = function() return T(_("Lightest dot: %1"), S().dot_max) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Lightest shade"), "dot_max", 0, 239, 8, 32)
                end,
                separator = true,
            },
            {
                text = _("Reset this style to defaults"),
                keep_menu_open = true,
                callback = function(inst)
                    cfg.styles[cfg.style] = copy(STYLE_DEFAULTS[cfg.style])
                    onChanged()
                    if inst then inst:updateItems() end
                end,
            },
        },
    }
end

return PaperDots
