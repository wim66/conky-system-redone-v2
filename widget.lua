--[[
    widget.lua
--]]

pcall(require, "cairo")

-- Portable drawing-surface helper: prefer conky_surface() (X11 + Wayland),
-- fall back to cairo_xlib_surface_create for builds without it.
-- luacheck: ignore cairo_xlib
local has_cairo_xlib, cairo_xlib = pcall(require, "cairo_xlib")
if not has_cairo_xlib then
    cairo_xlib = setmetatable({}, {
        __index = function(_, k) return _G[k] end,
    })
end

local function get_draw_surface()
    if conky_surface then
        local s = conky_surface()
        if s then return s, false end
    end
    if conky_window and cairo_xlib_surface_create then
        local s = cairo_xlib_surface_create(conky_window.display,
            conky_window.drawable, conky_window.visual,
            conky_window.width, conky_window.height)
        return s, true
    end
    return nil, false
end

-- Make sure Lua can find the bars/graphs modules in scripts/, regardless
-- of Conky's own working directory (Conky usually runs with its config
-- dir as cwd, not this script's dir).
local script_dir = (debug.getinfo(1, "S").source):match("^@(.*/)") or "./"
package.path = script_dir .. "scripts/?.lua;" .. script_dir .. "?.lua;" .. package.path

local function try_require(name)
    local ok, err = pcall(require, name)
    if not ok then
        print("widget.lua: could not load '" .. name .. ".lua' -- " .. tostring(err))
    end
end

-- ==================== config ====================

local CFG = {
    network_iface = "enp0s31f6", -- change to your primary network interface

    -- Which bars/graphs module to load from scripts/, without the ".lua"
    bars_module = "bars2",      -- Pick "bars" or "bars2"
    graphs_module = "graphs2",  -- Pick"graphs" or "graphs2"

    -- CPU temperature normally auto-prefers coretemp/k10temp/zenpower (the
    -- CPU's own on-die sensor) over a motherboard Super I/O chip's "CPU"
    -- reading (an external socket thermistor -- see find_cpu_temp_sensor
    -- below for why). Set this to a specific hwmon chip name, e.g.
    -- "nct6687", to always prefer that chip's reading instead -- useful if
    -- you'd simply rather see your motherboard's socket temp. Leave nil
    -- for the automatic behavior.
    preferred_temp_chip = nil,

    -- Shows an extra DEBUG box at the bottom with the values this widget
    -- auto-detected (CPU temp sensor chip/path, package manager, whether
    -- /home is a separate partition, window size...) -- useful when
    -- something looks wrong and you need to see what the widget itself
    -- thinks is true about the system. Off by default.
    debug = false,
    font = "DejaVu Sans Mono",
    margin = 14,       -- outer margin, left/right
    top_margin = 14,
    pad = 10,          -- inner padding per box
    gap = 10,          -- vertical gap between boxes
    corner_radius = 10,

    -- Draws a bright dashed-look border around the FULL conky window (not
    -- just the widget's own glass boxes)
    -- Off by default -- purely a sizing aid.
    debug_show_canvas = false,

    -- Where the widget's content block sits vertically inside the conky
    -- window:
    --   "top"    -- starts at CFG.top_margin (the original behavior)
    --   "middle" -- vertically centers the whole content block within the
    --              conky window's actual height (conky_window.height),
    --              computed here in Lua every frame -- rather than
    --              relying on conky.conf's own alignment/gap_y, which
    --              several window managers (KWin on Wayland, notably)
    --              simply ignore for own_window_type='normal' windows.
    --              Stays centered even as optional sections (Fans,
    --              AUR/Flatpak lines...) grow or shrink the content.
    --   <number> -- a fixed Y offset in pixels, for full manual control.
    --              A quoted numeric string (e.g. "400") also works, in
    --              case you write it that way by habit alongside
    --              "top"/"middle" -- both do the exact same thing.
    -- Whichever mode is used, the same vertical shift is also applied to
    -- the bars/graphs modules from scripts/ (via a small WIDGET_Y_OFFSET
    -- global set in draw_all() below) so they move together with the
    -- rest of the widget instead of staying pinned to their own
    -- hardcoded positions.
    vertical_align = "middle", -- "top", "middle", or a number of pixels

    -- AUR helper for extra "Updates" line, in addition to the pacman/apt
    -- check below. Set to "yay", "paru", or "" to disable AUR checking.
    aur_helper = "yay",

    -- Adds a "N updates available (Flatpak)" line to the Updates box.
    -- Off by default: not everyone uses Flatpak, and checking involves a
    -- `flatpak update --appstream` metadata refresh every 30 minutes.
    -- Safe to leave on even without Flatpak installed -- it's simply
    -- skipped if the `flatpak` binary isn't found.
    show_flatpak_updates = false,

    -- Shows the "Fans" box (RPM per fan, via getfans.lua). Set to false to
    -- turn the whole section off -- the box simply isn't drawn at all,
    -- regardless of whether getfans.lua loaded or how many fans it finds.
    show_fans = false,

    -- Shows the Date & time box at the bottom. Independent of show_fans
    -- above -- toggle each on/off separately as you like.
    show_datetime = true,

    -- Layer 1 is the base glass fill behind every box -- the one layer
    -- worth tuning per-wallpaper, since a busier/brighter background
    -- often wants a darker or more opaque base to keep text readable.
    glass_base_color = 0x08081A,
    glass_base_alpha = 0.35,

    colors = {
        text     = 0xE8E8E8, -- light gray
        accent1  = 0xE7660B, -- orange
        accent2  = 0xDCE142, -- yellow
        accent3  = 0x42E147, -- green
        accent4  = 0x0055FF, -- blue
        accent5  = 0xFFFFFF, -- white
        danger   = 0xFF3B30, -- red, used above 90% load/usage
    },
}

try_require(CFG.graphs_module)
try_require(CFG.bars_module)
try_require("getfans")

-- ==================== widget state ====================

local W = {
    cache = {}, -- generic cache store, keyed by cached() calls below
}

-- ==================== generic helpers ====================

-- Division-based hex->rgb (no bitwise ops, works on Lua 5.1 and 5.3+)
local function hex_to_rgb(hex)
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    return r / 255, g / 255, b / 255
end

local function hex_to_rgba(hex, alpha)
    local r, g, b = hex_to_rgb(hex)
    return r, g, b, alpha
end



local function shell(cmd)
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a")
    h:close()
    if out then out = out:gsub("%s+$", "") end
    return out
end

-- Generic cache: call fn() at most once per `interval` seconds, per key.
-- Always wrapped in pcall so a failing command never kills conky_main().
local function cached(key, interval, fn)
    local c = W.cache[key]
    if not c then
        c = { value = nil, last = 0 }
        W.cache[key] = c
    end
    local now = os.time()
    if now - c.last >= interval then
        local ok, result = pcall(fn)
        if ok and result ~= nil then
            c.value = result
        end
        c.last = now
    end
    return c.value
end

-- locale-safe: treat "," as a decimal point rather than letting tonumber()
-- silently return nil on a comma-decimal locale (e.g. "12,3" -> 0 via the
-- usual `or 0` fallback, instead of the real 12.3)
local function num(s)
    if s == nil then return 0 end
    return tonumber((tostring(s):gsub(",", "."))) or 0
end

-- ==================== cached data sources ====================

local function get_distro()
    return cached("distro", 86400, function()
        return shell("lsb_release -d | cut -f2") or "Linux"
    end) or "Linux"
end

local function get_cpu_model()
    return cached("cpu_model", 86400, function()
        local s = shell("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/ @.*//'")
        return s and s:match("^%s*(.-)%s*$") or "Unknown CPU"
    end) or "Unknown CPU"
end

-- Chips that expose ONLY CPU temperature(s) -- safe to fall back to their
-- first temp*_input if no _label files exist at all. These read the CPU's
-- own on-die digital thermal sensor directly and are always preferred.
local CPU_ONLY_CHIPS = { coretemp = true, k10temp = true, zenpower = true }

-- Motherboard Super I/O chips that also expose a CPU reading, but alongside
-- many unrelated sensors (VRM, chipset, board, fans...). Their "CPU" input
-- is normally an external thermistor near the socket, not the die itself --
-- it can differ from the true CPU temp by several degrees, so these are
-- only used when no CPU_ONLY_CHIPS is present at all, and only ever via an
-- explicit label match, never a blind "first temp input" guess.
local MULTI_SENSOR_CHIPS = { nct6687 = true, nct6775 = true, nct6776 = true, it8688 = true }

-- Scans every hwmon dir for chips in `chip_set`, returning the first
-- temp*_input whose label matches package/Tctl/Tdie/cpu. If `allow_fallback`
-- is true and a matching chip has no _label files at all, its first temp
-- input is used instead of matching nothing.
local function scan_hwmon(dirs, chip_set, allow_fallback)
    for dir in dirs:gmatch("[^\n]+") do
        local nf = io.open(dir .. "name", "r")
        if nf then
            local chip = nf:read("*l") or ""
            nf:close()
            if chip_set[chip] then
                local fallback_input = nil
                for i = 1, 16 do
                    local input_path = dir .. "temp" .. i .. "_input"
                    local lf = io.open(dir .. "temp" .. i .. "_label", "r")
                    if lf then
                        -- note: label is lowercased here, so search terms
                        -- must be lowercase too -- searching for "CPU"
                        -- against an already-lowercased label never
                        -- matches (that was the bug in an earlier patch)
                        local label = (lf:read("*l") or ""):lower()
                        lf:close()
                        if label:find("package") or label:find("tctl")
                           or label:find("tdie") or label:find("cpu") then
                            return input_path
                        end
                    elseif allow_fallback and not fallback_input and io.open(input_path, "r") then
                        fallback_input = input_path
                    end
                end
                if fallback_input then return fallback_input end
            end
        end
    end
    return nil
end

-- Locate the CPU package/die temperature sensor directly via hwmon sysfs
-- (the same data `sensors` reads), instead of parsing sensors' human-
-- formatted text or hardcoding a hwmon index that differs between
-- machines/reboots. The hwmon path itself is stable for the life of a
-- boot -- only the reading changes -- so the *path* is cached long, the
-- *value* short.
--
-- Two passes across ALL hwmon dirs, not one combined pass: a system can
-- have both coretemp AND a motherboard Super I/O chip (e.g. nct6687) at
-- once, and hwmon enumeration order isn't guaranteed to put coretemp
-- first. Without this, whichever chip happens to sort first would win --
-- on at least one reported system, that put nct6687's socket-thermistor
-- "CPU" reading (57.5C) ahead of coretemp's actual Package reading
-- (56.0C), the exact class of mismatch this function exists to avoid.
local function find_cpu_temp_sensor()
    return cached("cpu_temp_path", 86400, function()
        local dirs = shell("ls -d /sys/class/hwmon/hwmon*/ 2>/dev/null") or ""

        if CFG.preferred_temp_chip then
            local forced = scan_hwmon(dirs, { [CFG.preferred_temp_chip] = true }, true)
            if forced then return forced end
            -- named chip not found/no usable temp input on it -- fall
            -- through to the automatic logic below rather than showing
            -- nothing
        end

        local cpu_vendor_match = scan_hwmon(dirs, CPU_ONLY_CHIPS, true)
        if cpu_vendor_match then return cpu_vendor_match end
        return scan_hwmon(dirs, MULTI_SENSOR_CHIPS, false)
    end)
end

local function get_cpu_temp()
    local path = find_cpu_temp_sensor()
    if not path then return nil end
    return cached("cpu_temp", 3, function()
        local f = io.open(path, "r")
        if not f then return nil end
        local raw = tonumber(f:read("*l"))
        f:close()
        if not raw then return nil end
        return string.format("+%.1f°C", raw / 1000)
    end)
end

-- Detect the system's package manager once (doesn't change at runtime).
-- More robust than checking for a single hardcoded binary path like
-- apt-check, which isn't guaranteed to be installed on every Debian/
-- Ubuntu/Mint system.
local function get_pkg_manager()
    return cached("pkg_manager", 86400, function()
        local p = shell("command -v pacman 2>/dev/null")
        if p and p ~= "" then return "pacman" end
        local a = shell("command -v apt 2>/dev/null")
        if a and a ~= "" then return "apt" end
        return "none"
    end) or "none"
end

-- Updates: pacman (checkupdates) on Arch, `apt list --upgradable` on
-- Debian/Ubuntu/Mint -- picked via get_pkg_manager() rather than probing
-- for one specific apt-check binary that may not be installed.
local function get_updates_lines()
    return cached("updates", 1800, function()
        local mgr = get_pkg_manager()
        if mgr == "pacman" then
            local n = shell("checkupdates 2>/dev/null | wc -l")
            return { (tonumber(n) or 0) .. " updates available (pacman)" }
        elseif mgr == "apt" then
            -- Match on content ("/" appears in every real "pkg/repo version
            -- arch [upgradable from: ...]" line) rather than assuming a
            -- fixed header-line position: apt sends its "Listing..." status
            -- to stderr on some versions and stdout on others, so a
            -- position-based `tail -n +2` isn't reliable either way.
            local n = shell("apt list --upgradable 2>/dev/null | grep -c '/'")
            return { (tonumber(n) or 0) .. " updates available (apt)" }
        end
        return { "No supported package manager found" }
    end) or {}
end

-- AUR only makes sense on an Arch/pacman system -- skip it entirely
-- elsewhere instead of silently printing "0 AUR updates" on Mint/Ubuntu.
local function get_aur_updates_line()
    if get_pkg_manager() ~= "pacman" then return nil end
    if CFG.aur_helper ~= "yay" and CFG.aur_helper ~= "paru" then
        return nil
    end
    return cached("updates_aur", 1800, function()
        local n = shell(CFG.aur_helper .. " -Qua 2>/dev/null | wc -l")
        return (tonumber(n) or 0) .. " AUR updates available (" .. CFG.aur_helper .. ")"
    end)
end

-- Flatpak is independent of the OS package manager, so this is checked
-- separately from get_pkg_manager()/get_updates_lines() above -- gated by
-- CFG.show_flatpak_updates and only shown if the `flatpak` binary is
-- actually present. `flatpak update --appstream` refreshes each remote's
-- metadata before counting; skipping that step can otherwise report
-- "ghost" updates for packages that were already updated (a known
-- flatpak quirk -- see flatpak/flatpak#3748). `remote-ls --updates`
-- prints one line per updatable ref and no header line, so a plain
-- `wc -l` is an exact count.
local function get_flatpak_updates_line()
    if not CFG.show_flatpak_updates then return nil end
    local has_flatpak = cached("has_flatpak", 86400, function()
        local p = shell("command -v flatpak 2>/dev/null")
        return p ~= nil and p ~= ""
    end)
    if not has_flatpak then return nil end
    return cached("updates_flatpak", 1800, function()
        shell("flatpak update --appstream >/dev/null 2>&1")
        local n = shell("flatpak remote-ls --updates 2>/dev/null | wc -l")
        return (tonumber(n) or 0) .. " updates available (Flatpak)"
    end)
end

-- ==================== drawing primitives ====================

local function draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_move_to(cr, x + r, y)
    cairo_line_to(cr, x + w - r, y)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_line_to(cr, x + w, y + h - r)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_line_to(cr, x + r, y + h)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_line_to(cr, x, y + r)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

-- Multi-layer liquid-glass box, ported from background-layout.lua's
-- 5-layer structure (base, vertical top/bottom reflections, horizontal
-- left highlight, top specular gloss, subtle inner glow) + gradient
-- border. Layer 4 (specular) is scaled to each box's own height instead
-- of a fixed 120px, since our boxes are much shorter than V4's single
-- 650px panel.
local function draw_glass_box(cr, x, y, w, h)
    local r = CFG.corner_radius

    -- Layer 1: base glass body (configurable, see CFG.glass_base_color/alpha)
    cairo_set_source_rgba(cr, hex_to_rgba(CFG.glass_base_color, CFG.glass_base_alpha))
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_fill(cr)

    cairo_save(cr)
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_clip(cr)

    -- Layer 2: vertical gradient -- reflections top and bottom
    local g2 = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(g2, 0.00, hex_to_rgba(0xFFFFFF, 0.30))
    cairo_pattern_add_color_stop_rgba(g2, 0.06, hex_to_rgba(0xDDEEFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 0.15, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.45, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.55, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.85, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.94, hex_to_rgba(0xCCDDFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 1.00, hex_to_rgba(0xFFFFFF, 0.28))
    cairo_set_source(cr, g2)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g2)

    -- Layer 3: horizontal highlight, light from the left
    local g3 = cairo_pattern_create_linear(x, y, x + w, y)
    cairo_pattern_add_color_stop_rgba(g3, 0.00, hex_to_rgba(0xFFFFFF, 0.32))
    cairo_pattern_add_color_stop_rgba(g3, 0.08, hex_to_rgba(0xEEF4FF, 0.16))
    cairo_pattern_add_color_stop_rgba(g3, 0.20, hex_to_rgba(0xCCDDFF, 0.05))
    cairo_pattern_add_color_stop_rgba(g3, 0.50, hex_to_rgba(0x000000, 0.0))
    cairo_pattern_add_color_stop_rgba(g3, 0.80, hex_to_rgba(0x8899CC, 0.03))
    cairo_pattern_add_color_stop_rgba(g3, 0.92, hex_to_rgba(0xAABBEE, 0.08))
    cairo_pattern_add_color_stop_rgba(g3, 1.00, hex_to_rgba(0xFFFFFF, 0.18))
    cairo_set_source(cr, g3)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g3)

    -- Layer 4: specular top gloss, height proportional to this box
    local spec_h = math.min(h * 0.35, 55)
    local g4 = cairo_pattern_create_linear(x, y, x, y + spec_h)
    cairo_pattern_add_color_stop_rgba(g4, 0.00, hex_to_rgba(0xFFFFFF, 0.38))
    cairo_pattern_add_color_stop_rgba(g4, 0.25, hex_to_rgba(0xEEF4FF, 0.18))
    cairo_pattern_add_color_stop_rgba(g4, 0.60, hex_to_rgba(0xFFFFFF, 0.04))
    cairo_pattern_add_color_stop_rgba(g4, 1.00, hex_to_rgba(0xFFFFFF, 0.0))
    cairo_set_source(cr, g4)
    cairo_rectangle(cr, x, y, w, spec_h)
    cairo_fill(cr)
    cairo_pattern_destroy(g4)

    -- Layer 5: subtle inner blue glow, inset horizontally
    local inset = math.min(10, w * 0.1)
    local g5 = cairo_pattern_create_linear(x + inset, y, x + w - inset, y)
    cairo_pattern_add_color_stop_rgba(g5, 0.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_pattern_add_color_stop_rgba(g5, 0.30, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 0.50, hex_to_rgba(0x3344CC, 0.10))
    cairo_pattern_add_color_stop_rgba(g5, 0.70, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 1.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_set_source(cr, g5)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g5)

    cairo_restore(cr) -- lift the clip before stroking the border

    -- Border: vertical white/blue gradient with sharp top & bottom edges
    local gb = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(gb, 0.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_pattern_add_color_stop_rgba(gb, 0.10, hex_to_rgba(0xFFFFFF, 0.90))
    cairo_pattern_add_color_stop_rgba(gb, 0.30, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.50, hex_to_rgba(0x8899EE, 0.25))
    cairo_pattern_add_color_stop_rgba(gb, 0.70, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.90, hex_to_rgba(0xFFFFFF, 0.85))
    cairo_pattern_add_color_stop_rgba(gb, 1.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_set_source(cr, gb)
    cairo_set_line_width(cr, 1.0)
    draw_rounded_rect_path(cr, x + 0.5, y + 0.5, w - 1, h - 1, r)
    cairo_stroke(cr)
    cairo_pattern_destroy(gb)
end



local function draw_text(cr, x, y, text, size, color_hex, alpha, bold, align)
    cairo_select_font_face(cr, CFG.font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local rr, gg, bb = hex_to_rgb(color_hex)
    cairo_set_source_rgba(cr, rr, gg, bb, alpha or 1)

    local tx = x
    if align == "center" or align == "right" then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, text, ext)
        tx = (align == "center") and (x - ext.width / 2) or (x - ext.width)
    end
    cairo_move_to(cr, tx, y)
    cairo_show_text(cr, text)
end

-- ==================== section content ====================

local function draw_sysinfo(cr, x, y, w, h)
    local sysname = conky_parse("${sysname}")
    local kernel = conky_parse("${kernel}")
    local uptime = conky_parse("${uptime}")
    draw_text(cr, x + w / 2, y + 22, get_distro(), 18, CFG.colors.accent1, 1, true, "center")
    draw_text(cr, x, y + 42, sysname .. " " .. kernel, 11, CFG.colors.text, 0.9)
    draw_text(cr, x, y + 60, "Uptime: " .. uptime, 11, CFG.colors.text, 0.9)
    draw_text(cr, x, y + 78, get_cpu_model(), 10, CFG.colors.text, 0.7)
end

local function draw_cpu(cr, x, y, w, h)
    local cpu_pct = num(conky_parse("${cpu cpu0}"))
    local temp = get_cpu_temp()
    local label = temp and temp ~= "" and ("CPU  " .. temp) or "CPU"
    draw_text(cr, x, y + 12, label, 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x + w, y + 12, string.format("%.0f%%", cpu_pct), 12, CFG.colors.text, 1, true, "right")
end

local function draw_mem(cr, x, y, w, h)
    local used = conky_parse("${mem}")
    local free = conky_parse("${memeasyfree}")
    draw_text(cr, x, y + 12, "Memory", 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x, y + 30, "Used: " .. used, 10, CFG.colors.text, 0.9)
    draw_text(cr, x + w, y + 30, "Free: " .. free, 10, CFG.colors.text, 0.9, false, "right")
end

-- /home counts as "separate" only if it's a different filesystem than /
-- (compared by device id via stat, cached -- this never changes at runtime).
local function has_separate_home()
    local v = cached("separate_home", 86400, function()
        local root_id = shell("stat -c %d / 2>/dev/null")
        local home_id = shell("stat -c %d /home 2>/dev/null")
        return root_id ~= nil and root_id ~= "" and home_id ~= nil and home_id ~= "" and root_id ~= home_id
    end)
    if v == nil then return true end -- unknown yet: assume separate, don't hide data
    return v
end

local function draw_disks(cr, x, y, w, h)
    local function disk_row(label, path, yy)
        local used = conky_parse("${fs_used " .. path .. "}")
        local free = conky_parse("${fs_free " .. path .. "}")
        draw_text(cr, x, yy, label .. "  Used: " .. used, 10, CFG.colors.text, 0.9)
        draw_text(cr, x + w, yy, "Free: " .. free, 10, CFG.colors.text, 0.9, false, "right")
    end
    draw_text(cr, x, y + 10, "Disks", 12, CFG.colors.accent2, 1, true)
    disk_row(has_separate_home() and "Root" or "/", "/", y + 30)
    if has_separate_home() then
        disk_row("Home", "/home", y + 70)
    end
end

-- Box height now depends on whether /home is a separate partition.
local function disks_section_height()
    return has_separate_home() and 122 or 82
end

local function draw_network(cr, x, y, w, h)
    local up = conky_parse("${upspeed " .. CFG.network_iface .. "}")
    local down = conky_parse("${downspeed " .. CFG.network_iface .. "}")
    local totalup = conky_parse("${totalup " .. CFG.network_iface .. "}")
    local totaldown = conky_parse("${totaldown " .. CFG.network_iface .. "}")

    draw_text(cr, x, y + 10, "Network", 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x, y + 28, "Up: " .. up, 10, CFG.colors.text, 0.9)
    draw_text(cr, x + w, y + 28, "Down: " .. down, 10, CFG.colors.text, 0.9, false, "right")

    draw_text(cr, x, y + 105, "Total up: " .. totalup, 9, CFG.colors.text, 0.7)
    draw_text(cr, x + w, y + 105, "Total down: " .. totaldown, 9, CFG.colors.text, 0.7, false, "right")
end

-- Fan RPMs, via the loaded getfans.lua's own conky_get_fans() (unmodified --
-- see scripts/getfans.lua). That function returns one "${alignr}"-templated
-- line per spinning fan for TEXT-conky's own renderer, so it's parsed here
-- into a label/value pair and drawn with this widget's own draw_text
-- right-align, same as every other section, rather than fed through
-- conky_parse (which wouldn't honor ${alignr} outside the main template).
-- Rate-limited to once every 2s since each call shells out to `ls` and
-- reads several sysfs files.
local function get_fans_raw()
    if not conky_get_fans then return "" end
    return cached("fans_raw", 2, function() return conky_get_fans() end) or ""
end

local function draw_fans(cr, x, y, w, h)
    draw_text(cr, x, y + 10, "Fans", 12, CFG.colors.accent2, 1, true)

    if not conky_get_fans then
        draw_text(cr, x, y + 28, "getfans.lua not loaded", 10, CFG.colors.text, 0.6)
        return
    end

    local i = 0
    for line in get_fans_raw():gmatch("[^\n]+") do
        i = i + 1
        local label, value = line:match("^(.-)%$%{alignr%}(.*)$")
        local yy = y + 10 + i * 18
        if label then
            draw_text(cr, x, yy, label, 10, CFG.colors.text, 0.9)
            draw_text(cr, x + w, yy, value, 10, CFG.colors.text, 0.9, false, "right")
        else
            draw_text(cr, x, yy, line, 10, CFG.colors.text, 0.9)
        end
    end
    if i == 0 then
        draw_text(cr, x, y + 28, "No fan sensors found", 10, CFG.colors.text, 0.6)
    end
end

-- Box height depends on how many fans are actually detected/spinning --
-- same pattern as disks_section_height()/updates_section_height() above.
local function fans_section_height()
    local n = 0
    for _ in get_fans_raw():gmatch("[^\n]+") do n = n + 1 end
    if n == 0 then n = 1 end -- reserve a line for "No fan sensors found"
    return 2 * CFG.pad + 10 + n * 18
end

local function draw_processes(cr, x, y, w, h)
    draw_text(cr, x, y + 10, "Processes", 12, CFG.colors.accent2, 1, true)
    for i = 1, 6 do
        local name = conky_parse("${top name " .. i .. "}")
        local cpu = num(conky_parse("${top cpu " .. i .. "}"))
        local yy = y + 10 + i * 18
        draw_text(cr, x, yy, name, 10, CFG.colors.text, 0.85)
        draw_text(cr, x + w - 4, yy, string.format("%5.2f%%", cpu), 10, CFG.colors.text, 0.85, false, "right")
    end
end

local function draw_updates(cr, x, y, w, h)
    draw_text(cr, x, y + 10, "Updates", 12, CFG.colors.accent2, 1, true)

    local lines = {}
    for _, l in ipairs(get_updates_lines()) do
        if l ~= "" then table.insert(lines, l) end
    end
    local aur_line = get_aur_updates_line()
    if aur_line then table.insert(lines, aur_line) end
    local flatpak_line = get_flatpak_updates_line()
    if flatpak_line then table.insert(lines, flatpak_line) end

    for i, l in ipairs(lines) do
        draw_text(cr, x, y + 14 + i * 16, l, 10, CFG.colors.text, 0.85)
    end
end

-- Box height now depends on how many update lines are actually shown
-- (pacman/apt always, AUR and/or Flatpak only if enabled and detected) --
-- same pattern as disks_section_height() below.
local function updates_section_height()
    local lines = 1 -- pacman/apt always shows a line, even if "0 updates"
    if get_aur_updates_line() then lines = lines + 1 end
    if get_flatpak_updates_line() then lines = lines + 1 end
    return 2 * CFG.pad + 28 + lines * 16
end

-- Derives the containing hwmon chip's name from a "...tempN_input" path,
-- for display in the debug output (find_cpu_temp_sensor() itself only
-- needs the path, not the human-readable chip name).
local function chip_name_for_path(path)
    local dir = path and path:match("^(.*/)[^/]+$")
    if not dir then return "?" end
    local f = io.open(dir .. "name", "r")
    if not f then return "?" end
    local name = f:read("*l") or "?"
    f:close()
    return name
end

-- Prints what the widget auto-detected to the terminal/log (stdout via
-- `print`, so it shows up wherever conky's own output goes -- the terminal
-- if run in the foreground, journalctl/a log file if run as a service).
-- Rate-limited through cached() so it prints once per interval instead of
-- once per tick.
local function print_debug_info()
    if not CFG.debug then return end
    cached("debug_print", 10, function()
        local temp_path = find_cpu_temp_sensor()
        local win = conky_window and (conky_window.width .. "x" .. conky_window.height) or "?"

        print("---- widget.lua debug (" .. os.date("%H:%M:%S") .. ") ----")
        print("CPU temp chip:   " .. (temp_path and chip_name_for_path(temp_path) or "none found"))
        print("CPU temp path:   " .. (temp_path or "-"))
        print("Pkg manager:     " .. get_pkg_manager())
        print("/home separate:  " .. tostring(has_separate_home()))
        print("Net iface (cfg): " .. CFG.network_iface)
        print("Window size:     " .. win)

        return true -- cached() only re-runs fn() once `true` is stale again
    end)
end

local function draw_datetime(cr, x, y, w, h)
    local date_str = conky_parse("${time %A, %d %B, %Y}")
    local time_str = conky_parse("${time %H:%M}")
    draw_text(cr, x + w / 2, y + 16, date_str, 11, CFG.colors.text, 0.9, false, "center")
    draw_text(cr, x + w / 2, y + 42, time_str, 20, CFG.colors.accent1, 1, true, "center")
end

-- ==================== layout ====================

local SECTIONS = {
    { height = 110, draw = draw_sysinfo },
    { height = 112,  draw = draw_cpu },
    { height = 80,  draw = draw_mem },
    { height = disks_section_height, draw = draw_disks },
    { height = 132, draw = draw_network },
    { height = fans_section_height, draw = draw_fans, enabled = function() return CFG.show_fans end },
    { height = 140, draw = draw_processes },
    { height = updates_section_height, draw = draw_updates },
    { height = 72,  draw = draw_datetime, enabled = function() return CFG.show_datetime end },
}

local function sec_h(sec)
    return type(sec.height) == "function" and sec.height() or sec.height
end

-- Sums every currently-enabled section's height plus the gaps between
-- them (no top/bottom margin) -- this is the height of the content block
-- itself. Recomputed every frame, so it tracks Fans/AUR/Flatpak sections
-- growing or shrinking. Used for both CFG.vertical_align = "middle" and
-- the debug canvas overlay below.
local function total_content_height()
    local total = 0
    local first = true
    for _, sec in ipairs(SECTIONS) do
        if not sec.enabled or sec.enabled() then
            if not first then total = total + CFG.gap end
            total = total + sec_h(sec)
            first = false
        end
    end
    return total
end

-- Bright, hard-to-miss border around the ENTIRE conky window (canvas_w x
-- canvas_h -- i.e. conky.conf's minimum_width/minimum_height as actually
-- granted), plus a one-line readout comparing that to how tall the
-- content block actually needs to be right now (content height + a
-- top_margin-sized margin mirrored at the bottom). Toggle via
-- CFG.debug_show_canvas.
local function draw_canvas_debug_overlay(cr, canvas_w, canvas_h, content_h)
    cairo_save(cr)
    cairo_set_source_rgba(cr, 1, 0, 1, 0.9) -- magenta -- nothing else here looks like this
    cairo_set_line_width(cr, 2)
    cairo_rectangle(cr, 1, 1, canvas_w - 2, canvas_h - 2)
    cairo_stroke(cr)
    cairo_restore(cr)

    local needed = math.ceil(content_h + 2 * CFG.top_margin)
    local fits = needed <= canvas_h
    local msg = string.format("canvas %dx%d | content needs ~%dpx tall | %s",
        canvas_w, canvas_h, needed,
        fits and "fits" or ("SHORT by " .. (needed - canvas_h) .. "px"))
    draw_text(cr, 4, canvas_h - 6, msg, 9, fits and CFG.colors.accent3 or CFG.colors.danger, 1, true)
end

local function draw_all(cr, canvas_w, canvas_h)
    local x = CFG.margin
    local w = canvas_w - 2 * CFG.margin
    local content_h = total_content_height()

    -- CFG.vertical_align accepts "middle", "top", a plain number, OR a
    -- numeric string (e.g. "400") -- the latter so a stray pair of quotes
    -- around a pixel value (an easy mistake, since "top"/"middle" ARE
    -- quoted strings) still works instead of silently doing nothing.
    local y
    if CFG.vertical_align == "middle" then
        y = (canvas_h - content_h) / 2
    elseif tonumber(CFG.vertical_align) then
        y = tonumber(CFG.vertical_align)
        -- Clamp so a number that's too large/small can't push the whole
        -- content block off-canvas entirely (which would otherwise look
        -- exactly like "nothing happened").
        y = math.max(0, math.min(y, canvas_h - content_h))
    else
        y = CFG.top_margin
    end

    -- The bars/graphs modules (scripts/bars*.lua, scripts/graphs*.lua)
    -- have their own hardcoded x/y positions, tuned for the original
    -- fixed CFG.top_margin ("top") layout -- they have no other way to
    -- know the content has shifted for "middle" or a custom number. This
    -- global is the one bit of coordination between widget.lua and those
    -- self-contained scripts: it's the same vertical delta widget.lua
    -- itself just applied to its own boxes, so each script's own y values
    -- (already tuned for the "top" position) can add this on top and
    -- move in lockstep. 0 whenever vertical_align == "top" (the position
    -- those scripts were originally tuned for), so nothing changes for
    -- anyone not using the newer alignment options.
    WIDGET_Y_OFFSET = y - CFG.top_margin

    for _, sec in ipairs(SECTIONS) do
        if not sec.enabled or sec.enabled() then
            local h = sec_h(sec)
            draw_glass_box(cr, x, y, w, h)
            sec.draw(cr, x + CFG.pad, y + CFG.pad, w - 2 * CFG.pad, h - 2 * CFG.pad)
            y = y + h + CFG.gap
        end
    end

    if CFG.debug_show_canvas then
        draw_canvas_debug_overlay(cr, canvas_w, canvas_h, content_h)
    end
end

-- ==================== Conky hooks ====================

function conky_main()
    print_debug_info()

    local surface, owns_surface = get_draw_surface()
    if surface then
        local cr = cairo_create(surface)

        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
        cairo_paint(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        local ok, err = pcall(draw_all, cr,
            conky_window and conky_window.width or 280,
            conky_window and conky_window.height or 1040)
        if not ok then
            io.stderr:write("widget.lua draw error: " .. tostring(err) .. "\n")
        end

        cairo_destroy(cr)
        if owns_surface then
            cairo_surface_destroy(surface)
        end
    end

    -- The bars/graphs modules loaded from scripts/ (per CFG.bars_module /
    -- CFG.graphs_module above) are self-contained conky scripts in their
    -- own right (each creates and destroys its own cairo surface). Calling
    -- their own native entry points here is the only way widget.lua
    -- refers to them at all.
    if conky_draw_graph then conky_draw_graph() end
    if conky_main_bars then conky_main_bars() end
end