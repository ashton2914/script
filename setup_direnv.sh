#!/bin/bash

# =================================================================
# Script Name: setup_direnv.sh
# Description: Script to install direnv and configure shell hooks
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2025-12-26
# =================================================================

set -e

# 1. Check for prerequisites
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is not installed. Please install curl first."
    exit 1
fi

echo "Prerequisites checked."


# 2. Define Installation Paths and Version
INSTALL_BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DIRENV_VERSION="v2.32.1" # Pinning a stable version
OS="$(uname -s)"
ARCH="$(uname -m)"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")
DIRENV_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/direnv"

# Map OS and ARCH to direnv release naming
case "$OS" in
    Linux)
        OS_NAME="linux"
        ;;
    Darwin)
        OS_NAME="darwin"
        ;;
    *)
        echo "Error: Unsupported OS: $OS"
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64)
        ARCH_NAME="amd64"
        ;;
    arm64|aarch64)
        ARCH_NAME="arm64"
        ;;
    *)
        echo "Error: Unsupported Architecture: $ARCH"
        exit 1
        ;;
esac

install_direnv() {
    # 1. Check for prerequisites
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is not installed. Please install curl first."
        exit 1
    fi
    echo "Prerequisites checked."

    # Fix for macOS arm64 naming in direnv releases
    if [ "$OS_NAME" == "darwin" ] && [ "$ARCH_NAME" == "arm64" ]; then
        :
    fi

    # Construct URL based on official release naming convention
    DOWNLOAD_URL="https://github.com/direnv/direnv/releases/download/${DIRENV_VERSION}/direnv.${OS_NAME}-${ARCH_NAME}"

    # 3. Download and Install direnv
    echo "Installing direnv ${DIRENV_VERSION}..."
    mkdir -p "$INSTALL_BIN_DIR"
    curl -L "$DOWNLOAD_URL" -o "$INSTALL_BIN_DIR/direnv"
    chmod +x "$INSTALL_BIN_DIR/direnv"

    echo "direnv installed to $INSTALL_BIN_DIR/direnv"

    # 4. Configure environment variables
    echo "Configuring environment variables..."

    PATH_LINE="export PATH=\"$INSTALL_BIN_DIR:\$PATH\""
    UPDATED_FILES=()

    # Function to get the hook line for a specific shell
    get_hook_line() {
        local shell_name="$1"
        if [ "$shell_name" == "bash" ]; then
            echo 'eval "$(direnv hook bash)"'
        elif [ "$shell_name" == "zsh" ]; then
            echo 'eval "$(direnv hook zsh)"'
        fi
    }

    # Ensure PATH is configured
    if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
        for CONF in "${SHELL_CONFIGS[@]}"; do
            if [ -f "$CONF" ]; then
                if ! grep -q "$INSTALL_BIN_DIR" "$CONF"; then
                    echo "" >> "$CONF"
                    echo "# direnv path added by setup_direnv.sh" >> "$CONF"
                    echo "$PATH_LINE" >> "$CONF"
                fi
            fi
        done
    fi

    # Ensure Hooks are configured
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            SHELL_TYPE=""
            if [[ "$CONF" == *".bashrc" ]]; then
                SHELL_TYPE="bash"
            elif [[ "$CONF" == *".zshrc" ]]; then
                SHELL_TYPE="zsh"
            fi

            HOOK_LINE=$(get_hook_line "$SHELL_TYPE")
            
            if [ -n "$HOOK_LINE" ]; then
                if ! grep -q "direnv hook $SHELL_TYPE" "$CONF"; then
                    echo "" >> "$CONF"
                    echo "# direnv hook added by setup_direnv.sh" >> "$CONF"
                    echo "$HOOK_LINE" >> "$CONF"
                    UPDATED_FILES+=("$CONF")
                    echo "Added direnv hook to $CONF"
                else
                    echo "direnv hook already exists in $CONF. Skipping."
                fi
            fi
        fi
    done

    # 6. Configure Global direnvrc for uv integration
    echo "Configuring global direnvrc for uv..."
    mkdir -p "$DIRENV_CONFIG_DIR"
    DIRENVRC="$DIRENV_CONFIG_DIR/direnvrc"

    LAYOUT_UV_FUNC=$(cat <<'EOF'

# Custom layout for uv
layout_uv() {
    if [[ ! -x "$(command -v uv)" ]]; then
        log_error "uv is not installed. Please install uv first."
        return 1
    fi

    if [[ ! -d ".venv" ]]; then
        log_status "Creating virtual environment with uv..."
        uv venv
    fi

    export VIRTUAL_ENV="$(pwd)/.venv"
    PATH_add "$VIRTUAL_ENV/bin"
}
EOF
    )

    if [ -f "$DIRENVRC" ]; then
        if ! grep -q "layout_uv" "$DIRENVRC"; then
            echo "$LAYOUT_UV_FUNC" >> "$DIRENVRC"
            echo "Added layout_uv to $DIRENVRC"
        else
            echo "layout_uv already exists in $DIRENVRC. Skipping."
        fi
    else
        echo "$LAYOUT_UV_FUNC" > "$DIRENVRC"
        echo "Created $DIRENVRC with layout_uv"
    fi

    # 7. Finalize
    echo "--------------------------------------------------"
    echo "direnv setup completed successfully!"
    echo "Installed version: $("$INSTALL_BIN_DIR/direnv" version)"
    echo ""

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
        echo "Please run the following command to apply changes:"
        for UPDATED in "${UPDATED_FILES[@]}"; do
            echo "  source $UPDATED"
        done
    else
        echo "Configuration appears up to date."
    fi

    echo "--------------------------------------------------"
    echo "Usage:"
    echo "1. Go to your project directory"
    echo "2. Run 'echo layout uv > .envrc'"
    echo "3. Run 'direnv allow'"
    echo "   This will automatically create and activate a uv virtualenv."
    echo "--------------------------------------------------"
}

uninstall_direnv() {
    echo "Uninstalling direnv..."
    if [ -f "$INSTALL_BIN_DIR/direnv" ]; then
        rm "$INSTALL_BIN_DIR/direnv"
        echo "Removed binary: $INSTALL_BIN_DIR/direnv"
    else
        echo "Binary not found: $INSTALL_BIN_DIR/direnv"
    fi

    if [ -d "$DIRENV_CONFIG_DIR" ]; then
        rm -rf "$DIRENV_CONFIG_DIR"
        echo "Removed config dir: $DIRENV_CONFIG_DIR"
    fi

    echo "Removing configuration from shell files..."
    USER_REMOVED_CONFIG=false
    for CONF in "${SHELL_CONFIGS[@]}"; do
        if [ -f "$CONF" ]; then
            # Remove Path block
            if grep -q "# direnv path added by setup_direnv.sh" "$CONF"; then
                sed -i.bak '/# direnv path added by setup_direnv.sh/{N;d;}' "$CONF" && rm "${CONF}.bak"
                echo "Removed path configuration from $CONF"
                USER_REMOVED_CONFIG=true
            fi
            
            # Remove Hook block
            if grep -q "# direnv hook added by setup_direnv.sh" "$CONF"; then
                sed -i.bak '/# direnv hook added by setup_direnv.sh/{N;d;}' "$CONF" && rm "${CONF}.bak"
                echo "Removed hook configuration from $CONF"
                USER_REMOVED_CONFIG=true
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for direnv configuration."
    fi

    echo "direnv uninstallation completed."
}

repair_direnv() {
    echo "Repairing direnv..."
    uninstall_direnv
    install_direnv
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_direnv
        ;;
    2)
        uninstall_direnv
        ;;
    3)
        repair_direnv
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
