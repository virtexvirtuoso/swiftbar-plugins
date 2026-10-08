#!/bin/bash
# SwiftBar memory monitor
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

# Palette: only alert red. Everything else uses system menu label color
# (auto-adapts to light/dark mode). Hierarchy is size + spacing, not color.
ALERT="#FF3B30"

# Timing
SAMPLE_INTERVAL=120     # Sparkline sample cadence (~1 hour window at 30 samples)

# Paths
HISTORY_FILE="/tmp/swiftbar-mem-history"
CLUSTER_CACHE="/tmp/swiftbar-cluster.cache"
CLUSTER_TTL=60

# Machine-invariant
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 17179869184)
total_gb=$(awk -v b="$total_bytes" 'BEGIN {printf "%.0f", b/1073741824}')

# Detect self for cluster view
this_host=$(hostname -s 2>/dev/null)
self_node=""; self_alias=""
case "$this_host" in
    *[Mm]ac-[Mm]ini*|*[Mm]acmini*)                self_node="mini"; self_alias="macmini" ;;
    *[Mm]ac[Bb]ook-[Pp]ro*|*[Mm]ac[Bb]ook*|*FFV*) self_node="mbp";  self_alias="mbp"     ;;
esac

# Memory pressure stat command — works on macOS + Linux. Base64'd for nested SSH.
STAT_CMD='if [ "$(uname)" = Darwin ]; then memory_pressure 2>/dev/null | awk "/System-wide memory free percentage/{gsub(/%/,\"\",\$NF); printf \"%d\", 100-\$NF}"; else awk "/MemAvailable/{f=\$2} /MemTotal/{t=\$2} END{if(t>0) printf \"%d\", (1-f/t)*100}" /proc/meminfo 2>/dev/null; fi'
STAT_B64=$(printf '%s' "$STAT_CMD" | base64 | tr -d '\n')
SSH_OPTS="-o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# Spark glyphs
spark_chars=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

# ─── fast: called every tick ────────────────────────────────────────────
compute_fast() {
    free_pct=$(memory_pressure 2>/dev/null | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print $NF}')
    used_pct=$((100 - ${free_pct:-0}))

    if   [[ "$used_pct" -ge 90 ]]; then alert_mode=1
    else                                alert_mode=0
    fi
}

# ─── heavy: called every REFRESH_INTERVAL ───────────────────────────────
compute_heavy() {
    # vm_stat
    eval "$(vm_stat 2>/dev/null | awk -v ps="$PAGE_SIZE" '
        /Pages active/                 {gsub(/\./,"",$NF); active=$NF}
        /Pages wired down/             {gsub(/\./,"",$NF); wired=$NF}
        /Pages occupied by compressor/ {gsub(/\./,"",$NF); comp=$NF}
        END {
            printf "used_gb=%.1f\n", (active+wired)*ps/1073741824
            printf "comp_gb=%.1f\n", comp*ps/1073741824
        }')"

    # Swap
    eval "$(sysctl vm.swapusage 2>/dev/null | awk '
        {
            for(i=1;i<=NF;i++) {
                if($i=="used"){sub(/M/,"",$(i+2)); used=$(i+2)+0}
            }
            printf "swap_used_mb=%d\nswap_used_gb=%.1f\n", used, used/1024
        }')"

    # Uptime
    uptime_str=$(uptime | awk -F'up ' '{sub(/, *[0-9]+ users.*/, "", $2); sub(/, *load.*/, "", $2); gsub(/^ +| +$/, "", $2); print $2}' | awk -F',' '{print $1}')

    # Sparkline sample (only at SAMPLE_INTERVAL cadence to preserve ~1h window)
    now_ts=$(date +%s)
    if [[ $((now_ts - last_sample_time)) -ge $SAMPLE_INTERVAL ]]; then
        echo "$used_pct" >> "$HISTORY_FILE"
        tail -n 30 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" 2>/dev/null && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        last_sample_time=$now_ts
    fi
    sparkline=""; spark_count=0
    while IFS= read -r pct; do
        [[ -z "$pct" ]] && continue
        level=$(( pct * 7 / 100 ))
        [[ $level -gt 7 ]] && level=7
        [[ $level -lt 0 ]] && level=0
        sparkline+="${spark_chars[$level]}"
        spark_count=$((spark_count + 1))
    done < "$HISTORY_FILE"
    # Right-align sparkline: pad left so newest sample anchors the same column
    spark_pad=$((30 - spark_count))
    [[ $spark_pad -lt 0 ]] && spark_pad=0
    spark_lead=$(printf "%${spark_pad}s" "")

    # Processes + GUI apps (single ps call)
    ps_output=$(ps -axo rss,comm 2>/dev/null)

    top_procs=$(echo "$ps_output" | awk '
        NR==1 {next}
        {
            n = split($2, parts, "/"); name = parts[n]
            if (name ~ /^Brave Browser Helper/)    name = "Brave"
            else if (name ~ /^TradingView Helper/) name = "TradingView"
            else if (name ~ /^Notion Helper/)      name = "Notion"
            else if (name ~ /^Discord Helper/)     name = "Discord"
            else if (name ~ /^Spotify Helper/)     name = "Spotify"
            else if (name ~ /^Dropbox Helper/)     name = "Dropbox"
            else if (name ~ /^Claude Helper/)      name = "Claude"
            if      (name == "Brave Browser")        name = "Brave"
            else if (name == "claude-code@latest")   name = "Claude Code"
            else if (name == "iTerm2")               name = "iTerm"
            else if (name == "mDNSResponder")        name = "mDNS"
            else if (name ~ /^com\.apple\.Virtualization/) name = "VM"
            agg[name] += $1
        }
        END { for (k in agg) printf "%d\t%s\n", agg[k], k }' | sort -rn | head -3 | awk '
        {
            mb = int($1/1024)
            name = $2; for (i=3;i<=NF;i++) name = name" "$i
            if (mb >= 1024) printf "%-22s%7.1f GB | size=13 font=Menlo\n", name, mb/1024
            else            printf "%-22s%7d MB | size=13 font=Menlo\n", name, mb
        }')

    running_gui_apps=$(echo "$ps_output" | awk '
        NR==1 {next}
        {
            idx = index($0, $2); if (idx == 0) next
            cmd = substr($0, idx)
            if (match(cmd, /\/Applications\/[^\/]+\.app/)) {
                appdir = substr(cmd, RSTART, RLENGTH)
                n = split(appdir, p, "/"); name = p[n]
                gsub(/\.app$/, "", name)
                agg[name] += $1
            }
        }
        END { for (k in agg) printf "%d|%s\n", agg[k], k }' | sort -rn | head -10)

    # Cluster (cached 60s, parallel SSH)
    cluster_age=$CLUSTER_TTL
    [[ -f "$CLUSTER_CACHE" ]] && cluster_age=$(( $(date +%s) - $(stat -f%m "$CLUSTER_CACHE" 2>/dev/null || echo 0) ))

    if [[ ! -f "$CLUSTER_CACHE" ]] || [[ "$cluster_age" -ge "$CLUSTER_TTL" ]]; then
        nodes=(
            "mini|macmini|"
            "mbp|mbp|"
            "x1|x1pro|macmini"
            "pi|pi|macmini"
            "vps|vps|macmini"
        )
        tmpdir=$(mktemp -d 2>/dev/null)
        if [[ -n "$tmpdir" ]]; then
            for i in "${!nodes[@]}"; do
                IFS='|' read -r name target via <<< "${nodes[$i]}"
                if [[ "$name" == "$self_node" ]]; then
                    echo "${name}|●|${used_pct}" > "$tmpdir/$i"
                else
                    (
                        [[ "$via" == "$self_alias" ]] && via=""
                        if [[ -n "$via" ]]; then
                            pct=$(ssh $SSH_OPTS "$via" "ssh $SSH_OPTS $target 'echo $STAT_B64 | base64 -d | bash'" 2>/dev/null | tr -cd '0-9')
                        else
                            pct=$(ssh $SSH_OPTS "$target" "echo $STAT_B64 | base64 -d | bash" 2>/dev/null | tr -cd '0-9')
                        fi
                        if [[ -n "$pct" ]] && [[ "$pct" =~ ^[0-9]+$ ]]; then
                            echo "${name}|●|${pct}"
                        else
                            echo "${name}|○|—"
                        fi
                    ) > "$tmpdir/$i" &
                fi
            done
            wait
            { for i in "${!nodes[@]}"; do cat "$tmpdir/$i" 2>/dev/null; done } > "$CLUSTER_CACHE"
            rm -rf "$tmpdir"
        fi
    fi

    # Build vertical cluster table: one line per node -> "name  dot   val%"
    # 5-char name col (left), space, dot, two-space gap, right-aligned 3-char value + %
    cluster_lines=()
    while IFS='|' read -r n dot pct; do
        [[ -z "$n" ]] && continue
        if [[ "$pct" == "—" ]]; then
            cluster_lines+=("$(printf "%-5s %s    —" "$n" "$dot")")
        else
            cluster_lines+=("$(printf "%-5s %s  %3s%%" "$n" "$dot" "$pct")")
        fi
    done < "$CLUSTER_CACHE"
}

# ─── icon selection ─────────────────────────────────────────────────────
pick_icon() {
    if   [[ "$alert_mode" -eq 1 ]];    then sfimage="exclamationmark.triangle.fill"
    elif [[ "$used_pct" -ge 75 ]]; then sfimage="gauge.with.dots.needle.67percent"
    elif [[ "$used_pct" -ge 50 ]]; then sfimage="gauge.with.dots.needle.50percent"
    elif [[ "$used_pct" -ge 25 ]]; then sfimage="gauge.with.dots.needle.33percent"
    else                                sfimage="gauge.with.dots.needle.0percent"
    fi
}

# ─── render ─────────────────────────────────────────────────────────────
emit_menu() {
    # Menu bar icon
    if [[ "$alert_mode" -eq 1 ]]; then
        echo "${used_pct}% | sfimage=${sfimage} sfcolor=${ALERT} size=13"
    else
        echo "${used_pct}% | sfimage=${sfimage} size=13"
    fi
    echo "---"

    # THE number
    if [[ "$alert_mode" -eq 1 ]]; then
        echo "${used_gb} / ${total_gb} GB | size=17 color=${ALERT}"
    else
        echo "${used_gb} / ${total_gb} GB | size=17"
    fi

    # Qualifier (swap only if meaningful)
    qualifier="${free_pct:-0}% free"
    [[ "${swap_used_mb:-0}" -gt 100 ]] && qualifier+="  ·  ${swap_used_gb} GB swap"
    echo "${qualifier} | size=12"

    # Sparkline (right-aligned via spark_lead)
    echo "${spark_lead}${sparkline}   past hour | size=13 font=Menlo"
    echo "---"

    # Cluster (vertical table)
    if [[ ${#cluster_lines[@]} -gt 0 ]]; then
        for cline in "${cluster_lines[@]}"; do
            echo "${cline} | size=13 font=Menlo"
        done
        echo "---"
    fi

    # Top 3
    echo "$top_procs"
    echo "---"

    # Actions
    echo "Run Watchdog | sfimage=shield.checkered bash=$HOME/scripts/memory-watchdog.sh terminal=false refresh=true"
    echo "Tools"
    echo "-- Purge Memory | sfimage=trash.circle bash=$HOME/scripts/purge-memory.sh terminal=false refresh=true"
    echo "-- Restart mDNSResponder | sfimage=arrow.clockwise bash=$HOME/scripts/restart-mdns.sh terminal=false refresh=true"
    echo "-- Activity Monitor | sfimage=gauge.with.dots.needle.bottom.50percent bash=/usr/bin/open args=-a args='Activity Monitor' terminal=false"

    echo "Quit an app…"
    QUIT_SCRIPT="$HOME/scripts/quit-app.sh"
    EXCLUDE='^(Finder|SwiftBar|Dock|Xcode|Activity Monitor|System Settings|System Preferences)$'
    while IFS='|' read -r rss name; do
        [[ -z "$name" ]] && continue
        [[ "$name" =~ $EXCLUDE ]] && continue
        mb=$((rss / 1024))
        esc_name="${name// /\\ }"
        if [[ "$mb" -ge 1024 ]]; then
            display=$(awk -v m="$mb" 'BEGIN{printf "%.1f GB", m/1024}')
        else
            display="${mb} MB"
        fi
        echo "-- ${name}    ${display} | size=12 bash=${QUIT_SCRIPT} param1=${esc_name} terminal=false refresh=true"
    done <<< "$running_gui_apps"

    echo "---"
    echo "Up ${uptime_str} | size=11"
}

# ─── run once (refreshed on filename interval) ─────────────────────────
last_sample_time=$(stat -f%m "$HISTORY_FILE" 2>/dev/null || echo 0)

compute_fast
compute_heavy
[[ "${ALERT_TEST:-0}" -eq 1 ]] && alert_mode=1
pick_icon
emit_menu
