#!/bin/bash

# ==========================================================
# Script Name: setup_nvim.sh
# Description: Rootless Neovim environment setup for Linux/macOS
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2026-01-18
# ==========================================================

set -e

# 2. Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)     OS_TYPE="linux" ;;
    Darwin)    OS_TYPE="macos" ;;
    *)         echo "Error: Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64)          ARCH_TYPE="x86_64" ;;
    aarch64|arm64)   ARCH_TYPE="arm64" ;;
    *)               echo "Error: Unsupported Architecture: $ARCH"; exit 1 ;;
esac

# Neovim on Linux uses 'linux64' for x86_64.
# Neovim on macOS uses 'macos-x86_64' or 'macos-arm64'.
# We need to construct the correct release name.

if [ "$OS_TYPE" = "linux" ]; then
    if [ "$ARCH_TYPE" = "x86_64" ]; then
        RELEASE_NAME="nvim-linux-x86_64"
    elif [ "$ARCH_TYPE" = "arm64" ]; then
        RELEASE_NAME="nvim-linux-arm64"
    else
        echo "Error: Unsupported architecture for Linux: $ARCH_TYPE"
        exit 1
    fi
elif [ "$OS_TYPE" = "macos" ]; then
    RELEASE_NAME="nvim-macos-${ARCH_TYPE}"
fi

echo "Detected Platform: $OS_TYPE/$ARCH_TYPE"
echo "Target Release: $RELEASE_NAME"

# 3. Define Rootless paths
INSTALL_BASE="$HOME/.local"
INSTALL_DIR="$INSTALL_BASE/nvim"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

install_nvim() {
    echo "Installing Neovim..."

    # URL for the latest stable release
    DOWNLOAD_URL="https://github.com/neovim/neovim/releases/latest/download/${RELEASE_NAME}.tar.gz"
    TAR_FILE="${RELEASE_NAME}.tar.gz"

    mkdir -p "$INSTALL_BASE"

    # Clean up previous installation
    if [ -d "$INSTALL_DIR" ]; then
        echo "Removing existing Neovim installation at $INSTALL_DIR..."
        rm -rf "$INSTALL_DIR"
    fi

    # Create a temporary directory for download and extraction
    TEMP_DIR=$(mktemp -d)
    echo "Created temporary directory: $TEMP_DIR"
    
    # Ensure cleanup of the temporary directory on exit or return
    # We use a trap for safety, but also explicit removal at the end of the function
    trap 'rm -rf "$TEMP_DIR"' EXIT

    echo "Downloading $DOWNLOAD_URL to $TEMP_DIR..."
    
    if command -v curl >/dev/null 2>&1; then
        echo "Using curl to download..."
        if ! curl -L --fail -o "$TEMP_DIR/$TAR_FILE" "$DOWNLOAD_URL"; then
            echo "Error: Failed to download Neovim using curl."
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        echo "Using wget to download..."
        if ! wget --show-progress -O "$TEMP_DIR/$TAR_FILE" "$DOWNLOAD_URL"; then
            echo "Error: Failed to download Neovim using wget."
            exit 1
        fi
    else
        echo "Error: Neither curl nor wget was found. Please install one to continue."
        exit 1
    fi

    echo "Extracting to $TEMP_DIR..."
    tar -xzf "$TEMP_DIR/$TAR_FILE" -C "$TEMP_DIR"
    
    # Identify the extracted directory name
    # It is expected to be in the temp root
    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "nvim-*" | head -n 1)
    
    if [ -z "$EXTRACTED_DIR" ]; then
         echo "Error: Could not find extracted directory in $TEMP_DIR"
         exit 1
    fi

    mv "$EXTRACTED_DIR" "$INSTALL_DIR"

    # Cleanup is handled by trap, but we can do it explicitly here for this function scope if we weren't exiting
    # Since trap EXIT covers the script exit, it's fine. 
    # However, if the script continues, we should remove it now.
    rm -rf "$TEMP_DIR"
    trap - EXIT # Reset trap so we don't try to remove a non-existent dir later if we reused the variable (though local scoping in bash is tricky)


    echo "Configuring environment variables..."
    
    NVIM_ENV_BLOCK=$(cat <<EOF

# Neovim Environment (Rootless)
export PATH="\$HOME/.local/nvim/bin:\$PATH"
EOF
    )

    UPDATED_FILES=()

    # Check if PATH is already configured
    # This is a simple check; it might not catch all cases if PATH is manipulated complexly
    if [[ ":$PATH:" == *":$INSTALL_DIR/bin:"* ]]; then
        echo "Neovim path is already in the current environment PATH."
        echo "Skipping modification of shell configuration files."
    else
        for CONF in "${SHELL_CONFIGS[@]}"; do
            if [ -f "$CONF" ]; then
                if ! grep -q "export PATH=\"\$HOME/.local/nvim/bin:\$PATH\"" "$CONF"; then
                    echo "$NVIM_ENV_BLOCK" >> "$CONF"
                    UPDATED_FILES+=("$CONF")
                    echo "Added Neovim to PATH in $CONF"
                else
                    echo "Neovim PATH configuration already exists in $CONF. Skipping."
                fi
            fi
        done
    fi

    echo "--------------------------------------------------"
    echo "Installation completed successfully!"
    echo "Installed at: $INSTALL_DIR"
    
    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
        echo "Please run the following command to apply changes:"
        for UPDATED in "${UPDATED_FILES[@]}"; do
            echo "  source $UPDATED"
        done
    fi

    echo "Verify installation by running: $INSTALL_DIR/bin/nvim --version"
    echo "--------------------------------------------------"
}

uninstall_nvim() {
    echo "Uninstalling Neovim..."
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo "Removed directory: $INSTALL_DIR"
    else
        echo "Directory not found: $INSTALL_DIR"
    fi

    echo "Removing configuration from shell files..."
    USER_REMOVED_CONFIG=false
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            if grep -q "# Neovim Environment (Rootless)" "$CONF"; then
                # Remove block starting with the header and the following line
                # Assumes the structure:
                # # Neovim Environment (Rootless)
                # export PATH="$HOME/.local/nvim/bin:$PATH"
                
                # Using sed to delete the block. 
                # This pattern matches the header, then reads the next line (N), then deletes both if it matches.
                # However, a safer approach for variable multiline edits in scripts is often just sed range or specific search.
                # Given our specific insertion, we can try to delete the range.
                
                sed -i.bak '/# Neovim Environment (Rootless)/,/export PATH="\$HOME\/.local\/nvim\/bin:\$PATH"/d' "$CONF" && rm "${CONF}.bak"
                
                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No automatic configuration found to remove."
    fi
    
    echo "Neovim uninstallation completed."
}

repair_nvim() {
    echo "Repairing Neovim..."
    uninstall_nvim
    install_nvim
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_nvim
        ;;
    2)
        uninstall_nvim
        ;;
    3)
        repair_nvim
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
