#!/bin/bash

# ==========================================================
# Script Name: setup_go.sh
# Description: Rootless Go environment setup for Debian/macOS
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-24
# ==========================================================

set -e


# 2. Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)     OS_TYPE="linux" ;;
    Darwin)    OS_TYPE="darwin" ;;
    *)         echo "Error: Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64)          ARCH_TYPE="amd64" ;;
    aarch64|arm64)   ARCH_TYPE="arm64" ;;
    *)               echo "Error: Unsupported Architecture: $ARCH"; exit 1 ;;
esac

echo "Detected Platform: $OS_TYPE/$ARCH_TYPE"

# 3. Define Rootless paths
INSTALL_BASE="$HOME/.local"
GOROOT_DIR="$INSTALL_BASE/go"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

install_go() {
    # 1. Fetch the latest Go version
    echo "Checking for the latest Go version..."
    GO_VERSION=$(curl -s https://go.dev/dl/?mode=json | grep -o 'go[0-9.]*' | head -n 1)

    if [ -z "$GO_VERSION" ]; then
        echo "Error: Could not fetch the latest Go version."
        exit 1
    fi
    echo "Latest version found: $GO_VERSION"

    TAR_FILE="${GO_VERSION}.${OS_TYPE}-${ARCH_TYPE}.tar.gz"
    DOWNLOAD_URL="https://go.dev/dl/${TAR_FILE}"

    # Create the directory if it doesn't exist
    mkdir -p "$INSTALL_BASE"

    # 3. Clean up previous installation
    if [ -d "$GOROOT_DIR" ]; then
        echo "Removing existing Go installation at $GOROOT_DIR..."
        rm -rf "$GOROOT_DIR"
    fi

    # 4. Download and Extract
    echo "Downloading $DOWNLOAD_URL..."
    wget -q --show-progress "$DOWNLOAD_URL"

    echo "Extracting to $INSTALL_BASE..."
    tar -C "$INSTALL_BASE" -xzf "$TAR_FILE"

    # 5. Clean up the downloaded tarball
    rm "$TAR_FILE"

    # 6. Configure environment variables
    echo "Configuring environment variables..."

    GO_ENV_BLOCK=$(cat <<EOF

# Go Environment (Rootless)
export GOROOT=\$HOME/.local/go
export GOPATH=\$HOME/go
export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin
EOF
    )

    UPDATED_FILES=()

    # Check if GOROOT is already configured in the current environment
    if [ "$GOROOT" = "$GOROOT_DIR" ] && [[ ":$PATH:" == *":$GOROOT/bin:"* ]]; then
        echo "Go environment variables are already correctly configured in the current shell."
        echo "Skipping modification of shell configuration files."
    else
        for CONF in "${SHELL_CONFIGS[@]}"; do
            if [ -f "$CONF" ]; then
                if ! grep -q "export GOROOT=" "$CONF"; then
                    echo "$GO_ENV_BLOCK" >> "$CONF"
                    UPDATED_FILES+=("$CONF")
                    echo "Added Go environment to $CONF"
                else
                    echo "Go environment already exists in $CONF. Skipping."
                fi
            fi
        done
    fi

    # 7. Finalize
    echo "--------------------------------------------------"
    echo "Rootless installation completed successfully!"
    echo "Installed at: $GOROOT_DIR"

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
        echo "Please run the following command to apply changes:"
        for UPDATED in "${UPDATED_FILES[@]}"; do
            echo "  source $UPDATED"
        done
    fi

    echo "Verify installation: go version"
    echo "--------------------------------------------------"
}

uninstall_go() {
    echo "Uninstalling Go..."
    if [ -d "$GOROOT_DIR" ]; then
        rm -rf "$GOROOT_DIR"
        echo "Removed directory: $GOROOT_DIR"
    else
        echo "Directory not found: $GOROOT_DIR"
    fi
    
    # Not removing GOPATH ($HOME/go) as it contains user data

    echo "Removing configuration from shell files..."
    USER_REMOVED_CONFIG=false
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            if grep -q "# Go Environment (Rootless)" "$CONF"; then
                # Remove block starting with "# Go Environment (Rootless)" and ending with the PATH export
                sed -i.bak '/# Go Environment (Rootless)/,/export PATH=\$PATH:\$GOROOT\/bin:\$GOPATH\/bin/d' "$CONF" && rm "${CONF}.bak"
                
                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            elif grep -q "export GOROOT=" "$CONF"; then
                 echo "Warning: Found Go configuration in $CONF but not marked by standard block. Skipping auto-removal."
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for 'export GOROOT=...'"
    fi
    
    echo "Go uninstallation completed."
}

repair_go() {
    echo "Repairing Go..."
    uninstall_go
    install_go
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_go
        ;;
    2)
        uninstall_go
        ;;
    3)
        repair_go
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac