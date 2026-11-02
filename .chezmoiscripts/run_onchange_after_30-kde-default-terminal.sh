#!/usr/bin/env bash
#
# Makes Alacritty the KDE default terminal.
#
# KDE keeps its own terminal choice in kdeglobals, separate from the
# xdg-terminals.list that xdg-terminal-exec reads. Dolphin's "Open Terminal" and
# every Terminal=true .desktop entry launched through KDE use this key and fall
# back to Konsole when it is unset. kwriteconfig6 is only present on KDE
# Plasma 6 machines, so other machines skip cleanly.

set -euo pipefail

command -v kwriteconfig6 >/dev/null 2>&1 || exit 0

kwriteconfig6 --file kdeglobals --group General --key TerminalApplication alacritty
kwriteconfig6 --file kdeglobals --group General --key TerminalService Alacritty.desktop
