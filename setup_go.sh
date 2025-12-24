#!/bin/bash

# ==========================================================
# Script Name: setup_go.sh
# Description: Rootless Go environment setup for Debian/macOS
# Date: 2025-12-24
# ==========================================================

set -e

# 1. Fetch the latest Go version for Linux AMD64
echo "Checking for the latest Go version..."
GO_VERSION=$(curl -s https://go.dev/dl/?mode=json | grep -o 'go[0-9.]*' | head -n 1)

if [ -z "$GO_VERSION" ]; then
    echo "Error: Could not fetch the latest Go version."
    exit 1
fi

echo "Latest version found: $GO_VERSION"

# 2. Define Rootless paths
INSTALL_BASE="$HOME/.local"
GOROOT_DIR="$INSTALL_BASE/go"
TAR_FILE="${GO_VERSION}.linux-amd64.tar.gz"
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

# List of potential config files
CONFIG_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
UPDATED_FILES=()

for CONF in "${CONFIG_FILES[@]}"; do
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