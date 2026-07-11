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

**But only for NorthWest-gravity windows.** The leading `0` in the wmctrl
geometry argument is the gravity field; `0` means "use the window's own
`WM_NORMAL_HINTS` win_gravity". GTK apps (xfce4-terminal, thunar) hint
NorthWest and behave as above. kitty and Qt apps (Qube Manager, most
qubes-* tools) hint **Static** gravity, for which xfwm4 positions the
*client* at the request instead — those windows landed exactly one
title-bar height higher than their GTK neighbors in the same layout
(user-visible dom0 misalignment bug). All apply paths therefore pass
gravity **1** (NorthWest) explicitly, which makes every window obey the
same rule regardless of its toolkit's hint. Never pass gravity `0`.

Practical consequences:

- **To place a window at xwininfo `(X, Y)`** you must call
  `wmctrl -e "1, X-L, Y-T, W, H"`. Skipping the subtraction shifts every
  apply down by `T` pixels (and right by `L`).
- **Reading the position back via `wmctrl -lG`** returns `(X+L, Y+T)`, not
  `(X, Y)`. So `wmctrl -lG`'s output is *not* directly suitable as input to
  `wmctrl -e`. Round-tripping needs the same `(L, T)` correction.
- **`xwininfo`'s "Absolute upper-left"** is the frame outer corner — that
  is the user-visible upper-left, and the value the layout code thinks of
  as "the position of the window."

## The two apply functions and their coordinate semantics

All geometry applies now go through `_apply_frame_exact` (`lib/windows.sh`),
which fetches the window's own `_NET_FRAME_EXTENTS` fresh on every call and
passes `wmctrl -e (X-L, Y-T)` — the pattern validated in commit `407b3e4`.
Every window's frame therefore lands where the caller said, regardless of
that window's decorations. Two public wrappers exist with **different
coordinate semantics**; picking the wrong one reintroduces per-window drift:

- **`apply_geometry` (LAYOUT semantics)** — lands the frame at
  `(x, y + DECORATION_HEIGHT)`. All layout math in `lib/layouts.sh` and
  `lib/interactive.sh` was tuned in the era when `apply_geometry` passed
  coordinates raw and xfwm4 shifted standard windows down by `T` (the
  title bar, = `DECORATION_HEIGHT`). Normalizing to `DECORATION_HEIGHT`
  keeps every standard window exactly where it always was — no layout
  re-tune — while windows with *non-standard* extents (client-side-decorated
  dom0 apps, GTK CSD, vs xfwm4-decorated AppVM windows on Qubes) now land
  aligned with their neighbors instead of a title-bar height higher. That
  misalignment was a real user-reported bug; it existed because the old raw
  `wmctrl -e` call let each window's OWN `(L, T)` decide its landing.

- **`apply_geom_adaptive` (ABSOLUTE semantics)** — lands the frame exactly
  at `(fx, fy)`. Use for round-trip applies: coordinates that were read back
  from X (saved presets via `save_position`/`load_position`,
  `simultaneous_resize`) and must land exactly where they were read.
  The name is kept for call-site continuity; the former
  `detect_wmctrl_coord_mode` probe it wrapped is **gone** — the probe's
  no-op apply could never classify xfwm4 (nothing moves on a no-op, so it
  always said "frame"/pass-through, which is wrong on any real move) and
  its "client" branch was unreachable. Don't resurrect it; if a non-xfwm4
  WM ever matters, write a probe that performs a *non-zero-delta* move and
  observes whether the result lands at `+(L,T)`, `0`, or `-(L,T)`.

`swap_window_geometries`, `cycle_window_positions`, and
`reverse_cycle_window_positions` keep their inline manual `(L, T)`
subtraction from `407b3e4` (equivalent to `_apply_frame_exact`, kept
explicit to preserve that revert's narrative).

## Self-correcting applies

`apply_geometry` and `apply_geom_adaptive` verify the result after
`wait_window_settled` and re-apply once if drift exceeds a 2 px epsilon on
any axis. `_geom_drift_exceeds` reads back via
`get_window_frame_geometry_wmctrl` (xwininfo space) and compares against the
**absolute frame target** — since applies subtract per-window extents, the
expected readback is the target itself, with no `(L, T)` shift. A useful
side effect: a first apply that ran while `_NET_FRAME_EXTENTS` was still
unset (freshly mapped window, extents default to 0) shows up as drift and
the retry corrects it with the by-then-real extents.

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

## Suspend/resume watchdog

After a suspend/resume cycle the `xprop -spy` event watcher can hold a stale
X connection that neither delivers events nor exits. Its wrapper subshell
stays alive, so the heartbeat's `kill -0` respawn check passes and the daemon
goes permanently deaf — running but never re-tiling. The main loop in
`watch_daemon_with_ipc` therefore tracks wall-clock time per iteration; a
gap larger than `2 × SAFETY_TICK + 5` seconds can only mean the machine was
suspended (an iteration is otherwise bounded by the read timeout plus
processing). On detection it unconditionally restarts the event watcher,
drops the monitor cache, clears `WINDOW_COUNT` (forcing every
`(workspace, monitor)` dirty so the next reconcile reapplies), and clears
stale holds/cooldowns from before the suspend.

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
| `IGNORED_APPS` patterns are compiled ONCE in `compile_ignored_patterns` and matched with bash `[[ =~ ]]` | `lib/config.sh`, `lib/windows.sh:get_visible_windows` | The old per-window inline compiler forked ~5 processes per pattern per window per call — the largest CPU cost on the daemon's hot path. Don't move compilation back into the window loop. |
| `get_visible_windows` reads all per-window properties via ONE `xprop` call | `lib/windows.sh:get_visible_windows` | Was 4-5 xprop forks per window per call. Add new properties to the existing batched call, not as separate xprop invocations. |
| `apply_geometry` = layout semantics (`y + DECORATION_HEIGHT`); `apply_geom_adaptive` = absolute frame position | `lib/windows.sh` | Layout math is tuned to the historical landing of standard xfwm4 windows; round-trip callers need exact landing. Mixing them up reintroduces the per-window title-bar drift (user-visible dom0-vs-AppVM misalignment). |
| Suspend watchdog: main-loop wall-clock gap check restarts the event watcher | `lib/daemon.sh:watch_daemon_with_ipc` | `kill -0` on the watcher subshell cannot detect a stale-but-alive `xprop -spy` after resume; the daemon went deaf until manually restarted. |
| Every `wmctrl -e` passes gravity `1` (NorthWest), never `0` | `lib/windows.sh:_apply_frame_exact`, `swap_window_geometries`, cycle functions | Gravity `0` defers to the window's own hint; Static-gravity toolkits (kitty, Qt/Qube Manager) then land a title-bar height higher than GTK windows in the same layout. |
| Event-driven ticks are rate-limited to 1/s via `PENDING_EVENT_TICK` (never silently dropped — pending ticks flush on a 1s read timeout) | `lib/daemon.sh:watch_daemon_with_ipc` | `_NET_ACTIVE_WINDOW` (watched to make minimize/restore event-driven) fires on every focus click; unlimited ticks would reintroduce the click-storm churn that got stacking events excluded (commit `a0286af`). Dropping instead of deferring would delay the trailing event up to 30s. |

## When in doubt

- For one-off geometry at an absolute xwininfo position: use
  `apply_geom_adaptive` (subtracts frame extents, settles, retries on
  drift). For layout-space coordinates: use `apply_geometry`.
- For batch layout (master, grid, columns): use the existing meta-layout
  helpers in `lib/layouts.sh`. Their gap math already accounts for the
  xfwm4 quirk via `apply_geometry`.
- Before adding a sleep, check whether `wait_window_settled` already
  covers your need.
- Before adding a log line inside an IPC-reachable function, route it
  through `>&6 2>/dev/null`.
