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

local DEFAULTS = {
    enabled = true,
    book_only = false, -- true: draw dots only while a book is open
    density = 3,       -- % of pixels covered by dots
    dot_size = 1,      -- px
    dot_min = 0x60,    -- darkest dot (0 = black)
    dot_max = 0xA0,    -- lightest dot
}

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/paperdots.lua")

local cfg = {}
for key, default in pairs(DEFAULTS) do
    local value = settings:readSetting(key)
    if value == nil then value = default end
    cfg[key] = value
end

local function saveSettings()
    for key in pairs(DEFAULTS) do
        settings:saveSetting(key, cfg[key])
    end
    settings:flush()
end

-- Dot pattern of one tile, sorted by y so small regions can skip most dots
local tile

local function buildTile()
    local size = cfg.dot_size
    local n = math.max(1, math.floor(TILE * TILE * (cfg.density / 100) / (size * size)))
    local lo, hi = cfg.dot_min, cfg.dot_max
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
            c = Blitbuffer.Color8(math.floor(lo + rand() * (hi - lo))),
        }
    end
    table.sort(pts, function(a, b) return a.y < b.y end)
    local xs, ys, cs = {}, {}, {}
    for i = 1, n do
        xs[i], ys[i], cs[i] = pts[i].x, pts[i].y, pts[i].c
    end
    tile = { n = n, xs = xs, ys = ys, cs = cs }
end

-- First index whose value is >= target (ys is sorted ascending)
local function lowerBound(ys, n, target)
    local lo, hi = 1, n + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ys[mid] < target then lo = mid + 1 else hi = mid end
    end
    return lo
end

local use_paintrect = false
local verified = false

-- One-time check that setPixel really writes the color we asked for
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

local active_reader = nil -- set while a book is open

local function applyDots(x, y, w, h)
    if not cfg.enabled then return end
    if cfg.book_only and not active_reader then return end
    local bb = Screen.bb
    if not bb then return end
    local bw, bh = bb:getWidth(), bb:getHeight()

    x = x or 0
    y = y or 0
    w = w or bw
    h = h or bh

    local x1, y1 = math.max(x, 0), math.max(y, 0)
    local x2, y2 = math.min(x + w, bw), math.min(y + h, bh) -- exclusive
    if x2 <= x1 or y2 <= y1 then return end

    local size = cfg.dot_size
    local n, xs, ys, cs = tile.n, tile.xs, tile.ys, tile.cs

    local tx0, tx1 = math.floor((x1 - size + 1) / TILE), math.floor((x2 - 1) / TILE)
    local ty0, ty1 = math.floor((y1 - size + 1) / TILE), math.floor((y2 - 1) / TILE)

    for ty = ty0, ty1 do
        local oy = ty * TILE
        for tx = tx0, tx1 do
            local ox = tx * TILE
            if ox >= x1 and oy >= y1
                and ox + TILE + size - 1 <= x2 and oy + TILE + size - 1 <= y2 then
                -- tile fully inside the region: no bounds checks needed
                for i = 1, n do
                    local dx, dy, color = ox + xs[i], oy + ys[i], cs[i]
                    for j = 0, size - 1 do
                        for k = 0, size - 1 do
                            paintAt(bb, dx + k, dy + j, color)
                        end
                    end
                end
            else
                -- partial tile: only visit dots in the rows that matter
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

buildTile()

local BASE_METHODS = {
    "refreshFull", "refreshPartial", "refreshFlashPartial",
    "refreshUI", "refreshFlashUI", "refreshFast", "refreshA2",
    "refreshNoMergePartial",
}

local in_refresh = false

if not Screen._paper_dots_hooked then
    Screen._paper_dots_hooked = true
    local hooked = 0
    for _idx, base in ipairs(BASE_METHODS) do
        for _idx2, name in ipairs({ base, base .. "Imp" }) do
            local orig = Screen[name]
            if type(orig) == "function" then
                Screen[name] = function(self, x, y, w, h, ...)
                    if in_refresh then return orig(self, x, y, w, h, ...) end
                    in_refresh = true
                    local ok, err = pcall(applyDots, x, y, w, h)
                    if not ok then logger.warn("paperdots: error", err) end
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

local function onChanged()
    buildTile()
    saveSettings()
    UIManager:setDirty("all", "full")
end

local PaperDots = WidgetContainer:extend{
    name = "paperdots",
    is_doc_only = true, -- the menu lives in the reader, so no instance in the file browser
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
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = cfg[key],
        value_min = min,
        value_max = max,
        value_step = step,
        value_hold_step = hold,
        default_value = DEFAULTS[key],
        ok_text = _("Set"),
        callback = function(spin)
            cfg[key] = spin.value
            if key == "dot_min" and cfg.dot_min > cfg.dot_max then
                cfg.dot_max = cfg.dot_min
            elseif key == "dot_max" and cfg.dot_max < cfg.dot_min then
                cfg.dot_min = cfg.dot_max
            end
            onChanged()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function PaperDots:addToMainMenu(menu_items)
    menu_items.paper_dots = {
        text = _("Paper dots"),
        sorting_hint = "typeset", -- "Document" tab (second icon of the reader menu)
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
                help_text = _("When checked, dots are not drawn in the file browser or other screens, only while a book is open."),
                checked_func = function() return cfg.book_only end,
                callback = function()
                    cfg.book_only = not cfg.book_only
                    onChanged()
                end,
            },
            {
                text_func = function() return T(_("Density: %1%"), cfg.density) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Density (% of pixels)"), "density", 1, 30, 1, 5)
                end,
            },
            {
                text_func = function() return T(_("Dot size: %1 px"), cfg.dot_size) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Dot size (px)"), "dot_size", 1, 4, 1, 1)
                end,
            },
            {
                text_func = function() return T(_("Darkest dot: %1"), cfg.dot_min) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Darkest dot (0 = black)"), "dot_min", 0, 239, 8, 32)
                end,
            },
            {
                text_func = function() return T(_("Lightest dot: %1"), cfg.dot_max) end,
                keep_menu_open = true,
                callback = function(inst)
                    showSpin(inst, _("Lightest dot"), "dot_max", 0, 239, 8, 32)
                end,
            },
            {
                text = _("Reset to defaults"),
                keep_menu_open = true,
                callback = function(inst)
                    for key, default in pairs(DEFAULTS) do cfg[key] = default end
                    onChanged()
                    if inst then inst:updateItems() end
                end,
            },
        },
    }
end

return PaperDots