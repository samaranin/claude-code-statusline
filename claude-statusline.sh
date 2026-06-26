#!/usr/bin/env bash
# claude-statusline.sh — cship-equivalent statusline built on the official
# Claude Code statusLine contract (JSON on stdin) + the OAuth usage API.
#
# Line 1: directory  git-branch git-status  langs(py/node/rust)  time
# Line 2: 🤖 model  💰 cost  context-bar  ⌛5h 📅7d  🟢Sonnet/🔴Opus/🟣Cowork  📝 +/-
#
# Usage limits come from https://api.anthropic.com/api/oauth/usage (undocumented),
# cached briefly and refreshed in the background so rendering never blocks.
# Per-profile creds are picked up automatically via $CLAUDE_CONFIG_DIR.

set -o pipefail
export LC_NUMERIC=C   # force '.' decimals; the user's locale uses ',' which breaks printf %f

# ---- read the statusLine JSON from stdin -----------------------------------
IN="$(cat)"
jqv() { jq -r "$1 // empty" <<<"$IN" 2>/dev/null; }

CWD="$(jqv '.workspace.current_dir')"; [ -z "$CWD" ] && CWD="$(jqv '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
MODEL="$(jqv '.model.display_name')"; [ -z "$MODEL" ] && MODEL="Claude"
COST="$(jqv '.cost.total_cost_usd')"; [ -z "$COST" ] && COST=0
ADDED="$(jqv '.cost.total_lines_added')"; [ -z "$ADDED" ] && ADDED=0
REMOVED="$(jqv '.cost.total_lines_removed')"; [ -z "$REMOVED" ] && REMOVED=0
TRANSCRIPT="$(jqv '.transcript_path')"
EFFORT="$(jqv '.effort.level')"                       # live reasoning effort (absent on models w/o it)
CTXP="$(jqv '.context_window.used_percentage')"       # native context %, denom-aware (200k vs 1M)
# stdin already carries 5h/7d limits (epoch resets) — used as a fallback when the API is unavailable
SL_5HP="$(jqv '.rate_limits.five_hour.used_percentage')";  SL_5HR="$(jqv '.rate_limits.five_hour.resets_at')"
SL_7DP="$(jqv '.rate_limits.seven_day.used_percentage')";  SL_7DR="$(jqv '.rate_limits.seven_day.resets_at')"

# ---- colors ----------------------------------------------------------------
R=$'\033[0m'; B=$'\033[1m'
C_DIR=$'\033[1;36m'; C_GB=$'\033[1;35m'; C_GS=$'\033[1;31m'
C_PY=$'\033[1;33m'; C_NODE=$'\033[1;32m'; C_RUST=$'\033[1;31m'
C_TIME=$'\033[38;2;169;177;214m'        # #a9b1d6
C_MODEL=$'\033[1;36m'
C_EFFORT=$'\033[38;2;187;154;247m'      # #bb9af7 purple
C_BASE=$'\033[38;2;169;177;214m'        # #a9b1d6
C_CTX=$'\033[38;2;125;207;255m'         # #7dcfff
C_WARN=$'\033[38;2;224;175;104m'        # #e0af68
C_CRIT=$'\033[1;38;2;247;118;142m'      # #f7768e bold

# pick a style by thresholds: pick <pct> <warn> <crit> <basecolor>
pick() { awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{print (v>=c)?"crit":(v>=w)?"warn":"base"}'; }

# ---- line 1: directory -----------------------------------------------------
disp="$CWD"
case "$disp" in "$HOME"*) disp="~${disp#$HOME}";; esac
IFS='/' read -ra parts <<<"$disp"
n=${#parts[@]}
if [ "$n" -gt 3 ]; then disp="${parts[n-3]}/${parts[n-2]}/${parts[n-1]}"; fi
LINE1="${C_DIR}${disp}${R}"

# ---- line 1: git -----------------------------------------------------------
if br="$(git -C "$CWD" symbolic-ref --quiet --short HEAD 2>/dev/null)" || \
   br="$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null)"; then
  LINE1+=" on ${C_GB} ${br}${R}"
  st="$(git -C "$CWD" status --porcelain 2>/dev/null)"
  flags=""
  grep -q '^.[MD]' <<<"$st" && flags+="!"          # unstaged changes
  grep -q '^[MADRC]' <<<"$st" && flags+="+"         # staged
  grep -q '^??' <<<"$st" && flags+="?"              # untracked
  ab="$(git -C "$CWD" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
  behind="$(awk '{print $1}' <<<"$ab")"; ahead="$(awk '{print $2}' <<<"$ab")"
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && flags+="⇡${ahead}"
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && flags+="⇣${behind}"
  [ -n "$flags" ] && LINE1+=" ${C_GS}[${flags}]${R}"
fi

# ---- line 1: language versions (only when project markers exist) -----------
shopt -s nullglob
if compgen -G "$CWD/*.py" >/dev/null || [ -f "$CWD/pyproject.toml" ] || [ -f "$CWD/requirements.txt" ] || [ -f "$CWD/setup.py" ]; then
  v="$(python3 --version 2>/dev/null | awk '{print $2}')"; [ -n "$v" ] && LINE1+=" via ${C_PY} v${v}${R}"
fi
if [ -f "$CWD/package.json" ] || compgen -G "$CWD/*.js" >/dev/null || compgen -G "$CWD/*.ts" >/dev/null; then
  v="$(node --version 2>/dev/null | tr -d 'v')"; [ -n "$v" ] && LINE1+=" via ${C_NODE} v${v}${R}"
fi
if [ -f "$CWD/Cargo.toml" ]; then
  v="$(rustc --version 2>/dev/null | awk '{print $2}')"; [ -n "$v" ] && LINE1+=" via ${C_RUST} v${v}${R}"
fi
shopt -u nullglob

# ---- line 1: time ----------------------------------------------------------
LINE1+=" ${C_TIME}🕐 $(date +%H:%M)${R}"

# ---- line 2: model + cost --------------------------------------------------
LINE2="${C_MODEL}🤖 ${MODEL}${R}"
[ -n "$EFFORT" ] && LINE2+="  ${C_EFFORT}🧠 ${EFFORT}${R}"
costp="$(printf '%.2f' "$COST" 2>/dev/null || echo 0.00)"
case "$(pick "$costp" 10 25)" in crit) cc=$C_CRIT;; warn) cc=$C_WARN;; *) cc=$C_BASE;; esac
LINE2+="  ${cc}💰 \$${costp}${R}"

# ---- line 2: context bar ---------------------------------------------------
# Prefer the native context_window.used_percentage from stdin (denom-aware:
# 200k vs 1M). Fall back to parsing the transcript only if it's absent.
CTX_PCT=0
if [ -n "$CTXP" ]; then
  CTX_PCT="$(printf '%.0f' "$CTXP" 2>/dev/null || echo 0)"
elif [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  used="$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | jq -rs '
    [ .[] | select(.message.usage != null) ] | last // empty
    | (.message.usage)
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
       + (.cache_creation_input_tokens // 0))' 2>/dev/null)"
  [ -n "$used" ] && CTX_PCT="$(awk -v u="$used" 'BEGIN{d=(u>200000)?1000000:200000; p=u/d*100; printf "%d", (p>100?100:p)}')"
fi
filled="$(awk -v p="$CTX_PCT" 'BEGIN{printf "%d", p/10}')"
bar=""; for ((i=0;i<10;i++)); do [ "$i" -lt "$filled" ] && bar+="█" || bar+="░"; done
case "$(pick "$CTX_PCT" 40 70)" in crit) bc=$C_CRIT;; warn) bc=$C_WARN;; *) bc=$C_CTX;; esac
LINE2+="  ${bc}${bar} ${CTX_PCT}%${R}"

# ---- usage limits (cached + background refresh) ----------------------------
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CREDS="$CFG/.credentials.json"
hash="$(printf '%s' "$CFG" | cksum | awk '{print $1}')"
CACHE="${TMPDIR:-/tmp}/claude-statusline-usage-${hash}.json"
TTL=45

fetch_usage() { # writes JSON to $1 atomically
  local out="$1" tok
  tok="$(jq -r '.claudeAiOauth.accessToken' "$CREDS" 2>/dev/null)"
  [ -z "$tok" ] || [ "$tok" = "null" ] && return 1
  curl -s --max-time 2 https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" -o "${out}.tmp" \
    && jq -e '(.error == null) and (.five_hour != null or .seven_day != null or ((.limits // []) | length > 0))' "${out}.tmp" >/dev/null 2>&1 \
    && mv "${out}.tmp" "$out" || { rm -f "${out}.tmp"; return 1; }
}

# Single-flight, non-blocking refresh:
#  - the statusline renders many times/sec; without a lock every render while the
#    cache is stale would spawn its own curl → API spam / rate-limit.
#  - LOCK (atomic mkdir) ensures at most ONE in-flight fetch.
#  - FAIL marker imposes a cooldown so a failing/rate-limited API isn't retried each render.
#  - fetch always runs in the background → rendering never blocks on the network.
LOCK="${CACHE}.lock"; FAIL="${CACHE}.fail"; COOLDOWN=120; LOCK_STALE=15
NOW=$(date +%s)
age_of() { local f="$1"; { [ -e "$f" ] && echo $(( NOW - $(stat -c %Y "$f" 2>/dev/null || echo "$NOW") )); } || echo 999999; }

if [ -f "$CREDS" ]; then
  need=0
  { [ ! -f "$CACHE" ] || [ "$(age_of "$CACHE")" -ge "$TTL" ]; } && need=1
  # back off while a recent failure cooldown is active
  { [ -f "$FAIL" ] && [ "$(age_of "$FAIL")" -lt "$COOLDOWN" ]; } && need=0
  if [ "$need" = 1 ]; then
    # clear an abandoned lock (a fetch that died mid-flight)
    { [ -d "$LOCK" ] && [ "$(age_of "$LOCK")" -ge "$LOCK_STALE" ]; } && rmdir "$LOCK" 2>/dev/null
    # acquire the lock atomically; only the winner fetches, in the background
    if mkdir "$LOCK" 2>/dev/null; then
      ( fetch_usage "$CACHE" && rm -f "$FAIL" || : >"$FAIL"; rmdir "$LOCK" 2>/dev/null ) >/dev/null 2>&1 &
    fi
  fi
fi

# relative "time until reset", e.g. 2h / 45m / 3d. Accepts an ISO string (API cache)
# or a unix epoch (stdin rate_limits).
rel() {
  local ts="$1" sec d
  { [ -z "$ts" ] || [ "$ts" = "null" ] || [ "$ts" = "-" ]; } && { echo ""; return; }
  if [[ "$ts" =~ ^[0-9]+$ ]]; then sec="$ts"; else sec="$(date -d "$ts" +%s 2>/dev/null || echo 0)"; fi
  d=$(( sec - $(date +%s) ))
  [ "$d" -le 0 ] && { echo "now"; return; }
  # include minutes (cship-style): 6d5h / 1h23m / 45m
  if [ "$d" -ge 86400 ]; then
    local days=$((d/86400)) hrs=$(((d%86400)/3600))
    [ "$hrs" -gt 0 ] && echo "${days}d${hrs}h" || echo "${days}d"
  elif [ "$d" -ge 3600 ]; then
    local hrs=$((d/3600)) mins=$(((d%3600)/60))
    [ "$mins" -gt 0 ] && echo "${hrs}h${mins}m" || echo "${hrs}h"
  else
    echo "$((d/60))m"
  fi
}

limit_seg() { # symbol label pct resets_at  -> styled "sym label pct% (reset)"
  local sym="$1" label="$2" pct="$3" reset="$4" col
  case "$(pick "$pct" 60 80)" in crit) col=$C_CRIT;; warn) col=$C_WARN;; *) col=$C_BASE;; esac
  local r; r="$(rel "$reset")"
  if [ -n "$r" ]; then printf '%s%s %s %.0f%% (%s)%s' "$col" "$sym" "$label" "$pct" "$r" "$R"
  else printf '%s%s %s %.0f%%%s' "$col" "$sym" "$label" "$pct" "$R"; fi
}

f5p=- f5r=- d7p=- d7r=- sop=- sor=- snp=- snr=- cop=- cor=-
if [ -f "$CACHE" ]; then
  # NOTE: keep FIXED positions — do NOT use `// empty` (it drops null entries and
  # shifts every later field, mislabelling Sonnet/Opus/Cowork). Map null -> "-" instead.
  read -r f5p f5r d7p d7r sop sor snp snr cop cor < <(jq -r '
    def u(x): x.utilization; def t(x): x.resets_at;
    [ u(.five_hour), t(.five_hour),
      u(.seven_day), t(.seven_day),
      u(.seven_day_opus), t(.seven_day_opus),
      u(.seven_day_sonnet), t(.seven_day_sonnet),
      u(.seven_day_cowork), t(.seven_day_cowork) ]
    | map(if . == null then "-" else tostring end) | @tsv' "$CACHE" 2>/dev/null \
    | tr '\t' ' ')
fi
# Fall back to stdin rate_limits for 5h/7d when the API cache has no value
# (first run, persistent rate-limit, etc.). Per-model stays API-only.
{ [ "$f5p" = "-" ] || [ -z "$f5p" ]; } && [ -n "$SL_5HP" ] && { f5p="$SL_5HP"; f5r="${SL_5HR:--}"; }
{ [ "$d7p" = "-" ] || [ -z "$d7p" ]; } && [ -n "$SL_7DP" ] && { d7p="$SL_7DP"; d7r="${SL_7DR:--}"; }

[ "$f5p" != "-" ] && [ -n "$f5p" ] && LINE2+="  $(limit_seg '⌛' '5h' "$f5p" "$f5r")"
[ "$d7p" != "-" ] && [ -n "$d7p" ] && LINE2+=" $(limit_seg '📅' '7d' "$d7p" "$d7r")"
[ "$snp" != "-" ] && [ -n "$snp" ] && LINE2+=" $(limit_seg '🟢' 'Sonnet' "$snp" "$snr")"
[ "$sop" != "-" ] && [ -n "$sop" ] && LINE2+=" $(limit_seg '🔴' 'Opus' "$sop" "$sor")"
[ "$cop" != "-" ] && [ -n "$cop" ] && LINE2+=" $(limit_seg '🟣' 'Cowork' "$cop" "$cor")"

# ---- line 2: lines changed -------------------------------------------------
LINE2+="  ${C_BASE}📝 +${ADDED}/-${REMOVED}${R}"

printf '%b\n%b\n' "$LINE1" "$LINE2"
