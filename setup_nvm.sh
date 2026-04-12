#!/bin/bash

# =================================================================
# Script Name: setup_nvm.sh
# Description: NVM configuration script
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2026-04-11
# =================================================================

set -e


# 2. Define global variables
INSTALL_DIR="$HOME/.nvm"
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc")

install_nvm() {
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

    # 5. Configure default-packages (auto-installed for every new Node version)
    DEFAULT_PACKAGES_FILE="$INSTALL_DIR/default-packages"
    if [ ! -f "$DEFAULT_PACKAGES_FILE" ]; then
        echo "Creating default-packages file at $DEFAULT_PACKAGES_FILE..."
        cat > "$DEFAULT_PACKAGES_FILE" <<PKGEOF
# Packages listed here will be automatically installed when you run 'nvm install <version>'.
# One package per line. You can pin versions with @, e.g. typescript@5
PKGEOF
        echo "Edit $DEFAULT_PACKAGES_FILE to add packages you want in every Node version."
    fi

    # 6. Configure environment variables
    echo "Configuring environment variables..."

    NVM_ENV_BLOCK=$(cat <<EOF

# NVM Configuration
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
    )

    UPDATED_FILES=()

    for CONF in "${SHELL_CONFIGS[@]}"; do
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
}

uninstall_nvm() {
    echo "Uninstalling NVM..."

    # Remove default-packages file
    DEFAULT_PACKAGES_FILE="$INSTALL_DIR/default-packages"
    if [ -f "$DEFAULT_PACKAGES_FILE" ]; then
        rm -f "$DEFAULT_PACKAGES_FILE"
        echo "Removed: $DEFAULT_PACKAGES_FILE"
    fi

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
            if grep -q "# NVM Configuration" "$CONF"; then
                # Remove block from "# NVM Configuration" to the last PATH line we added
                # We match from "NVM Configuration" to just before a blank line that follows our block
                sed -i.bak '/# NVM Configuration/,/nvm bash_completion/d' "$CONF" && rm -f "${CONF}.bak"

                echo "Removed configuration from $CONF"
                USER_REMOVED_CONFIG=true
            elif grep -q 'export NVM_DIR="$HOME/.nvm"' "$CONF"; then
                 echo "Warning: Found NVM configuration in $CONF but not marked by standard block. Skipping auto-removal."
            fi
        fi
    done

    if [ "$USER_REMOVED_CONFIG" = false ]; then
         echo "No configuration found to remove or manual removal required."
         echo "Please manually check your .bashrc/.zshrc for 'export NVM_DIR=...' and '~/.npm-global' references."
    fi

    echo "NVM uninstallation completed."
}

repair_nvm() {
    echo "Repairing NVM..."
    uninstall_nvm
    install_nvm
}

echo "Choose an option:"
echo "1. install (default)"
echo "2. uninstall"
echo "3. repair"
read -p "Enter selection [1]: " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        install_nvm
        ;;
    2)
        uninstall_nvm
        ;;
    3)
        repair_nvm
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
