#!/bin/sh
input=$(cat)
echo "$input" > /tmp/statusline-debug.json

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
cache_write=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')

# Git branch with clean/dirty indicator
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    if git -C "$cwd" status --porcelain 2>/dev/null | grep -q .; then
      git_info="⑆ \033[31m$branch\033[0m"
    else
      git_info="⑆ \033[32m$branch\033[0m"
    fi
  fi
fi

# Session cost: prefer cost.total_cost_usd from JSON, fall back to token-based calculation
# Fallback pricing per million tokens (claude-sonnet-4 / sonnet-4-5 / sonnet-4-6 tiers)
# Input: $3.00, Output: $15.00, Cache write: $3.75, Cache read: $0.30
cost_info=""
total_cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$total_cost_usd" ] && [ "$total_cost_usd" != "null" ]; then
  cost=$(awk -v c="$total_cost_usd" 'BEGIN { printf "%.4f", c }')
  cost_info="\$${cost}"
elif command -v awk > /dev/null 2>&1 && [ "$total_input" != "0" -o "$total_output" != "0" ]; then
  cost=$(awk -v inp="$total_input" -v out="$total_output" -v cw="$cache_write" -v cr="$cache_read" \
    'BEGIN { cost = (inp/1000000)*3.00 + (out/1000000)*15.00 + (cw/1000000)*3.75 + (cr/1000000)*0.30; printf "%.4f", cost }')
  cost_info="\$${cost}"
fi

# Context usage progress bar
ctx_info=""
if [ -n "$used" ] && [ "$used" != "null" ]; then
  ctx_info=$(awk -v pct="$used" 'BEGIN {
    total = 10
    filled = int(pct / 100 * total + 0.5)
    if (filled > total) filled = total
    bar = ""
    for (i = 0; i < filled; i++) bar = bar "\342\226\210"
    for (i = filled; i < total; i++) bar = bar "\342\226\221"
    if (pct >= 80) color = "\033[31m"
    else if (pct >= 50) color = "\033[33m"
    else color = ""
    reset = (color != "") ? "\033[0m" : ""
    printf "%s%s %d%%%s", color, bar, int(pct), reset
  }')
fi

# Model info: extract family name only (e.g. "Sonnet", "Haiku", "Opus")
# Display name format is "Claude <Family> <Version> (...)", strip "Claude" prefix then take first word
model_info=""
if [ -n "$model" ] && [ "$model" != "null" ]; then
  model_family=$(echo "$model" | sed 's/^[Cc]laude[[:space:]]*//' | awk '{print $1}')
  model_info="🤖 $model_family"
fi

# Current working directory basename
cwd_info="📁 $(basename "$cwd")"

# Row 1: cwd | git branch
row1=""
for part in "$cwd_info" "$git_info"; do
  if [ -n "$part" ]; then
    if [ -n "$row1" ]; then
      row1="$row1 | $part"
    else
      row1="$part"
    fi
  fi
done

# Rate limit usage (5h and 7d) with mini progress bars
rate_info=""
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
make_mini_bar() {
  awk -v pct="$1" -v label="$2" 'BEGIN {
    total = 5
    filled = int(pct / 100 * total + 0.5)
    if (filled > total) filled = total
    bar = ""
    for (i = 0; i < filled; i++) bar = bar "\342\226\210"
    for (i = filled; i < total; i++) bar = bar "\342\226\221"
    if (pct >= 80) color = "\033[31m"
    else if (pct >= 50) color = "\033[33m"
    else color = ""
    reset = (color != "") ? "\033[0m" : ""
    printf "%s %s%s %d%%%s", label, color, bar, pct, reset
  }'
}
if [ -n "$five_pct" ] && [ "$five_pct" != "null" ]; then
  rate_info=$(make_mini_bar "$five_pct" "5h")
fi
if [ -n "$week_pct" ] && [ "$week_pct" != "null" ]; then
  week_str=$(make_mini_bar "$week_pct" "7d")
  if [ -n "$rate_info" ]; then
    rate_info="$rate_info | $week_str"
  else
    rate_info="$week_str"
  fi
fi

# Row 2: model+ctx | rate limits | cost
row2=""
if [ -n "$model_info" ] && [ -n "$ctx_info" ]; then
  row2="$model_info $ctx_info"
elif [ -n "$model_info" ]; then
  row2="$model_info"
elif [ -n "$ctx_info" ]; then
  row2="$ctx_info"
fi
if [ -n "$rate_info" ]; then
  if [ -n "$row2" ]; then
    row2="$row2 | $rate_info"
  else
    row2="$rate_info"
  fi
fi
if [ -n "$cost_info" ]; then
  if [ -n "$row2" ]; then
    row2="$row2 | $cost_info"
  else
    row2="$cost_info"
  fi
fi

line=""
for part in "$row1" "$row2"; do
  if [ -n "$part" ]; then
    if [ -n "$line" ]; then
      line="$line | $part"
    else
      line="$part"
    fi
  fi
done
printf "%b" "$line"
