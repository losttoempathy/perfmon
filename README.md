# perfmon

A performance and memory dashboard for **Ashita v4** addons (Final Fantasy XI).

perfmon shows how much main-thread time each addon's event callbacks use, how fast the game is rendering, and whether any addon (or the game itself) is leaking memory. It works with any addon: install it from the dashboard with one click, or add a single `require` line yourself.

It comes in two parts:

| File | Goes in | What it does |
|---|---|---|
| `perfmon.lua` | `Ashita/addons/perfmon/` | The dashboard addon. Collects reports, draws the window, logs CSV, checks for leaks. |
| `libs/perf.lua` | `Ashita/addons/libs/` | A small library loaded *inside* each addon you want to measure. Times its callbacks and reports to perfmon once a second. |

---

## Features

- **Per-addon timing:** calls per second, average / max / all-time peak microseconds, and total ms of main-thread time per second, for every event callback.
- **Frame stats:** FPS, average and worst frame time, a frame-time graph, and a count of hitches (frames over 50 ms).
- **Leak detection:**
  - Lua memory per addon, measured after a forced garbage collection, with a trend fitted over the last 10 minutes. Steady growth gets flagged.
  - The game process's private memory, which catches leaks Lua can't see (FFI allocations, textures and fonts never released, handles).
- **One-click install:** the Install tab adds instrumentation to any loaded addon, backs up the original file and reloads the addon. Remove reverses it.
- **CSV logging:** every report written to a timestamped CSV for graphing in Excel or anything else.
- **Low overhead:** about 1 µs per timed call, and the library's own cost is shown as its own `(perf)` row.

---

## Installation

1. Put this repository in `Ashita/addons/perfmon/` so you have `Ashita/addons/perfmon/perfmon.lua`.
2. Copy `libs/perf.lua` to `Ashita/addons/libs/perf.lua`. Instrumented addons load it from there.
3. In game:

   ```
   /addon load perfmon
   ```

When you update perfmon, update `Ashita/addons/libs/perf.lua` too. The two are versioned together.

---

## Instrumenting an addon

### Option 1: the Install tab (easiest)

Open `/perfmon`, go to **Install**, and click **Install** next to an addon (or run `/perfmon install <addon>`). perfmon will:

1. Save a one-time backup of the addon's main file as `<file>.perfbak`.
2. Add this line to the top of the file:
   ```lua
   require('perf').auto(); --[[perfmon:auto]] -- added by perfmon. Undo: /perfmon remove <addon>
   ```
3. Reload the addon.

`auto()` hooks `ashita.events.register` inside that addon, so **every callback it registers afterwards** is timed, named `<event>:<alias>` (for example `d3d_present:myaddon_present`).

To undo it, click **Remove** or run `/perfmon remove <addon>`.

### Option 2: by hand

Same effect as the installer:

```lua
require('perf').auto();
```

Or, for finer control:

```lua
local perf = require('perf');

-- Time one callback (use instead of ashita.events.register):
perf.register('d3d_present', 'myaddon_present', function ()
    -- ...
end);

-- Time any function:
local build_list = perf.wrap('build_list', function (items) ... end);

-- Time a block of code:
perf.start('sort');
table.sort(list, cmp);
perf.stop('sort');
```

### Growth that's on purpose

Some addons are *supposed* to grow, such as a session log that's cleared on zone or a cache with a size cap. Tell perfmon so it doesn't call it a leak:

```lua
pcall(function () require('perf').expect_growth('session log, cleared on zone', 81920); end);
```

The first argument is a short note shown on the Memory tab. The second is an optional cap in KB. While the addon grows below the cap, its status is **expected**. If its after-GC memory ever passes the cap, it's flagged **OVER CAP**, so a cap that stops working is still caught. The `pcall` keeps the addon working on machines without `perf.lua`.

Addons that `require('perf')` themselves show as **manual (in code)** on the Install tab. Edit those by hand.

### perf.lua settings

Set these on the table returned by `require('perf')`:

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Turn timing off (wrapped functions still run, untimed). |
| `report` | `true` | Send 1-second summaries to perfmon when it is loaded. |
| `interval_ms` | `1000` | Roll-up / report interval. |
| `gc_interval_s` | `60` | How often to force a full GC and record the leak-check baseline. `0` = don't force a GC; use the lowest memory reading each minute instead (no hitch risk, less accurate). |

---

## The dashboard

`/perfmon` toggles the window.

### Stats tab

- **Top line:** FPS, average and worst frame time, and hitches per second and total. Under it: game memory and any addons flagged for a leak.
- **Graph:** frame time for the last 240 frames.
- **Table:** addons sorted by main-thread time, each with its sections underneath. Click an addon's name to collapse or expand its sections (a collapsed addon shows its section count, and its totals stay visible). **Expand all** / **Collapse all** do every addon at once.

| Column | Meaning |
|---|---|
| Calls/s | How many times the callback ran in the last second. |
| Avg us / Max us | Average and worst single call in the last second. |
| Peak us | Worst single call since load (or the last **Reset peaks**). |
| ms/s | Total main-thread time per second. 16.7 ms is a whole frame at 60 FPS. |
| Mem KB | The addon's Lua memory (and peak). Shows **LEAK?** in red if flagged. |

**Colors:**
- **Per-call times:** green under 0.5 ms, yellow from 0.5 ms, red from 2 ms.
- **ms/s:** green under 5, yellow from 5, red from 20.
- **Grey:** an addon that hasn't reported for 3 seconds.

Uninstrumented addons are listed at the bottom.

### Memory tab

- **Game process:** private memory, peak, trend in MB/min and a graph sampled every 10 s.
- **Per addon:** current Lua memory, memory after GC, trend in KB/min, fit, status and a history graph.

| Status | Meaning |
|---|---|
| waiting | No after-GC reading yet. The first one comes 10–30 s after load. If it never changes, that addon is using an old `perf.lua`. |
| collecting n/5 | Gathering readings. About 5 minutes until the first verdict. |
| stable | Not growing. |
| growing | Rising steadily, but slower than the leak threshold. Worth watching. |
| **LEAK?** | Rising steadily at or above the threshold. |
| expected | Rising, but the addon declared that growth with `perf.expect_growth`. Hover to see its note. |
| **OVER CAP** | The addon declared expected growth, but its after-GC memory passed the cap it gave. |

### Install tab

Lists loaded addons with their instrumentation status (installed / manual / not installed / file not found), whether each is reporting, and Install / Remove buttons. Buttons in the window ask you to confirm first.

---

## How leak detection works

Raw Lua memory (`collectgarbage('count')`) goes up and down in a sawtooth even in a healthy addon, because it includes garbage that hasn't been collected yet. Its peak mostly tells you when the GC last ran.

So once a minute, `perf.lua` runs a full collection inside the addon and reports **the memory left afterwards**. That's what the addon is actually holding on to. perfmon fits a straight line through the last 10 minutes of those readings. An addon is flagged when all of these are true:

- it grows by **at least 20 KB/min**,
- it gained **at least 100 KB** over the window,
- and the line **fits well (0.85 or better)**, meaning growth is steady rather than a one-time jump such as loading a data file.

Game process memory is sampled every 10 s and flagged at **2 MB/min** with the same fit rule. If the game's memory rises while no addon's Lua memory does, the leak is outside Lua: FFI `malloc`s, textures or fonts never released, or the game itself. Zoning legitimately loads data, so judge game memory over a stretch in one zone.

You get one chat message when something is first flagged. `/perfmon mem` prints the full picture at any time. To change the thresholds, edit the `LEAK_*` and `PROC_*` constants at the top of `perfmon.lua`.

**Testing it:** in a scratch addon, append to a table every frame. It should show **LEAK?** within about 5 minutes.

**Cost:** the forced GC is timed under its own `(perf:gc)` row. For most addons it takes well under a millisecond once a minute. If an addon with a large heap shows a noticeable hitch there, set `perf.gc_interval_s = 0` for that addon.

---

## Commands

### perfmon

| Command | Action |
|---|---|
| `/perfmon` | Toggle the window. |
| `/perfmon log [on\|off]` | Toggle CSV logging. |
| `/perfmon log clear` | Empty the current CSV back to its header (logging continues). |
| `/perfmon reset` | Clear all collected data. |
| `/perfmon print` | Timing summary to chat. |
| `/perfmon mem` | Memory / leak summary to chat. |
| `/perfmon install <addon>` | Instrument a loaded addon (backup + reload). |
| `/perfmon remove <addon>` | Remove instrumentation (reload). |
| `/perfmon status` | Show which loaded addons are instrumented. |
| `/perfmon help` | List commands. |

### perf.lua (works without perfmon too)

| Command | Action |
|---|---|
| `/perf` or `/perf list` | Each instrumented addon prints its name. |
| `/perf <addon>` | Toggle that addon's own small stats panel. |
| `/perf <addon> print` | Print its stats to chat. |
| `/perf <addon> reset` | Reset its stats. |
| `/perf <addon> on\|off` | Turn its timing on or off. |

---

## CSV logs

Written to `Ashita/config/addons/perfmon/perf_YYYYMMDD_HHMMSS.csv`, flushed every 10 seconds and on unload.

```
time,addon,section,calls,avg_us,max_us,ms_per_s,mem_kb
```

| Row | Contents |
|---|---|
| `<addon>,<section>` | Timing for one section in one second, with the addon's Lua memory. |
| `(game),frame` | Frames that second, average / worst frame time (µs), perfmon's own ms/s, perfmon's Lua memory. |
| `<addon>,(gc baseline)` | The after-GC Lua memory reading (once a minute). Chart `mem_kb` to see a leak. |
| `(game),process_private` | Game process private memory in KB (every 10 s). |

---

## How it fits together

Each instrumented addon runs in its own Lua state, so `perf.lua` sends its once-a-second summary to perfmon as a hidden chat command (`/perfmon_rpt ...`). perfmon catches and blocks it, so you never see it in chat. Long reports are split across several commands.

Timing uses `QueryPerformanceCounter` through LuaJIT FFI, which doesn't allocate a table per call. If FFI isn't available it falls back to `ashita.time.qpc()`. Game memory comes from `K32GetProcessMemoryInfo` (falls back to `psapi`). If neither is available, the Memory tab says so and the rest still works.

---

## Troubleshooting

- **An addon never appears:** check it's instrumented (Install tab) and that `perf.lua` is in `Ashita/addons/libs/`.
- **"auto mode could not hook ashita.events.register":** your Ashita build doesn't allow the hook. Use `perf.register` / `perf.wrap` in that addon instead.
- **Memory tab stuck on "waiting":** that addon is loading an older `perf.lua`. Copy the new one into `addons/libs` and reload the addon.
- **First section name looks garbled:** you're running an older perfmon with a newer `perf.lua`. Update both.

---

## License

GPL-3.0. See [LICENSE](LICENSE).

Author: Lift
