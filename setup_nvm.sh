#!/bin/bash

# =================================================================
# Script Name: setup_nvm.sh
# Description: NVM configuration script
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-25
# =================================================================

set -e

# 1. Check for dependencies
echo "Checking for dependencies..."
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed."
    exit 1
fi

# 2. Fetch the latest NVM version
echo "Checking for the latest NVM version..."
NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$NVM_VERSION" ]; then
    echo "Error: Could not fetch the latest NVM version."
    exit 1
fi

echo "Latest version found: $NVM_VERSION"

# 3. Define installation path
INSTALL_DIR="$HOME/.nvm"

# 4. Install or Update NVM
if [ -d "$INSTALL_DIR" ]; then
    echo "Updating NVM in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" fetch --tags origin
    git -C "$INSTALL_DIR" checkout "$NVM_VERSION" --quiet
else
    echo "Installing NVM to $INSTALL_DIR..."
    git clone https://github.com/nvm-sh/nvm.git "$INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout "$NVM_VERSION" --quiet
fi

# 5. Configure environment variables
echo "Configuring environment variables..."

NVM_ENV_BLOCK=$(cat <<EOF

# NVM Configuration
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
)

# List of potential config files
CONFIG_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
UPDATED_FILES=()

for CONF in "${CONFIG_FILES[@]}"; do
    if [ -f "$CONF" ]; then
        if ! grep -q 'export NVM_DIR="$HOME/.nvm"' "$CONF"; then
            echo "$NVM_ENV_BLOCK" >> "$CONF"
            UPDATED_FILES+=("$CONF")
            echo "Added NVM configuration to $CONF"
        else
            echo "NVM configuration already exists in $CONF. Skipping."
        fi
    fi
done

# 6. Finalize
echo "--------------------------------------------------"
echo "NVM installation/update completed successfully!"
echo "Version: $NVM_VERSION"
echo "Installed at: $INSTALL_DIR"

if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Please run the following command to apply changes:"
    for UPDATED in "${UPDATED_FILES[@]}"; do
        echo "  source $UPDATED"
    done
else
    echo "You may need to restart your terminal or run:"
    echo "  export NVM_DIR=\"\$HOME/.nvm\""
    echo "  [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\""
fi

echo "Verify installation: nvm --version"
echo "--------------------------------------------------"
