#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Server Setup Script for Ubuntu 22.04 / 24.04
# Run as root on a fresh server. Safe to run over SSH — won't drop connection.
# Idempotent — safe to run multiple times.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/server-setup.log"

# Detect SSH service name (Ubuntu 22.04+ uses 'ssh', older uses 'sshd')
if systemctl list-unit-files ssh.service &>/dev/null; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="sshd"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

# ── Pre-flight checks ──────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run this script as root: sudo bash setup.sh"

source /etc/os-release 2>/dev/null
if [[ "${ID:-}" != "ubuntu" ]]; then
    err "This script is designed for Ubuntu 22.04/24.04. Detected: ${ID:-unknown}"
fi

log "Starting server setup on Ubuntu ${VERSION_ID}..."
log "Log file: $LOG_FILE"

export DEBIAN_FRONTEND=noninteractive

# ── 1. System update & base packages ──────────────────────────────────────
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

log "Installing base utilities..."
apt-get install -y -qq \
    curl wget git vim htop tmux tree unzip jq \
    build-essential make gcc g++ \
    ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    net-tools dnsutils mtr-tiny \
    ncdu ripgrep fd-find bat \
    libpam-google-authenticator qrencode \
    ufw fail2ban \
    unattended-upgrades apt-listchanges \
    zsh

# Symlink batcat -> bat, fdfind -> fd (Ubuntu packaging quirks)
[[ -f /usr/bin/batcat ]] && ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
[[ -f /usr/bin/fdfind ]] && ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

# ── 2. Install Go ─────────────────────────────────────────────────────────
GO_VERSION="1.22.5"
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null)" != *"$GO_VERSION"* ]]; then
    log "Installing Go ${GO_VERSION}..."
    GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
    wget -q "https://go.dev/dl/${GO_ARCHIVE}" -O "/tmp/${GO_ARCHIVE}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_ARCHIVE}"
    rm -f "/tmp/${GO_ARCHIVE}"

    # System-wide Go path
    cat > /etc/profile.d/go.sh << 'GOEOF'
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
GOEOF
    chmod +x /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
    log "Go $(go version | awk '{print $3}') installed"
else
    log "Go already installed: $(go version)"
fi

# ── 3. Install Docker ─────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    # --yes to overwrite existing keyring file on re-run
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed"
else
    log "Docker already installed"
fi

# ── 4. Zsh + Oh My Zsh ───────────────────────────────────────────────────
setup_zsh_for_user() {
    local target_user="$1"
    local target_home
    target_home="$(eval echo "~${target_user}")"

    if [[ -d "${target_home}/.oh-my-zsh" ]]; then
        warn "Oh My Zsh already installed for ${target_user}, skipping"
        return
    fi

    log "Setting up Zsh for ${target_user}..."

    # Install oh-my-zsh (run in user's home dir to avoid permission errors)
    sudo -u "$target_user" -H bash -c \
        'cd ~ && RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

    local ZSH_CUSTOM="${target_home}/.oh-my-zsh/custom"

    # Plugins
    sudo -u "$target_user" -H git clone --depth=1 \
        https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" 2>/dev/null || true

    sudo -u "$target_user" -H git clone --depth=1 \
        https://github.com/zsh-users/zsh-autosuggestions.git \
        "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" 2>/dev/null || true

    # Configure .zshrc
    cat > "${target_home}/.zshrc" << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
    git
    zsh-syntax-highlighting
    zsh-autosuggestions
    docker
    golang
    command-not-found
    history
    sudo
)

source $ZSH/oh-my-zsh.sh

# Go
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

# Aliases
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gl='git log --oneline -20'
alias gd='git diff'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
ZSHEOF

    chown "$target_user":"$target_user" "${target_home}/.zshrc"

    # Set zsh as default shell
    chsh -s "$(which zsh)" "$target_user"
}

# Setup zsh for root
setup_zsh_for_user root

# ── 5. UFW Firewall ──────────────────────────────────────────────────────
log "Configuring UFW firewall..."

# IMPORTANT: Allow SSH first to avoid lockout
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh comment 'SSH'
ufw allow http comment 'HTTP'
ufw allow https comment 'HTTPS'

# Enable without prompt, SSH is already allowed
ufw --force enable
log "UFW enabled — allowed: SSH, HTTP, HTTPS"

# ── 6. Fail2Ban ──────────────────────────────────────────────────────────
log "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
bantime  = 7200
F2BEOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2Ban configured (SSH: 3 retries, 2h ban)"

# ── 7. Unattended Upgrades ───────────────────────────────────────────────
log "Enabling unattended upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UUEOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF2'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF2

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "Unattended upgrades enabled (security patches, no auto-reboot)"

# ── 8. SSH Hardening + 2FA ────────────────────────────────────────────────
log "Configuring SSH with 2FA..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.bak.before-setup"

# Only create backup if our backup doesn't exist yet (first run)
[[ ! -f "$SSHD_BACKUP" ]] && cp "$SSHD_CONFIG" "$SSHD_BACKUP"

# Apply settings idempotently (handles duplicates, commented lines, and re-runs)
apply_sshd_setting() {
    local key="$1" value="$2"

    # Remove ALL existing lines for this key (commented or not) to avoid duplicates
    sed -i "/^\s*#\?\s*${key}\s/d" "$SSHD_CONFIG"

    # Append the desired setting
    echo "${key} ${value}" >> "$SSHD_CONFIG"
}

# Remove legacy ChallengeResponseAuthentication (renamed to KbdInteractiveAuthentication in OpenSSH 8.7+)
# Having both causes sshd -t validation to fail on Ubuntu 22.04+
sed -i '/^\s*#\?\s*ChallengeResponseAuthentication\s/d' "$SSHD_CONFIG"

# Ubuntu 24.04 ships drop-in configs in /etc/ssh/sshd_config.d/ that can override our settings.
# Disable the default cloud-init config which may set PasswordAuthentication yes
if [[ -d /etc/ssh/sshd_config.d ]]; then
    for drop_in in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$drop_in" ]] || continue
        # Comment out conflicting settings in drop-in files
        if grep -qE '^\s*(PasswordAuthentication|KbdInteractiveAuthentication|AuthenticationMethods)\s' "$drop_in" 2>/dev/null; then
            sed -i 's|^\(\s*PasswordAuthentication\s\)|# \1|; s|^\(\s*KbdInteractiveAuthentication\s\)|# \1|; s|^\(\s*AuthenticationMethods\s\)|# \1|' "$drop_in"
            warn "Disabled conflicting SSH settings in drop-in: $(basename "$drop_in")"
        fi
    done
fi

apply_sshd_setting "PermitRootLogin" "prohibit-password"
apply_sshd_setting "PasswordAuthentication" "no"
apply_sshd_setting "KbdInteractiveAuthentication" "yes"
apply_sshd_setting "UsePAM" "yes"
apply_sshd_setting "AuthenticationMethods" "publickey,keyboard-interactive"
apply_sshd_setting "PubkeyAuthentication" "yes"
apply_sshd_setting "X11Forwarding" "no"
apply_sshd_setting "MaxAuthTries" "3"
apply_sshd_setting "ClientAliveInterval" "300"
apply_sshd_setting "ClientAliveCountMax" "2"

# Configure PAM for Google Authenticator
# The goal: keyboard-interactive should ONLY ask for TOTP code, NOT system password.
# By default, /etc/pam.d/sshd includes @include common-auth which prompts for password.
# We comment it out so PAM only uses google-authenticator for the keyboard-interactive step.
PAM_SSHD="/etc/pam.d/sshd"

# Comment out @include common-auth (prevents "Password:" prompt)
if grep -q '^\s*@include\s\+common-auth' "$PAM_SSHD"; then
    sed -i 's|^\(\s*@include\s\+common-auth\)|# \1  # Disabled by server-setup (pubkey handles auth, TOTP handles 2FA)|' "$PAM_SSHD"
    log "Disabled @include common-auth in PAM (no password prompt for SSH)"
fi

# Add google-authenticator PAM module if not already present
if ! grep -q "pam_google_authenticator.so" "$PAM_SSHD"; then
    # Add after the comment block at the top, before other auth rules
    echo "" >> "$PAM_SSHD"
    echo "# Google Authenticator — TOTP 2FA (added by server-setup)" >> "$PAM_SSHD"
    echo "auth required pam_google_authenticator.so nullok" >> "$PAM_SSHD"
    log "PAM configured for Google Authenticator (nullok — 2FA optional until user sets it up)"
else
    log "PAM Google Authenticator already configured"
fi

# Ensure privilege separation directory exists (required by sshd -t)
mkdir -p /run/sshd

# Validate sshd config before restarting
if SSHD_TEST_OUTPUT=$(sshd -t 2>&1); then
    systemctl restart "$SSH_SERVICE"
    log "SSH hardened and restarted successfully"
else
    echo ""
    warn "═══ sshd config validation failed! ═══"
    warn "Error output from 'sshd -t':"
    echo "${SSHD_TEST_OUTPUT}" | tee -a "$LOG_FILE"
    warn "═══════════════════════════════════════"
    warn "Restoring backup..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    if systemctl restart "$SSH_SERVICE"; then
        warn "Backup restored and SSH restarted. Fix the issue and re-run."
    else
        warn "Backup restored but SSH failed to restart. Check: systemctl status ${SSH_SERVICE}"
    fi
    exit 1
fi

# ── 9. Install add-ssh-user command ──────────────────────────────────────
log "Installing add-ssh-user command..."
cp "${SCRIPT_DIR}/add-ssh-user.sh" /usr/local/bin/add-ssh-user
chmod +x /usr/local/bin/add-ssh-user
log "add-ssh-user command installed — run: add-ssh-user <username> <ssh-public-key>"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Server setup complete!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Base tools: git, curl, wget, htop, tmux, jq, ripgrep, bat, fd"
echo -e "  ${GREEN}✓${NC} Dev tools:  make, gcc, Go ${GO_VERSION}, Docker"
echo -e "  ${GREEN}✓${NC} Shell:      zsh + oh-my-zsh (syntax-highlighting, autosuggestions)"
echo -e "  ${GREEN}✓${NC} Firewall:   UFW (SSH, HTTP, HTTPS only)"
echo -e "  ${GREEN}✓${NC} Security:   fail2ban, unattended-upgrades"
echo -e "  ${GREEN}✓${NC} SSH:        publickey + 2FA (Google Authenticator)"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Add your first user:  ${CYAN}add-ssh-user myuser 'ssh-ed25519 AAAA...'${NC}"
echo -e "  2. Set up 2FA for root:  ${CYAN}google-authenticator -t -d -f -r 3 -R 30 -w 3${NC}"
echo -e "  3. Start a new shell:    ${CYAN}exec zsh${NC}"
echo ""
echo -e "  ${YELLOW}SSH is configured with nullok — users without 2FA can still log in.${NC}"
echo -e "  ${YELLOW}Once all users set up 2FA, remove 'nullok' from /etc/pam.d/sshd.${NC}"
echo ""
