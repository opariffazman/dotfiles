#!/bin/bash
cpu=$(grep 'cpu ' /proc/stat | awk '{printf "%.0f%%", ($2+$4)*100/($2+$4+$5)}')
mem=$(free -h | awk '/^Mem:/ {print $3"/"$2}')
echo "$cpu 󰍛 $mem"
