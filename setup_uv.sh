#!/bin/bash

# =================================================================
# Script Name: setup_uv.sh
# Description: Script to install uv (Python project management tool)
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-25
# =================================================================

set -e

# 1. Check for prerequisites
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is not installed. Please install curl first."
    exit 1
fi

echo "Prerequisites checked."

# 2. Define Installation Paths
INSTALL_BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

# 3. Download and Install uv
# We use the official installer but with UV_NO_MODIFY_PATH=1 to handle environment variables ourselves
# This avoids duplicate configurations and follows the requirement to not just append blindly.
echo "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh

# 4. Configure environment variables
echo "Configuring environment variables..."

# List of potential config files
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")
PATH_LINE="export PATH=\"\$PATH:$INSTALL_BIN_DIR\""
UPDATED_FILES=()

# Check if INSTALL_BIN_DIR is already in the PATH
if [[ ":$PATH:" == *":$INSTALL_BIN_DIR:"* ]]; then
    echo "uv path ($INSTALL_BIN_DIR) is already in the current environment PATH."
    echo "Skipping modification of shell configuration files."
else
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            # We look for the specific path in the config file
            if ! grep -q "$INSTALL_BIN_DIR" "$CONF"; then
                echo >> "$CONF"
                echo "# uv path added by setup_uv.sh" >> "$CONF"
                echo "$PATH_LINE" >> "$CONF"
                UPDATED_FILES+=("$CONF")
                echo "Added uv path to $CONF"
            else
                echo "uv path entry already exists in $CONF. Skipping."
            fi
        fi
    done
fi

# 5. Finalize
echo "--------------------------------------------------"
echo "uv setup completed successfully!"
echo "Installed version: $( "$INSTALL_BIN_DIR/uv" --version )"
echo ""

if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Please run the following command to apply changes:"
    for UPDATED in "${UPDATED_FILES[@]}"; do
        echo "  source $UPDATED"
    done
else
    echo "You may need to restart your shell or run 'source <shell_config>' to use uv."
fi
echo "--------------------------------------------------"
