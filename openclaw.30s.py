#!/usr/bin/python3
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
"""OpenClaw menubar — a pure renderer over /tmp/openclaw-snapshot.json.

This file knows NOTHING about OpenClaw: not where the config lives, not that crons moved
to sqlite, not how to find the gateway PID. All of that is in `openclaw-snapshot`, which
is the only reader of those substrates. The plugin this replaced knew all five, and all
five moved between April and September; it rendered the resulting blindness as `0 agents`,
`0 crons` and a green dot.

What it renders, in order:
  1. Problems, already ranked by the collector. Nothing else may appear above them.
  2. A trust line — how many assertions and invariants passed — so silence is *provable*
     rather than merely quiet.
  3. Five summary lines that can actually change, and a 24h activity sparkline.
  4. Actions, all of which go through `openclaw-menu-action`.

Palette follows the sibling mem plugin: red is reserved for alerts, everything else uses
the system label colour so it adapts to light and dark mode. (The old plugin hardcoded
color=white, which is invisible on a light menu.)
"""

import json
import os
import subprocess
import time

SNAPSHOT = "/tmp/openclaw-snapshot.json"
COLLECTOR = os.path.expanduser("~/bin/openclaw-snapshot")
ACTION = os.path.expanduser("~/bin/openclaw-menu-action")
STALE_S = 120          # older than this and the snapshot is no longer evidence
REFRESH_S = 25         # kick a background refresh once the snapshot is older than this
SPARK = "▁▂▃▄▅▆▇█"


def load():
    """Return (snapshot, age_seconds). Never blocks the menu on the collector."""
    age = None
    snap = None
    try:
        age = time.time() - os.path.getmtime(SNAPSHOT)
        snap = json.load(open(SNAPSHOT))
    except Exception:
        snap, age = None, None

    if snap is None:
        # Cold start only: pay the ~0.8s once so the first render has real data.
        try:
            subprocess.run([COLLECTOR], timeout=20, capture_output=True)
            age = time.time() - os.path.getmtime(SNAPSHOT)
            snap = json.load(open(SNAPSHOT))
        except Exception:
            return None, None
    elif age > REFRESH_S:
        # Refresh in the background and render what we have. The menu stays instant, and
        # the age is printed at the bottom, so stale data can never masquerade as fresh.
        try:
            subprocess.Popen([COLLECTOR], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except Exception:
            pass
    return snap, age


def human(sec):
    if sec is None:
        return "?"
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m"
    if sec < 86400:
        return f"{sec // 3600}h{(sec % 3600) // 60:02d}"
    return f"{sec // 86400}d{(sec % 86400) // 3600}h"


def spark(series):
    if not series:
        return ""
    hi = max(series) or 1
    return "".join(SPARK[min(len(SPARK) - 1, v * (len(SPARK) - 1) // hi)] for v in series)


def out(text, **attrs):
    parts = [text]
    if attrs:
        parts.append("| " + " ".join(f"{k}={v}" for k, v in attrs.items()))
    print(" ".join(parts))


def main():
    snap, age = load()

    # ── blind: the collector itself is gone or never ran ────────────────────────────
    if snap is None:
        out("🦞 ⚠︎", color="red", size=12)
        print("---")
        out("Snapshot unavailable — collector failed", color="red", size=13)
        out(f"Expected {SNAPSHOT}", size=11)
        out("Run self-test", bash=ACTION, param1="selftest", terminal="true", size=12)
        return

    stale = age is not None and age > STALE_S
    problems = snap.get("problems", [])
    # The snapshot marks lines that must NOT raise the badge with badge=False (owner
    # decision 2026-09-08: cron outcomes are informational). They stay in `problems` and
    # are still printed below — this filter governs the dot only, not visibility.
    badge_problems = [p for p in problems if p.get("badge") is not False]
    crit = [p for p in badge_problems if p["sev"] == "crit"]

    # ── menubar dot ──────────────────────────────────────────────────────────────────
    # Four states, no number: a count in the menubar is a count of *problem lines*, and
    # "🦞 1" was read as one failing cron. The dropdown states magnitude precisely; the
    # badge only answers "should I look, and how hard".
    #
    # ⚪ is the state the old plugin never had, and the reason it could sit green while
    # reading five dead paths: it fires whenever this monitor cannot vouch for what it is
    # showing — a stale snapshot, any probe that came back `unknown`, or any failed
    # assertion. So 🟢 now means 11/11 assertions passed, not merely "nothing threw".
    blind = (bool(snap.get("selftest", {}).get("failures"))
             or any(d.get("status") == "unknown" for d in snap.get("probes", {}).values()))
    if stale:
        out("🦞⚪", size=12)
    elif crit:
        out("🦞🔴", size=12)
    elif blind:
        out("🦞⚪", size=12)
    elif badge_problems:
        out("🦞🟡", size=12)
    else:
        out("🦞🟢", size=12)
    print("---")

    if stale:
        out(f"⚠︎ Snapshot is {human(age)} old — data below is not current",
            color="red", size=13)
        print("---")

    # ── 1. problems first, always ────────────────────────────────────────────────────
    P = snap["probes"]
    for p in problems:
        mark = "✗" if p["sev"] == "crit" else "⚠︎"
        attrs = {"size": 13}
        if p["sev"] == "crit":
            attrs["color"] = "red"
        out(f"{mark} {p['text']}", **attrs)
        if p.get("kind") == "cron_failing":
            # Every row is clickable and shows that job's real last errors. A list of names
            # you cannot act on is just a longer way of saying "something is wrong".
            for f in (P.get("crons", {}).get("failing") or [])[:12]:
                age_txt = f"{f['age_h']}h" if f.get("age_h") is not None else "never"
                tag = "‼" if f.get("chronic") else " "
                out(f"-- {tag} {f['errs']}x  {(f.get('name') or '?')[:34]:<34} {(f.get('agent') or 'cmd')[:10]:<10} {age_txt}",
                    size=11, font="Menlo", bash=ACTION, param1="cron",
                    param2=f["job_id"], terminal="true")
        else:
            for d in (p.get("detail") or [])[:6]:
                out(f"-- {d}", size=11, font="Menlo")
    if problems:
        print("---")

    g, c, a, ag, b = (P.get("gateway", {}), P.get("crons", {}), P.get("activity", {}),
                      P.get("agents", {}), P.get("budget", {}))

    # ── 2. the trust line: proof the checks ran, not just that nothing was printed ────
    st = snap.get("selftest", {})
    inv = snap.get("invariants", [])
    inv_ok = sum(1 for i in inv if i["status"] == "ok")
    passed = st.get("checked", 0) - len(st.get("failures", []))
    out(f"✓ {passed}/{st.get('checked', 0)} assertions · {inv_ok}/{len(inv)} invariants",
        size=12)
    for i in inv:
        out(f"-- {'✓' if i['status'] == 'ok' else '✗'} {i['id']}: {i['msg']}",
            size=11, font="Menlo")
    print("---")

    # ── 3. five lines that can actually change ───────────────────────────────────────
    if g.get("pid"):
        mem = ""
        if g.get("footprint_mb") and g.get("cap_fp_mb"):
            mem = f" · {g['footprint_mb']}/{g['cap_fp_mb']} MB ({g.get('cap_used_pct')}%)"
        out(f"Gateway   up {human(g.get('uptime_s'))} · pid {g['pid']}{mem}", size=12)
        out(f"-- RSS {g.get('rss_mb')} MB · footprint {g.get('footprint_mb')} MB",
            size=11, font="Menlo")
        out(f"-- caps {g.get('cap_rss_mb')} / {g.get('cap_fp_mb')} MB "
            f"(read from {g.get('cap_source')})", size=11, font="Menlo")
        out(f"-- last exit {g.get('last_exit')} · ExitTimeOut {g.get('exit_timeout_s')}s "
            f"· log {human(g.get('log_age_s'))} old", size=11, font="Menlo")
        for name, ep in (P.get("endpoints", {}).get("endpoints") or {}).items():
            out(f"-- {'✓' if ep.get('up') else '✗'} {name} {ep.get('http') or ep.get('error','')}",
                size=11, font="Menlo")
    else:
        out("Gateway   DOWN", color="red", size=13)

    if a:
        out(f"Activity  {spark(a.get('series_24h', []))}  {a.get('runs_24h', 0)} runs · "
            f"{a.get('runs_failed_24h', 0)} failed · {a.get('tool_failed_24h', 0)} tool "
            f"fails /24h", size=12, font="Menlo")
        runs = a.get("runs_24h", 0) or 1
        out(f"-- last event {human(a.get('last_event_age_s'))} ago", size=11, font="Menlo")
        out(f"-- agent runs failed {a.get('runs_failed_24h', 0)}/{a.get('runs_24h', 0)} "
            f"({100 * a.get('runs_failed_24h', 0) // runs}%)", size=11, font="Menlo")
        out(f"-- tool actions failed/timed out {a.get('tool_failed_24h', 0)} /24h",
            size=11, font="Menlo")
        last6 = (a.get("series_24h") or [])[-6:]
        out(f"-- runs per hour, last 6h: {' '.join(str(x) for x in last6)}",
            size=11, font="Menlo")

    if c:
        nxt = ""
        if c.get("next_run_ms"):
            when = time.strftime("%H:%M", time.localtime(c["next_run_ms"] / 1000))
            nxt = f" · next {when} {(c.get('next_run_name') or '')[:24]}"
        out(f"Crons     {c.get('enabled', 0)} enabled · {c.get('ok_24h', 0)} ok / "
            f"{c.get('errors_24h', 0)} err (24h){nxt}", size=12)
        for u in (c.get("upcoming") or [])[:5]:
            when = time.strftime("%H:%M", time.localtime(u["at_ms"] / 1000))
            out(f"-- {when}  {(u.get('name') or '?')[:34]:<34} {(u.get('agent') or 'cmd')[:12]}", size=11, font="Menlo")
        # Standing failures live here too, not only under a problem line — a stale single
        # failure stops raising the badge but must never stop being visible.
        fl = c.get("failing") or []
        quiet = [f for f in fl if not f.get("chronic")
                 and (f.get("age_h") is None or f["age_h"] > 24)]
        has_line = any(p.get("kind") == "cron_failing" for p in problems)
        # Two cases, one rule: whatever is NOT raising the badge still has to be reachable
        # from this menu. With a problem line up, that is the aged-out singles it points at
        # ("+N older, see Crons"); with no problem line, it is the whole standing list.
        show = quiet if has_line else fl
        if show:
            label = ("older single failures — not raising the badge" if has_line
                     else "standing failures — not raising the badge")
            out(f"-- ── {label} ──", size=11, font="Menlo")
            for f in show[:12]:
                age_txt = f"{f['age_h']}h" if f.get("age_h") is not None else "never"
                out(f"-- {f['errs']}x  {(f.get('name') or '?')[:34]:<34} {(f.get('agent') or 'cmd')[:10]:<10} {age_txt}",
                    size=11, font="Menlo", bash=ACTION, param1="cron",
                    param2=f["job_id"], terminal="true")
        if c.get("clusters"):
            out("-- ── failure causes, 24h ──", size=11, font="Menlo")
            for cl in c["clusters"][:4]:
                out(f"-- {cl['n']}x {cl['sample'][:70]}", size=11, font="Menlo")

    if ag.get("chain"):
        short = " → ".join(m.split("/")[-1] for m in ag["chain"])
        out(f"Chain     {short}", size=12)
        out(f"-- {ag['count']} agents · {ag['distinct_chains']} distinct chain(s) · "
            f"{ag['allow_count']} models allowed", size=11, font="Menlo")
        for m in ag["chain"]:
            out(f"-- {m}", size=11, font="Menlo")

    bits = []
    if b.get("max_window"):
        bits.append(f"Max {b['max_window']}" + (" (re-tiered)" if b.get("retiered") else ""))
    if b.get("ollama_weekly_pct") is not None:
        bits.append(f"Ollama wk {b['ollama_weekly_pct']}%")
    elif b.get("ollama_error"):
        bits.append(f"Ollama {b['ollama_error']}")
    if bits:
        out("Budget    " + " · ".join(bits), size=12)
        out(f"-- Max window {b.get('max_window')} · state {human(b.get('governor_age_s'))} old",
            size=11, font="Menlo")
        out(f"-- crons re-tiered off Claude: {'YES' if b.get('retiered') else 'no'}",
            size=11, font="Menlo")
        if b.get("ollama_session_pct") is not None:
            out(f"-- Ollama session {b['ollama_session_pct']}% · weekly "
                f"{b.get('ollama_weekly_pct')}% · plan {b.get('ollama_plan', '?')}",
                size=11, font="Menlo")

    pn = P.get("pins", {})
    if pn.get("stores"):
        auto, user = pn.get("auto", 0), pn.get("user", 0)
        # A pin is the one thing on this panel that makes every OTHER panel lie: the
        # agent still shows its configured chain while the session ignores it.
        attrs = {"size": 12}
        if auto:
            attrs["color"] = "orange"
        out(f"Pins      {auto} auto · {user} user · {pn.get('stores')} stores", **attrs)
        out(f"-- auto-pins strip the fallback chain — a pinned session has no failover",
            size=11, font="Menlo")
        for x in (pn.get("samples") or [])[:6]:
            out(f"-- {x['agent'][:14]:<14} {x['ref'][:26]:<26} {x['layer']}",
                size=11, font="Menlo")
        if user:
            out(f"-- {user} user pin(s) — deliberate, never cleared wholesale",
                size=11, font="Menlo")
        by_l = pn.get("by_layer") or {}
        if by_l:
            out("-- " + " · ".join(f"{k} {v}" for k, v in sorted(by_l.items())),
                size=11, font="Menlo")
        out(f"-- 07:00 drift check ran today: "
            f"{'yes' if pn.get('drift_check_ran_today') else 'NO'}", size=11, font="Menlo")
        out("-- Audit pins (read-only)", bash=ACTION, param1="pins",
            terminal="true", size=11, font="Menlo")
    elif "pins" in P:
        out("Pins      unknown — pin store not readable", color="orange", size=12)
        out(f"-- {P['pins'].get('error', 'no data')}", size=11, font="Menlo")

    print("---")

    # ── 4. actions, all through one auditable script ─────────────────────────────────
    et = g.get("exit_timeout_s")
    hint = f" (up to {et}s)" if et else ""
    out(f"Restart gateway{hint}", sfimage="arrow.clockwise", bash=ACTION,
        param1="restart", terminal="false", refresh="true", size=12)
    out("Open gateway log", sfimage="doc.text", bash=ACTION, param1="log",
        terminal="false", size=12)
    url = P.get("endpoints", {}).get("dashboard_url")
    if url:
        out("Open Web UI", sfimage="globe", href=url, size=12)
    out("Run self-test", sfimage="checkmark.seal", bash=ACTION, param1="selftest",
        terminal="true", size=12)
    out("Copy diagnostics", sfimage="doc.on.clipboard", bash=ACTION, param1="copy",
        terminal="false", size=12)

    print("---")
    v = P.get("version", {})
    foot = f"snapshot {human(age)} old · {snap.get('took_ms', '?')}ms · v{v.get('current', '?')}"
    out(foot, size=11, color="gray")
    if v.get("update_available"):
        out(f"Update available: {v['latest']}", sfimage="arrow.down.circle",
            bash="/opt/homebrew/bin/openclaw", param1="update", param2="--yes",
            terminal="true", refresh="true", size=12)


if __name__ == "__main__":
    main()
