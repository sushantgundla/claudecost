#!/bin/bash
# ============================================================================
# claudecost - Claude Code Usage Stats
# ============================================================================
# A zero-dependency bash alternative to `npx ccusage`.
# Reads JSONL session logs from ~/.claude/projects/ and displays:
#   - Total tokens, estimated API cost, active days, cache hit rate
#   - Daily/weekly/monthly cost chart (ASCII bar chart)
#   - Monthly breakdown with per-model info
#   - Token composition (input, output, cache read, cache create)
#
# Requirements: bash, awk, curl
# Works on: macOS (default awk), Linux (gawk)
#
# Usage:
#   ./ccusage.sh                            # daily view
#   ./ccusage.sh --freq monthly             # monthly chart
#   ./ccusage.sh --freq weekly --days 30    # weekly chart, last 30 days
#   ./ccusage.sh --month 2026-02            # specific month only
#   ./ccusage.sh --project my-app           # filter by project name
#   ./ccusage.sh --offline                  # skip LiteLLM, use hardcoded pricing
#
# Pricing: fetches latest from LiteLLM on every run (falls back to hardcoded)
# Dedup strategy: messageId:requestId (matches ccusage npm package)
# ============================================================================

set -euo pipefail

# --- Defaults ---
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
DAYS=""
MONTH=""
PROJECT_FILTER=""
CHART_FREQ="daily"  # daily | weekly | monthly
OFFLINE=false
LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --days)    DAYS="$2"; shift 2 ;;
    --month)   MONTH="$2"; shift 2 ;;
    --project) PROJECT_FILTER="$2"; shift 2 ;;
    --dir)     CLAUDE_DIR="$2"; shift 2 ;;
    --freq)    CHART_FREQ="$2"; shift 2 ;;
    --offline) OFFLINE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--days N] [--month YYYY-MM] [--freq daily|weekly|monthly] [--offline] [--project PATTERN] [--dir PATH]"
      echo ""
      echo "Options:"
      echo "  --days N          Show last N days only"
      echo "  --month YYYY-MM   Show specific month only"
      echo "  --freq FREQ       Chart grouping: daily (default), weekly, monthly"
      echo "  --offline         Skip LiteLLM fetch, use hardcoded pricing"
      echo "  --project PATTERN Filter by project folder name (substring match)"
      echo "  --dir PATH        Custom log directory (default: ~/.claude/projects)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ ! -d "$CLAUDE_DIR" ]]; then
  echo "Error: Claude logs directory not found: $CLAUDE_DIR"
  echo "Set CLAUDE_DIR or use --dir to point to your logs."
  exit 1
fi

# --- Colors ---
DIM='\033[2m'
YELLOW='\033[33m'
RESET='\033[0m'

# --- Fetch LiteLLM pricing (default behavior) ---
PRICING_FILE=""
if [[ "$OFFLINE" != true ]]; then
  echo -e "${DIM}Fetching latest pricing from LiteLLM...${RESET}"
  TMPJSON=$(mktemp)
  TMPTSV=$(mktemp)
  if curl -sS --fail -o "$TMPJSON" "$LITELLM_URL" 2>/dev/null; then
    # Parse JSON into TSV: model\tinput_per_1m\toutput_per_1m\tcache_write_per_1m\tcache_read_per_1m
    awk '
    {
      gsub(/^[ \t]+/, "")
      gsub(/[ \t]+$/, "")
    }
    /^"[a-zA-Z]/ && /": *\{/ {
      if (model != "") print model "|" data
      model = $0
      gsub(/^"/, "", model)
      gsub(/".*/, "", model)
      data = ""
      next
    }
    model != "" && (/cost_per_token/ || /token_cost/) {
      gsub(/[ \t]*"/, "")
      gsub(/: */, "=")
      gsub(/,[ \t]*$/, "")
      data = data $0 "|"
    }
    END { if (model != "") print model "|" data }
    ' "$TMPJSON" | \
    grep -E '^(anthropic/)?claude-' | \
    awk -F"|" '
    {
      model = $1
      inp=0; out=0; cw=0; cr=0
      for (i=2; i<=NF; i++) {
        if ($i == "") continue
        split($i, kv, "=")
        k = kv[1]; v = kv[2] + 0
        if (k == "input_cost_per_token") inp = v
        else if (k == "output_cost_per_token") out = v
        else if (k == "cache_creation_input_token_cost") cw = v
        else if (k == "cache_read_input_token_cost") cr = v
      }
      if (inp > 0 || out > 0) {
        printf "%s\t%.6f\t%.6f\t%.6f\t%.6f\n", model, inp*1000000, out*1000000, cw*1000000, cr*1000000
      }
    }
    ' > "$TMPTSV"
    MODELS_LOADED=$(wc -l < "$TMPTSV" | tr -d ' ')
    echo -e "${DIM}Loaded pricing for $MODELS_LOADED Claude models${RESET}"
    if [[ -s "$TMPTSV" ]]; then
      PRICING_FILE="$TMPTSV"
    fi
  else
    echo -e "${YELLOW}Warning: Could not fetch LiteLLM pricing, using hardcoded defaults${RESET}"
  fi
  rm -f "$TMPJSON"
fi

# --- Date filter setup ---
if [[ -n "$DAYS" ]]; then
  if date --version &>/dev/null 2>&1; then
    DATE_FROM=$(date -d "-${DAYS} days" +%Y-%m-%d)  # GNU/Linux
  else
    DATE_FROM=$(date -v-${DAYS}d +%Y-%m-%d)          # macOS
  fi
fi

# --- Find all JSONL files (including subagent sessions) ---
FIND_CMD="find \"$CLAUDE_DIR\" -name '*.jsonl' -type f"
if [[ -n "$PROJECT_FILTER" ]]; then
  FIND_CMD="$FIND_CMD -path '*${PROJECT_FILTER}*'"
fi

JSONL_FILES=$(eval $FIND_CMD 2>/dev/null)

if [[ -z "$JSONL_FILES" ]]; then
  echo "No JSONL files found in $CLAUDE_DIR"
  exit 1
fi

FILE_COUNT=$(echo "$JSONL_FILES" | wc -l | tr -d ' ')

echo -e "${DIM}Scanning $FILE_COUNT session files...${RESET}"

# --- Extract and aggregate usage data with awk ---
echo "$JSONL_FILES" | xargs awk -v date_from="${DATE_FROM:-}" -v month_filter="${MONTH:-}" -v chart_freq="${CHART_FREQ}" -v pricing_file="${PRICING_FILE:-}" '
BEGIN {
  # --- Load pricing ---
  loaded_live = 0
  if (pricing_file != "") {
    while ((getline line < pricing_file) > 0) {
      n = split(line, f, "\t")
      if (n >= 5) {
        price[f[1],"input"]       = f[2] + 0
        price[f[1],"output"]      = f[3] + 0
        price[f[1],"cache_write"] = f[4] + 0
        price[f[1],"cache_read"]  = f[5] + 0
        loaded_live++
      }
    }
    close(pricing_file)
  }

  if (loaded_live == 0) {
    # Hardcoded fallback pricing (per 1M tokens)
    price["claude-opus-4-6","input"]       = 5.00
    price["claude-opus-4-6","output"]      = 25.00
    price["claude-opus-4-6","cache_write"] = 6.25
    price["claude-opus-4-6","cache_read"]  = 0.50
    price["claude-opus-4-5-20251101","input"]       = 5.00
    price["claude-opus-4-5-20251101","output"]      = 25.00
    price["claude-opus-4-5-20251101","cache_write"] = 6.25
    price["claude-opus-4-5-20251101","cache_read"]  = 0.50
    price["claude-sonnet-4-6","input"]       = 3.00
    price["claude-sonnet-4-6","output"]      = 15.00
    price["claude-sonnet-4-6","cache_write"] = 3.75
    price["claude-sonnet-4-6","cache_read"]  = 0.30
    price["claude-sonnet-4-5-20250929","input"]       = 3.00
    price["claude-sonnet-4-5-20250929","output"]      = 15.00
    price["claude-sonnet-4-5-20250929","cache_write"] = 3.75
    price["claude-sonnet-4-5-20250929","cache_read"]  = 0.30
    price["sonnet","input"]       = 3.00
    price["sonnet","output"]      = 15.00
    price["sonnet","cache_write"] = 3.75
    price["sonnet","cache_read"]  = 0.30
    price["claude-haiku-4-5-20251001","input"]       = 1.00
    price["claude-haiku-4-5-20251001","output"]      = 5.00
    price["claude-haiku-4-5-20251001","cache_write"] = 1.25
    price["claude-haiku-4-5-20251001","cache_read"]  = 0.10
  }

  # Default fallback (always set)
  price["default","input"]       = 3.00
  price["default","output"]      = 15.00
  price["default","cache_write"] = 3.75
  price["default","cache_read"]  = 0.30
}

# --- Portable sort (works on macOS awk which lacks asorti) ---
function sort_keys(arr, sorted,    i, j, n, tmp, k) {
  n = 0
  for (k in arr) { n++; sorted[n] = k }
  for (i = 2; i <= n; i++) {
    tmp = sorted[i]
    j = i - 1
    while (j >= 1 && sorted[j] > tmp) {
      sorted[j+1] = sorted[j]
      j--
    }
    sorted[j+1] = tmp
  }
  return n
}

function extract_num(str, key,    pat, val) {
  pat = "\"" key "\":[0-9]+"
  if (match(str, pat)) {
    val = substr(str, RSTART, RLENGTH)
    gsub(/.*:/, "", val)
    return val + 0
  }
  return 0
}

function extract_str(str, key,    pat, val) {
  pat = "\"" key "\":\"[^\"]*\""
  if (match(str, pat)) {
    val = substr(str, RSTART, RLENGTH)
    gsub(/.*:"/, "", val)
    gsub(/"$/, "", val)
    return val
  }
  return ""
}

function get_price(model, type,    key, m) {
  key = model SUBSEP type
  if (key in price) return price[key]
  key = ("anthropic/" model) SUBSEP type
  if (key in price) return price[key]
  m = model; sub(/-20[0-9]+$/, "", m)
  key = m SUBSEP type
  if (key in price) return price[key]
  key = ("anthropic/" m) SUBSEP type
  if (key in price) return price[key]
  return price["default" SUBSEP type]
}

function model_short(m) {
  if (m ~ /opus/)   return "opus"
  if (m ~ /sonnet/) return "sonnet"
  if (m ~ /haiku/)  return "haiku"
  return "other"
}

function week_start(datestr,    y, m, d, a, jdn, dow, mon_jdn) {
  split(datestr, _dp, "-")
  y = _dp[1] + 0; m = _dp[2] + 0; d = _dp[3] + 0
  a = int((14 - m) / 12)
  y = y + 4800 - a
  m = m + 12 * a - 3
  jdn = d + int((153 * m + 2) / 5) + 365 * y + int(y/4) - int(y/100) + int(y/400) - 32045
  dow = jdn % 7
  mon_jdn = jdn - dow
  return jdn_to_date(mon_jdn)
}

function jdn_to_date(jdn,    a, b, c, d, e, m, day, mon, yr) {
  a = jdn + 32044
  b = int((4*a + 3) / 146097)
  c = a - int(146097*b / 4)
  d = int((4*c + 3) / 1461)
  e = c - int(1461*d / 4)
  m = int((5*e + 2) / 153)
  day = e - int((153*m + 2)/5) + 1
  mon = m + 3 - 12 * int(m/10)
  yr  = 100*b + d - 4800 + int(m/10)
  return sprintf("%04d-%02d-%02d", yr, mon, day)
}

function chart_key(datestr) {
  if (chart_freq == "monthly") return substr(datestr, 1, 7)
  if (chart_freq == "weekly")  return week_start(datestr)
  return datestr
}

# --- Skip non-usage lines early ---
!/\"usage\"/ { next }

{
  # ---- Dedup streaming lines using messageId:requestId ----
  # Claude Code logs multiple JSONL lines per API call (streaming chunks).
  # We deduplicate globally using messageId:requestId as a composite key,
  # matching ccusage strategy. First occurrence wins.

  ts = extract_str($0, "timestamp")
  if (ts == "") {
    if (match($0, /20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]/)) {
      ts = substr($0, RSTART, RLENGTH) "T00:00:00Z"
    } else {
      next
    }
  }
  cur_date = substr(ts, 1, 10)
  cur_ym = substr(cur_date, 1, 7)

  if (date_from != "" && cur_date < date_from) next
  if (month_filter != "" && cur_ym != month_filter) next

  cur_model = extract_str($0, "model")
  if (cur_model == "" || cur_model == "<synthetic>") next

  cur_input   = extract_num($0, "input_tokens")
  cur_output  = extract_num($0, "output_tokens")
  cur_ccreate = extract_num($0, "cache_creation_input_tokens")
  cur_cread   = extract_num($0, "cache_read_input_tokens")

  if (cur_input + cur_output + cur_ccreate + cur_cread == 0) next

  # Build dedup key: messageId:requestId
  msg_id = extract_str($0, "id")
  req_id = extract_str($0, "requestId")
  if (msg_id != "" && req_id != "") {
    dedup_key = msg_id ":" req_id
  } else if (msg_id != "") {
    dedup_key = msg_id ":" NR
  } else {
    dedup_key = "unk_" NR
  }

  if (dedup_key in seen) next
  seen[dedup_key] = 1

  dk_date[dedup_key]    = cur_date
  dk_model[dedup_key]   = cur_model
  dk_input[dedup_key]   = cur_input
  dk_output[dedup_key]  = cur_output
  dk_ccreate[dedup_key] = cur_ccreate
  dk_cread[dedup_key]   = cur_cread
}

END {
  # ---- Aggregate from deduplicated messages ----
  for (dk in dk_date) {
    date    = dk_date[dk]
    model   = dk_model[dk]
    ym      = substr(date, 1, 7)
    input_tok    = dk_input[dk]
    output_tok   = dk_output[dk]
    cache_create = dk_ccreate[dk]
    cache_read   = dk_cread[dk]

    cost_input  = input_tok    * get_price(model, "input")       / 1000000
    cost_output = output_tok   * get_price(model, "output")      / 1000000
    cost_cwrite = cache_create * get_price(model, "cache_write") / 1000000
    cost_cread  = cache_read   * get_price(model, "cache_read")  / 1000000
    line_cost   = cost_input + cost_output + cost_cwrite + cost_cread

    total_input   += input_tok
    total_output  += output_tok
    total_ccreate += cache_create
    total_cread   += cache_read
    total_cost    += line_cost

    day_cost[date]   += line_cost
    day_tokens[date] += input_tok + output_tok + cache_create + cache_read
    active_days[date] = 1

    ck = chart_key(date)
    chart_cost[ck]   += line_cost
    chart_tokens[ck] += input_tok + output_tok + cache_create + cache_read

    month_cost[ym]   += line_cost
    month_tokens[ym] += input_tok + output_tok + cache_create + cache_read

    ms = model_short(model)
    month_models[ym SUBSEP ms] = 1
  }

  total_tokens = total_input + total_output + total_ccreate + total_cread
  num_active = 0
  for (_k in active_days) num_active++
  cache_total = total_cread + total_ccreate
  if (cache_total + total_input > 0)
    cache_hit = total_cread / (total_cread + total_ccreate + total_input) * 100
  else
    cache_hit = 0

  avg_cost = (num_active > 0) ? total_cost / num_active : 0
  avg_tokens = (num_active > 0) ? total_tokens / num_active : 0

  peak_cost = 0; peak_day = ""
  for (d in day_cost) {
    if (day_cost[d] > peak_cost) {
      peak_cost = day_cost[d]
      peak_day = d
    }
  }

  split(peak_day, pd, "-")
  months_arr[1]="Jan"; months_arr[2]="Feb"; months_arr[3]="Mar"
  months_arr[4]="Apr"; months_arr[5]="May"; months_arr[6]="Jun"
  months_arr[7]="Jul"; months_arr[8]="Aug"; months_arr[9]="Sep"
  months_arr[10]="Oct"; months_arr[11]="Nov"; months_arr[12]="Dec"
  peak_label = months_arr[pd[2]+0] " " pd[3]+0

  # ===== HEADER =====
  printf "\n"
  printf "\033[1;36m╔══════════════════════════════════════════════════════════════════╗\033[0m\n"
  printf "\033[1;36m║             ⚡ Claude Code Usage Dashboard ⚡                  ║\033[0m\n"
  if (loaded_live > 0)
    printf "\033[1;36m║           \033[0;2m pricing: LiteLLM (%d models)                  \033[1;36m║\033[0m\n", loaded_live
  else
    printf "\033[1;36m║           \033[0;2m pricing: hardcoded (offline mode)              \033[1;36m║\033[0m\n"
  printf "\033[1;36m╚══════════════════════════════════════════════════════════════════╝\033[0m\n"
  printf "\n"

  # ===== KPI CARDS =====
  printf "\033[1m  ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐\033[0m\n"
  printf "\033[1m  │\033[0m \033[2mTotal tokens\033[0m     \033[1m│\033[0m \033[2mEst. API cost\033[0m    \033[1m│\033[0m \033[2mActive days\033[0m      \033[1m│\033[0m \033[2mCache hit rate\033[0m   \033[1m│\033[0m\n"
  cache_str = sprintf("%.1f%%", cache_hit)
  printf "\033[1m  │\033[0m \033[1;97m%-17s\033[0m\033[1m│\033[0m \033[1;32m$%-16.2f\033[0m\033[1m│\033[0m \033[1;97m%-17s\033[0m\033[1m│\033[0m \033[1;33m%-17s\033[0m\033[1m│\033[0m\n", \
    format_tokens(total_tokens), total_cost, num_active, cache_str
  printf "\033[1m  ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤\033[0m\n"
  printf "\033[1m  │\033[0m \033[2mAvg cost/day\033[0m     \033[1m│\033[0m \033[2mAvg tokens/day\033[0m   \033[1m│\033[0m \033[2mPeak day cost\033[0m    \033[1m│\033[0m \033[2mPeak day\033[0m         \033[1m│\033[0m\n"
  printf "\033[1m  │\033[0m \033[1;32m$%-16.2f\033[0m\033[1m│\033[0m \033[1;97m%-17s\033[0m\033[1m│\033[0m \033[1;31m$%-16.2f\033[0m\033[1m│\033[0m \033[1;97m%-17s\033[0m\033[1m│\033[0m\n", \
    avg_cost, format_tokens(avg_tokens), peak_cost, peak_label
  printf "\033[1m  └──────────────────┴──────────────────┴──────────────────┴──────────────────┘\033[0m\n"

  # ===== COST BAR CHART =====
  if (chart_freq == "weekly")
    freq_label = "Weekly"
  else if (chart_freq == "monthly")
    freq_label = "Monthly"
  else
    freq_label = "Daily"
  printf "\n\033[1m  📊 %s Cost (USD)\033[0m\n\n", freq_label

  n = sort_keys(chart_cost, sorted_buckets)

  max_cost = 0
  for (i = 1; i <= n; i++) {
    if (chart_cost[sorted_buckets[i]] > max_cost)
      max_cost = chart_cost[sorted_buckets[i]]
  }

  bar_width = 40
  if (max_cost <= 0) max_cost = 1

  for (i = 1; i <= n; i++) {
    bk = sorted_buckets[i]
    c = chart_cost[bk]

    if (chart_freq == "monthly") {
      split(bk, _bp, "-")
      dlabel = sprintf("%-8s", months_arr[_bp[2]+0] " " _bp[1])
    } else if (chart_freq == "weekly") {
      split(bk, _bp, "-")
      dlabel = sprintf("%-8s", months_arr[_bp[2]+0] " " _bp[3]+0)
    } else {
      split(bk, _bp, "-")
      dlabel = months_arr[_bp[2]+0] " " sprintf("%2d", _bp[3]+0)
    }

    blen = int(c / max_cost * bar_width + 0.5)
    if (blen < 1 && c > 0) blen = 1

    if (c > max_cost * 0.7)
      color = "\033[31m"   # red
    else if (c > max_cost * 0.4)
      color = "\033[33m"   # yellow
    else
      color = "\033[36m"   # cyan

    bar = ""
    for (b = 0; b < blen; b++) bar = bar "█"

    printf "  %s │ %s%-*s\033[0m $%.2f\n", dlabel, color, bar_width, bar, c
  }

  # ===== MONTHLY BREAKDOWN =====
  printf "\n\033[1m  📅 Monthly Breakdown\033[0m\n\n"
  printf "  \033[2m%-10s %6s %12s %12s   %-30s\033[0m\n", "Month", "Days", "Tokens", "Cost", "Models"
  printf "  \033[2m─────────────────────────────────────────────────────────────────────\033[0m\n"

  nm = sort_keys(month_cost, sorted_months)
  for (i = 1; i <= nm; i++) {
    ym = sorted_months[i]
    split(ym, mp, "-")
    mlabel = months_arr[mp[2]+0] " " mp[1]

    mdays = 0
    for (d in active_days) {
      if (substr(d, 1, 7) == ym) mdays++
    }

    mlist = ""
    if ((ym SUBSEP "haiku") in month_models) mlist = mlist "haiku"
    if ((ym SUBSEP "sonnet") in month_models) {
      if (mlist != "") mlist = mlist ", "
      mlist = mlist "sonnet"
    }
    if ((ym SUBSEP "opus") in month_models) {
      if (mlist != "") mlist = mlist ", "
      mlist = mlist "opus"
    }
    if ((ym SUBSEP "other") in month_models) {
      if (mlist != "") mlist = mlist ", "
      mlist = mlist "other"
    }

    printf "  %-10s %6d %12s \033[32m$%10.2f\033[0m   %s\n", \
      mlabel, mdays, format_tokens(month_tokens[ym]), month_cost[ym], mlist
  }

  # ===== TOKEN COMPOSITION =====
  printf "\n\033[1m  🔤 Token Composition\033[0m\n\n"
  printf "  \033[2m%-20s %14s %8s\033[0m\n", "Type", "Tokens", "Share"
  printf "  \033[2m──────────────────────────────────────────\033[0m\n"

  if (total_tokens > 0) {
    printf "  %-20s %14s %7.1f%%\n", "Cache read",    format_tokens(total_cread),   total_cread/total_tokens*100
    printf "  %-20s %14s %7.1f%%\n", "Cache create",  format_tokens(total_ccreate), total_ccreate/total_tokens*100
    printf "  %-20s %14s %7.1f%%\n", "Input",         format_tokens(total_input),   total_input/total_tokens*100
    printf "  %-20s %14s %7.1f%%\n", "Output",        format_tokens(total_output),  total_output/total_tokens*100
  }

  printf "\n"
}

function format_tokens(t) {
  if (t >= 1000000000) return sprintf("%.1fB", t/1000000000)
  if (t >= 1000000)    return sprintf("%.1fM", t/1000000)
  if (t >= 1000)       return sprintf("%.1fK", t/1000)
  return sprintf("%d", t)
}
' 2>/dev/null

# Clean up temp pricing file
[[ -n "${TMPTSV:-}" ]] && rm -f "$TMPTSV" 2>/dev/null

echo ""
