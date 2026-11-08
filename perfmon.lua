--[[
* perfmon - Dashboard for addons instrumented with libs/perf.lua (Ashita v4).
*
* Commands:
*   /perfmon                 Toggle the dashboard window.
*   /perfmon log [on|off]    Toggle CSV logging (config/addons/perfmon/perf_YYYYMMDD_HHMMSS.csv).
*   /perfmon log clear       Empty the current CSV (keeps the header; logging continues).
*   /perfmon reset           Clear all collected data.
*   /perfmon print           Print a summary to chat.
*   /perfmon mem             Print memory / leak-check summary to chat.
*   /perfmon install <addon> Add auto-instrumentation to a loaded addon (backup + reload).
*   /perfmon remove <addon>  Take it back out and reload.
*   /perfmon install all     Install into every loaded addon that isn't instrumented yet.
*   /perfmon remove all      Remove from every addon perfmon installed into.
*   /perfmon status          Show which loaded addons are instrumented.
*   /perfmon snap            Snapshot memory, address space, handles and per-addon objects.
*   /perfmon diff            Show what changed since the snapshot (both force a GC first).
*   /perfmon mark [text]     Put a marker on the process memory graph (zones and addon
*                            loads/unloads are marked automatically).
*   /perfmon help            Show commands.
*
* Leak check: perf.lua sends a post-GC Lua memory baseline once a minute. perfmon fits a line
* through the last 10 minutes of baselines and flags an addon whose baseline rises steadily.
* It also samples the game process's private memory, which catches native leaks (FFI
* allocations, textures, handles) that Lua memory can't see.
*
* Native breakdown (1.6): every 30 s the game's address space is scanned and logged by type
* (private / mapped / image / reserved / largest free gap), plus handle and GDI/USER counts.
* Zone, addon load/unload and /perfmon mark markers go into the CSV as (event) rows, and the
* first row says whether the game is running on Windows or under Wine/Proton.
*
* 1.7: Memory tab shows address-space headroom with an estimated time until it runs out,
* live font / primitive / texture counts per addon (needs the matching perf.lua), and
* snapshot / diff.
--]]

addon.name    = 'perfmon';
addon.author  = 'Lift';
addon.version = '1.7';
addon.desc    = 'Performance dashboard for addons that use libs/perf.lua.';
addon.link    = '';

require('common');
local ffi   = require('ffi');
local imgui = require('imgui');

--[[
* Timer (same approach as perf.lua: FFI QPC, fallback to ashita.time.qpc)
--]]
local now_us;
do
    pcall(ffi.cdef, [[
        int QueryPerformanceCounter(int64_t* lpPerformanceCount);
        int QueryPerformanceFrequency(int64_t* lpFrequency);
    ]]);
    local buf = ffi.new('int64_t[1]');
    local ok, freq = pcall(function ()
        ffi.C.QueryPerformanceFrequency(buf);
        return tonumber(buf[0]);
    end);
    if (ok and freq ~= nil and freq > 0) then
        local scale = 1000000 / freq;
        now_us = function () ffi.C.QueryPerformanceCounter(buf); return tonumber(buf[0]) * scale; end;
    else
        local scale = 1000000 / ashita.time.qpf().q;
        now_us = function () return ashita.time.qpc().q * scale; end;
    end
end

--[[
* State
--]]
local FRAME_RING   = 240;     -- frames kept for the graph
local STALE_US     = 3000000; -- addon greyed out if no report for 3s
local HITCH_MS     = 50;      -- a frame longer than this counts as a hitch
local FLUSH_US     = 10000000;
local CSV_HEADER   = 'time,addon,section,calls,avg_us,max_us,ms_per_s,mem_kb';

-- Leak detection
local LEAK_WINDOW_US = 10 * 60 * 1000000; -- trend is fitted over this much history
local LEAK_KEEP_US   = 30 * 60 * 1000000; -- history kept for the graphs
local LEAK_MIN_N     = 5;                 -- baselines needed before judging an addon (~5 min)
local LEAK_KB_MIN    = 20;                -- addon baseline growth that counts as a leak (KB/min)...
local LEAK_MIN_RISE  = 100;               -- ...with at least this much total growth (KB)...
local LEAK_R2        = 0.85;              -- ...and steady growth (line fit 0..1), not one jump
local PROC_SAMPLE_US = 10 * 1000000;      -- game process memory sample interval
local PROC_MIN_N     = 12;                -- samples needed (~2 min)
local PROC_MB_MIN    = 2;                 -- game process growth worth flagging (MB/min)

--[[
* Game process private memory (KB), via K32GetProcessMemoryInfo / psapi. nil if unavailable.
--]]
local proc_mem_kb = function () return nil; end;
do
    pcall(ffi.cdef, [[
        typedef struct {
            uint32_t cb;
            uint32_t PageFaultCount;
            size_t   PeakWorkingSetSize;
            size_t   WorkingSetSize;
            size_t   QuotaPeakPagedPoolUsage;
            size_t   QuotaPagedPoolUsage;
            size_t   QuotaPeakNonPagedPoolUsage;
            size_t   QuotaNonPagedPoolUsage;
            size_t   PagefileUsage;
            size_t   PeakPagefileUsage;
        } PM_PROCESS_MEMORY_COUNTERS;
        void* __stdcall GetCurrentProcess(void);
        int   __stdcall K32GetProcessMemoryInfo(void* Process, PM_PROCESS_MEMORY_COUNTERS* ppsmemCounters, uint32_t cb);
        int   __stdcall GetProcessMemoryInfo(void* Process, PM_PROCESS_MEMORY_COUNTERS* ppsmemCounters, uint32_t cb);
    ]]);
    local ok, pmc = pcall(ffi.new, 'PM_PROCESS_MEMORY_COUNTERS');
    if (ok and pmc ~= nil) then
        local sz = ffi.sizeof(pmc);
        pmc.cb = sz;
        local function find(lib, fname)
            local ok2, f = pcall(function () return lib[fname]; end);
            if (ok2 and f ~= nil) then return f; end
            return nil;
        end
        local psapi = nil;
        local getinfo = find(ffi.C, 'K32GetProcessMemoryInfo');
        if (getinfo == nil) then
            local okl, lib = pcall(ffi.load, 'psapi');
            if (okl) then
                psapi = lib;
                getinfo = find(psapi, 'GetProcessMemoryInfo');
            end
        end
        if (getinfo ~= nil) then
            local fn = function ()
                local _ = psapi; -- keep the library loaded
                if (getinfo(ffi.C.GetCurrentProcess(), pmc, sz) ~= 0) then
                    return tonumber(pmc.PagefileUsage) / 1024;
                end
                return nil;
            end;
            local okc, v = pcall(fn);
            if (okc and v ~= nil and v > 0) then
                proc_mem_kb = fn;
            end
        end
    end
end

--[[
* Native memory breakdown (for leaks Lua can't see).
*
* vm_scan() walks the game's address space with VirtualQuery and totals it by type:
*   private  - heap / VirtualAlloc memory (game, plugins, drivers' system-RAM copies)
*   mapped   - file mappings / shared sections (graphics layers often put buffers here)
*   image    - loaded EXE/DLL files
*   reserved - address space set aside but not committed yet
*   free_largest - biggest free gap. A 32-bit process dies when no gap is big enough for
*                  an allocation, often well before total use reaches the limit.
* Also: handle count, GDI/USER object counts, and whether we are running under Wine.
* Every function returns nil when the API isn't there, and callers just skip the row.
--]]
local VM_SAMPLE_US = 30 * 1000000;   -- address-space scan interval
local VM_BIG_KB    = 1024;
local VM_MIN_N     = 6;              -- scans needed (~3 min) before estimating time to run out
local VM_MARGIN_MB = 64;             -- treat the address space as gone when this little is free
local OBJ_RISE     = 10;             -- live objects must grow at least this much...
local OBJ_PER_MIN  = 1;              -- ...at this rate, steadily, to be flagged           -- committed private regions this size or bigger count as "big"

local vm_scan       = function () return nil; end;
local handle_counts = function () return nil; end;
local platform_str  = 'unknown';
do
    pcall(ffi.cdef, [[
        typedef struct {
            void*    BaseAddress;
            void*    AllocationBase;
            uint32_t AllocationProtect;
            size_t   RegionSize;
            uint32_t State;
            uint32_t Protect;
            uint32_t Type;
        } PM_MBI;
        size_t __stdcall VirtualQuery(const void* lpAddress, PM_MBI* lpBuffer, size_t dwLength);
        int    __stdcall GetProcessHandleCount(void* hProcess, uint32_t* pdwHandleCount);
        uint32_t __stdcall GetGuiResources(void* hProcess, uint32_t uiFlags);
        const char* wine_get_version(void);
        void wine_get_host_version(const char** sysname, const char** release);
    ]]);

    local MEM_COMMIT, MEM_RESERVE, MEM_FREE = 0x1000, 0x2000, 0x10000;
    local MEM_PRIVATE, MEM_MAPPED, MEM_IMAGE = 0x20000, 0x40000, 0x1000000;

    local okm, mbi = pcall(ffi.new, 'PM_MBI');
    local okq, vq  = pcall(function () return ffi.C.VirtualQuery; end);
    if (okm and okq and vq ~= nil) then
        local msz = ffi.sizeof('PM_MBI');
        local fn = function ()
            local r = { private = 0, private_big = 0, mapped = 0, image = 0, reserved = 0,
                        free_total = 0, free_largest = 0, regions = 0 };
            local addr = 0x10000;
            local limit = 2 ^ 32;
            local guard = 0;
            while (addr < limit and guard < 200000) do
                guard = guard + 1;
                if (vq(ffi.cast('const void*', ffi.cast('uintptr_t', addr)), mbi, msz) == 0) then
                    break;
                end
                local size = tonumber(mbi.RegionSize);
                if (size == nil or size <= 0) then break; end
                local kb = size / 1024;
                local state, typ = mbi.State, mbi.Type;
                r.regions = r.regions + 1;
                if (state == MEM_FREE) then
                    r.free_total = r.free_total + kb;
                    if (kb > r.free_largest) then r.free_largest = kb; end
                elseif (state == MEM_RESERVE) then
                    r.reserved = r.reserved + kb;
                elseif (state == MEM_COMMIT) then
                    if (typ == MEM_PRIVATE) then
                        r.private = r.private + kb;
                        if (kb >= VM_BIG_KB) then r.private_big = r.private_big + kb; end
                    elseif (typ == MEM_MAPPED) then
                        r.mapped = r.mapped + kb;
                    elseif (typ == MEM_IMAGE) then
                        r.image = r.image + kb;
                    end
                end
                addr = tonumber(ffi.cast('uintptr_t', mbi.BaseAddress)) + size;
            end
            return r;
        end;
        local okc, v = pcall(fn);
        if (okc and v ~= nil and v.regions > 0) then
            vm_scan = fn;
        end
    end

    -- Handles (kernel32) and GDI/USER objects (user32).
    local okh, ghc = pcall(function () return ffi.C.GetProcessHandleCount; end);
    local user32 = nil;
    pcall(function () user32 = ffi.load('user32'); end);
    local ggr = nil;
    if (user32 ~= nil) then
        pcall(function () ggr = user32.GetGuiResources; end);
    end
    local hbuf = ffi.new('uint32_t[1]');
    local hfn = function ()
        local _ = user32; -- keep the library loaded
        local proc = ffi.C.GetCurrentProcess();
        local r = {};
        if (okh and ghc ~= nil and ghc(proc, hbuf) ~= 0) then r.handles = tonumber(hbuf[0]); end
        if (ggr ~= nil) then
            r.gdi  = tonumber(ggr(proc, 0));
            r.user = tonumber(ggr(proc, 1));
        end
        return r;
    end;
    local okt, tv = pcall(hfn);
    if (okt and tv ~= nil and (tv.handles ~= nil or tv.gdi ~= nil)) then
        handle_counts = hfn;
    end

    -- Wine/Proton exports wine_get_version from ntdll; real Windows doesn't.
    pcall(function ()
        local ntdll = ffi.load('ntdll');
        local okv, wgv = pcall(function () return ntdll.wine_get_version; end);
        if (okv and wgv ~= nil) then
            local ver = ffi.string(wgv());
            local host = '';
            pcall(function ()
                local sys, rel = ffi.new('const char*[1]'), ffi.new('const char*[1]');
                ntdll.wine_get_host_version(sys, rel);
                host = (' on %s %s'):fmt(ffi.string(sys[0]), ffi.string(rel[0]));
            end);
            platform_str = ('wine %s%s'):fmt(ver, host);
        else
            platform_str = 'windows';
        end
    end);
end

-- CSV fields can't hold commas or newlines.
local function csv_safe(s)
    return (tostring(s):gsub('[,\r\n]', ' '));
end

--[[
* History + trend helpers. hist = { {t=us, v=value}, ... } oldest first.
--]]
local function push_hist(hist, t, v)
    hist[#hist + 1] = { t = t, v = v };
    while (#hist > 0 and (t - hist[1].t) > LEAK_KEEP_US) do
        table.remove(hist, 1);
    end
end

-- Least-squares line over the samples inside LEAK_WINDOW_US.
-- Returns { slope = units/min, r2 = 0..1, rise = last - first, n = samples, mins = span } or nil.
local function trend(hist, now)
    local n, sx, sy, sxx, sxy, syy = 0, 0, 0, 0, 0, 0;
    local t0, v0, x, y;
    for i = 1, #hist do
        local h = hist[i];
        if ((now - h.t) <= LEAK_WINDOW_US) then
            if (t0 == nil) then t0, v0 = h.t, h.v; end
            x = (h.t - t0) / 60000000;
            y = h.v - v0;
            n, sx, sy = n + 1, sx + x, sy + y;
            sxx, sxy, syy = sxx + x * x, sxy + x * y, syy + y * y;
        end
    end
    if (n < 2) then return nil; end
    local dx = n * sxx - sx * sx;
    if (dx <= 0) then return nil; end
    local cov = n * sxy - sx * sy;
    local dy  = n * syy - sy * sy;
    return {
        slope = cov / dx,
        r2    = (dy > 0) and ((cov * cov) / (dx * dy)) or 0,
        rise  = y,
        n     = n,
        mins  = x,
    };
end

local function build_plot(hist, plot)
    for i = #plot, 1, -1 do plot[i] = nil; end
    local lo, hi = math.huge, -math.huge;
    for i = 1, #hist do
        local v = hist[i].v;
        plot[i] = v;
        if (v < lo) then lo = v; end
        if (v > hi) then hi = v; end
    end
    if (#hist == 0) then return 0, 1; end
    local pad = math.max((hi - lo) * 0.1, 1);
    return lo - pad, hi + pad;
end

local pm = {
    show      = { true },
    addons    = {},           -- name -> entry
    -- frame timing
    last_frame  = nil,
    ring        = {},
    plot        = {},
    ring_head   = 0,
    sec_start   = now_us(),
    sec_frames  = 0,
    sec_sum_ms  = 0,
    sec_worst   = 0,
    fps         = 0,
    avg_ms      = 0,
    worst_ms    = 0,
    hitches     = 0,          -- hitches in last second
    hitch_total = 0,
    -- self cost
    self_tot    = 0,
    self_last   = 0,
    -- logging
    log_on      = false,
    log_path    = nil,
    log_buf     = {},
    log_flushed = now_us(),
    -- uninstrumented list cache
    others      = {},
    others_at   = 0,
    -- Stats tab: addon name -> true when its sections are hidden
    collapsed = {},
    -- Per-table sort state: col = column index, asc = ascending.
    -- text = columns that start A-Z when picked (numbers start biggest first); nosort = not clickable.
    sorts = {
        stats = { col = 6, asc = false, def_col = 6, def_asc = false, text = { [1] = true } },
        mem   = { col = 4, asc = false, def_col = 4, def_asc = false, text = { [1] = true }, nosort = { [8] = true } },
        inst  = { col = 1, asc = true,  def_col = 1, def_asc = true,  text = { [1] = true, [2] = true }, nosort = { [4] = true } },
    },
    -- game process memory
    proc = { kb = nil, peak = 0, at = 0, hist = {}, plot = {}, lo = 0, hi = 1, trend = nil, rising = false, warned = false },
    -- native breakdown (last scan): see vm_scan() / handle_counts()
    vm = { at = 0, last = nil, first = nil, handles = nil, first_handles = nil, scan_us = 0,
           free_hist = {}, free_trend = nil, h_hist = {}, h_trend = nil },
    -- snapshot / diff
    snap = nil, diff = nil, capture = nil,
    -- markers on the process graph: { t, kind = 'zone'|'load'|'unload'|'mark', label }
    events      = {},
    prev_loaded = nil,        -- name -> true from the last addon-list refresh
};

local draw_event_markers, draw_event_list;
local obj_risers, draw_obj_cell, draw_native, draw_snapshot, request_capture, capture_tick;

local function log_line(str)
    if (pm.log_on) then
        pm.log_buf[#pm.log_buf + 1] = str;
    end
end
local EVENT_AFTER_US = 30 * 1000000;   -- memory jump for a marker = sample ~30s after vs the one before

local function add_event(kind, label)
    local t = now_us();
    local ev = pm.events;
    -- The zone packet can arrive twice; drop exact repeats within 3s.
    local last = ev[#ev];
    if (last ~= nil and last.kind == kind and last.label == label and (t - last.t) < 3000000) then
        return;
    end
    ev[#ev + 1] = { t = t, kind = kind, label = label };
    log_line(('%s,(event),%s:%s,0,0,0,0,%d'):fmt(os.date('%H:%M:%S'), kind, csv_safe(label), math.floor(pm.proc.kb or 0)));
    while (#ev > 0 and (t - ev[1].t) > LEAK_KEEP_US) do
        table.remove(ev, 1);
    end
end

for i = 1, FRAME_RING do
    pm.ring[i] = 0;
    pm.plot[i] = 0;
end

--[[
* Report parsing
* Format: /perfmon_rpt <addon> <seq> <mem_kb> <win_ms> name|calls|tot_us|max_us;name|...;
--]]
local function get_addon(name)
    local a = pm.addons[name];
    if (a == nil) then
        a = { name = name, seq = -1, mem = 0, mem_peak = 0, win_ms = 1000, seen = 0, sections = {}, order = {}, total_us = 0,
              base = nil, base_hist = {}, base_plot = {}, lo = 0, hi = 1, trend = nil, leak = false, growing = false,
              obj = nil, obj_first = nil, obj_hist = {}, obj_trend = nil, obj_rising = false };
        pm.addons[name] = a;
    end
    return a;
end

local function judge_addon(a, now)
    local tr = trend(a.base_hist, now);
    a.trend = tr;
    local was = a.leak;
    local looks_leak = (tr ~= nil and tr.n >= LEAK_MIN_N and tr.slope >= LEAK_KB_MIN and tr.rise >= LEAK_MIN_RISE and tr.r2 >= LEAK_R2);
    -- Addons that declared expected growth (perf.expect_growth) are only flagged past their cap.
    a.over_cap = (a.expect_note ~= nil and a.expect_max ~= nil and a.expect_max > 0 and a.base ~= nil and a.base > a.expect_max);
    if (a.expect_note ~= nil) then
        a.leak     = a.over_cap;
        a.expected = (not a.over_cap) and looks_leak;
    else
        a.leak     = looks_leak;
        a.expected = false;
    end
    a.growing = (not a.leak) and (not a.expected) and tr ~= nil and tr.n >= LEAK_MIN_N and tr.slope >= LEAK_KB_MIN / 4 and tr.r2 >= LEAK_R2;
    a.lo, a.hi = build_plot(a.base_hist, a.base_plot);
    if (a.leak and not was) then
        if (a.over_cap) then
            print(('[perfmon] %s is past its declared memory cap: %d KB after GC (cap %d KB, "%s").'):fmt(a.name, a.base, a.expect_max, a.expect_note));
        else
            print(('[perfmon] possible leak in %s: Lua memory after GC rising %.0f KB/min (+%.0f KB over %.0f min).'):fmt(a.name, tr.slope, tr.rise, tr.mins));
        end
    end
end

local function handle_report(cmd)
    local name, seq, mem, win, payload = cmd:match('^/perfmon_rpt%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s*(.*)$');
    if (name == nil) then
        return;
    end
    seq, mem, win = tonumber(seq), tonumber(mem), tonumber(win);

    -- Optional post-GC baseline:  b<kb>  before the sections (sent ~once a minute).
    -- Optional expected-growth note:  e<max_kb>:<note>  right after the baseline.
    local base, exp_max, exp_note = nil, nil, nil;
    local b, rest = payload:match('^b(%d+)%s+(.*)$');
    if (b ~= nil) then
        base, payload = tonumber(b), rest;
        local em, en, rest2 = payload:match('^e(%d+):(%S+)%s+(.*)$');
        if (em ~= nil) then
            exp_max, exp_note, payload = tonumber(em), en:gsub('_+', ' '), rest2;
        end
    end

    -- Optional live object counts:  o<fonts>:<prims>:<com>:<fonts made>:<prims made>:<com made>
    local obj = nil;
    local ostr, rest3 = payload:match('^o([%d:]+)%s+(.*)$');
    if (ostr ~= nil) then
        payload = rest3;
        local f, pr, c, fm, pm_, cm = ostr:match('^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$');
        if (f ~= nil) then
            obj = { fonts = tonumber(f), prims = tonumber(pr), com = tonumber(c),
                    fonts_made = tonumber(fm), prims_made = tonumber(pm_), com_made = tonumber(cm) };
        end
    end

    local a = get_addon(name);

    -- A new seq means a new 1s window; continuation chunks share the same seq.
    if (seq ~= a.seq) then
        -- seq restarts at 1 when the addon reloads: its old memory history no longer applies.
        if (seq < a.seq) then
            a.base_hist, a.base_plot, a.base, a.trend, a.leak, a.growing = {}, {}, nil, nil, false, false;
            a.expect_note, a.expect_max, a.expected, a.over_cap = nil, nil, false, false;
            a.obj_hist, a.obj_trend, a.obj_rising, a.obj_first = {}, nil, false, nil;
        end
        if (obj ~= nil) then
            a.obj = obj;
            a.obj_first = a.obj_first or obj;
        end
        if (base ~= nil) then
            local t = now_us();
            a.base = base;
            if (exp_note ~= nil) then
                a.expect_note, a.expect_max = exp_note, exp_max;
            end
            push_hist(a.base_hist, t, base);
            judge_addon(a, t);
            if (a.obj ~= nil) then
                -- Live object count, sampled with the once-a-minute baseline.
                local live = a.obj.fonts + a.obj.prims + a.obj.com;
                push_hist(a.obj_hist, t, live);
                local otr = trend(a.obj_hist, t);
                a.obj_trend = otr;
                a.obj_rising = (otr ~= nil and otr.n >= LEAK_MIN_N and otr.slope >= OBJ_PER_MIN and otr.rise >= OBJ_RISE and otr.r2 >= LEAK_R2);
                log_line(('%s,%s,(objects),%d,%d,%d,0,%d'):fmt(os.date('%H:%M:%S'), name, a.obj.fonts, a.obj.prims, a.obj.com, live));
            end
            log_line(('%s,%s,(gc baseline),0,0,0,0,%d'):fmt(os.date('%H:%M:%S'), name, base));
        end
        a.seq      = seq;
        a.mem      = mem;
        a.win_ms   = (win > 0) and win or 1000;
        a.seen     = now_us();
        a.total_us = 0;
        if (mem > a.mem_peak) then a.mem_peak = mem; end
    end

    for sname, n, tot, mx in payload:gmatch('([^|;]+)|(%d+)|(%d+)|(%d+);') do
        n, tot, mx = tonumber(n), tonumber(tot), tonumber(mx);
        local s = a.sections[sname];
        if (s == nil) then
            s = { name = sname, n = 0, tot = 0, max = 0, peak = 0 };
            a.sections[sname] = s;
            a.order[#a.order + 1] = sname;
        end
        s.n, s.tot, s.max = n, tot, mx;
        if (mx > s.peak) then s.peak = mx; end
        a.total_us = a.total_us + tot;

        if (pm.log_on and n > 0) then
            log_line(('%s,%s,%s,%d,%.1f,%d,%.3f,%d'):fmt(os.date('%H:%M:%S'), name, sname, n, tot / n, mx, tot / 1000 * (1000 / a.win_ms), mem));
        end
    end
end

--[[
* Logging
--]]
local function flush_log()
    if (pm.log_path == nil or #pm.log_buf == 0) then
        return;
    end
    local f = io.open(pm.log_path, 'a');
    if (f ~= nil) then
        f:write(table.concat(pm.log_buf, '\n'), '\n');
        f:close();
    end
    pm.log_buf = {};
    pm.log_flushed = now_us();
end

local function set_logging(on)
    if (on == pm.log_on) then
        return;
    end
    if (on) then
        local dir = ('%s\\config\\addons\\perfmon\\'):fmt(AshitaCore:GetInstallPath());
        if (not ashita.fs.exists(dir)) then
            ashita.fs.create_directory(dir);
        end
        pm.log_path = ('%sperf_%s.csv'):fmt(dir, os.date('%Y%m%d_%H%M%S'));
        pm.log_buf  = { CSV_HEADER };
        pm.log_on   = true;
        log_line(('%s,(game),platform:%s,0,0,0,0,0'):fmt(os.date('%H:%M:%S'), csv_safe(platform_str)));
        pm.vm.at = 0; -- write a native breakdown right away
        print(('[perfmon] logging to %s (platform: %s)'):fmt(pm.log_path, platform_str));
    else
        flush_log();
        pm.log_on = false;
        print('[perfmon] logging stopped.');
    end
end

-- Empties the current (or last used) CSV back to just the header row.
-- Logging keeps running if it was on.
local function clear_log()
    if (pm.log_path == nil) then
        print('[perfmon] no CSV to empty (logging has not been started this session).');
        return;
    end
    pm.log_buf = {};
    local f, err = io.open(pm.log_path, 'w');
    if (f == nil) then
        print(('[perfmon] could not empty %s: %s'):fmt(pm.log_path, tostring(err)));
        return;
    end
    f:write(CSV_HEADER, '\n');
    f:close();
    pm.log_flushed = now_us();
    print(('[perfmon] emptied %s'):fmt(pm.log_path));
end

--[[
* Frame timing
--]]
local function frame_tick(t)
    if (pm.last_frame ~= nil) then
        local ms = (t - pm.last_frame) / 1000;
        pm.ring_head = (pm.ring_head % FRAME_RING) + 1;
        pm.ring[pm.ring_head] = ms;

        pm.sec_frames = pm.sec_frames + 1;
        pm.sec_sum_ms = pm.sec_sum_ms + ms;
        if (ms > pm.sec_worst) then pm.sec_worst = ms; end
        if (ms > HITCH_MS) then
            pm.hitch_total = pm.hitch_total + 1;
            pm.hitches = pm.hitches + 1;
        end
    end
    pm.last_frame = t;

    if (t - pm.sec_start >= 1000000) then
        local secs = (t - pm.sec_start) / 1000000;
        pm.fps      = pm.sec_frames / secs;
        pm.avg_ms   = (pm.sec_frames > 0) and (pm.sec_sum_ms / pm.sec_frames) or 0;
        pm.worst_ms = pm.sec_worst;
        pm.last_hitches = pm.hitches;

        if (pm.log_on) then
            log_line(('%s,(game),frame,%d,%.1f,%d,%.3f,%d'):fmt(os.date('%H:%M:%S'), pm.sec_frames, pm.avg_ms * 1000, math.floor(pm.worst_ms * 1000), pm.self_last / 1000, math.floor(collectgarbage('count'))));
        end

        pm.sec_start, pm.sec_frames, pm.sec_sum_ms, pm.sec_worst, pm.hitches = t, 0, 0, 0, 0;
        pm.self_last, pm.self_tot = pm.self_tot, 0;
    end
end

--[[
* Game process memory sampling
--]]
local function proc_tick(t)
    local p = pm.proc;
    if ((t - p.at) < PROC_SAMPLE_US) then
        return;
    end
    p.at = t;
    local kb = proc_mem_kb();
    if (kb == nil) then
        return;
    end
    p.kb = kb;
    if (kb > p.peak) then p.peak = kb; end
    push_hist(p.hist, t, kb / 1024);   -- history in MB
    p.trend = trend(p.hist, t);
    local tr = p.trend;
    p.rising = (tr ~= nil and tr.n >= PROC_MIN_N and tr.slope >= PROC_MB_MIN and tr.r2 >= LEAK_R2);
    p.lo, p.hi = build_plot(p.hist, p.plot);
    if (p.rising and not p.warned) then
        p.warned = true;
        print(('[perfmon] game process memory rising %.1f MB/min (+%.0f MB over %.0f min). See the Memory tab.'):fmt(tr.slope, tr.rise, tr.mins));
    elseif (not p.rising) then
        p.warned = false;
    end
    log_line(('%s,(game),process_private,0,0,0,0,%d'):fmt(os.date('%H:%M:%S'), math.floor(kb)));
end

--[[
* Native breakdown sampling (every 30 s). Rows: (game),vm_<kind> / handles / gdi / user,
* value in the mem_kb column (KB for vm_*, a count for the others). vm_scan_us = scan cost.
--]]
local VM_ROWS = { 'private', 'private_big', 'mapped', 'image', 'reserved', 'free_total', 'free_largest', 'regions' };
local function vm_tick(t)
    local v = pm.vm;
    if ((t - v.at) < VM_SAMPLE_US) then
        return;
    end
    v.at = t;
    local ts = os.date('%H:%M:%S');
    local t0 = now_us();
    local okv, r = pcall(vm_scan);
    v.scan_us = now_us() - t0;
    if (okv and r ~= nil) then
        v.last = r;
        v.first = v.first or r;
        push_hist(v.free_hist, t, r.free_total / 1024);   -- MB
        v.free_trend = trend(v.free_hist, t);
        for _, k in ipairs(VM_ROWS) do
            log_line(('%s,(game),vm_%s,0,0,0,0,%d'):fmt(ts, k, math.floor(r[k])));
        end
        log_line(('%s,(game),vm_scan_us,1,%.1f,%d,0,0'):fmt(ts, v.scan_us, math.floor(v.scan_us)));
    end
    local okh, h = pcall(handle_counts);
    if (okh and h ~= nil) then
        v.handles = h;
        v.first_handles = v.first_handles or h;
        if (h.handles ~= nil) then
            push_hist(v.h_hist, t, h.handles);
            v.h_trend = trend(v.h_hist, t);
        end
        for _, k in ipairs({ 'handles', 'gdi', 'user' }) do
            if (h[k] ~= nil) then
                log_line(('%s,(game),%s,0,0,0,0,%d'):fmt(ts, k, h[k]));
            end
        end
    end
end

local COL_OK    = { 0.6, 1.0, 0.6, 1.0 };
local COL_WARN  = { 1.0, 0.85, 0.3, 1.0 };
local COL_BAD   = { 1.0, 0.4, 0.4, 1.0 };
local COL_HEAD  = { 0.55, 0.8, 1.0, 1.0 };
local COL_STALE = { 0.5, 0.5, 0.5, 1.0 };
local COL_HDR   = { 0.85, 0.85, 0.85, 1.0 };

-- All tables: resizable columns (drag the borders), striped rows, scrolling with a frozen header.
local TABLE_FLAGS = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_Resizable,
    ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY);

-- Picks column i for a sort state (click again to flip direction).
local function sort_pick(st, i)
    if (st.col == i) then
        st.asc = not st.asc;
    else
        st.col = i;
        st.asc = (st.text ~= nil and st.text[i] == true);
    end
end

--[[
* Clickable header row, drawn by hand so sorting doesn't depend on the imgui binding's
* sort-specs support. cols = list of header names, st = a pm.sorts entry.
--]]
local function draw_sort_headers(id, cols, st)
    imgui.TableNextRow(ImGuiTableRowFlags_Headers or 1);
    for i, name in ipairs(cols) do
        imgui.TableNextColumn();
        if (st.nosort ~= nil and st.nosort[i]) then
            imgui.TextColored(COL_HDR, name);
        else
            local active = (st.col == i);
            local label = name;
            if (active) then label = label .. (st.asc and ' ^' or ' v'); end
            imgui.PushStyleColor(ImGuiCol_Text, active and COL_HEAD or COL_HDR);
            if (imgui.Selectable(label .. '##' .. id .. i, active)) then sort_pick(st, i); end
            imgui.PopStyleColor();
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Click to sort. Click again to flip. Drag column borders to resize.');
            end
        end
    end
end

-- Compares two values for a sort state; tie-break on name keeps rows from jumping around.
local function sort_cmp(st, xv, yv, xn, yn)
    if (xv == yv) then return xn < yn; end
    if (st.asc) then return xv < yv; end
    return xv > yv;
end

--[[
* Installer: adds / removes one marker line at the top of an addon's main .lua file.
*
* The line is:   require('perf').auto();  followed by a perfmon:auto marker comment.
* auto() hooks ashita.events.register inside that addon, so every callback is timed.
* A one-time backup of the original file is saved next to it as <file>.perfbak.
--]]
local MARK_PAT   = '%-%-%[%[perfmon:auto%]%]';
local INSTALL_LN = "require('perf').auto(); --[[perfmon:auto]] -- added by perfmon. Undo: /perfmon remove %s";

local mgr = {
    loaded  = {},     -- sorted names of loaded addons (excluding perfmon)
    status  = {},     -- name -> 'auto' | 'manual' | 'none' | 'nofile'
    path    = {},     -- name -> resolved file path
    rows    = {},     -- Install tab display order (reused each frame)
    pending = nil,    -- { action = 'install'|'remove'|'install_all'|'remove_all', name = ... } awaiting confirm
    msg     = '',
    msg_col = nil,
};

local function file_exists(p)
    local f = io.open(p, 'rb');
    if (f ~= nil) then f:close(); return true; end
    return false;
end

local function read_file(p)
    local f = io.open(p, 'rb');
    if (f == nil) then return nil; end
    local s = f:read('*a');
    f:close();
    return s;
end

local function write_file(p, s)
    local f, err = io.open(p, 'wb');
    if (f == nil) then return false, err; end
    f:write(s);
    f:close();
    return true;
end

-- Finds an addon's main .lua file.
local function resolve_path(name)
    if (mgr.path[name] ~= nil) then
        return mgr.path[name];
    end
    local candidates = {};
    local ok, fname = pcall(function () return AddonManager:GetFileName(name); end);
    if (ok and type(fname) == 'string' and fname ~= '') then
        candidates[#candidates + 1] = fname;
        candidates[#candidates + 1] = ('%s\\addons\\%s\\%s'):fmt(AshitaCore:GetInstallPath(), name, fname);
    end
    candidates[#candidates + 1] = ('%s\\addons\\%s\\%s.lua'):fmt(AshitaCore:GetInstallPath(), name, name);

    for _, p in ipairs(candidates) do
        if (p:lower():match('%.lua$') and file_exists(p)) then
            mgr.path[name] = p;
            return p;
        end
    end
    return nil;
end

local function detect_status(name)
    local p = resolve_path(name);
    if (p == nil) then return 'nofile'; end
    local src = read_file(p);
    if (src == nil) then return 'nofile'; end
    if (src:find(MARK_PAT)) then return 'auto'; end
    if (src:find("require%s*%(?%s*['\"]perf['\"]")) then return 'manual'; end
    return 'none';
end

local function set_msg(text, col)
    mgr.msg, mgr.msg_col = text, col;
    print('[perfmon] ' .. text);
end

local function reload_addon(name)
    AshitaCore:GetChatManager():QueueCommand(-1, ('/addon reload %s'):fmt(name));
end

local function find_loaded(name)
    local want = name:lower();
    for _, n in ipairs(mgr.loaded) do
        if (n:lower() == want) then return n; end
    end
    return nil;
end

local function install(name)
    if (name:lower() == 'perfmon') then
        return set_msg('perfmon does not instrument itself.', COL_WARN);
    end
    local st = detect_status(name);
    if (st == 'auto' or st == 'manual') then
        mgr.status[name] = st;
        return set_msg(('%s is already instrumented (%s).'):fmt(name, st), COL_WARN);
    end
    if (st == 'nofile') then
        return set_msg(('Could not find the .lua file for %s.'):fmt(name), COL_BAD);
    end

    local p   = mgr.path[name];
    local src = read_file(p);

    -- Backup (only the first time, so it stays the original).
    local bak = p .. '.perfbak';
    if (not file_exists(bak)) then
        local ok, err = write_file(bak, src);
        if (not ok) then
            return set_msg(('Backup failed for %s (%s); nothing changed.'):fmt(name, tostring(err)), COL_BAD);
        end
    end

    -- Keep a UTF-8 BOM first, match the file's line endings.
    local bom = '';
    if (src:sub(1, 3) == '\239\187\191') then
        bom, src = src:sub(1, 3), src:sub(4);
    end
    local nl = src:find('\r\n', 1, true) and '\r\n' or '\n';
    local ok, err = write_file(p, bom .. INSTALL_LN:fmt(name) .. nl .. src);
    if (not ok) then
        return set_msg(('Write failed for %s: %s'):fmt(name, tostring(err)), COL_BAD);
    end

    mgr.status[name] = 'auto';
    reload_addon(name);
    set_msg(('Installed into %s and reloaded it (backup: %s).'):fmt(name, bak), COL_OK);
    return true;
end

local function remove(name)
    local st = detect_status(name);
    if (st ~= 'auto') then
        mgr.status[name] = st;
        if (st == 'manual') then
            return set_msg(('%s uses perf manually (require in its code); edit it by hand.'):fmt(name), COL_WARN);
        end
        return set_msg(('%s has no perfmon install line.'):fmt(name), COL_WARN);
    end

    local p   = mgr.path[name];
    local src = read_file(p);
    local bom = '';
    if (src:sub(1, 3) == '\239\187\191') then
        bom, src = src:sub(1, 3), src:sub(4);
    end
    local out, n = src:gsub('[^\r\n]*' .. MARK_PAT .. '[^\r\n]*\r?\n', '', 1);
    if (n == 0) then
        out, n = src:gsub('[^\r\n]*' .. MARK_PAT .. '[^\r\n]*', '', 1);
    end
    local ok, err = write_file(p, bom .. out);
    if (not ok) then
        return set_msg(('Write failed for %s: %s'):fmt(name, tostring(err)), COL_BAD);
    end

    mgr.status[name] = 'none';
    pm.addons[name] = nil;
    reload_addon(name);
    set_msg(('Removed from %s and reloaded it.'):fmt(name), COL_OK);
    return true;
end

--[[
* Loaded addon list (refreshed every 5s).
--]]
local function refresh_others(t, force)
    if (not force and t - pm.others_at < 5000000) then
        return;
    end
    pm.others_at = t;
    local loaded, others = {}, {};
    pcall(function ()
        local count = AddonManager:Count();
        for i = 0, count do
            local n = AddonManager:Get(i);
            if (n ~= nil and n ~= '' and n:lower() ~= 'perfmon') then
                loaded[#loaded + 1] = n;
                if (pm.addons[n] == nil) then
                    others[#others + 1] = n;
                end
                if (mgr.status[n] == nil) then
                    mgr.status[n] = detect_status(n);
                end
            end
        end
    end);
    table.sort(loaded);
    table.sort(others);
    mgr.loaded = loaded;
    pm.others  = others;

    -- Addon load/unload markers for the process graph (skipped on the first refresh).
    local now_set = {};
    for _, n in ipairs(loaded) do now_set[n] = true; end
    if (pm.prev_loaded ~= nil) then
        for _, n in ipairs(loaded) do
            if (not pm.prev_loaded[n]) then add_event('load', n); end
        end
        for n in pairs(pm.prev_loaded) do
            if (not now_set[n]) then add_event('unload', n); end
        end
    end
    pm.prev_loaded = now_set;
end

-- Names of loaded addons a batch action would touch (install: 'none', remove: 'auto').
local function batch_targets(action)
    local want = (action == 'install') and 'none' or 'auto';
    local out = {};
    for _, n in ipairs(mgr.loaded) do
        if (mgr.status[n] == want) then out[#out + 1] = n; end
    end
    return out;
end

-- Install into / remove from every eligible loaded addon. Manual and file-not-found addons are skipped.
local function batch_apply(action)
    mgr.status, mgr.path = {}, {};
    refresh_others(now_us(), true);
    local targets = batch_targets(action);
    if (#targets == 0) then
        return set_msg(action == 'install' and 'Nothing to install: every loaded addon is already instrumented or has no file.'
            or 'Nothing to remove: perfmon is not installed in any loaded addon.', COL_WARN);
    end
    local ok_n, failed = 0, {};
    for _, n in ipairs(targets) do
        local ok = (action == 'install') and install(n) or remove(n);
        if (ok) then ok_n = ok_n + 1; else failed[#failed + 1] = n; end
    end
    local verb = (action == 'install') and 'Installed into' or 'Removed from';
    if (#failed == 0) then
        set_msg(('%s %d addon(s) and reloaded them.'):fmt(verb, ok_n), COL_OK);
    else
        set_msg(('%s %d addon(s); failed: %s'):fmt(verb, ok_n, table.concat(failed, ', ')), COL_WARN);
    end
end

local STATUS_TXT = {
    auto   = 'installed (auto)',
    manual = 'manual (in code)',
    none   = 'not installed',
    nofile = 'file not found',
};

local INST_COLS = { 'Addon', 'Status', 'Reporting', 'Action' };
local INST_W    = { 1.8, 1.8, 1.0, 1.0 };

local function cmp_inst(x, y)
    local st = pm.sorts.inst;
    local xv, yv;
    if (st.col == 2) then
        xv, yv = STATUS_TXT[mgr.status[x] or 'none'] or '', STATUS_TXT[mgr.status[y] or 'none'] or '';
    elseif (st.col == 3) then
        xv, yv = (pm.addons[x] ~= nil) and 1 or 0, (pm.addons[y] ~= nil) and 1 or 0;
    else
        xv, yv = x:lower(), y:lower();
    end
    return sort_cmp(st, xv, yv, x, y);
end

local function draw_installer()
    imgui.TextWrapped('Install adds one line to the top of the addon\'s main .lua file and reloads it. '
        .. 'Every event callback in that addon is then timed. A backup of the original is saved as <file>.perfbak.');

    if (mgr.msg ~= '') then
        imgui.TextColored(mgr.msg_col or COL_HEAD, mgr.msg);
    end

    if (mgr.pending ~= nil) then
        local pd = mgr.pending;
        if (pd.action == 'install_all' or pd.action == 'remove_all') then
            local list = batch_targets(pd.action == 'install_all' and 'install' or 'remove');
            imgui.TextColored(COL_WARN, ('%s %d addon(s)? This edits and reloads each one:'):fmt(
                pd.action == 'install_all' and 'Install into' or 'Remove from', #list));
            imgui.TextWrapped(table.concat(list, ', '));
        else
            imgui.TextColored(COL_WARN, ('%s %s? This edits %s'):fmt(pd.action == 'install' and 'Install into' or 'Remove from', pd.name, mgr.path[pd.name] or '?'));
        end
        if (imgui.Button('Confirm')) then
            mgr.pending = nil;
            if (pd.action == 'install') then install(pd.name);
            elseif (pd.action == 'remove') then remove(pd.name);
            elseif (pd.action == 'install_all') then batch_apply('install');
            elseif (pd.action == 'remove_all') then batch_apply('remove'); end
        end
        imgui.SameLine();
        if (imgui.Button('Cancel')) then mgr.pending = nil; end
        imgui.Separator();
    end

    if (imgui.SmallButton('Refresh list')) then
        mgr.status, mgr.path = {}, {};
        refresh_others(now_us(), true);
    end
    local n_inst, n_rem = #batch_targets('install'), #batch_targets('remove');
    imgui.SameLine();
    if (n_inst > 0) then
        if (imgui.SmallButton(('Install all (%d)##pm_ia'):fmt(n_inst))) then
            mgr.pending = { action = 'install_all' };
        end
    else
        imgui.TextDisabled('Install all (0)');
    end
    imgui.SameLine();
    if (n_rem > 0) then
        if (imgui.SmallButton(('Remove all (%d)##pm_ra'):fmt(n_rem))) then
            mgr.pending = { action = 'remove_all' };
        end
    else
        imgui.TextDisabled('Remove all (0)');
    end

    -- Display order (mgr.loaded itself stays A-Z).
    local rows = mgr.rows;
    for i = #rows, 1, -1 do rows[i] = nil; end
    for i, n in ipairs(mgr.loaded) do rows[i] = n; end
    table.sort(rows, cmp_inst);

    if (imgui.BeginTable('##pm_inst', 4, TABLE_FLAGS, { 0, -1 })) then
        imgui.TableSetupScrollFreeze(0, 1);
        for i, name in ipairs(INST_COLS) do
            imgui.TableSetupColumn(name, ImGuiTableColumnFlags_WidthStretch, INST_W[i]);
        end
        draw_sort_headers('pm_ih', INST_COLS, pm.sorts.inst);

        for _, n in ipairs(rows) do
            local st = mgr.status[n] or 'none';
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(n);
            imgui.TableNextColumn();
            local col = (st == 'auto' or st == 'manual') and COL_OK or (st == 'nofile' and COL_BAD or COL_STALE);
            imgui.TextColored(col, STATUS_TXT[st] or st);
            imgui.TableNextColumn();
            if (pm.addons[n] ~= nil) then imgui.TextColored(COL_OK, 'yes'); else imgui.TextDisabled('no'); end
            imgui.TableNextColumn();
            if (st == 'none') then
                if (imgui.SmallButton('Install##' .. n)) then
                    resolve_path(n);
                    mgr.pending = { action = 'install', name = n };
                end
            elseif (st == 'auto') then
                if (imgui.SmallButton('Remove##' .. n)) then
                    mgr.pending = { action = 'remove', name = n };
                end
            end
        end
        imgui.EndTable();
    end
end

--[[
* UI
--]]
local function heat_us(us)
    if (us >= 2000) then return COL_BAD; end
    if (us >= 500) then return COL_WARN; end
    return COL_OK;
end

local function heat_mss(ms)  -- ms of main-thread time per second
    if (ms >= 20) then return COL_BAD; end
    if (ms >= 5) then return COL_WARN; end
    return COL_OK;
end

local sorted = {};
local NO_SECTIONS = {};   -- iterated when an addon is collapsed (avoids a new table per frame)

--[[
* Stats table sorting. Click a header to sort by it; click again to flip direction.
* Addons are sorted by their totals, and each addon's sections by the same column.
--]]
local STAT_COLS = { 'Addon / section', 'Calls/s', 'Avg us', 'Max us', 'Peak us', 'ms/s', 'Mem KB' };
local STAT_W    = { 2.6, 1.0, 1.0, 1.0, 1.0, 1.0, 1.6 };   -- starting widths (relative)

-- Sort value of a section for a column. (Window scaling is per addon, so raw counts sort the same.)
local function sec_key(s, col)
    if (col == 2) then return s.n; end
    if (col == 3) then return (s.n > 0) and (s.tot / s.n) or 0; end
    if (col == 4) then return s.max; end
    if (col == 5) then return s.peak; end
    return s.tot;   -- ms/s, and Mem (sections have no memory of their own)
end

-- Sort value of an addon row: totals across its sections, per second.
local function addon_key(a, col)
    if (col == 7) then return a.mem or 0; end
    if (col == 6) then return a.total_us / a.win_ms; end
    local n, mx, pk = 0, 0, 0;
    for _, s in pairs(a.sections) do
        n = n + s.n;
        if (s.max > mx) then mx = s.max; end
        if (s.peak > pk) then pk = s.peak; end
    end
    if (col == 2) then return n / a.win_ms; end
    if (col == 3) then return (n > 0) and (a.total_us / n) or 0; end
    if (col == 4) then return mx; end
    return pk;
end

local function cmp_addons(x, y)
    local st = pm.sorts.stats;
    if (st.col == 1) then
        return sort_cmp(st, x.name:lower(), y.name:lower(), x.name, y.name);
    end
    return sort_cmp(st, addon_key(x, st.col), addon_key(y, st.col), x.name, y.name);
end

local sec_cmp_addon = nil;   -- addon whose sections are being sorted (avoids a closure per frame)
local function cmp_sections(x, y)
    local st = pm.sorts.stats;
    if (st.col == 1) then
        return sort_cmp(st, x:lower(), y:lower(), x, y);
    end
    local secs = sec_cmp_addon.sections;
    return sort_cmp(st, sec_key(secs[x], st.col), sec_key(secs[y], st.col), x, y);
end

-- Returns the addon's section names in display order, reusing a per-addon array.
local function sorted_sections(a)
    local out = a.order_sorted;
    if (out == nil) then out = {}; a.order_sorted = out; end
    for i = #out, 1, -1 do out[i] = nil; end
    for i, sname in ipairs(a.order) do out[i] = sname; end
    sec_cmp_addon = a;
    table.sort(out, cmp_sections);
    sec_cmp_addon = nil;
    return out;
end

local function show_all()
    pm.collapsed = {};
end

local function collapse_all()
    for n in pairs(pm.addons) do pm.collapsed[n] = true; end
end

-- Right-click menu for the Stats table.
local function draw_stat_menu()
    if (not imgui.BeginPopupContextWindow('##pm_stat_ctx', ImGuiPopupFlags_MouseButtonRight or 1)) then
        return;
    end
    if (imgui.MenuItem('Show all')) then show_all(); end
    if (imgui.MenuItem('Collapse all')) then collapse_all(); end
    imgui.Separator();
    if (imgui.BeginMenu('Sort by')) then
        local st = pm.sorts.stats;
        for i, name in ipairs(STAT_COLS) do
            if (imgui.MenuItem(name, nil, st.col == i)) then sort_pick(st, i); end
        end
        imgui.Separator();
        if (imgui.MenuItem('Ascending', nil, st.asc)) then st.asc = not st.asc; end
        if (imgui.MenuItem('Default (ms/s, highest first)')) then st.col, st.asc = st.def_col, st.def_asc; end
        imgui.EndMenu();
    end
    imgui.EndPopup();
end

local function addon_status(a)
    if (a.base == nil) then
        return 'waiting (or old perf.lua)', COL_STALE;
    end
    local n = a.trend and a.trend.n or #a.base_hist;
    if (n < LEAK_MIN_N) then
        return ('collecting %d/%d'):fmt(n, LEAK_MIN_N), COL_STALE;
    end
    if (a.over_cap) then return 'OVER CAP', COL_BAD; end
    if (a.leak) then return 'LEAK?', COL_BAD; end
    if (a.expected) then return 'expected', COL_HEAD; end
    if (a.growing) then return 'growing', COL_WARN; end
    return 'stable', COL_OK;
end

local MEM_COLS = { 'Addon', 'Now KB', 'After GC KB', 'KB/min', 'Fit', 'Status', 'Objects', 'After-GC history' };
local MEM_W    = { 1.6, 1.0, 1.2, 1.0, 0.8, 1.5, 1.4, 2.0 };

-- Status column sorts by severity (worst = biggest), not alphabetically.
local function mem_status_rank(a)
    if (a.base == nil) then return 0; end
    local n = a.trend and a.trend.n or #a.base_hist;
    if (n < LEAK_MIN_N) then return 1; end
    if (a.over_cap) then return 6; end
    if (a.leak) then return 5; end
    if (a.growing) then return 4; end
    if (a.expected) then return 3; end
    return 2;
end

local function mem_key(a, col)
    if (col == 2) then return a.mem or 0; end
    if (col == 3) then return a.base or -math.huge; end
    if (col == 4) then return a.trend and a.trend.slope or -math.huge; end
    if (col == 5) then return a.trend and a.trend.r2 or -math.huge; end
    if (col == 7) then
        if (a.obj == nil) then return -math.huge; end
        return (a.obj_rising and 1000000 or 0) + a.obj.fonts + a.obj.prims + a.obj.com;
    end
    return mem_status_rank(a);
end

local function cmp_mem(x, y)
    local st = pm.sorts.mem;
    if (st.col == 1) then
        return sort_cmp(st, x.name:lower(), y.name:lower(), x.name, y.name);
    end
    return sort_cmp(st, mem_key(x, st.col), mem_key(y, st.col), x.name, y.name);
end

--[[
* Process graph markers
--]]
local EVENT_COL = {
    zone   = { 0.4, 0.85, 1.0, 0.9 },
    load   = { 0.5, 1.0, 0.5, 0.9 },
    unload = { 1.0, 0.65, 0.3, 0.9 },
    mark   = { 1.0, 1.0, 1.0, 0.9 },
};
local EVENT_TAG = { zone = 'zone', load = 'load', unload = 'unload', mark = 'mark' };

-- Ashita's imgui returns ImVec2 either as two numbers or as a table, depending on the build.
local function xy(a, b)
    if (type(a) == 'number') then return a, b or 0; end
    if (a == nil) then return 0, 0; end
    if (type(a) == 'table' and a[1] ~= nil) then return a[1], a[2] or 0; end
    return a.x or 0, a.y or 0;   -- table or userdata ImVec2
end

-- Process MB just before t, and the first sample at least EVENT_AFTER_US after it (nil if not yet).
local function mem_around(hist, t)
    local before, after;
    for i = 1, #hist do
        local h = hist[i];
        if (h.t <= t) then
            before = h.v;
        elseif (after == nil and (h.t - t) >= EVENT_AFTER_US) then
            after = h.v;
            break;
        end
    end
    return before, after;
end

local function ago(t)
    local s = (now_us() - t) / 1000000;
    if (s < 60) then return ('%ds ago'):fmt(s); end
    return ('%.0fm ago'):fmt(s / 60);
end

local function event_text(p, e)
    local b, a = mem_around(p.hist, e.t);
    local d = (b ~= nil and a ~= nil) and ('  %+.0f MB'):fmt(a - b) or '  (measuring...)';
    return ('%s %s, %s%s'):fmt(EVENT_TAG[e.kind] or e.kind, e.label, ago(e.t), d);
end

-- Vertical lines over the plot just drawn, one per event inside the plotted time span.
draw_event_markers = function (p)
    local hist = p.hist;
    if (#hist < 2 or #pm.events == 0) then return; end
    local t0, t1 = hist[1].t, hist[#hist].t;
    if (t1 <= t0) then return; end

    local ok = pcall(function ()
        local x0, y0 = xy(imgui.GetItemRectMin());
        local x1, y1 = xy(imgui.GetItemRectMax());
        local px, py = 3, 3;
        pcall(function () px, py = xy(imgui.GetStyle().FramePadding); end);
        x0, x1, y0, y1 = x0 + px, x1 - px, y0 + py, y1 - py;
        local dl = imgui.GetWindowDrawList();
        local hovered = imgui.IsItemHovered();
        local mx = hovered and xy(imgui.GetMousePos()) or nil;
        local tips = {};

        for _, e in ipairs(pm.events) do
            if (e.t >= t0 and e.t <= t1) then
                local x = x0 + (x1 - x0) * ((e.t - t0) / (t1 - t0));
                dl:AddLine({ x, y0 }, { x, y1 }, imgui.GetColorU32(EVENT_COL[e.kind] or EVENT_COL.mark), 1.0);
                if (mx ~= nil and math.abs(mx - x) <= 4) then
                    tips[#tips + 1] = event_text(p, e);
                end
            end
        end
        if (#tips > 0) then
            imgui.SetTooltip(table.concat(tips, '\n'));
        end
    end);
    if (not ok) then
        pm.markers_failed = true;
    end
end

-- The last few events with the memory jump each one caused, newest first.
draw_event_list = function (p)
    if (#pm.events == 0) then
        imgui.TextDisabled('Markers: blue = zone, green = addon load, orange = addon unload, white = /perfmon mark. None yet.');
        return;
    end
    imgui.TextDisabled('Markers: blue = zone, green = load, orange = unload, white = /perfmon mark. Hover the graph for details.');
    local shown = 0;
    for i = #pm.events, 1, -1 do
        local e = pm.events[i];
        imgui.TextColored(EVENT_COL[e.kind] or EVENT_COL.mark, '  ' .. event_text(p, e));
        shown = shown + 1;
        if (shown >= 4) then break; end
    end
    if (pm.markers_failed) then
        imgui.TextDisabled('  (graph markers could not be drawn on this imgui build; the list above still works)');
    end
end

--[[
* Objects column, address space panel, snapshot / diff
--]]
obj_risers = function ()
    local r = {};
    for _, a in pairs(pm.addons) do
        if (a.obj_rising) then r[#r + 1] = a.name; end
    end
    table.sort(r);
    return r;
end

draw_obj_cell = function (a)
    local o = a.obj;
    if (o == nil) then
        imgui.TextDisabled('-');
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('No object counts: this addon uses an older perf.lua (update addons/libs/perf.lua and reload it).');
        end
        return;
    end
    local live = o.fonts + o.prims + o.com;
    local f = a.obj_first or o;
    local d = live - (f.fonts + f.prims + f.com);
    local col = a.obj_rising and COL_BAD or ((d >= OBJ_RISE) and COL_WARN or nil);
    local txt = (d ~= 0) and ('%d (%+d)'):fmt(live, d) or ('%d'):fmt(live);
    if (col ~= nil) then imgui.TextColored(col, txt); elseif (live == 0) then imgui.TextDisabled(txt); else imgui.Text(txt); end
    if (imgui.IsItemHovered()) then
        local tr = a.obj_trend;
        imgui.SetTooltip(('Live: %d fonts, %d primitives, %d COM/textures\nCreated since load: %d / %d / %d\nChange since first seen: %+d%s%s'):fmt(
            o.fonts, o.prims, o.com, o.fonts_made, o.prims_made, o.com_made, d,
            tr and ('\nTrend %+.1f objects/min (fit %.2f)'):fmt(tr.slope, tr.r2) or '',
            a.obj_rising and '\nRISING STEADILY: objects are created and never destroyed.' or ''));
    end
end

local function fmt_dur(mins)
    if (mins >= 120) then return ('%.0fh %02dm'):fmt(math.floor(mins / 60), math.floor(mins % 60)); end
    if (mins >= 60) then return ('%dh %02dm'):fmt(math.floor(mins / 60), math.floor(mins % 60)); end
    return ('%.0f min'):fmt(mins);
end

-- Minutes until free address space reaches VM_MARGIN_MB at the current trend (nil = not shrinking).
local function vm_eta()
    local v = pm.vm;
    local tr = v.free_trend;
    if (v.last == nil or tr == nil or tr.n < VM_MIN_N or tr.slope >= -0.1 or tr.r2 < 0.5) then
        return nil;
    end
    local left = v.last.free_total / 1024 - VM_MARGIN_MB;
    if (left <= 0) then return 0; end
    return left / -tr.slope;
end

draw_native = function ()
    local v = pm.vm;
    local r = v.last;
    if (r == nil) then
        imgui.TextDisabled('Address space: first scan in a few seconds...');
        return;
    end
    local used = (r.private + r.mapped + r.image + r.reserved) / 1024;
    local total = used + r.free_total / 1024;
    local f = v.first;
    local col = COL_HEAD;
    if (r.free_largest / 1024 < 64 or r.free_total / 1024 < 256) then col = COL_BAD;
    elseif (r.free_largest / 1024 < 200 or r.free_total / 1024 < 512) then col = COL_WARN; end
    imgui.TextColored(col, ('Address space: %.0f of %.0f MB used, %.0f MB free (%+.0f), largest free gap %.0f MB (%+.0f)'):fmt(
        used, total, r.free_total / 1024, (r.free_total - f.free_total) / 1024, r.free_largest / 1024, (r.free_largest - f.free_largest) / 1024));
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(('FFXI is a 32-bit program: it crashes when no free gap is big enough for an allocation,\n'
            .. 'often before total memory looks full. Zoning needs the biggest gaps.\n\n'
            .. 'private %.0f MB (%+.0f)   big private %.0f MB (%+.0f)\nmapped %.0f MB (%+.0f)   image %.0f MB (%+.0f)   reserved %.0f MB (%+.0f)\n'
            .. '%d regions, scan %.1f ms, every %ds.  Platform: %s'):fmt(
            r.private / 1024, (r.private - f.private) / 1024, r.private_big / 1024, (r.private_big - f.private_big) / 1024,
            r.mapped / 1024, (r.mapped - f.mapped) / 1024, r.image / 1024, (r.image - f.image) / 1024,
            r.reserved / 1024, (r.reserved - f.reserved) / 1024, r.regions, v.scan_us / 1000, VM_SAMPLE_US / 1000000, platform_str));
    end

    local tr = v.free_trend;
    local eta = vm_eta();
    if (eta ~= nil) then
        local ecol = (eta < 60) and COL_BAD or ((eta < 240) and COL_WARN or COL_HEAD);
        imgui.TextColored(ecol, ('  Free space shrinking %.1f MB/min (fit %.2f): runs out in about %s at this rate.'):fmt(-tr.slope, tr.r2, fmt_dur(eta)));
    elseif (tr ~= nil and tr.n < VM_MIN_N) then
        imgui.TextDisabled(('  Time-to-run-out estimate after %d scans (%d so far).'):fmt(VM_MIN_N, tr.n));
    else
        imgui.TextDisabled('  Free address space is not shrinking steadily. No crash in sight from memory.');
    end
    if (r.free_largest / 1024 < 64) then
        imgui.TextColored(COL_BAD, '  Fragmented: the biggest free gap is under 64 MB. Large allocations (zoning) may fail soon.');
    end

    local h, hf = v.handles, v.first_handles;
    if (h ~= nil) then
        local function c(k) return h[k] and ('%d (%+d)'):fmt(h[k], h[k] - (hf[k] or h[k])) or '-'; end
        local htr = v.h_trend;
        local hcol = (htr ~= nil and htr.n >= VM_MIN_N and htr.slope >= 5 and htr.r2 >= LEAK_R2) and COL_WARN or COL_HDR;
        imgui.TextColored(hcol, ('Handles %s   GDI %s   USER %s%s'):fmt(c('handles'), c('gdi'), c('user'),
            (htr ~= nil and htr.n >= VM_MIN_N) and ('   handles %+.1f/min'):fmt(htr.slope) or ''));
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Changes are since perfmon loaded. Handles that climb steadily point at files, events,\nthreads or sockets that are opened and never closed.');
        end
    end
end

--[[
* Snapshot / diff. Both ask every instrumented addon to collect garbage first ('/perf gc'),
* force a fresh process + address-space sample, then capture 3 s later.
--]]
local CAPTURE_DELAY_US = 3 * 1000000;

local function copy(t)
    if (t == nil) then return nil; end
    local r = {};
    for k, v in pairs(t) do r[k] = v; end
    return r;
end

request_capture = function (kind)
    if (pm.capture ~= nil) then
        print('[perfmon] a capture is already running.');
        return;
    end
    if (kind == 'diff' and pm.snap == nil) then
        print('[perfmon] no snapshot yet. Use /perfmon snap first.');
        return;
    end
    AshitaCore:GetChatManager():QueueCommand(-1, '/perf gc');
    pm.vm.at, pm.proc.at = 0, 0;
    pm.capture = { kind = kind, at = now_us() + CAPTURE_DELAY_US };
    print(('[perfmon] %s: collecting garbage in instrumented addons, capturing in 3 s...'):fmt(kind == 'snap' and 'snapshot' or 'diff'));
end

local function capture_state()
    local s = { t = now_us(), clock = os.date('%H:%M:%S'), proc = pm.proc.kb, vm = copy(pm.vm.last), h = copy(pm.vm.handles), addons = {} };
    for n, a in pairs(pm.addons) do
        s.addons[n] = { mem = a.mem, base = a.base, obj = copy(a.obj) };
    end
    return s;
end

local function build_diff(a, b)
    local lines = {};
    local function add(col, txt) lines[#lines + 1] = { col = col, txt = txt }; end
    local mins = (b.t - a.t) / 60000000;
    add(COL_HEAD, ('Since snapshot at %s (%s ago):'):fmt(a.clock, fmt_dur(mins)));

    local function mbd(x, y) return (x ~= nil and y ~= nil) and ((y - x) / 1024) or nil; end
    local pd = mbd(a.proc, b.proc);
    if (pd ~= nil) then
        add(math.abs(pd) >= 20 and (pd > 0 and COL_WARN or COL_OK) or COL_HDR,
            ('  Process private %.0f -> %.0f MB (%+.0f MB)'):fmt(a.proc / 1024, b.proc / 1024, pd));
    end
    if (a.vm ~= nil and b.vm ~= nil) then
        local parts = {};
        for _, k in ipairs({ 'private', 'mapped', 'image', 'reserved' }) do
            local d = (b.vm[k] - a.vm[k]) / 1024;
            if (math.abs(d) >= 1) then parts[#parts + 1] = ('%s %+.0f'):fmt(k, d); end
        end
        add(COL_HDR, ('  Native MB: %s'):fmt(#parts > 0 and table.concat(parts, ', ') or 'no change'));
        local fl = (b.vm.free_largest - a.vm.free_largest) / 1024;
        add(fl <= -20 and COL_WARN or COL_HDR, ('  Address space free %+.0f MB, largest gap %.0f -> %.0f MB'):fmt(
            (b.vm.free_total - a.vm.free_total) / 1024, a.vm.free_largest / 1024, b.vm.free_largest / 1024));
    end
    if (a.h ~= nil and b.h ~= nil) then
        local parts = {};
        for _, k in ipairs({ 'handles', 'gdi', 'user' }) do
            if (a.h[k] ~= nil and b.h[k] ~= nil) then parts[#parts + 1] = ('%s %+d'):fmt(k, b.h[k] - a.h[k]); end
        end
        add(COL_HDR, '  ' .. table.concat(parts, ', '));
    end

    -- Per addon: after-GC memory and live objects, biggest changes first.
    local rows = {};
    local names = {};
    for n in pairs(a.addons) do names[n] = true; end
    for n in pairs(b.addons) do names[n] = true; end
    for n in pairs(names) do
        local x, y = a.addons[n], b.addons[n];
        if (x == nil) then
            rows[#rows + 1] = { score = 1e9, col = COL_HEAD, txt = ('  %s: loaded since the snapshot'):fmt(n) };
        elseif (y == nil) then
            rows[#rows + 1] = { score = 1e9, col = COL_HEAD, txt = ('  %s: gone since the snapshot'):fmt(n) };
        else
            local kb = (x.base ~= nil and y.base ~= nil) and (y.base - x.base) or nil;
            local od, parts = 0, {};
            if (x.obj ~= nil and y.obj ~= nil) then
                for _, k in ipairs({ { 'fonts', 'fonts' }, { 'prims', 'primitives' }, { 'com', 'textures' } }) do
                    local d = y.obj[k[1]] - x.obj[k[1]];
                    if (d ~= 0) then parts[#parts + 1] = ('%+d %s'):fmt(d, k[2]); od = od + d; end
                end
            end
            local score = math.abs(kb or 0) + math.abs(od) * 200;
            if (score > 0) then
                local col = (od > 0 or (kb or 0) >= 200) and COL_WARN or COL_HDR;
                rows[#rows + 1] = { score = score, col = col, txt = ('  %s: after-GC %s%s'):fmt(n,
                    kb and ('%+d KB'):fmt(kb) or '?', #parts > 0 and ('; ' .. table.concat(parts, ', ')) or '') };
            end
        end
    end
    table.sort(rows, function (p1, p2) return p1.score > p2.score; end);
    if (#rows == 0) then
        add(COL_OK, '  No instrumented addon changed its Lua memory or object counts.');
    end
    for i, r in ipairs(rows) do
        if (i > 15) then add(COL_STALE, ('  ...and %d more'):fmt(#rows - 15)); break; end
        add(r.col, r.txt);
    end
    return lines;
end

capture_tick = function (t)
    local c = pm.capture;
    if (c == nil or t < c.at) then
        return;
    end
    pm.capture = nil;
    local s = capture_state();
    if (c.kind == 'snap') then
        pm.snap, pm.diff = s, nil;
        print(('[perfmon] snapshot taken at %s (%.0f MB private). Do the thing you want to test, then /perfmon diff.'):fmt(
            s.clock, (s.proc or 0) / 1024));
        add_event('mark', 'snapshot');
    else
        pm.diff = build_diff(pm.snap, s);
        for _, l in ipairs(pm.diff) do
            print('[perfmon] ' .. l.txt);
        end
        add_event('mark', 'diff');
    end
end

draw_snapshot = function ()
    imgui.Spacing();
    if (pm.capture ~= nil) then
        imgui.TextDisabled('Capturing...');
    else
        if (imgui.SmallButton('Snapshot')) then request_capture('snap'); end
        imgui.SameLine();
        if (pm.snap ~= nil) then
            if (imgui.SmallButton('Diff vs snapshot')) then request_capture('diff'); end
            imgui.SameLine();
            imgui.TextDisabled(('snapshot %s, %s ago'):fmt(pm.snap.clock, fmt_dur((now_us() - pm.snap.t) / 60000000)));
        else
            imgui.TextDisabled('Take a snapshot, do something (zone 5 times, open a menu...), then Diff.');
        end
    end
    if (pm.diff ~= nil) then
        if (imgui.CollapsingHeader('Last diff', ImGuiTreeNodeFlags_DefaultOpen)) then
            for _, l in ipairs(pm.diff) do
                imgui.TextColored(l.col, l.txt);
            end
            if (imgui.SmallButton('Clear diff')) then pm.diff = nil; end
        end
    end
end

local function draw_memory()
    local p = pm.proc;
    local any_leak = false;
    for _, a in pairs(pm.addons) do
        if (a.leak) then any_leak = true; end
    end

    -- Game process
    if (p.kb == nil) then
        imgui.TextDisabled('Game process memory: not available on this system.');
    else
        local tr = p.trend;
        local col = p.rising and COL_BAD or COL_HEAD;
        if (tr ~= nil) then
            imgui.TextColored(col, ('Game process: %.0f MB private (peak %.0f MB)   trend %+.2f MB/min  fit %.2f  over %.0f min'):fmt(
                p.kb / 1024, p.peak / 1024, tr.slope, tr.r2, tr.mins));
        else
            imgui.TextColored(col, ('Game process: %.0f MB private (peak %.0f MB)   collecting...'):fmt(p.kb / 1024, p.peak / 1024));
        end
        if (#p.plot >= 2) then
            imgui.PlotLines('##pm_proc', p.plot, #p.plot, 0, 'process MB (every 10s)', p.lo, p.hi, { -1, 50 });
            draw_event_markers(p);
        end
        if (p.rising and not any_leak and #obj_risers() > 0) then
            imgui.PushStyleColor(ImGuiCol_Text, COL_BAD);
            imgui.TextWrapped(('Process memory is rising and these addons keep creating objects they never destroy: %s. That is the likely leak.'):fmt(table.concat(obj_risers(), ', ')));
            imgui.PopStyleColor();
        elseif (p.rising and not any_leak) then
            imgui.PushStyleColor(ImGuiCol_Text, COL_WARN);
            imgui.TextWrapped('Process memory is rising but no addon\'s Lua memory is. Likely native: FFI allocations, textures/fonts not released, or the game itself (zoning also loads data). Check the markers below: a jump right after a zone or an addon load points at the cause.');
            imgui.PopStyleColor();
        end
        draw_event_list(p);
    end

    imgui.Separator();
    draw_native();
    draw_snapshot();
    imgui.Separator();

    -- Per-addon Lua baselines
    for i = #sorted, 1, -1 do sorted[i] = nil; end
    for _, a in pairs(pm.addons) do sorted[#sorted + 1] = a; end
    table.sort(sorted, cmp_mem);

    if (imgui.BeginTable('##pm_mem', 8, TABLE_FLAGS, { 0, -60 })) then
        imgui.TableSetupScrollFreeze(0, 1);
        for i, name in ipairs(MEM_COLS) do
            imgui.TableSetupColumn(name, ImGuiTableColumnFlags_WidthStretch, MEM_W[i]);
        end
        draw_sort_headers('pm_mh', MEM_COLS, pm.sorts.mem);

        for _, a in ipairs(sorted) do
            local st, scol = addon_status(a);
            local tr = a.trend;
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(a.name);
            imgui.TableNextColumn(); imgui.Text(('%d'):fmt(a.mem));
            imgui.TableNextColumn(); imgui.Text(a.base and ('%d'):fmt(a.base) or '-');
            imgui.TableNextColumn();
            if (tr ~= nil) then imgui.TextColored(scol, ('%+.1f'):fmt(tr.slope)); else imgui.TextDisabled('-'); end
            imgui.TableNextColumn();
            if (tr ~= nil) then imgui.Text(('%.2f'):fmt(tr.r2)); else imgui.TextDisabled('-'); end
            imgui.TableNextColumn(); imgui.TextColored(scol, st);
            if (a.expect_note ~= nil and imgui.IsItemHovered()) then
                imgui.SetTooltip(('Declared expected growth: %s%s'):fmt(a.expect_note,
                    (a.expect_max or 0) > 0 and ('\nFlagged if after-GC memory passes %d KB.'):fmt(a.expect_max) or ''));
            end
            imgui.TableNextColumn(); draw_obj_cell(a);
            imgui.TableNextColumn();
            if (#a.base_plot >= 2) then
                imgui.PlotLines('##pm_b_' .. a.name, a.base_plot, #a.base_plot, 0, '', a.lo, a.hi, { -1, 18 });
            end
        end
        imgui.EndTable();
    end
    imgui.PushStyleColor(ImGuiCol_Text, COL_STALE);
    imgui.TextWrapped(('Flags an addon when its after-GC memory grows >= %d KB/min (and +%d KB) steadily (fit >= %.2f) over %d min. Fit near 1 = straight-line growth.'):fmt(
        LEAK_KB_MIN, LEAK_MIN_RISE, LEAK_R2, LEAK_WINDOW_US / 60000000));
    imgui.PopStyleColor();
end

local function draw()
    if (not pm.show[1]) then
        return;
    end

    imgui.SetNextWindowSize({ 640, 420 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('perfmon', pm.show)) and (imgui.BeginTabBar('##pm_tabs')) then
      if (imgui.BeginTabItem('Stats')) then
        -- Frame summary
        imgui.Text(('FPS %.1f   frame avg %.2f ms   worst %.1f ms   hitches(>%dms) %d/s (%d total)'):fmt(
            pm.fps, pm.avg_ms, pm.worst_ms, HITCH_MS, pm.last_hitches or 0, pm.hitch_total));
        if (pm.proc.kb ~= nil) then
            local ptr = pm.proc.trend;
            imgui.TextColored(pm.proc.rising and COL_BAD or COL_HEAD, ('Game memory %.0f MB%s'):fmt(pm.proc.kb / 1024,
                (ptr ~= nil and ptr.n >= PROC_MIN_N) and ('  (%+.2f MB/min)'):fmt(ptr.slope) or ''));
            local leaks = 0;
            for _, a in pairs(pm.addons) do if (a.leak) then leaks = leaks + 1; end end
            if (leaks > 0) then
                imgui.SameLine();
                imgui.TextColored(COL_BAD, ('  %d addon(s) flagged for a possible leak - see Memory tab'):fmt(leaks));
            end
        end

        -- Copy ring into a linear, oldest-first array for the plot (no allocation).
        local idx = pm.ring_head;
        local top = 0;
        for i = 1, FRAME_RING do
            idx = (idx % FRAME_RING) + 1;
            local v = pm.ring[idx];
            pm.plot[i] = v;
            if (v > top) then top = v; end
        end
        imgui.PlotLines('##frames', pm.plot, FRAME_RING, 0, ('frame ms (last %d)'):fmt(FRAME_RING), 0, math.max(40, top), { -1, 60 });

        -- Controls
        local log = { pm.log_on };
        if (imgui.Checkbox('Log CSV', log)) then set_logging(log[1]); end
        imgui.SameLine();
        if (pm.log_path ~= nil) then
            if (pm.clear_confirm) then
                imgui.TextColored(COL_WARN, 'Empty CSV?');
                imgui.SameLine();
                if (imgui.SmallButton('Yes##pm_clr')) then clear_log(); pm.clear_confirm = false; end
                imgui.SameLine();
                if (imgui.SmallButton('No##pm_clr')) then pm.clear_confirm = false; end
            elseif (imgui.SmallButton('Empty CSV')) then
                pm.clear_confirm = true;
            end
            imgui.SameLine();
        end
        if (imgui.SmallButton('Reset peaks')) then
            for _, a in pairs(pm.addons) do
                a.mem_peak = a.mem;
                for _, s in pairs(a.sections) do s.peak = s.max; end
            end
            pm.hitch_total = 0;
            pm.proc.peak = pm.proc.kb or 0;
        end
        imgui.SameLine();
        if (imgui.SmallButton('Show all')) then show_all(); end
        imgui.SameLine();
        if (imgui.SmallButton('Collapse all')) then collapse_all(); end
        imgui.SameLine();
        imgui.TextDisabled(('perfmon self: %.3f ms/s'):fmt(pm.self_last / 1000));

        imgui.Separator();

        -- Sort addons by the chosen column (default: main-thread time used).
        for i = #sorted, 1, -1 do sorted[i] = nil; end
        for _, a in pairs(pm.addons) do sorted[#sorted + 1] = a; end
        table.sort(sorted, cmp_addons);

        local t = now_us();
        if (imgui.BeginTable('##pm_tbl', 7, TABLE_FLAGS, { 0, -60 })) then
            imgui.TableSetupScrollFreeze(0, 1);
            for i, name in ipairs(STAT_COLS) do
                imgui.TableSetupColumn(name, ImGuiTableColumnFlags_WidthStretch, STAT_W[i]);
            end
            draw_sort_headers('pm_sh', STAT_COLS, pm.sorts.stats);

            for _, a in ipairs(sorted) do
                local stale = (t - a.seen) > STALE_US;
                local scale = 1000 / a.win_ms;
                local mss = a.total_us / 1000 * scale;

                -- Addon row: click the name (or arrow) to show/hide its sections.
                -- '###' keeps the node's ID fixed while the label text changes.
                local hidden = pm.collapsed[a.name] == true;
                local label = a.name;
                if (stale) then label = label .. ' (no report)'; end
                if (hidden) then label = ('%s  [%d]'):fmt(label, #a.order); end
                imgui.TableNextRow();
                imgui.TableNextColumn();
                imgui.PushStyleColor(ImGuiCol_Text, stale and COL_STALE or COL_HEAD);
                local open;
                if (imgui.SetNextItemOpen ~= nil) then
                    imgui.SetNextItemOpen(not hidden);
                    open = imgui.TreeNodeEx(label .. '###pm_a_' .. a.name, ImGuiTreeNodeFlags_NoTreePushOnOpen);
                else
                    -- Older binding: a clickable row with a +/- marker instead of a tree arrow.
                    open = not hidden;
                    if (imgui.Selectable((open and '[-] ' or '[+] ') .. label .. '###pm_a_' .. a.name, false)) then
                        open = not open;
                    end
                end
                imgui.PopStyleColor();
                pm.collapsed[a.name] = (not open) or nil;
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn(); imgui.TextColored(stale and COL_STALE or heat_mss(mss), ('%.3f'):fmt(mss));
                imgui.TableNextColumn();
                if (a.leak) then
                    imgui.TextColored(COL_BAD, ('%d LEAK?'):fmt(a.mem));
                else
                    imgui.Text(('%d (pk %d)'):fmt(a.mem, a.mem_peak));
                end

                for _, sname in ipairs(open and sorted_sections(a) or NO_SECTIONS) do
                    local s = a.sections[sname];
                    local avg = (s.n > 0) and (s.tot / s.n) or 0;
                    imgui.TableNextRow();
                    imgui.TableNextColumn(); imgui.Text('      ' .. sname);
                    imgui.TableNextColumn(); imgui.Text(('%.0f'):fmt(s.n * scale));
                    imgui.TableNextColumn(); imgui.Text(('%.1f'):fmt(avg));
                    imgui.TableNextColumn(); imgui.TextColored(heat_us(s.max), ('%d'):fmt(s.max));
                    imgui.TableNextColumn(); imgui.TextColored(heat_us(s.peak), ('%d'):fmt(s.peak));
                    imgui.TableNextColumn(); imgui.Text(('%.3f'):fmt(s.tot / 1000 * scale));
                    imgui.TableNextColumn();
                end
            end
            draw_stat_menu();
            imgui.EndTable();
        end

        if (#sorted == 0) then
            imgui.TextDisabled('No reports yet. Use the Install tab, or add  local perf = require(\'perf\');  to an addon.');
        end
        if (#pm.others > 0) then
            imgui.TextWrapped('Not instrumented: ' .. table.concat(pm.others, ', '));
        end
        imgui.EndTabItem();
      end
      if (imgui.BeginTabItem('Memory')) then
          draw_memory();
          imgui.EndTabItem();
      end
      if (imgui.BeginTabItem('Install')) then
          draw_installer();
          imgui.EndTabItem();
      end
      imgui.EndTabBar();
    end
    imgui.End();
end

--[[
* Chat summary
--]]
local function print_summary()
    print(('[perfmon] FPS %.1f  avg %.2f ms  worst %.1f ms  hitches %d total'):fmt(pm.fps, pm.avg_ms, pm.worst_ms, pm.hitch_total));
    for _, a in pairs(pm.addons) do
        local scale = 1000 / a.win_ms;
        print(('  %s: %.3f ms/s, mem %d KB (peak %d)%s'):fmt(a.name, a.total_us / 1000 * scale, a.mem, a.mem_peak, a.leak and '  POSSIBLE LEAK' or ''));
        for _, sname in ipairs(a.order) do
            local s = a.sections[sname];
            local avg = (s.n > 0) and (s.tot / s.n) or 0;
            print(('    %-20s %5.0f/s  avg %7.1fus  max %6dus  peak %6dus'):fmt(sname, s.n * scale, avg, s.max, s.peak));
        end
    end
end

local function print_mem()
    local p = pm.proc;
    if (p.kb ~= nil) then
        local tr = p.trend;
        print(('[perfmon] game process %.0f MB private (peak %.0f MB)%s'):fmt(p.kb / 1024, p.peak / 1024,
            tr and ('  %+.2f MB/min, fit %.2f over %.0f min%s'):fmt(tr.slope, tr.r2, tr.mins, p.rising and '  RISING' or '') or ''));
    else
        print('[perfmon] game process memory not available.');
    end
    print(('[perfmon] platform: %s'):fmt(platform_str));
    local v = pm.vm;
    if (v.last ~= nil) then
        local r, f = v.last, v.first;
        local function mb(k) return ('%.0f MB (%+.0f)'):fmt(r[k] / 1024, (r[k] - f[k]) / 1024); end
        print(('[perfmon] native: private %s, big private %s, mapped %s, image %s, reserved %s'):fmt(
            mb('private'), mb('private_big'), mb('mapped'), mb('image'), mb('reserved')));
        print(('[perfmon] address space: largest free gap %s, free total %s, %d regions (scan %.1f ms)'):fmt(
            mb('free_largest'), mb('free_total'), r.regions, v.scan_us / 1000));
        local eta = vm_eta();
        if (eta ~= nil) then
            print(('[perfmon] free address space shrinking %.1f MB/min: runs out in about %s'):fmt(-v.free_trend.slope, fmt_dur(eta)));
        end
    end
    if (v.handles ~= nil) then
        local h, f = v.handles, v.first_handles;
        local function c(k) return h[k] and ('%d (%+d)'):fmt(h[k], h[k] - (f[k] or h[k])) or '-'; end
        print(('[perfmon] handles %s, GDI %s, USER %s   (changes are since perfmon loaded)'):fmt(c('handles'), c('gdi'), c('user')));
    end
    for _, a in pairs(pm.addons) do
        local st = addon_status(a);
        local tr = a.trend;
        local o = a.obj;
        print(('  %-16s now %6d KB  after GC %6s KB  %s  %s%s'):fmt(a.name, a.mem, a.base and tostring(a.base) or '-',
            tr and ('%+.1f KB/min (fit %.2f)'):fmt(tr.slope, tr.r2) or '', st,
            o and ('  objects %d font / %d prim / %d tex%s'):fmt(o.fonts, o.prims, o.com, a.obj_rising and ' RISING' or '') or ''));
    end
end

local function print_help()
    print('[perfmon] /perfmon - toggle window');
    print('[perfmon] /perfmon log [on|off] - CSV logging to config/addons/perfmon/');
    print('[perfmon] /perfmon log clear - empty the current CSV (keeps header)');
    print('[perfmon] /perfmon reset - clear all collected data');
    print('[perfmon] /perfmon print - summary to chat');
    print('[perfmon] /perfmon mem - memory / leak-check summary to chat');
    print('[perfmon] /perfmon snap - snapshot memory, address space, handles and objects');
    print('[perfmon] /perfmon diff - what changed since the snapshot');
    print('[perfmon] /perfmon mark [text] - put a marker on the process memory graph');
    print('[perfmon] /perfmon install <addon> - add auto-instrumentation to a loaded addon (edits its .lua, makes .perfbak backup, reloads it)');
    print('[perfmon] /perfmon remove <addon> - take it back out and reload');
    print('[perfmon] /perfmon install all - install into every loaded addon that is not instrumented yet');
    print('[perfmon] /perfmon remove all - remove from every addon perfmon installed into');
    print('[perfmon] /perfmon status - show which loaded addons are instrumented');
end

--[[
* Events
--]]
ashita.events.register('command', 'perfmon_command', function (e)
    local c = e.command;

    -- Reports from instrumented addons (fast path, no arg splitting).
    if (c:sub(1, 12) == '/perfmon_rpt') then
        e.blocked = true;
        handle_report(c);
        return;
    end

    local args = c:args();
    -- '/perf gc' is for the perf.lua instances; make sure it never reaches the game.
    if (#args >= 2 and args[1]:lower() == '/perf' and args[2]:lower() == 'gc') then
        e.blocked = true;
        return;
    end
    if (#args == 0 or args[1]:lower() ~= '/perfmon') then
        return;
    end
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    if (sub == '') then
        pm.show[1] = not pm.show[1];
    elseif (sub == 'log') then
        local v = (args[3] or ''):lower();
        if (v == 'on') then set_logging(true);
        elseif (v == 'off') then set_logging(false);
        elseif (v == 'clear' or v == 'empty') then clear_log();
        else set_logging(not pm.log_on); end
    elseif (sub == 'reset') then
        pm.addons = {};
        pm.hitch_total = 0;
        pm.proc.hist, pm.proc.plot, pm.proc.trend, pm.proc.rising, pm.proc.warned = {}, {}, nil, false, false;
        pm.proc.peak = pm.proc.kb or 0;
        pm.events = {};
        pm.vm.free_hist, pm.vm.free_trend, pm.vm.h_hist, pm.vm.h_trend = {}, nil, {}, nil;
        pm.vm.first, pm.vm.first_handles = pm.vm.last, pm.vm.handles;
        for _, a in pairs(pm.addons) do a.obj_first = a.obj; end
        pm.snap, pm.diff = nil, nil;
        print('[perfmon] reset.');
    elseif (sub == 'snap' or sub == 'snapshot') then
        request_capture('snap');
    elseif (sub == 'diff') then
        request_capture('diff');
    elseif (sub == 'mark') then
        local text = table.concat(args, ' ', 3);
        add_event('mark', text ~= '' and text or 'mark');
        print(('[perfmon] marked: %s'):fmt(text ~= '' and text or 'mark'));
    elseif (sub == 'print') then
        print_summary();
    elseif (sub == 'mem' or sub == 'leak' or sub == 'leaks') then
        print_mem();
    elseif (sub == 'install' or sub == 'remove') then
        if (args[3] == nil) then
            print(('[perfmon] usage: /perfmon %s <addon>'):fmt(sub));
            return;
        end
        if (args[3]:lower() == 'all' and find_loaded('all') == nil) then
            batch_apply(sub);
            return;
        end
        refresh_others(now_us(), true);
        local name = find_loaded(args[3]);
        if (name == nil) then
            print(('[perfmon] %s is not loaded. Load it first with /addon load %s'):fmt(args[3], args[3]));
            return;
        end
        if (sub == 'install') then install(name); else remove(name); end
    elseif (sub == 'status') then
        mgr.status, mgr.path = {}, {};
        refresh_others(now_us(), true);
        for _, n in ipairs(mgr.loaded) do
            print(('[perfmon]   %-16s %s'):fmt(n, STATUS_TXT[mgr.status[n]] or '?'));
        end
    else
        print_help();
    end
end);

ashita.events.register('d3d_present', 'perfmon_present', function ()
    local t = now_us();
    frame_tick(t);
    proc_tick(t);
    vm_tick(t);
    capture_tick(t);
    refresh_others(t);
    draw();

    if (pm.log_on and (t - pm.log_flushed) > FLUSH_US) then
        flush_log();
    end
    pm.self_tot = pm.self_tot + (now_us() - t);
end);

-- Zone-in (0x000A): mark the process graph with the zone name.
ashita.events.register('packet_in', 'perfmon_packet_in', function (e)
    if (e.id ~= 0x000A or e.data == nil or #e.data < 0x32) then
        return;
    end
    local zid = e.data:byte(0x31) + e.data:byte(0x32) * 256;
    local name;
    pcall(function () name = AshitaCore:GetResourceManager():GetString('zones.names', zid); end);
    add_event('zone', (name ~= nil and name ~= '') and name or ('zone ' .. zid));
end);

ashita.events.register('unload', 'perfmon_unload', function ()
    if (pm.log_on) then
        flush_log();
    end
end);
