#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# add-ssh-user — Create a system user with SSH key and Google Authenticator 2FA
# Usage: add-ssh-user <username> <ssh-public-key>
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: add-ssh-user <username> <ssh-public-key>"
    echo ""
    echo "Example:"
    echo "  add-ssh-user deploy 'ssh-ed25519 AAAAC3Nza... user@laptop'"
    echo ""
    echo "This will:"
    echo "  1. Create the user with a home directory and zsh shell"
    echo "  2. Add them to the sudo and docker groups"
    echo "  3. Install the SSH public key"
    echo "  4. Set up Oh My Zsh with plugins"
    echo "  5. Generate a Google Authenticator QR code"
    exit 1
}

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo add-ssh-user ...${NC}"; exit 1; }
[[ $# -lt 2 ]] && usage

USERNAME="$1"
shift
SSH_KEY="$*"

# Validate username
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo -e "${RED}Invalid username: ${USERNAME}${NC}"
    echo "Use only lowercase letters, digits, hyphens, and underscores."
    exit 1
fi

# Validate SSH key format
if ! [[ "$SSH_KEY" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
    echo -e "${RED}Invalid SSH key format.${NC}"
    echo "Key must start with ssh-rsa, ssh-ed25519, or ssh-ecdsa."
    exit 1
fi

# Check if user exists
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}User '${USERNAME}' already exists.${NC}"
    read -rp "Update SSH key and regenerate 2FA? [y/N]: " confirm
    [[ "$confirm" != [yY] ]] && exit 0
else
    echo -e "${GREEN}[+]${NC} Creating user: ${USERNAME}"
    useradd -m -s "$(which zsh)" -G sudo "$USERNAME"

    # Add to docker group if it exists
    getent group docker &>/dev/null && usermod -aG docker "$USERNAME"

    # Set a random password (user authenticates via SSH key + 2FA)
    local_pass=$(openssl rand -base64 24)
    echo "${USERNAME}:${local_pass}" | chpasswd
    echo -e "${GREEN}[+]${NC} User created with random password (SSH key + 2FA for login)"
fi

# ── SSH Key ───────────────────────────────────────────────────────────────
SSH_DIR="/home/${USERNAME}/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_KEY" > "${SSH_DIR}/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"
echo -e "${GREEN}[+]${NC} SSH key installed"

# ── Oh My Zsh ────────────────────────────────────────────────────────────
USER_HOME="/home/${USERNAME}"
if [[ ! -d "${USER_HOME}/.oh-my-zsh" ]]; then
    echo -e "${GREEN}[+]${NC} Installing Oh My Zsh..."
    # Run in user's home dir to avoid "can't cd to /root" errors
    sudo -u "$USERNAME" -H bash -c \
        'cd ~ && RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

    ZSH_CUSTOM="${USER_HOME}/.oh-my-zsh/custom"

    sudo -u "$USERNAME" -H git clone --depth=1 \
        https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" 2>/dev/null || true

    sudo -u "$USERNAME" -H git clone --depth=1 \
        https://github.com/zsh-users/zsh-autosuggestions.git \
        "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" 2>/dev/null || true

    cat > "${USER_HOME}/.zshrc" << 'ZSHEOF'
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

export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

alias ll='ls -alFh'
alias la='ls -A'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gl='git log --oneline -20'
alias gd='git diff'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
ZSHEOF
    chown "${USERNAME}:${USERNAME}" "${USER_HOME}/.zshrc"
    echo -e "${GREEN}[+]${NC} Zsh configured"
fi

# ── Google Authenticator 2FA ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Setting up 2FA for ${USERNAME}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Generate Google Authenticator config
# -t: TOTP, -d: disallow reuse, -f: force overwrite, -r 3 -R 30: rate limit, -w 3: window size
sudo -u "$USERNAME" -H google-authenticator \
    -t -d -f -r 3 -R 30 -w 3 \
    -s "/home/${USERNAME}/.google_authenticator"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  User '${USERNAME}' is ready!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Username:   ${CYAN}${USERNAME}${NC}"
echo -e "  ${GREEN}✓${NC} Shell:      zsh + oh-my-zsh"
echo -e "  ${GREEN}✓${NC} SSH key:    installed"
echo -e "  ${GREEN}✓${NC} 2FA:        configured (scan QR above)"
echo -e "  ${GREEN}✓${NC} Groups:     sudo, docker"
echo ""
echo -e "  ${YELLOW}Test login:${NC} ssh ${USERNAME}@$(hostname -I | awk '{print $1}')"
echo ""
