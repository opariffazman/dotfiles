#!/usr/bin/env bash
#
# Machine bootstrap — Arch / CachyOS.
#
# Counterpart to run_onchange_before_00-install-packages-debian.sh. Exactly one
# of the two applies to any machine; .chezmoiignore selects by OS family, so
# both live in the source tree without colliding.
#
# Provisioning a fresh machine is two commands:
#
#     sudo pacman -Syu --needed git chezmoi
#     chezmoi init --apply opariffazman
#
# It is also a normal script. Run all phases, or just some:
#
#     ./run_onchange_before_00-install-packages-arch.sh
#     ./run_onchange_before_00-install-packages-arch.sh pacman mdns
#     DRY_RUN=1 ./run_onchange_before_00-install-packages-arch.sh
#
# Every phase is idempotent: re-running is cheap and changes nothing once the
# machine is provisioned.
#
# This is deliberately shorter than the Debian script. Arch ships current
# upstream builds, so four phases that exist there collapse into package names:
#   neovim — Ubuntu's is too old for LazyVim, so that script untars into /opt
#   go     — Ubuntu's lags, so that script untars into /usr/local
#   fonts  — MesloLGS NF is unpackaged there, so that script curls four files
#   brew   — apt has neither chezmoi nor mise, so that script installs Homebrew
#
# There is deliberately no Homebrew phase here. A second package manager
# shadowing newer native packages is a liability, not a convenience.

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------- packages ---
PAC_CORE=(
  base-devel ca-certificates curl git unzip
  zsh tmux jq
  neovim go                          # current in the repos — no tarball dance
  chezmoi mise                       # no Homebrew needed
  ttf-meslo-nerd                     # p10k's nerdfont-v3 glyphs
  avahi nss-mdns                     # .local resolution to the other machines
  bubblewrap                         # claude-code sandboxing
)

# Installed individually, never fatal. Arch names the binary `fd`, so the
# Debian script's fdfind -> fd symlink has no equivalent here.
PAC_OPTIONAL=(eza fzf fd ripgrep ffmpeg wl-clipboard xclip)

# AUR, via paru (preinstalled on CachyOS). Desktop-only; skipped when headless.
AUR_DESKTOP=(google-chrome claude-desktop)

OMZ_PLUGINS=(
  "https://github.com/zsh-users/zsh-autosuggestions plugins/zsh-autosuggestions"
  "https://github.com/romkatv/powerlevel10k themes/powerlevel10k"
  # Cloned but inert until added to plugins=(...) in .zshrc — drop this line if unwanted.
  "https://github.com/zsh-users/zsh-syntax-highlighting plugins/zsh-syntax-highlighting"
)

GIT_USER_NAME="opariffazman"
GIT_USER_EMAIL="ariff.azman@proton.me"

# ------------------------------------------------------------------ helpers ---
c_ok=$'\033[38;5;76m'; c_warn=$'\033[38;5;178m'; c_err=$'\033[38;5;196m'
c_hd=$'\033[1;38;5;39m'; c_dim=$'\033[38;5;244m'; c_rst=$'\033[0m'

phase()  { printf '\n%s==> %s%s\n' "$c_hd" "$1" "$c_rst"; }
info()   { printf '    %s\n' "$1"; }
ok()     { printf '    %s✓%s %s\n' "$c_ok" "$c_rst" "$1"; }
skip()   { printf '    %s·%s %s\n' "$c_dim" "$c_rst" "$1"; }
warn()   { printf '    %s!%s %s\n' "$c_warn" "$c_rst" "$1"; }
die()    { printf '    %s✗%s %s\n' "$c_err" "$c_rst" "$1" >&2; exit 1; }
have()   { command -v "$1" >/dev/null 2>&1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then printf '    %s$ %s%s\n' "$c_dim" "$*" "$c_rst"; return 0; fi
  "$@"
}

# Phase selection: no args = all phases.
WANTED=("$@")
want() {
  [ ${#WANTED[@]} -eq 0 ] && return 0
  local w; for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

[ "$(id -u)" -eq 0 ] && die "run as your normal user, not root (sudo is called where needed)"
have pacman || die "this script targets Arch/CachyOS"

ME=$(id -un)                                  # $USER isn't set when chezmoi runs scripts

# Prompt for sudo once up front rather than mid-run.
if [ "$DRY_RUN" != "1" ]; then sudo -v; fi

# --------------------------------------------------------------- 1. pacman ---
if want pacman; then
  phase "System packages"

  # -Syu, never -Sy followed by -S. Arch does not support partial upgrades:
  # syncing the database and then installing against a half-old system is the
  # classic way to break a machine. Upgrading and installing in one transaction
  # is the only safe form, which is why this differs from the apt script's
  # "skip update if the index is fresh" optimisation.
  missing=()
  for p in "${PAC_CORE[@]}"; do
    pacman -Qi "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    info "installing: ${missing[*]}"
    run sudo pacman -Syu --needed --noconfirm "${missing[@]}"
    ok "core packages"
  else
    run sudo pacman -Syu --noconfirm
    skip "core packages already installed (system upgraded)"
  fi

  for p in "${PAC_OPTIONAL[@]}"; do
    if pacman -Qi "$p" >/dev/null 2>&1; then continue; fi
    if pacman -Si "$p" >/dev/null 2>&1; then
      run sudo pacman -S --needed --noconfirm "$p" && ok "$p"
    else
      warn "$p not in the repos — skipped"
    fi
  done
fi

# ----------------------------------------------------------------- 2. mDNS ---
# Lets this box reach the other machines as <host>.local without touching the
# router. Announcing and resolving are separate concerns: avahi-daemon publishes
# this host, nss-mdns lets it look others up. Installing only the daemon gives a
# machine that can be found but cannot find anyone — a confusing half-failure.
if want mdns; then
  phase "mDNS (.local resolution)"

  if systemctl is-enabled avahi-daemon >/dev/null 2>&1; then
    skip "avahi-daemon enabled"
  else
    run sudo systemctl enable --now avahi-daemon
    ok "avahi-daemon"
  fi

  # Arch ships nsswitch.conf with no mdns entry even once nss-mdns is present.
  if grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
    skip "nsswitch already wired for mdns"
  elif [ "$DRY_RUN" = "1" ]; then
    info "\$ sudo sed -i (insert mdns_minimal into /etc/nsswitch.conf hosts:)"
  else
    sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.pre-mdns
    # Inserted at the front of the line on purpose. It has to land before
    # `resolve`, whose [!UNAVAIL=return] would otherwise swallow .local lookups
    # and never fall through. mdns_minimal handles only .local and returns
    # UNAVAIL for everything else, so nothing ahead of it is lost.
    sudo sed -i -E 's/^hosts:[[:space:]]*/hosts: mdns_minimal [NOTFOUND=return] /' /etc/nsswitch.conf

    # A bad NSS edit breaks all name resolution, so verify and roll back.
    if getent hosts localhost >/dev/null 2>&1; then
      ok "nsswitch: $(grep '^hosts:' /etc/nsswitch.conf)"
    else
      sudo mv /etc/nsswitch.conf.pre-mdns /etc/nsswitch.conf
      die "nsswitch edit broke resolution — reverted, resolve by hand"
    fi
  fi
fi

# ------------------------------------------------------------- 3. oh-my-zsh ---
# CachyOS defaults to fish. Nothing here removes it — fish stays installed and
# runnable, this only changes the login shell.
if want zsh; then
  phase "oh-my-zsh + plugins"
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    # --unattended: don't run zsh or chsh from inside the installer.
    run sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    ok "oh-my-zsh"
  else
    skip "oh-my-zsh present"
  fi

  ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  for entry in "${OMZ_PLUGINS[@]}"; do
    url=${entry%% *}; dest="$ZSH_CUSTOM/${entry##* }"
    if [ -d "$dest" ]; then
      skip "$(basename "$dest")"
    else
      run git clone --depth=1 "$url" "$dest" && ok "$(basename "$dest")"
    fi
  done

  if [ "$(getent passwd "$ME" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    run sudo chsh -s "$(command -v zsh)" "$ME"
    ok "login shell -> zsh (takes effect next login)"
  else
    skip "login shell already zsh"
  fi
fi

# ------------------------------------------------------------------ 4. tmux ---
# dot_config/tmux/symlink_tmux.conf points at this clone. Without it, chezmoi
# lays down a dangling symlink and tmux starts unconfigured. Clone only — do NOT
# run the upstream install.sh: it copies files into $HOME and backs up the
# config chezmoi owns.
if want tmux; then
  phase "oh-my-tmux"
  omt="$HOME/.local/share/tmux/oh-my-tmux"
  if [ -d "$omt/.git" ]; then
    skip "oh-my-tmux present"
  else
    run mkdir -p "$(dirname "$omt")"
    run git clone --depth=1 https://github.com/gpakosz/.tmux.git "$omt"
    ok "oh-my-tmux -> $omt"
  fi
fi

# ---------------------------------------------------------------- 5. docker ---
# From the repos, not get.docker.com: that script has no pacman path, and Arch's
# package is current anyway. Unlike Debian it does not auto-enable the daemon.
if want docker; then
  phase "Docker"
  if pacman -Qi docker >/dev/null 2>&1; then
    skip "docker present"
  else
    run sudo pacman -S --needed --noconfirm docker docker-buildx
    ok "docker + buildx"
  fi

  if systemctl is-enabled docker >/dev/null 2>&1; then
    skip "docker.service enabled"
  else
    run sudo systemctl enable --now docker
    ok "docker.service"
  fi

  if id -nG "$ME" | tr ' ' '\n' | grep -qx docker; then
    skip "already in docker group"
  else
    run sudo usermod -aG docker "$ME"
    warn "added $ME to the docker group — log out and back in for it to apply"
  fi
fi

# ------------------------------------------------------- 6. vendor installers ---
if want tools; then
  phase "Claude Code / Hermes"
  if have claude; then skip "claude"; else run sh -c "curl -fsSL https://claude.ai/install.sh | bash" && ok "claude"; fi
  if have hermes; then skip "hermes"; else run sh -c "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash" && ok "hermes"; fi
fi

# ------------------------------------------------------------ 7. desktop apps ---
# AUR rather than the Debian script's apt-keyring dance.
if want desktop; then
  phase "Desktop apps (AUR)"
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "${FORCE_DESKTOP:-0}" != "1" ]; then
    skip "headless machine — set FORCE_DESKTOP=1 to install desktop apps"
  elif ! have paru; then
    warn "paru not found — skipping AUR (install with: sudo pacman -S --needed paru)"
  else
    for p in "${AUR_DESKTOP[@]}"; do
      if pacman -Qi "$p" >/dev/null 2>&1; then
        skip "$p"
      else
        # AUR builds fail for reasons outside our control (upstream URL moved,
        # PGP key rotated). Never let that abort the rest of the bootstrap.
        run paru -S --needed --noconfirm "$p" && ok "$p" || warn "$p failed to build — skipped"
      fi
    done
  fi
fi

# ------------------------------------------------------------------- 8. git ---
if want git; then
  phase "Git identity"
  [ "$(git config --global user.name  || true)" = "$GIT_USER_NAME"  ] || run git config --global user.name  "$GIT_USER_NAME"
  [ "$(git config --global user.email || true)" = "$GIT_USER_EMAIL" ] || run git config --global user.email "$GIT_USER_EMAIL"
  ok "user.name / user.email"

  # Signing key is per-machine — configure it only if a secret key exists.
  key=$(gpg --list-secret-keys --keyid-format=long --with-colons "$GIT_USER_EMAIL" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}' || true)
  if [ -n "$key" ]; then
    if [ "$(git config --global user.signingkey || true)" != "$key" ]; then
      run git config --global user.signingkey "$key"
      run git config --global commit.gpgsign true
      run git config --global tag.gpgsign true
      ok "commit signing -> $key"
    else
      skip "commit signing configured"
    fi
  else
    warn "no GPG secret key for $GIT_USER_EMAIL — see manual steps below"
  fi
fi

# ------------------------------------------------------------------ summary ---
cat <<EOF

$(printf '%s' "$c_hd")Remaining manual steps$(printf '%s' "$c_rst")
  1. gpg --full-generate-key                     # then re-run: $0 git
     gpg --armor --export <FPR> | wl-copy        # add to GitHub (xclip on X11)
  2. gh auth login                               # + ssh -T git@github.com
     (gh arrives via mise, installed by run_onchange_after_10-mise-tools.sh,
      which runs after this script — so it exists by the time you read this)
  3. Set your terminal font to "MesloLGS Nerd Font"
     (that is the family ttf-meslo-nerd registers; romkatv's own build calls
      itself "MesloLGS NF" — same glyphs, different name, so the Debian script
      says NF and this one does not)
  4. Log out/in once  (zsh login shell + docker group, replacing fish)
EOF
