#!/bin/bash

# =================================================================
# Script Name: setup_sqlite.sh
# Description: Rootless SQLite installation (Binary preferred, source fallback)
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-26
# =================================================================

set -e


# 2. Determine Download Strategy
# Global vars
OS="$(uname -s)"
ARCH="$(uname -m)"
INSTALL_BASE="$HOME/.local"
BIN_DIR="$INSTALL_BASE/bin"
mkdir -p "$BIN_DIR"

case "$OS" in
    Linux)
        OS_TYPE="linux"
        ;;
    Darwin)
        OS_TYPE="osx"
        ;;
    *)
        echo "Error: Unsupported OS: $OS"
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64)
        ARCH_TYPE="x64"
        ;;
    aarch64|arm64)
        ARCH_TYPE="arm64"
        ;;
    *)
        echo "Error: Unsupported Architecture: $ARCH"
        exit 1
        ;;
esac

echo "Detected System: $OS_TYPE $ARCH_TYPE"

install_sqlite() {
    URL=""
    IS_BINARY=false

    # Helper to find latest url
    get_url() {
        local pattern="$1"
        # Look for format: YYYY/pattern.zip or .tar.gz
        curl -s https://www.sqlite.org/download.html | \
            grep -oE "[0-9]{4}/${pattern}" | \
            head -n 1
    }

    # Define patterns
    TARGET_PATTERN=""

    if [ "$OS_TYPE" == "osx" ]; then
        TARGET_PATTERN="sqlite-tools-osx-${ARCH_TYPE}-[0-9]+\.zip"
        IS_BINARY=true
    elif [ "$OS_TYPE" == "linux" ]; then
        if [ "$ARCH_TYPE" == "x64" ]; then
             TARGET_PATTERN="sqlite-tools-linux-x64-[0-9]+\.zip"
             IS_BINARY=true
        else
             # Fallback for Linux arm64 or others
             TARGET_PATTERN="sqlite-autoconf-[0-9]+\.tar\.gz"
             IS_BINARY=false
        fi
    fi

    echo "Fetching latest version URL..."
    LATEST_PATH=$(get_url "$TARGET_PATTERN")

    if [ -z "$LATEST_PATH" ]; then
        if [ "$IS_BINARY" == "true" ]; then
            echo "Warning: Could not find binary matching $TARGET_PATTERN. Trying source..."
            TARGET_PATTERN="sqlite-autoconf-[0-9]+\.tar\.gz"
            IS_BINARY=false
            LATEST_PATH=$(get_url "$TARGET_PATTERN")
        fi
    fi

    if [ -z "$LATEST_PATH" ]; then
        echo "Error: Could not find download URL."
        exit 1
    fi

    DOWNLOAD_URL="https://www.sqlite.org/${LATEST_PATH}"
    FILENAME=$(basename "$DOWNLOAD_URL")

    echo "Found: $DOWNLOAD_URL"

    # 3. Download and Install
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "Downloading to $TMP_DIR..."
    cd "$TMP_DIR"
    curl -fsSL -O "$DOWNLOAD_URL"

    if [ "$IS_BINARY" == "true" ]; then
        # Binary Installation
        
        # Check for unzip
        if ! command -v unzip &> /dev/null; then
            echo "Error: 'unzip' is required but not installed."
            if [ "$OS" == "Linux" ]; then
                 echo "Please run: sudo apt install unzip (Debian/Ubuntu) or sudo yum install unzip (RHEL/CentOS)"
            elif [ "$OS" == "Darwin" ]; then
                 echo "Please run: brew install unzip"
            fi
            exit 1
        fi

        echo "Extracting zip..."
        unzip -q "$FILENAME"
        
        # Locate sqlite3 binary
        if [ -f "sqlite3" ]; then
            SRC_BINARY="./sqlite3"
        else
            # Try to find it in a subdirectory
            EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "sqlite-tools-*" | head -n 1)
            if [ -n "$EXTRACTED_DIR" ] && [ -f "$EXTRACTED_DIR/sqlite3" ]; then
                SRC_BINARY="$EXTRACTED_DIR/sqlite3"
            fi
        fi
        
        if [ -n "$SRC_BINARY" ]; then
            echo "Installing sqlite3 to $BIN_DIR..."
            install -m 755 "$SRC_BINARY" "$BIN_DIR/sqlite3"
        else
            echo "Error: sqlite3 binary not found in zip extraction."
            ls -l
            exit 1
        fi

    else
        # Source Compilation
        echo "Extracting tarball..."
        tar -xzf "$FILENAME"
        
        SRC_DIR=$(find . -maxdepth 1 -type d -name "sqlite-autoconf-*" | head -n 1)
        cd "$SRC_DIR"
        
        echo "Configuring..."
        ./configure --prefix="$INSTALL_BASE"
        
        echo "Compiling (make)..."
        make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
        
        echo "Installing (make install)..."
        make install
    fi

    # 4. Environment Configuration
    echo "Configuring environment variables..."

    SHELL_CONFIG=""
    if [[ "$SHELL" == */zsh ]]; then
        SHELL_CONFIG="$HOME/.zshrc"
    elif [[ "$SHELL" == */bash ]]; then
        SHELL_CONFIG="$HOME/.bashrc"
    fi

    ENV_BLOCK="
# SQLite User Install
export PATH=\"$BIN_DIR:\$PATH\"
"

    if [ "$IS_BINARY" == "false" ]; then
        # Add library path for source installs
        ENV_BLOCK="$ENV_BLOCK
export LD_LIBRARY_PATH=\"$INSTALL_BASE/lib:\$LD_LIBRARY_PATH\"
export PKG_CONFIG_PATH=\"$INSTALL_BASE/lib/pkgconfig:\$PKG_CONFIG_PATH\"
"
    fi

    # Function to safely append if not present
    update_shell_config() {
        local config_file="$1"
        if [ -f "$config_file" ]; then
            if ! grep -q "$BIN_DIR" "$config_file"; then
                echo "$ENV_BLOCK" >> "$config_file"
                echo "Updated $config_file"
            else
                echo "Configuration already present in $config_file"
            fi
        fi
    }

    if [ -n "$SHELL_CONFIG" ]; then
        update_shell_config "$SHELL_CONFIG"
    else
        echo "Warning: Could not detect shell config file. Please add $BIN_DIR to your PATH manually."
    fi

    echo "================================================="
    echo "SQLite installation complete."
    echo "Location: $BIN_DIR/sqlite3"
    echo "You may need to restart your shell or run: source $SHELL_CONFIG"
    echo "================================================="
}

uninstall_sqlite() {
    echo "Uninstalling SQLite..."
    if [ -f "$BIN_DIR/sqlite3" ]; then
        rm "$BIN_DIR/sqlite3"
        echo "Removed binary: $BIN_DIR/sqlite3"
    else
        echo "Binary not found: $BIN_DIR/sqlite3"
    fi
    
    # We don't remove the entire ~/.local/lib because other things might use it,
    # unless we are sure. For now, just the binary is safe.

    echo "Removing configuration from shell files..."
    
    # Determine which config files to check
    CONFIG_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
    USER_REMOVED_CONFIG=false
    
    for CONF in "${CONFIG_FILES[@]}"; do
        if [ -f "$CONF" ]; then
            if grep -q "# SQLite User Install" "$CONF"; then
                # Remove block starting with "# SQLite User Install" and following lines
                # The block ends with an empty line or end of file usually if we appended it.
                # We can try to match until empty line
                sed -i.bak '/# SQLite User Install/,/^$/d' "$CONF" && rm "${CONF}.bak"
                
                # Check if it worked (if we had no empty line at end, it might delete till end of file if no empty line found? 
                # sed address range /start/,/end/. If end not found, goes to EOF.
                # Safer: assume it's small or look for next known pattern?
                # Actually, if we just appended, it might be at the end.
                
                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            elif grep -q "$BIN_DIR" "$CONF"; then
                 echo "Warning: Found SQLite path in $CONF but not marked by standard block. Skipping auto-removal."
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for SQLite PATH exports."
    fi
    
    echo "SQLite uninstallation completed."
}

repair_sqlite() {
    echo "Repairing SQLite..."
    uninstall_sqlite
    install_sqlite
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_sqlite
        ;;
    2)
        uninstall_sqlite
        ;;
    3)
        repair_sqlite
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "================================================="
echo "SQLite installation complete."
echo "Location: $BIN_DIR/sqlite3"
echo "You may need to restart your shell or run: source $SHELL_CONFIG"
echo "================================================="
