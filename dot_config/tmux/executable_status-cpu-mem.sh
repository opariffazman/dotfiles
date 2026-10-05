#!/bin/bash
# Each metric gets its own separator and icon color so they read apart at a glance.
# The segment sits on the dark #080808 status background, so the icon colors are light
# pastels (all above 4.5:1 contrast, WCAG AA) and the text resets to the theme foreground.
cpu_color='#89b4fa'
ram_color='#cba6f7'
gpu_color='#f38ba8'

cpu=$(grep 'cpu ' /proc/stat | awk '{printf "%.0f%%", ($2+$4)*100/($2+$4+$5)}')
mem=$(free -h | awk '/^Mem:/ {print $3"/"$2}')
out="#[fg=$cpu_color,bold]󰻠#[default] $cpu #[fg=$ram_color,bold]│ 󰍛#[default] $mem"

# Skipped silently on hosts without an NVIDIA driver so the segment still renders.
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null |
    awk -F', ' 'NR==1 {printf "%s%% %.1f/%.0fG", $1, $2/1024, $3/1024}')
  [ -n "$gpu" ] && out="$out #[fg=$gpu_color,bold]│ 󰢮#[default] $gpu"
fi

echo "$out"
