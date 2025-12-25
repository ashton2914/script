#!/bin/bash

# ==========================================================
# Script Name: setup_pyenv.sh
# Description: Rootless pyenv environment setup
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-25
# ==========================================================

set -e

# 1. Check for prerequisites
if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is not installed. Please install git first."
    exit 1
fi

echo "Prerequisites checked."

# 2. Define Rootless paths
PYENV_ROOT="$HOME/.pyenv"
REPO_URL="https://github.com/pyenv/pyenv.git"

# 3. Download/Update pyenv
if [ -d "$PYENV_ROOT" ]; then
    echo "Updating existing pyenv installation at $PYENV_ROOT..."
    git -C "$PYENV_ROOT" pull
else
    echo "Cloning pyenv to $PYENV_ROOT..."
    git clone "$REPO_URL" "$PYENV_ROOT"
fi

# 4. Configure environment variables
echo "Configuring environment variables..."

PYENV_ENV_BLOCK=$(cat <<EOF

# section: pyenv
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d \$PYENV_ROOT/bin ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
EOF
)

# List of potential config files
CONFIG_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
UPDATED_FILES=()

# Check if PYENV_ROOT is already configured in the current environment
# We check if the env var matches our target AND if 'pyenv' command is playable
if [ "$PYENV_ROOT" = "$HOME/.pyenv" ] && command -v pyenv >/dev/null 2>&1; then
    echo "pyenv environment variables are already correctly configured in the current shell."
    echo "Skipping modification of shell configuration files."
else
    for CONF in "${CONFIG_FILES[@]}"; do
        if [ -f "$CONF" ]; then
            # We look for a unique marker from our block or standard pyenv init
            if ! grep -q "export PYENV_ROOT=" "$CONF"; then
                echo "$PYENV_ENV_BLOCK" >> "$CONF"
                UPDATED_FILES+=("$CONF")
                echo "Added pyenv environment to $CONF"
            else
                echo "pyenv environment already exists in $CONF. Skipping."
            fi
        fi
    done
fi

# 5. Finalize
echo "--------------------------------------------------"
echo "Rootless pyenv setup completed successfully!"
echo "Installed at: $PYENV_ROOT"

if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Please run the following command to apply changes:"
    for UPDATED in "${UPDATED_FILES[@]}"; do
        echo "  source $UPDATED"
    done
fi

echo "Note: You may need to install Python build dependencies manually."
echo "      See https://github.com/pyenv/pyenv/wiki#suggested-build-environment"
echo "--------------------------------------------------"
echo "Suggested build environment installation command for your system:"
echo ""

if [ "$(uname)" == "Darwin" ]; then
    echo "  brew install openssl readline sqlite3 xz zlib tcl-tk"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|kali)
            echo "  sudo apt update; sudo apt install -y build-essential libssl-dev zlib1g-dev \\"
            echo "  libbz2-dev libreadline-dev libsqlite3-dev curl \\"
            echo "  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \\"
            echo "  libffi-dev liblzma-dev"
            ;;
        fedora|rhel|centos)
            echo "  sudo dnf install -y make gcc zlib-devel bzip2 bzip2-devel readline-devel \\"
            echo "  sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel"
            ;;
        arch)
            echo "  sudo pacman -S --needed base-devel openssl zlib xz tk"
            ;;
        opensuse*|suse)
            echo "  sudo zypper install -y gcc automake bzip2 libbz2-devel xz xz-devel \\"
            echo "  openssl-devel ncurses-devel readline-devel zlib-devel tk-devel \\"
            echo "  libffi-devel sqlite3-devel"
            ;;
        alpine)
            echo "  sudo apk add --no-cache git bash build-base libffi-dev openssl-dev \\"
            echo "  bzip2-dev zlib-dev readline-dev sqlite-dev tk-dev xy-utils"
            ;;
        *)
            echo "  (Unable to detect specific distro, please check the wiki link above)"
            ;;
    esac
else
    echo "  (Unable to detect OS, please check the wiki link above)"
fi
echo "--------------------------------------------------"
