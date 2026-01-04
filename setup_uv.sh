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
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

install_uv() {
    # 1. Check for prerequisites
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is not installed. Please install curl first."
        exit 1
    fi
    echo "Prerequisites checked."

    # 3. Download and Install uv
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh

    # 4. Configure environment variables
    echo "Configuring environment variables..."
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
    if [ -f "$INSTALL_BIN_DIR/uv" ]; then
        echo "Installed version: $( "$INSTALL_BIN_DIR/uv" --version )"
    fi
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
}

uninstall_uv() {
    echo "Uninstalling uv..."
    if [ -f "$INSTALL_BIN_DIR/uv" ]; then
        rm "$INSTALL_BIN_DIR/uv"
        echo "Removed binary: $INSTALL_BIN_DIR/uv"
    else
        echo "Binary not found: $INSTALL_BIN_DIR/uv"
    fi

    if [ -f "$INSTALL_BIN_DIR/uvx" ]; then
        rm "$INSTALL_BIN_DIR/uvx"
        echo "Removed binary: $INSTALL_BIN_DIR/uvx"
    fi

    # Consider removing cache/config dirs if known/standard
    UV_CACHE_DIR="$HOME/.uv" 
    if [ -d "$UV_CACHE_DIR" ]; then
        rm -rf "$UV_CACHE_DIR"
        echo "Removed cache directory: $UV_CACHE_DIR"
    fi

    echo "Removing configuration from shell files..."
    USER_REMOVED_CONFIG=false
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            if grep -q "# uv path added by setup_uv.sh" "$CONF"; then
                # Create a temporary file
                TMP_FILE=$(mktemp)
                # Remove the block: finding the marker line and the next line (assuming 2 lines: comment and export)
                # Or just simple sed deletion if unique
                # Using sed to delete the marker line and the following line? 
                # The install script adds:
                # echo >> "$CONF" (newline)
                # echo "# uv path added by setup_uv.sh" >> "$CONF"
                # echo "$PATH_LINE" >> "$CONF"
                # So we look for "# uv path added by setup_uv.sh" and remove it and the next line? 
                
                # Let's try to be robust. We search for the pattern.
                sed -i.bak '/# uv path added by setup_uv.sh/{N;d;}' "$CONF" && rm "${CONF}.bak"
                
                # Check if we also added an empty line before? It's hard to track empty lines.
                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            elif grep -q "$INSTALL_BIN_DIR" "$CONF"; then
                 echo "Warning: Found uv path in $CONF but not marked by this script. Skipping auto-removal."
            fi
        fi
    done
    
    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for 'export PATH=...$INSTALL_BIN_DIR...'"
    fi

    echo "uv uninstallation completed."
}

repair_uv() {
    echo "Repairing uv..."
    uninstall_uv
    install_uv
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_uv
        ;;
    2)
        uninstall_uv
        ;;
    3)
        repair_uv
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
