#!/bin/bash

# =================================================================
# Script Name: setup_code-server.sh
# Description: Script to install/update code-serve
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-24
# =================================================================

set -e


# 2. Define target directories and config files
INSTALL_LIB_DIR="$HOME/.local/lib"
INSTALL_BIN_DIR="$HOME/.local/bin"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

install_code_server() {
    echo "Fetching the latest code-server version from GitHub..."
    # Get the latest version tag (removing the 'v' prefix)
    VERSION=$(curl -s https://api.github.com/repos/coder/code-server/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [ -z "$VERSION" ]; then
        echo "Error: Failed to fetch version info. Please check your network."
        exit 1
    fi

    echo "Target version found: v$VERSION"

    # 2. Detect OS and Architecture
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)     OS_TYPE="linux" ;;
        Darwin)    OS_TYPE="macos" ;;
        *)         echo "Error: Unsupported OS: $OS"; exit 1 ;;
    esac

    case "$ARCH" in
        x86_64)          ARCH_TYPE="amd64" ;;
        aarch64|arm64)   ARCH_TYPE="arm64" ;;
        *)               echo "Error: Unsupported Architecture: $ARCH"; exit 1 ;;
    esac

    echo "Detected Platform: $OS_TYPE/$ARCH_TYPE"

    DOWNLOAD_URL="https://github.com/coder/code-server/releases/download/v$VERSION/code-server-$VERSION-${OS_TYPE}-${ARCH_TYPE}.tar.gz"
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
    mv "$INSTALL_LIB_DIR/code-server-$VERSION-${OS_TYPE}-${ARCH_TYPE}" "$TARGET_DIR"
    # Force create/update symbolic link in bin directory
    ln -sf "$TARGET_DIR/bin/code-server" "$INSTALL_BIN_DIR/code-server"

    # 6. Optimization: Update PATH for Bash and Zsh with duplication check
    PATH_LINE="export PATH=\"\$PATH:$INSTALL_BIN_DIR\""

    # Check if INSTALL_BIN_DIR is already in the PATH
    if [[ ":$PATH:" == *":$INSTALL_BIN_DIR:"* ]]; then
        echo "code-server path is already in the current environment PATH."
        echo "Skipping modification of shell configuration files."
    else
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
    fi

    echo "------------------------------------------------"
    echo "Installation and environment setup complete!"
    echo "Installed Version: v$VERSION"
    echo "Binary Location: $INSTALL_BIN_DIR/code-server"
    echo "------------------------------------------------"
    echo "To start using code-server, please run:"
    echo "source ~/.bashrc  (or source ~/.zshrc)"
    echo "code-server"
    echo "------------------------------------------------"
}

uninstall_code_server() {
    echo "Uninstalling code-server..."
    
    # Remove lib directories
    if find "$INSTALL_LIB_DIR" -maxdepth 1 -type d -name "code-server-*" | grep -q .; then
        find "$INSTALL_LIB_DIR" -maxdepth 1 -type d -name "code-server-*" -exec rm -rf {} +
        echo "Removed code-server directories from $INSTALL_LIB_DIR"
    else
        echo "No code-server directories found in $INSTALL_LIB_DIR"
    fi

    # Remove binary symlink
    if [ -L "$INSTALL_BIN_DIR/code-server" ] || [ -f "$INSTALL_BIN_DIR/code-server" ]; then
        rm "$INSTALL_BIN_DIR/code-server"
        echo "Removed binary: $INSTALL_BIN_DIR/code-server"
    fi

    echo "Removing configuration from shell files..."
    USER_REMOVED_CONFIG=false
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            if grep -q "# code-server path added by install script" "$CONF"; then
                # Remove comment line and the next line (export PATH...)
                sed -i.bak '/# code-server path added by install script/{N;d;}' "$CONF" && rm "${CONF}.bak"
                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            elif grep -q "$INSTALL_BIN_DIR" "$CONF"; then
                 echo "Warning: Found code-server path in $CONF but not marked by this script. Skipping auto-removal."
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for code-server configuration."
    fi

    echo "code-server uninstallation completed."
}

repair_code_server() {
    echo "Repairing code-server..."
    uninstall_code_server
    install_code_server
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_code_server
        ;;
    2)
        uninstall_code_server
        ;;
    3)
        repair_code_server
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac