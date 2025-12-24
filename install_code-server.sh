#!/bin/bash

# =================================================================
# Script Name: install_code-server.sh
# Description: Script to install/update code-serve
# Date: 2025-12-24
# =================================================================

set -e

# 1. Define target directories and config files
INSTALL_LIB_DIR="$HOME/.local/lib"
INSTALL_BIN_DIR="$HOME/.local/bin"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

echo "Fetching the latest code-server version from GitHub..."
# Get the latest version tag (removing the 'v' prefix)
VERSION=$(curl -s https://api.github.com/repos/coder/code-server/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

if [ -z "$VERSION" ]; then
    echo "Error: Failed to fetch version info. Please check your network."
    exit 1
fi

echo "Target version found: v$VERSION"
DOWNLOAD_URL="https://github.com/coder/code-server/releases/download/v$VERSION/code-server-$VERSION-linux-amd64.tar.gz"
TARGET_DIR="$INSTALL_LIB_DIR/code-server-$VERSION"

# 2. Create necessary directories
mkdir -p "$INSTALL_LIB_DIR"
mkdir -p "$INSTALL_BIN_DIR"

# 3. Optimization: Clean up previous versions in lib directory
echo "Cleaning up old code-server directories in $INSTALL_LIB_DIR..."
# Find and remove any directory starting with 'code-server-' to save space
find "$INSTALL_LIB_DIR" -maxdepth 1 -type d -name "code-server-*" -exec rm -rf {} +

# 4. Download and extract
echo "Downloading and extracting code-server v$VERSION..."
curl -fL "$DOWNLOAD_URL" | tar -C "$INSTALL_LIB_DIR" -xz

# 5. Setup directory and symbolic link
echo "Finalizing installation structure..."
mv "$INSTALL_LIB_DIR/code-server-$VERSION-linux-amd64" "$TARGET_DIR"
# Force create/update symbolic link in bin directory
ln -sf "$TARGET_DIR/bin/code-server" "$INSTALL_BIN_DIR/code-server"

# 6. Optimization: Update PATH for Bash and Zsh with duplication check
PATH_LINE="export PATH=\"\$PATH:$INSTALL_BIN_DIR\""

for CONF in "${SHELL_CONFIGS[@]}"; do
    if [ -f "$CONF" ]; then
        # Check if the path already exists in the config file
        if ! grep -q "$INSTALL_BIN_DIR" "$CONF"; then
            echo "Adding code-server path to $CONF"
            echo "" >> "$CONF"
            echo "# code-server path added by install script" >> "$CONF"
            echo "$PATH_LINE" >> "$CONF"
        else
            echo "Path already exists in $CONF, skipping..."
        fi
    fi
done

echo "------------------------------------------------"
echo "Installation and environment setup complete!"
echo "Installed Version: v$VERSION"
echo "Binary Location: $INSTALL_BIN_DIR/code-server"
echo "------------------------------------------------"
echo "To start using code-server, please run:"
echo "source ~/.bashrc  (or source ~/.zshrc)"
echo "code-server"
echo "------------------------------------------------"