#!/usr/bin/env bash
#
# Machine bootstrap — installs everything the dotfiles assume exists.
#
# Runs automatically before `chezmoi apply` (chezmoi re-runs it whenever this
# file's contents change), so provisioning a new machine is one command:
#
#     sh -c "$(curl -fsSL https://get.chezmoi.io)" -- init --apply opariffazman
#
# It is also a normal script. Run all phases, or just some:
#
#     ./run_onchange_before_00-install-packages.sh
#     ./run_onchange_before_00-install-packages.sh nvim go
#     DRY_RUN=1 ./run_onchange_before_00-install-packages.sh
#
# Every phase is idempotent: re-running is cheap and changes nothing once the
# machine is provisioned.

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
GO_VERSION="${GO_VERSION:-latest}"   # or pin, e.g. GO_VERSION=1.26.5

# ---------------------------------------------------------------- packages ---
# One transaction instead of re-running apt per tool.
APT_CORE=(
  build-essential ca-certificates curl git gnupg unzip
  zsh tmux util-linux-extra          # util-linux-extra provides `script`, needed by omz
  jq xclip
  python3-dev libffi-dev             # build deps, if mise ever compiles python
  bubblewrap                         # claude-code sandboxing
)
# Not present on every Ubuntu release — installed individually, never fatal.
# lazygit is deliberately absent: mise ships a far newer build than apt does.
APT_OPTIONAL=(eza fzf fd-find ripgrep ffmpeg)

# Kept minimal on purpose. chezmoi bootstraps itself (so it cannot come from
# mise), and mise then provides every other CLI tool — see dot_config/mise.
# Formerly also gh/pyenv/tfenv/tgenv, all now mise-managed.
BREW_FORMULAE=(chezmoi mise)

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

case "$(uname -m)" in
  x86_64)  ARCH_GO=amd64; ARCH_NVIM=x86_64 ;;
  aarch64) ARCH_GO=arm64; ARCH_NVIM=arm64  ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

[ "$(id -u)" -eq 0 ] && die "run as your normal user, not root (sudo is called where needed)"
have apt-get || die "this script targets Debian/Ubuntu"

ME=$(id -un)                                  # $USER isn't set when chezmoi runs scripts
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Prompt for sudo once up front rather than mid-run.
if [ "$DRY_RUN" != "1" ]; then sudo -v; fi

# ---------------------------------------------------------------- 1. system ---
if want apt; then
  phase "System packages"
  stamp=/var/lib/apt/periodic/update-success-stamp
  if [ -f "$stamp" ] && [ "$(( $(date +%s) - $(stat -c %Y "$stamp") ))" -lt 86400 ]; then
    skip "apt index fresh (updated in the last 24h)"
  else
    run sudo apt-get update -qq
  fi

  missing=()
  for p in "${APT_CORE[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    info "installing: ${missing[*]}"
    run sudo apt-get install -y "${missing[@]}"
    ok "core packages"
  else
    skip "core packages already installed"
  fi

  for p in "${APT_OPTIONAL[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then continue; fi
    if apt-cache show "$p" >/dev/null 2>&1; then
      run sudo apt-get install -y "$p" && ok "$p"
    else
      warn "$p not in this release's repos — skipped"
    fi
  done

  # Ubuntu ships fd as `fdfind`; everything (and fzf) expects `fd`.
  if have fdfind && ! have fd; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    ok "linked fdfind -> ~/.local/bin/fd"
  fi
fi

# --------------------------------------------------------------- 2. homebrew ---
if want brew; then
  phase "Homebrew"
  BREW_BIN=/home/linuxbrew/.linuxbrew/bin/brew
  if [ ! -x "$BREW_BIN" ]; then
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ok "installed homebrew"
  else
    skip "homebrew present"
  fi
  if [ -x "$BREW_BIN" ]; then
    eval "$("$BREW_BIN" shellenv)"
    for f in "${BREW_FORMULAE[@]}"; do
      if brew list --formula "$f" >/dev/null 2>&1; then skip "$f"; else run brew install "$f" && ok "$f"; fi
    done
  fi
fi

# --------------------------------------------------------------- 3. neovim ----
# Deliberately NOT apt: distro neovim is too old for the LazyVim config.
if want nvim; then
  phase "Neovim (upstream release -> /opt)"
  latest=$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest \
           | jq -r '.tag_name // empty' 2>/dev/null || true)
  current=$(/opt/nvim-linux-${ARCH_NVIM}/bin/nvim --version 2>/dev/null | head -1 | awk '{print $2}' || true)
  if [ -n "$current" ] && { [ -z "$latest" ] || [ "$current" = "$latest" ]; }; then
    skip "neovim ${current} is current"
  else
    tarball="nvim-linux-${ARCH_NVIM}.tar.gz"
    run curl -fsSL -o "$WORKDIR/$tarball" \
      "https://github.com/neovim/neovim/releases/latest/download/${tarball}"
    run sudo rm -rf "/opt/nvim-linux-${ARCH_NVIM}"
    run sudo tar -C /opt -xzf "$WORKDIR/$tarball"
    ok "neovim ${latest:-latest} -> /opt/nvim-linux-${ARCH_NVIM}"
    # Distro neovim would shadow it on PATH.
    if dpkg-query -W -f='${Status}' neovim 2>/dev/null | grep -q "install ok installed"; then
      run sudo apt-get remove -y neovim
      warn "removed apt neovim (it shadows the upstream build)"
    fi
  fi
fi

# ------------------------------------------------------------------- 4. go ----
if want go; then
  phase "Go toolchain"
  if [ "$GO_VERSION" = "latest" ]; then
    want_go=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)   # e.g. go1.26.5
  else
    want_go="go${GO_VERSION#go}"
  fi
  current_go=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)
  if [ -n "$current_go" ] && [ "$current_go" = "$want_go" ]; then
    skip "${current_go} installed"
  elif [ -z "$want_go" ]; then
    warn "could not resolve latest go version — skipped"
  else
    run curl -fsSL -o "$WORKDIR/go.tar.gz" "https://go.dev/dl/${want_go}.linux-${ARCH_GO}.tar.gz"
    run sudo rm -rf /usr/local/go        # required: extracting over an old tree corrupts it
    run sudo tar -C /usr/local -xzf "$WORKDIR/go.tar.gz"
    ok "${want_go} -> /usr/local/go"
  fi
fi

# ------------------------------------------------------------- 5. oh-my-zsh ---
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

# ----------------------------------------------------------------- 6. fonts ---
# p10k's nerdfont-v3 glyphs need these; without them the prompt renders as boxes.
if want fonts; then
  phase "MesloLGS NF fonts"
  fontdir="$HOME/.local/share/fonts"
  run mkdir -p "$fontdir"
  changed=0
  for variant in "Regular" "Bold" "Italic" "Bold Italic"; do
    target="$fontdir/MesloLGS NF ${variant}.ttf"
    if [ -f "$target" ]; then continue; fi
    encoded="MesloLGS%20NF%20${variant// /%20}.ttf"
    run curl -fsSL -o "$target" "https://github.com/romkatv/powerlevel10k-media/raw/master/${encoded}"
    changed=1
  done
  if [ "$changed" = "1" ]; then run fc-cache -f "$fontdir" >/dev/null 2>&1; ok "fonts installed"; else skip "fonts present"; fi
fi

# ------------------------------------------------------------------ 7. tmux ---
# dot_config/tmux/symlink_tmux.conf points at this clone. Without it, chezmoi
# lays down a dangling symlink and tmux starts unconfigured. Clone only — do NOT
# run the upstream install.sh: it copies files into $HOME and backs up the
# config chezmoi owns (that's where ~/.config/tmux.<timestamp> came from).
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

# ---------------------------------------------------------------- 8. docker ---
if want docker; then
  phase "Docker"
  if have docker; then
    skip "docker present"
  else
    run sh -c "curl -fsSL https://get.docker.com | sudo sh"
    ok "docker-ce"
  fi
  if ! id -nG "$ME" | tr ' ' '\n' | grep -qx docker; then
    run sudo usermod -aG docker "$ME"
    warn "added $ME to the docker group — log out and back in for it to apply"
  else
    skip "already in docker group"
  fi
fi

# ------------------------------------------------------- 9. vendor installers ---
if want tools; then
  phase "Claude Code / Hermes"
  if have claude; then skip "claude"; else run sh -c "curl -fsSL https://claude.ai/install.sh | bash" && ok "claude"; fi
  if have hermes; then skip "hermes"; else run sh -c "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash" && ok "hermes"; fi
fi

# ------------------------------------------------------------ 10. desktop apps ---
if want desktop; then
  phase "Desktop apps (apt repos)"
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "${FORCE_DESKTOP:-0}" = "1" ]; then
    if ! dpkg-query -W -f='${Status}' claude-desktop 2>/dev/null | grep -q "install ok installed"; then
      run sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc \
        https://downloads.claude.ai/claude-desktop/key.asc
      run sh -c 'echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null'
      run sudo apt-get update -qq
      run sudo apt-get install -y claude-desktop
      ok "claude-desktop"
    else
      skip "claude-desktop"
    fi

    if ! dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null | grep -q "install ok installed"; then
      run sudo curl -fsSLo /usr/share/keyrings/google-chrome.asc https://dl.google.com/linux/linux_signing_key.pub
      run sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null'
      run sudo apt-get update -qq
      run sudo apt-get install -y google-chrome-stable
      ok "google-chrome-stable"
    else
      skip "google-chrome-stable"
    fi
  else
    skip "headless machine — set FORCE_DESKTOP=1 to install desktop apps"
  fi
fi

# ------------------------------------------------------------------ 11. git ---
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
     gpg --armor --export <FPR> | xclip -selection clipboard   # add to GitHub
  2. gh auth login                               # + ssh -T git@github.com
     (gh arrives via mise, installed by run_onchange_after_10-mise-tools.sh,
      which runs after this script — so it exists by the time you read this)
  3. Set your terminal font to "MesloLGS NF"
  4. Log out/in once  (zsh login shell + docker group)
EOF
