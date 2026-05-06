# Development notes

Quirks and conventions worth knowing before changing anything in `lib/`. The
top-level `CLAUDE.md` describes architecture, file layout, and command
surface; this file captures the *why* behind decisions that would otherwise
look arbitrary.

## Geometry: how `wmctrl -e` actually behaves on xfwm4

xfwm4 — the WM the project primarily targets — does **not** treat
`wmctrl -e "0, X, Y, W, H"` the way most documentation suggests. Empirical
behavior:

```
wmctrl -e "0, X, Y, W, H"   →  window's xwininfo "Absolute upper-left"
                               ends up at (X + L, Y + T)
```

…where `(L, T)` are the frame extents from `_NET_FRAME_EXTENTS` (typically
`L=1, T=24` on the default theme: 1px left border, 24px title bar).

Practical consequences:

- **To place a window at xwininfo `(X, Y)`** you must call
  `wmctrl -e "0, X-L, Y-T, W, H"`. Skipping the subtraction shifts every
  apply down by `T` pixels (and right by `L`).
- **Reading the position back via `wmctrl -lG`** returns `(X+L, Y+T)`, not
  `(X, Y)`. So `wmctrl -lG`'s output is *not* directly suitable as input to
  `wmctrl -e`. Round-tripping needs the same `(L, T)` correction.
- **`xwininfo`'s "Absolute upper-left"** is the frame outer corner — that
  is the user-visible upper-left, and the value the layout code thinks of
  as "the position of the window."

## What `apply_geom_adaptive` does, and where it falls short

`lib/windows.sh:apply_geom_adaptive` is meant to abstract over WM-specific
coordinate mode differences. It probes once per process via
`detect_wmctrl_coord_mode` and caches "frame" (pass through) or "client"
(add `(L, T)` to convert frame→client).

The probe applies the window's *current* position back via `wmctrl -e`. If
the window doesn't move, the probe concludes "frame" mode. xfwm4 will
accept a no-op without moving, so the probe always concludes "frame" on
xfwm4 — but the actual behavior on a *real* (non-zero-delta) move is
neither "frame" nor "client": you have to *subtract* `(L, T)`, not pass
through and not add.

This means **`apply_geom_adaptive` is unsafe for one-off geometry applies
on xfwm4**. It happens to work for layout meta-functions in `lib/layouts.sh`
because those use the wrapper `apply_geometry` (which is also a raw
`wmctrl -e` call) and the layout math has been hand-tuned to compensate.
But functions like `swap_window_geometries` and `cycle_window_positions`
that compute a target xwininfo position and apply it directly need to
subtract `(L, T)` per-window themselves and use raw `wmctrl -e`.

If/when this codebase needs to run on a non-xfwm4 WM where the
"add `(L, T)`" interpretation is correct (i.e. real "client" mode), the
right fix is a more honest probe — apply a *non-zero-delta* move during
detection, observe whether the result moved by `+(L, T)`, `0`, or
`-(L, T)`, and pick a three-way mode. Until then, the safe pattern for
new direct-apply code is:

```bash
local L R T B
read -r L R T B < <(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null \
                   | awk -F' = ' '{print $2}' | sed 's/, / /g')
: "${L:=0}"; : "${T:=0}"
wmctrl -i -r "$id" -e "0,$((target_x - L)),$((target_y - T)),$w,$h"
wait_window_settled "$id"
```

## Self-correcting applies: `apply_geometry` and `apply_geom_adaptive` (frame branch)

`apply_geometry` and the frame branch of `apply_geom_adaptive` verify the
result after `wait_window_settled` and re-apply once if drift exceeds a 2 px
epsilon on any axis. The helper `_geom_drift_exceeds` reads back via
`get_window_frame_geometry_wmctrl` (xwininfo space) and compares against the
target shifted by `(L, T)` — see the helper for the round-trip arithmetic.

This eliminates the visible 1-2 s reflow snap that the daemon's SIGUSR1-driven
second pass produced previously: the second pass now happens inline, only
when needed. The `trigger_daemon_reapply` calls in `auto_layout_and_reset_monitor`
(`lib/layouts.sh`), `master_stack_layout_current_monitor` (`lib/daemon.sh`),
and `center_master_layout_current_monitor` (`lib/daemon.sh`) are now redundant
no-ops in steady state; they're left in place as belt-and-suspenders for now.

Cap: exactly **one** retry. Toolkits with `WM_NORMAL_HINTS` size increments
(xfce4-terminal, thunar, etc.) will always quantize the requested W/H by a few
px; we accept that floor after the single retry. Same convergence floor as the
daemon's reapply produced previously.

The client branch of `apply_geom_adaptive` is intentionally **not** wrapped:
`detect_wmctrl_coord_mode` always concludes "frame" on xfwm4 (its no-op probe
can't distinguish), so the client branch is dead today, and the existing probe
is documented broken — adding verify-retry there would falsely double the
`(L, T)` shift in the comparison.

`swap_window_geometries`, `cycle_window_positions`, and
`reverse_cycle_window_positions` are also **not** self-correcting. They use the
"raw `wmctrl -e` with manual `(L, T)` subtraction" pattern documented above,
settled on after the revert in commit `407b3e4`. Wrapping them is a possible
follow-up but would muddy that revert's narrative.

## Daemon IPC: why diagnostic logs use `>&6`

`lib/daemon.sh:watch_daemon_with_ipc` opens fd 6 as a dup of stdout, and
diagnostic helpers (e.g. `clear_workspace_monitor_layout` log line,
`reapply_saved_layout_for_monitor` decision branch logs) write through
`{ echo "..."; } >&6 2>/dev/null`.

This is required because the main loop captures command-handler output via
`resp="$(handle_daemon_command "$cmd" 2>&1)"`. Anything written to stdout
or stderr inside `handle_daemon_command` ends up in `$resp` — sent to the
IPC client over the response pipe — instead of the daemon log. fd 6 was
opened *before* the substitution, inherits unchanged, and bypasses the
capture so the line lands in `~/.config/window-positioning/daemon.log`.

If you add new diagnostic logging from any function reachable through an
IPC command (`auto`, `master`, `reapply`, `focus`, `cycle`,
`minimize-others`, …), use `>&6 2>/dev/null`. Functions only reachable
via the event-driven path (e.g. inside `monitor_tick` triggered by an
X11 event) can use plain `echo` — those run outside the substitution.

## Saved layout state file format

Per-(workspace, monitor) saved layouts live at
`~/.config/window-positioning/workspace-<N>-monitor.conf`. Format is
flat `KEY=VALUE` lines, e.g.:

```
MONITOR_HDMI-0_LAYOUT_=master vertical 75
```

The `_LAYOUT_` key (no count suffix) is what the master/auto/reapply paths
actually read and write. Older code also wrote `MONITOR_<name>_LAYOUT_<N>`
keys with a window-count suffix and `MONITOR_<name>_MASTER_LIST=…` for
window-ID lists; both are unused by current code (the `MASTER_LIST` was
removed in commit `c2031ee`, the `LAYOUT_<N>` form is read but never
written anymore). Stale entries from before that cleanup can sit in the
file harmlessly.

The only writer is `save_workspace_monitor_layout` in `lib/config.sh`. The
only deleter is `clear_workspace_monitor_layout` in `lib/config.sh`,
called from `auto_layout_and_reset_monitor` in `lib/layouts.sh`.

## Don't-undo list

The following decisions are load-bearing — they were made deliberately
after a specific incident. Re-litigating them silently will reintroduce
the same bug.

| Decision | Where | Why |
|---|---|---|
| Daemon is event-driven via `xprop -spy`, not polling | `lib/daemon.sh:start_event_watcher` | Polling pegged dom0 idle CPU at ~20% (commit `a0286af`). |
| IPC responses end with `__DAEMON_RESP_END__` sentinel | `lib/daemon.sh:watch_daemon_with_ipc`, `send_daemon_command` | Without it, clients didn't know when to stop reading multi-line responses (commit `ed5766b`). |
| `set -e` is OFF in the long-running daemon | `lib/daemon.sh` top | A trivial `grep` returning 1 would otherwise kill the daemon mid-tick (commit `886c867`). |
| `WATCH_AUTO_LAYOUT` from `settings.conf` wins on every daemon start | `lib/daemon.sh:watch_daemon_with_ipc` | Otherwise the runtime marker file silently overrode the user's authoritative config (commit `29444cf`). |
| Per-`(workspace, monitor)` debounce, not a single global timer | `lib/daemon.sh:HOLD_UNTIL_MS` keyed by `key_wsmon` | A global timer let one monitor's apply block another monitor's pending apply for up to 30s (commit `a0286af`). |
| Auto-start is XDG, not a systemd user unit | `~/.config/autostart/window-positioning.desktop` | XDG starts more reliably for X11 sessions; the systemd path was tried and removed. |
| `IGNORED_APPS` is split via `read -ra`, not unquoted `arr=($var)` | `lib/windows.sh:get_visible_windows`, `lib/config.sh:validate_ignored_apps` | Unquoted glob expansion against the daemon's CWD silently dropped patterns whose name matched a real file (commit `c1fda77`). |
| `clear_workspace_monitor_layout`, the four `reapply_saved_layout_for_monitor` branches, and `_NET_CURRENT_DESKTOP` transitions all log to fd 6 | `lib/daemon.sh`, `lib/config.sh`, `lib/layouts.sh` | Required to diagnose the open `master vertical 75` regression — see TODO.md (commit `5680872`). |

## When in doubt

- For one-off geometry: read xwininfo, fetch frame extents, subtract
  `(L, T)`, call `wmctrl -e` directly, then `wait_window_settled`.
- For batch layout (master, grid, columns): use the existing meta-layout
  helpers in `lib/layouts.sh`. Their gap math already accounts for the
  xfwm4 quirk via `apply_geometry`.
- Before adding a sleep, check whether `wait_window_settled` already
  covers your need.
- Before adding a log line inside an IPC-reachable function, route it
  through `>&6 2>/dev/null`.
