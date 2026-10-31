--[[
* perfmon - Dashboard for addons instrumented with libs/perf.lua (Ashita v4).
*
* Commands:
*   /perfmon                 Toggle the dashboard window.
*   /perfmon log [on|off]    Toggle CSV logging (config/addons/perfmon/perf_YYYYMMDD_HHMMSS.csv).
*   /perfmon log clear       Empty the current CSV (keeps the header; logging continues).
*   /perfmon reset           Clear peaks and frame stats.
*   /perfmon print           Print a summary to chat.
*   /perfmon help            Show commands.
--]]

addon.name    = 'perfmon';
addon.author  = 'Lift';
addon.version = '1.0';
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
};

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
        a = { name = name, seq = -1, mem = 0, mem_peak = 0, win_ms = 1000, seen = 0, sections = {}, order = {}, total_us = 0 };
        pm.addons[name] = a;
    end
    return a;
end

local function log_line(str)
    if (pm.log_on) then
        pm.log_buf[#pm.log_buf + 1] = str;
    end
end

local function handle_report(cmd)
    local name, seq, mem, win, payload = cmd:match('^/perfmon_rpt%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s*(.*)$');
    if (name == nil) then
        return;
    end
    seq, mem, win = tonumber(seq), tonumber(mem), tonumber(win);

    local a = get_addon(name);

    -- A new seq means a new 1s window; continuation chunks share the same seq.
    if (seq ~= a.seq) then
        a.seq      = seq;
        a.mem      = mem;
        a.win_ms   = (win > 0) and win or 1000;
        a.seen     = now_us();
        a.total_us = 0;
        if (mem > a.mem_peak) then a.mem_peak = mem; end
        for _, s in pairs(a.sections) do s.fresh = false; end
    end

    for sname, n, tot, mx in payload:gmatch('([^|;]+)|(%d+)|(%d+)|(%d+);') do
        n, tot, mx = tonumber(n), tonumber(tot), tonumber(mx);
        local s = a.sections[sname];
        if (s == nil) then
            s = { name = sname, n = 0, tot = 0, max = 0, peak = 0 };
            a.sections[sname] = s;
            a.order[#a.order + 1] = sname;
        end
        s.n, s.tot, s.max, s.fresh = n, tot, mx, true;
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
        print(('[perfmon] logging to %s'):fmt(pm.log_path));
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

local COL_OK    = { 0.6, 1.0, 0.6, 1.0 };
local COL_WARN  = { 1.0, 0.85, 0.3, 1.0 };
local COL_BAD   = { 1.0, 0.4, 0.4, 1.0 };
local COL_HEAD  = { 0.55, 0.8, 1.0, 1.0 };
local COL_STALE = { 0.5, 0.5, 0.5, 1.0 };

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
    pending = nil,    -- { action = 'install'|'remove', name = ... } awaiting confirm
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
end

local STATUS_TXT = {
    auto   = 'installed (auto)',
    manual = 'manual (in code)',
    none   = 'not installed',
    nofile = 'file not found',
};

local function draw_installer()
    imgui.TextWrapped('Install adds one line to the top of the addon\'s main .lua file and reloads it. '
        .. 'Every event callback in that addon is then timed. A backup of the original is saved as <file>.perfbak.');

    if (mgr.msg ~= '') then
        imgui.TextColored(mgr.msg_col or COL_HEAD, mgr.msg);
    end

    if (mgr.pending ~= nil) then
        local pd = mgr.pending;
        imgui.TextColored(COL_WARN, ('%s %s? This edits %s'):fmt(pd.action == 'install' and 'Install into' or 'Remove from', pd.name, mgr.path[pd.name] or '?'));
        if (imgui.Button('Confirm')) then
            mgr.pending = nil;
            if (pd.action == 'install') then install(pd.name); else remove(pd.name); end
        end
        imgui.SameLine();
        if (imgui.Button('Cancel')) then mgr.pending = nil; end
        imgui.Separator();
    end

    if (imgui.SmallButton('Refresh list')) then
        mgr.status, mgr.path = {}, {};
        refresh_others(now_us(), true);
    end

    local flags = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY);
    if (imgui.BeginTable('##pm_inst', 4, flags, { 0, -1 })) then
        imgui.TableSetupScrollFreeze(0, 1);
        imgui.TableSetupColumn('Addon', ImGuiTableColumnFlags_WidthStretch, 2.0);
        imgui.TableSetupColumn('Status', ImGuiTableColumnFlags_WidthStretch, 2.0);
        imgui.TableSetupColumn('Reporting', ImGuiTableColumnFlags_WidthStretch, 1.0);
        imgui.TableSetupColumn('Action', ImGuiTableColumnFlags_WidthStretch, 1.2);
        imgui.TableHeadersRow();

        for _, n in ipairs(mgr.loaded) do
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
        end
        imgui.SameLine();
        imgui.TextDisabled(('perfmon self: %.3f ms/s'):fmt(pm.self_last / 1000));

        imgui.Separator();

        -- Sort addons by main-thread time used.
        for i = #sorted, 1, -1 do sorted[i] = nil; end
        for _, a in pairs(pm.addons) do sorted[#sorted + 1] = a; end
        table.sort(sorted, function (x, y) return x.total_us > y.total_us; end);

        local t = now_us();
        local flags = bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY);
        if (imgui.BeginTable('##pm_tbl', 7, flags, { 0, -60 })) then
            imgui.TableSetupScrollFreeze(0, 1);
            imgui.TableSetupColumn('Addon / section', ImGuiTableColumnFlags_WidthStretch, 3.0);
            imgui.TableSetupColumn('Calls/s');
            imgui.TableSetupColumn('Avg us');
            imgui.TableSetupColumn('Max us');
            imgui.TableSetupColumn('Peak us');
            imgui.TableSetupColumn('ms/s');
            imgui.TableSetupColumn('Mem KB');
            imgui.TableHeadersRow();

            for _, a in ipairs(sorted) do
                local stale = (t - a.seen) > STALE_US;
                local scale = 1000 / a.win_ms;
                local mss = a.total_us / 1000 * scale;

                imgui.TableNextRow();
                imgui.TableNextColumn();
                imgui.TextColored(stale and COL_STALE or COL_HEAD, stale and (a.name .. ' (no report)') or a.name);
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn();
                imgui.TableNextColumn(); imgui.TextColored(stale and COL_STALE or heat_mss(mss), ('%.3f'):fmt(mss));
                imgui.TableNextColumn(); imgui.Text(('%d (pk %d)'):fmt(a.mem, a.mem_peak));

                for _, sname in ipairs(a.order) do
                    local s = a.sections[sname];
                    local avg = (s.n > 0) and (s.tot / s.n) or 0;
                    imgui.TableNextRow();
                    imgui.TableNextColumn(); imgui.Text('   ' .. sname);
                    imgui.TableNextColumn(); imgui.Text(('%.0f'):fmt(s.n * scale));
                    imgui.TableNextColumn(); imgui.Text(('%.1f'):fmt(avg));
                    imgui.TableNextColumn(); imgui.TextColored(heat_us(s.max), ('%d'):fmt(s.max));
                    imgui.TableNextColumn(); imgui.TextColored(heat_us(s.peak), ('%d'):fmt(s.peak));
                    imgui.TableNextColumn(); imgui.Text(('%.3f'):fmt(s.tot / 1000 * scale));
                    imgui.TableNextColumn();
                end
            end
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
        print(('  %s: %.3f ms/s, mem %d KB (peak %d)'):fmt(a.name, a.total_us / 1000 * scale, a.mem, a.mem_peak));
        for _, sname in ipairs(a.order) do
            local s = a.sections[sname];
            local avg = (s.n > 0) and (s.tot / s.n) or 0;
            print(('    %-20s %5.0f/s  avg %7.1fus  max %6dus  peak %6dus'):fmt(sname, s.n * scale, avg, s.max, s.peak));
        end
    end
end

local function print_help()
    print('[perfmon] /perfmon - toggle window');
    print('[perfmon] /perfmon log [on|off] - CSV logging to config/addons/perfmon/');
    print('[perfmon] /perfmon log clear - empty the current CSV (keeps header)');
    print('[perfmon] /perfmon reset - clear all collected data');
    print('[perfmon] /perfmon print - summary to chat');
    print('[perfmon] /perfmon install <addon> - add auto-instrumentation to a loaded addon (edits its .lua, makes .perfbak backup, reloads it)');
    print('[perfmon] /perfmon remove <addon> - take it back out and reload');
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
        print('[perfmon] reset.');
    elseif (sub == 'print') then
        print_summary();
    elseif (sub == 'install' or sub == 'remove') then
        if (args[3] == nil) then
            print(('[perfmon] usage: /perfmon %s <addon>'):fmt(sub));
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
    refresh_others(t);
    draw();

    if (pm.log_on and (t - pm.log_flushed) > FLUSH_US) then
        flush_log();
    end
    pm.self_tot = pm.self_tot + (now_us() - t);
end);

ashita.events.register('unload', 'perfmon_unload', function ()
    if (pm.log_on) then
        flush_log();
    end
end);
