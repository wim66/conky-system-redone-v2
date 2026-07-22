--[[
    getfans.lua

    Scans the Linux kernel's hwmon (hardware monitoring) sysfs tree for
    fan-speed sensors and returns one line per detected fan sensor --
    including ones currently reading 0 RPM (idle/stopped) -- formatted
    for conky's own TEXT-template renderer (see the "${alignr}" note
    below).

    Every hwmon-capable driver (thinkpad_acpi, nct6775, coretemp,
    it87, etc.) exposes its sensors under:
        /sys/class/hwmon/hwmon0/
        /sys/class/hwmon/hwmon1/
        ...
    Each of those directories has:
      - a "name" file containing the driver's short name, e.g. "thinkpad"
        or "nct6775" -- this is how we label which chip a fan belongs to.
      - zero or more "fanN_input" files (fan1_input, fan2_input, ...),
        each containing that fan's current speed in RPM as a plain integer.
    hwmonN numbers are NOT stable across reboots or driver load order, so
    this always re-discovers the mapping by scanning fresh every call
    rather than hardcoding a path like "/sys/class/hwmon/hwmon2/fan1_input".

    USAGE NOTE: the returned string embeds the conky template variable
    "${alignr}" between each fan's label and its RPM value. That variable
    only has meaning to conky's own TEXT-section renderer (it tells conky
    to right-align whatever comes after it on that line) -- it is NOT
    something Lua or conky_parse() resolves on their own outside that
    context. So this function is meant to be used either:
      (a) directly in conky.conf's TEXT section via
          ${lua_parse conky_get_fans}
      (b) or, if you're building your own Cairo-drawn widget (like
          widget.lua's "Fans" section does), by splitting each returned
          line on the literal "${alignr}" marker yourself and drawing the
          label/value pair with your own alignment -- since conky_parse()
          will not honor ${alignr} when called standalone from Lua.
--]]
function conky_get_fans()
    local output = ""

    -- `ls -d` lists only the matching directories themselves (not their
    -- contents), so this gives us one path per hwmon chip currently
    -- registered, e.g.:
    --   /sys/class/hwmon/hwmon0
    --   /sys/class/hwmon/hwmon1
    -- Redirecting stderr to /dev/null means a system with no hwmon
    -- devices at all just yields an empty result instead of an
    -- "ls: cannot access" error line leaking into our output.
    local handle = io.popen("ls -d /sys/class/hwmon/hwmon* 2>/dev/null")
    if not handle then return "" end

    -- Walk every hwmon chip directory found above.
    for path in handle:lines() do
        -- Every hwmon chip exposes a "name" file with its driver's short
        -- identifier -- e.g. "thinkpad" (laptop ACPI fan control),
        -- "coretemp" (Intel CPU package sensors), "nct6775"/"nct6687"
        -- (motherboard Super I/O chips), etc. We use this purely as a
        -- human-readable label; if the file is missing for some reason,
        -- we simply skip this chip rather than guessing a name.
        local name_file = io.open(path .. "/name", "r")
        if name_file then
            local name = name_file:read("*l")
            name_file:close()

            -- Within this chip's directory, find every "fanN_input" file
            -- (fan1_input, fan2_input, fan3_input, ...). Not every chip
            -- has fan sensors at all (e.g. a pure CPU temperature chip
            -- like coretemp normally has none), so this can legitimately
            -- come back empty for many of the hwmon dirs we iterate.
            local fan_handle = io.popen("ls " .. path .. "/fan*_input 2>/dev/null")
            if fan_handle then
                for fan_path in fan_handle:lines() do
                    -- Pull the fan's index number out of its filename,
                    -- e.g. "fan2_input" -> "2". This is just for the
                    -- display label ("Fan 2 (...)"), not used to build
                    -- any path (fan_path is already the full path).
                    local fan_num = fan_path:match("fan(%d+)_input")

                    -- The file's entire content is a single integer: the
                    -- fan's current speed in revolutions per minute.
                    -- io.open + read("*n") parses that integer directly
                    -- without needing a separate string-to-number step.
                    local file = io.open(fan_path, "r")
                    if file then
                        local speed = file:read("*n")
                        file:close()

                        -- Every fan whose input file could be read gets
                        -- listed, INCLUDING ones currently reading 0 RPM.
                        -- A stopped fan (many boards/GPUs run fans at 0
                        -- RPM under light load, a.k.a. "zero-RPM mode")
                        -- still physically exists -- it's a different
                        -- situation from no fan sensor being present at
                        -- all, and the two shouldn't look the same to
                        -- whoever's reading this. Callers (like
                        -- widget.lua's "No fan sensors found" fallback)
                        -- rely on that distinction: this function only
                        -- returns nothing when there are truly no
                        -- fanN_input files anywhere, not just when a fan
                        -- happens to be idle right now.
                        if speed then
                            -- "${alignr}" here is conky's own TEXT-template
                            -- right-align directive -- see the USAGE NOTE
                            -- in the file header above for how to handle
                            -- this if you're not feeding the result
                            -- straight into conky's TEXT section.
                            output = output .. string.format("Fan %s (%s):${alignr}%d RPM\n", fan_num, name, speed)
                        end
                    end
                end
                fan_handle:close()
            end
        end
    end
    handle:close()
    return output
end
