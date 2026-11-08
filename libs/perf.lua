--[[
* perf.lua - Lightweight performance instrumentation for Ashita v4 addons.
*
* Drop this file in:  Ashita/addons/libs/perf.lua
* Then in any addon:  local perf = require('perf');
*
* What it does:
*   - Times your event callbacks / functions with the high-resolution counter (microseconds).
*   - Keeps rolling 1-second stats (calls, avg, max) plus an all-time peak per section.
*   - Tracks this addon's Lua memory (KB), plus a post-GC "baseline" once a minute for leak
*     detection (perfmon watches the baseline's trend and flags steady growth).
*   - Counts this addon's live native objects: fonts (fonts.lua), primitives (primitives.lua) and
*     COM objects such as textures wrapped with d3d8.gc_safe_release. A count that keeps climbing
*     means objects are created and never destroyed, a native leak Lua memory can't show.
*   - Optional per-addon ImGui panel:  /perf <addonname>
*   - If the 'perfmon' addon is loaded, sends a 1-second summary to it so you can see every
*     instrumented addon in one dashboard.
*
* Overhead: two counter reads + a few additions per timed call (~1 microsecond). The once-per-second
* roll-up and report are the only other work. Nothing is written to disk by this library.
--]]

require('common');
local ffi   = require('ffi');
local imgui = require('imgui');

local perf = {
    enabled     = true,     -- Set false to stop timing (wrapped functions still run, untimed).
    report      = true,     -- Send 1s summaries to perfmon when it is loaded.
    interval_ms = 1000,     -- Roll-up / report interval.
    sections    = {},       -- name -> stats table
    order       = {},       -- section names in creation order
    mem_kb      = 0,
    mem_peak_kb = 0,
    -- Leak check: every gc_interval_s a full garbage collection runs and the memory left
    -- afterwards is the baseline. A leak shows up as a baseline that keeps rising.
    -- Set gc_interval_s = 0 to skip the forced GC (baseline = lowest reading in each minute;
    -- cheaper, but less accurate for addons that allocate little).
    gc_interval_s = 60,
    mem_base_kb = nil,
    base_fresh  = false,
    growth_note = nil,      -- set by perf.expect_growth
    growth_max  = 0,
    show        = { false },
    seq         = 0,
    gc_now      = false,    -- set by '/perf gc': force a GC + baseline on the next roll-up
    -- live native objects owned by this addon, and how many were ever created
    obj         = { fonts = 0, prims = 0, com = 0, fonts_made = 0, prims_made = 0, com_made = 0 },
};

--[[
* High-resolution timer.
* Prefer LuaJIT FFI (no table allocation per call); fall back to ashita.time.qpc().
--]]
local now_us;
do
    pcall(ffi.cdef, [[
        int QueryPerformanceCounter(int64_t* lpPerformanceCount);
        int QueryPerformanceFrequency(int64_t* lpFrequency);
    ]]);
    local buf = ffi.new('int64_t[1]');
    local ok2, freq = pcall(function ()
        ffi.C.QueryPerformanceFrequency(buf);
        return tonumber(buf[0]);
    end);

    if (ok2 and freq ~= nil and freq > 0) then
        local scale = 1000000 / freq;
        now_us = function ()
            ffi.C.QueryPerformanceCounter(buf);
            return tonumber(buf[0]) * scale;
        end;
    else
        -- Fallback: Ashita's wrapper (allocates a small table per call).
        local f = ashita.time.qpf().q;
        local scale = 1000000 / f;
        now_us = function ()
            return ashita.time.qpc().q * scale;
        end;
    end
end
perf.now_us = now_us;

--[[
* Native object counting.
*
* fonts.lua and primitives.lua keep every live object in <lib>.cache until :destroy() is
* called, so the live count is just #cache. Their new() is wrapped to count creations (churn).
* d3d8.gc_safe_release is wrapped so each COM object (usually a texture) it manages is counted
* until the garbage collector releases it.
* Objects created straight through AshitaCore's font/primitive managers, or textures released
* by hand, are not seen.
--]]
local function count_new(m, field)
    if (type(m.new) ~= 'function' or rawget(m, '__perf_counted')) then
        return;
    end
    local orig_new = m.new;
    rawset(m, '__perf_counted', true);
    m.new = function (...)
        perf.obj[field] = perf.obj[field] + 1;
        return orig_new(...);
    end;
end

local function patch_module(name, m)
    if (type(m) ~= 'table' or type(name) ~= 'string') then
        return;
    end
    local base = name:lower():match('([^%.%/\\]+)$') or name:lower();
    if (base == 'fonts') then
        count_new(m, 'fonts_made');
    elseif (base == 'primitives') then
        count_new(m, 'prims_made');
    elseif (base == 'd3d8' and type(m.gc_safe_release) == 'function' and not rawget(m, '__perf_counted')) then
        rawset(m, '__perf_counted', true);
        m.gc_safe_release = function (o)
            if (o == nil) then
                error('Invalid object for safe_release!');
            end
            perf.obj.com      = perf.obj.com + 1;
            perf.obj.com_made = perf.obj.com_made + 1;
            return ffi.gc(o, function (v)
                perf.obj.com = perf.obj.com - 1;
                v:Release();
            end);
        end;
    end
end

-- Patch libs already loaded, then catch the ones this addon requires later.
for _, n in ipairs({ 'fonts', 'primitives', 'd3d8' }) do
    patch_module(n, package.loaded[n]);
end
do
    local orig_require = require;
    local ok = pcall(function ()
        require = function (name, ...)
            local m = orig_require(name, ...);
            pcall(patch_module, name, m);
            return m;
        end;
    end);
    if (not ok) then
        require = orig_require;
    end
end

local function cache_len(name)
    local m = package.loaded[name];
    if (type(m) ~= 'table' or type(rawget(m, 'cache')) ~= 'table') then
        return 0;
    end
    return #m.cache;
end

local function count_objects()
    perf.obj.fonts = cache_len('fonts');
    perf.obj.prims = cache_len('primitives');
end

--[[
* Section stats
--]]
local function new_section(name)
    local s = {
        name   = name,
        -- current window
        n      = 0,
        total  = 0,
        max    = 0,
        -- last completed window (what the panel/report shows)
        l_n    = 0,
        l_tot  = 0,
        l_max  = 0,
        -- all time
        peak   = 0,
        calls  = 0,
        -- manual start/stop
        t0     = nil,
    };
    perf.sections[name] = s;
    perf.order[#perf.order + 1] = name;
    return s;
end

local function get_section(name)
    return perf.sections[name] or new_section(name);
end

local function record(s, dt)
    s.n     = s.n + 1;
    s.total = s.total + dt;
    if (dt > s.max) then s.max = dt; end
end

--[[
* Wraps a function so every call is timed under 'name'.
* Multiple return values are passed through untouched.
--]]
local function finish(s, t0, ...)
    record(s, now_us() - t0);
    return ...;
end

function perf.wrap(name, fn)
    local s = get_section(name);
    return function (...)
        if (not perf.enabled) then
            return fn(...);
        end
        return finish(s, now_us(), fn(...));
    end;
end

--[[
* Drop-in replacement for ashita.events.register that times the callback.
* The section is named after the alias unless 'label' is given.
--]]
local orig_register = ashita.events.register;

function perf.register(event_name, alias, fn, label)
    orig_register(event_name, alias, perf.wrap(label or alias, fn));
end

--[[
* Auto mode: hooks ashita.events.register for this addon so EVERY callback it (or any lib it
* loads) registers afterwards is timed, named '<event>:<alias>'.
* perfmon's "Install" button adds this as the first line of an addon:
*     require('perf').auto();
* Callbacks registered through perf.register are not double-timed.
--]]
perf.auto_on = false;

function perf.auto()
    if (perf.auto_on) then
        return true;
    end
    local hooked = function (event_name, alias, fn, ...)
        if (type(fn) ~= 'function') then
            return orig_register(event_name, alias, fn, ...);
        end
        return orig_register(event_name, alias, perf.wrap(('%s:%s'):fmt(event_name, alias), fn), ...);
    end
    local ok = pcall(function () ashita.events.register = hooked; end);
    if (not ok or ashita.events.register ~= hooked) then
        print('[perf] auto mode could not hook ashita.events.register in this Ashita build; use perf.register manually (see README).');
        return false;
    end
    perf.auto_on = true;
    return true;
end

--[[
* Manual timing for a block of code:
*     perf.start('build_list'); ... perf.stop('build_list');
--]]
function perf.start(name)
    if (not perf.enabled) then return; end
    get_section(name).t0 = now_us();
end

function perf.stop(name)
    local s = perf.sections[name];
    if (s == nil or s.t0 == nil) then return; end
    record(s, now_us() - s.t0);
    s.t0 = nil;
end

--[[
* Declares that this addon's memory grows on purpose (a session log, a cache that is
* cleared on zone, ...). perfmon then shows it as "expected" with this note instead of
* flagging a leak. If max_kb is given and the after-GC memory goes past it, perfmon
* flags it anyway, so a cap that stops working is still caught.
*     require('perf').expect_growth('session log, cleared on zone', 80000);
--]]
function perf.expect_growth(note, max_kb)
    perf.growth_note = tostring(note or 'expected');
    perf.growth_max  = math.max(0, math.floor(tonumber(max_kb) or 0));
    perf.base_fresh  = (perf.mem_base_kb ~= nil);   -- send it with the next report
end

--[[
* Resets all collected stats.
--]]
function perf.reset()
    for _, s in pairs(perf.sections) do
        s.n, s.total, s.max = 0, 0, 0;
        s.l_n, s.l_tot, s.l_max = 0, 0, 0;
        s.peak, s.calls = 0, 0;
    end
    perf.mem_peak_kb = 0;
end

--[[
* Reporting to perfmon
--]]
local function perfmon_loaded()
    local ok, res = pcall(function () return AddonManager:IsLoaded('perfmon'); end);
    return ok and res == true;
end

local function clean(str)
    return (tostring(str):gsub('[^%w_%.:%-%(%)]', '_'));
end

local MAX_CMD = 220;

local function send_report(win_ms)
    local name = clean(addon.name);
    perf.seq = (perf.seq % 100000) + 1;
    local head = ('/perfmon_rpt %s %d %d %d '):fmt(name, perf.seq, math.floor(perf.mem_kb), math.floor(win_ms));
    if (perf.base_fresh and perf.mem_base_kb ~= nil) then
        head = head .. ('b%d '):fmt(math.floor(perf.mem_base_kb));
        if (perf.growth_note ~= nil) then
            head = head .. ('e%d:%s '):fmt(perf.growth_max, clean(perf.growth_note):sub(1, 60));
        end
        perf.base_fresh = false;
    end
    local o = perf.obj;
    head = head .. ('o%d:%d:%d:%d:%d:%d '):fmt(o.fonts, o.prims, o.com, o.fonts_made, o.prims_made, o.com_made);

    local buf = head;
    local sent = false;
    for _, n in ipairs(perf.order) do
        local s = perf.sections[n];
        local item = ('%s|%d|%d|%d;'):fmt(clean(n), s.l_n, math.floor(s.l_tot), math.floor(s.l_max));
        if (#buf + #item > MAX_CMD and #buf > #head) then
            AshitaCore:GetChatManager():QueueCommand(-1, buf);
            sent = true;
            buf = head;
        end
        buf = buf .. item;
    end
    if (#buf > #head or not sent) then
        AshitaCore:GetChatManager():QueueCommand(-1, buf);
    end
end

--[[
* Once-per-interval roll-up (called from d3d_present; this callback itself is cheap
* and is timed under '(perf)' so you can see the library's own cost).
--]]
local last_roll = now_us();
local self_sec  = get_section('(perf)');
local gc_sec    = get_section('(perf:gc)');

--[[
* Leak baseline. Returns the microseconds spent in a forced GC (0 if none).
* The first sample is staggered 10-30s after load so addons loaded together
* don't all collect on the same frame.
--]]
local next_base = nil;
local trough    = math.huge;

local function sample_baseline(t)
    local forced = perf.gc_now or (perf.gc_interval_s ~= nil and perf.gc_interval_s > 0);
    if (perf.gc_now) then
        perf.gc_now = false;
        next_base = 0;   -- take the baseline now
    end
    if (not forced and perf.mem_kb < trough) then
        trough = perf.mem_kb;
    end
    if (next_base == nil) then
        next_base = t + (10000 + (math.floor(t / 1000) % 20000)) * 1000;
        return 0;
    end
    if (t < next_base) then
        return 0;
    end
    next_base = t + (forced and perf.gc_interval_s or 60) * 1000000;

    local gc_us = 0;
    if (forced) then
        local g0 = now_us();
        collectgarbage('collect');
        gc_us = now_us() - g0;
        record(gc_sec, gc_us);
        perf.mem_kb = collectgarbage('count');
        perf.mem_base_kb = perf.mem_kb;
    else
        perf.mem_base_kb = (trough < math.huge) and trough or perf.mem_kb;
        trough = math.huge;
    end
    perf.base_fresh = true;
    return gc_us;
end

local function roll()
    local t = now_us();
    local win = (t - last_roll) / 1000;
    if (win < perf.interval_ms) then
        return;
    end
    last_roll = t;

    for _, s in pairs(perf.sections) do
        s.l_n, s.l_tot, s.l_max = s.n, s.total, s.max;
        if (s.max > s.peak) then s.peak = s.max; end
        s.calls = s.calls + s.n;
        s.n, s.total, s.max = 0, 0, 0;
    end

    perf.mem_kb = collectgarbage('count');
    if (perf.mem_kb > perf.mem_peak_kb) then perf.mem_peak_kb = perf.mem_kb; end
    local gc_us = sample_baseline(t);
    count_objects();

    if (perf.report and perfmon_loaded()) then
        send_report(win);
    end

    record(self_sec, now_us() - t - gc_us);
end

--[[
* Optional local panel.
--]]
local COL_OK   = { 0.6, 1.0, 0.6, 1.0 };
local COL_WARN = { 1.0, 0.85, 0.3, 1.0 };
local COL_BAD  = { 1.0, 0.4, 0.4, 1.0 };

local function heat(us)
    if (us >= 2000) then return COL_BAD; end
    if (us >= 500) then return COL_WARN; end
    return COL_OK;
end

local function draw_panel()
    if (not perf.show[1]) then return; end

    imgui.SetNextWindowSize({ 520, 0 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin(('perf - %s'):fmt(addon.name), perf.show, ImGuiWindowFlags_NoSavedSettings)) then
        if (perf.mem_base_kb ~= nil) then
            imgui.Text(('Lua memory: %.0f KB  (peak %.0f KB, after GC %.0f KB)'):fmt(perf.mem_kb, perf.mem_peak_kb, perf.mem_base_kb));
        else
            imgui.Text(('Lua memory: %.0f KB  (peak %.0f KB)'):fmt(perf.mem_kb, perf.mem_peak_kb));
        end
        local o = perf.obj;
        imgui.Text(('Live objects: %d fonts, %d primitives, %d COM/textures  (created %d / %d / %d)'):fmt(
            o.fonts, o.prims, o.com, o.fonts_made, o.prims_made, o.com_made));
        imgui.SameLine();
        if (imgui.SmallButton('Reset')) then perf.reset(); end
        imgui.SameLine();
        local en = { perf.enabled };
        if (imgui.Checkbox('Timing', en)) then perf.enabled = en[1]; end

        local flags = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_SizingStretchProp);
        if (imgui.BeginTable('##perf_tbl', 6, flags)) then
            imgui.TableSetupColumn('Section');
            imgui.TableSetupColumn('Calls/s');
            imgui.TableSetupColumn('Avg us');
            imgui.TableSetupColumn('Max us');
            imgui.TableSetupColumn('Peak us');
            imgui.TableSetupColumn('ms/s');
            imgui.TableHeadersRow();

            for _, n in ipairs(perf.order) do
                local s = perf.sections[n];
                local avg = (s.l_n > 0) and (s.l_tot / s.l_n) or 0;
                imgui.TableNextRow();
                imgui.TableNextColumn(); imgui.Text(n);
                imgui.TableNextColumn(); imgui.Text(('%d'):fmt(s.l_n));
                imgui.TableNextColumn(); imgui.Text(('%.1f'):fmt(avg));
                imgui.TableNextColumn(); imgui.TextColored(heat(s.l_max), ('%.0f'):fmt(s.l_max));
                imgui.TableNextColumn(); imgui.TextColored(heat(s.peak), ('%.0f'):fmt(s.peak));
                imgui.TableNextColumn(); imgui.Text(('%.3f'):fmt(s.l_tot / 1000));
            end
            imgui.EndTable();
        end
    end
    imgui.End();
end

--[[
* Prints a one-shot summary to chat.
--]]
function perf.print()
    print(('[perf:%s] mem %.0f KB (peak %.0f KB, after GC %s KB)'):fmt(addon.name, perf.mem_kb, perf.mem_peak_kb,
        perf.mem_base_kb and ('%.0f'):fmt(perf.mem_base_kb) or '?'));
    local o = perf.obj;
    print(('[perf:%s] live objects: %d fonts, %d primitives, %d COM/textures  (created: %d / %d / %d)'):fmt(
        addon.name, o.fonts, o.prims, o.com, o.fonts_made, o.prims_made, o.com_made));
    for _, n in ipairs(perf.order) do
        local s = perf.sections[n];
        local avg = (s.l_n > 0) and (s.l_tot / s.l_n) or 0;
        print(('  %-20s %5d/s  avg %7.1fus  max %7.0fus  peak %7.0fus'):fmt(n, s.l_n, avg, s.l_max, s.peak));
    end
end

--[[
* Library events (registered once per addon state on first require).
--]]
ashita.events.register('d3d_present', '__perf_lib_present', function ()
    roll();
    draw_panel();
end);

ashita.events.register('command', '__perf_lib_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/perf') then
        return;
    end
    e.blocked = true;

    -- /perf gc  -> every instrumented addon collects garbage and reports a fresh baseline
    -- (perfmon sends this before a snapshot so the numbers are clean).
    if (#args >= 2 and args[2]:lower() == 'gc') then
        perf.gc_now = true;
        return;
    end

    -- /perf  or  /perf list  -> every instrumented addon announces itself
    if (#args == 1 or args[2]:lower() == 'list') then
        print(('[perf] instrumented: %s  (/perf %s)'):fmt(addon.name, addon.name));
        return;
    end

    if (args[2]:lower() ~= addon.name:lower()) then
        return;
    end

    local sub = (args[3] or ''):lower();
    if (sub == '' or sub == 'show' or sub == 'toggle') then
        perf.show[1] = not perf.show[1];
    elseif (sub == 'print') then
        perf.print();
    elseif (sub == 'reset') then
        perf.reset();
        print(('[perf:%s] stats reset.'):fmt(addon.name));
    elseif (sub == 'on') then
        perf.enabled = true;
    elseif (sub == 'off') then
        perf.enabled = false;
    else
        print('[perf] usage: /perf <addon> [show|print|reset|on|off]   /perf list   /perf gc');
    end
end);

return perf;
