#!/bin/bash

# =================================================================
# Script Name: setup_quickDAV.sh
# Description: Quick WebDAV share/mount manager driven by rclone
#              (rootless, single-binary, JSON-config under ~/.config)
# OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
# Date: 2026-05-20
# =================================================================

set -e

# ----------------- 1. Platform detection -----------------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)  OS_TYPE="linux" ;;
    Darwin) OS_TYPE="osx" ;;
    *) echo "Error: Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64)        ARCH_TYPE="amd64" ;;
    aarch64|arm64) ARCH_TYPE="arm64" ;;
    *) echo "Error: Unsupported Architecture: $ARCH"; exit 1 ;;
esac

# jq release naming differs slightly
case "$OS_TYPE" in
    linux) JQ_OS="linux" ;;
    osx)   JQ_OS="macos" ;;
esac

# ----------------- 2. Paths -----------------
INSTALL_BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickDAV"
CRED_FILE="$CONFIG_DIR/credentials.json"
SHARE_FILE="$CONFIG_DIR/shares.json"
MOUNT_FILE="$CONFIG_DIR/mounts.json"
RCLONE_CONF="$CONFIG_DIR/rclone.conf"
RUN_DIR="$CONFIG_DIR/run"
LOG_DIR="$CONFIG_DIR/logs"

# Prefer system-installed binaries; fall back to our private install dir
if command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN="$(command -v rclone)"
else
    RCLONE_BIN="$INSTALL_BIN_DIR/rclone"
fi

if command -v jq >/dev/null 2>&1; then
    JQ_BIN="$(command -v jq)"
else
    JQ_BIN="$INSTALL_BIN_DIR/jq"
fi

# Wrappers so callers always invoke the right binary
rclone() { "$RCLONE_BIN" "$@"; }
jq()     { "$JQ_BIN" "$@"; }

# ----------------- 3. Dependency installation -----------------
need_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: 'curl' is required but not found."
        exit 1
    fi
}

extract_zip() {
    # Usage: extract_zip <zipfile> <dest_dir>
    local zip="$1" dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip" -d "$dest"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$zip" -C "$dest"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest"
    else
        echo "Error: need 'unzip', 'bsdtar', or 'python3' to extract archives."
        exit 1
    fi
}

# Download with sane network timeouts so a stalled mirror fails fast
# instead of hanging forever. Tries each URL in turn until one succeeds.
# Usage: download_with_fallback <output_file> <url1> [url2 ...]
download_with_fallback() {
    local out="$1"; shift
    local url
    for url in "$@"; do
        [ -z "$url" ] && continue
        echo "  -> $url"
        if curl -fL --progress-bar \
                --connect-timeout 15 \
                --max-time 600 \
                --retry 3 \
                --retry-delay 2 \
                --retry-connrefused \
                -o "$out" "$url"; then
            return 0
        fi
        echo "  (failed, trying next mirror if available...)"
    done
    return 1
}

# Best-effort lookup of the latest rclone version tag (e.g. "v1.66.0").
# Falls back to "current" symlink naming when we cannot reach GitHub.
latest_rclone_version() {
    local v
    v="$(curl -fsSL --connect-timeout 10 --max-time 20 \
            https://api.github.com/repos/rclone/rclone/releases/latest 2>/dev/null \
            | grep -m1 '"tag_name"' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    printf '%s' "$v"
}

install_rclone() {
    if [ -x "$RCLONE_BIN" ]; then return 0; fi
    need_curl
    mkdir -p "$INSTALL_BIN_DIR"
    local tmp
    tmp="$(mktemp -d)"

    # Build candidate URL list: env override > official > GitHub release mirror.
    local urls=()
    [ -n "$QUICKDAV_RCLONE_URL" ] && urls+=("$QUICKDAV_RCLONE_URL")
    urls+=("https://downloads.rclone.org/rclone-current-${OS_TYPE}-${ARCH_TYPE}.zip")
    local ver
    ver="$(latest_rclone_version)"
    if [ -n "$ver" ]; then
        urls+=("https://github.com/rclone/rclone/releases/download/${ver}/rclone-${ver}-${OS_TYPE}-${ARCH_TYPE}.zip")
    fi

    echo "Downloading rclone (will try ${#urls[@]} source(s); set QUICKDAV_RCLONE_URL to override)..."
    if ! download_with_fallback "$tmp/rclone.zip" "${urls[@]}"; then
        echo "Error: failed to download rclone from all sources."
        echo "Hint: set QUICKDAV_RCLONE_URL to a reachable mirror, or place a"
        echo "      'rclone' binary at: $INSTALL_BIN_DIR/rclone"
        rm -rf "$tmp"
        exit 1
    fi

    extract_zip "$tmp/rclone.zip" "$tmp"
    local found
    found="$(find "$tmp" -type f -name rclone | head -n 1)"
    if [ -z "$found" ]; then
        echo "Error: could not locate rclone binary in archive."
        rm -rf "$tmp"
        exit 1
    fi
    mv "$found" "$INSTALL_BIN_DIR/rclone"
    chmod +x "$INSTALL_BIN_DIR/rclone"
    rm -rf "$tmp"
    RCLONE_BIN="$INSTALL_BIN_DIR/rclone"
    echo "rclone installed at $RCLONE_BIN ($("$RCLONE_BIN" version | head -n 1))"
}

install_jq() {
    if [ -x "$JQ_BIN" ]; then return 0; fi
    need_curl
    mkdir -p "$INSTALL_BIN_DIR"

    local urls=()
    [ -n "$QUICKDAV_JQ_URL" ] && urls+=("$QUICKDAV_JQ_URL")
    urls+=("https://github.com/jqlang/jq/releases/latest/download/jq-${JQ_OS}-${ARCH_TYPE}")

    echo "Downloading jq (will try ${#urls[@]} source(s); set QUICKDAV_JQ_URL to override)..."
    if ! download_with_fallback "$INSTALL_BIN_DIR/jq" "${urls[@]}"; then
        echo "Error: failed to download jq from all sources."
        echo "Hint: set QUICKDAV_JQ_URL to a reachable mirror, or place a"
        echo "      'jq' binary at: $INSTALL_BIN_DIR/jq"
        rm -f "$INSTALL_BIN_DIR/jq"
        exit 1
    fi
    chmod +x "$INSTALL_BIN_DIR/jq"
    JQ_BIN="$INSTALL_BIN_DIR/jq"
    echo "jq installed at $JQ_BIN ($("$JQ_BIN" --version))"
}

ensure_dependencies() {
    install_rclone
    install_jq
}

# ----------------- 4. Config bootstrap -----------------
ensure_config() {
    mkdir -p "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR"
    chmod 700 "$CONFIG_DIR"
    local f
    for f in "$CRED_FILE" "$SHARE_FILE" "$MOUNT_FILE"; do
        if [ ! -f "$f" ]; then
            printf '%s\n' '[]' > "$f"
            chmod 600 "$f"
        fi
    done
    if [ ! -f "$RCLONE_CONF" ]; then
        : > "$RCLONE_CONF"
        chmod 600 "$RCLONE_CONF"
    fi
}

json_write() {
    # Usage: json_write <file> <json_string>
    local file="$1" content="$2"
    local tmp="$file.tmp.$$"
    printf '%s\n' "$content" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# ----------------- 5. Misc helpers -----------------
canon_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null || echo "$p"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
    else
        ( cd "$p" 2>/dev/null && pwd ) || echo "$p"
    fi
}

is_running() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 1
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null
}

fuse_userland_present() {
    if [ "$OS_TYPE" = "linux" ]; then
        command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1
    else
        [ -d /Library/Filesystems/macfuse.fs ] \
            || [ -d /Library/Filesystems/osxfuse.fs ] \
            || [ -d /Library/Filesystems/fuse-t.fs ]
    fi
}

# Detect Linux distro family for package manager hints / auto-install.
# Echoes one of: debian | rhel | fedora | arch | suse | alpine | unknown
linux_distro_family() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi
    case " $id $like " in
        *" debian "*|*" ubuntu "*) echo debian ;;
        *" fedora "*)              echo fedora ;;
        *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) echo rhel ;;
        *" arch "*|*" manjaro "*)  echo arch ;;
        *" suse "*|*" opensuse "*) echo suse ;;
        *" alpine "*)              echo alpine ;;
        *)                         echo unknown ;;
    esac
}

# Build the recommended install command for the FUSE userland on this Linux
# distro. Echoes the command, or empty if unknown.
fuse_install_command() {
    case "$(linux_distro_family)" in
        debian) echo "sudo apt-get update && sudo apt-get install -y fuse3" ;;
        fedora) echo "sudo dnf install -y fuse3" ;;
        rhel)   echo "sudo dnf install -y fuse3 || sudo yum install -y fuse3" ;;
        arch)   echo "sudo pacman -S --noconfirm fuse3" ;;
        suse)   echo "sudo zypper install -y fuse3" ;;
        alpine) echo "sudo apk add fuse3" ;;
        *)      echo "" ;;
    esac
}

# Returns 0 if FUSE userland is ready (or was just installed), 1 otherwise.
# May prompt the user to run a sudo install command on Linux.
ensure_fuse() {
    if fuse_userland_present; then
        return 0
    fi

    if [ "$OS_TYPE" != "linux" ]; then
        echo "Error: macFUSE / FUSE-T not detected."
        echo "  Install macFUSE: https://osxfuse.github.io/ (requires admin)"
        echo "  or FUSE-T:       https://www.fuse-t.org/"
        return 1
    fi

    echo "Error: FUSE userland not found (need 'fusermount3' or 'fusermount')."
    local cmd
    cmd="$(fuse_install_command)"
    if [ -z "$cmd" ]; then
        echo "  Please install the 'fuse3' package using your distro's package manager,"
        echo "  then retry the mount."
        return 1
    fi

    echo "  Recommended install command:"
    echo "      $cmd"
    if ! command -v sudo >/dev/null 2>&1; then
        echo "  'sudo' is not available; run the command above as root, then retry."
        return 1
    fi

    local yn
    read -rp "Run it now via sudo? [y/N] " yn
    case "$yn" in
        y|Y|yes|YES)
            if bash -c "$cmd"; then
                if fuse_userland_present; then
                    echo "FUSE userland installed."
                    return 0
                fi
                echo "Install command finished but 'fusermount3'/'fusermount' still not found."
                return 1
            else
                echo "Install command failed (exit $?)."
                return 1
            fi
            ;;
        *)
            echo "Skipped. Install 'fuse3' manually and retry the mount."
            return 1
            ;;
    esac
}

# Returns 0 if the path is currently a mountpoint (including stale FUSE mounts).
is_mountpoint() {
    local p="$1"
    [ -n "$p" ] || return 1
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$p" 2>/dev/null && return 0
    fi
    if [ -r /proc/self/mountinfo ]; then
        awk -v p="$p" '$5 == p { found=1 } END { exit !found }' /proc/self/mountinfo \
            && return 0
    fi
    return 1
}

# Robustly unmount a FUSE mount, escalating to lazy unmount for stale states
# (e.g. when the backing rclone process died, leaving "Transport endpoint is
# not connected"). Echoes a short status. Returns 0 on success.
fuse_unmount() {
    local p="$1"
    [ -n "$p" ] || return 1
    # Nothing to do if it is not a mountpoint at all.
    if ! is_mountpoint "$p"; then
        return 0
    fi

    if [ "$OS_TYPE" = "linux" ]; then
        local cmd=""
        if command -v fusermount3 >/dev/null 2>&1; then cmd="fusermount3"
        elif command -v fusermount  >/dev/null 2>&1; then cmd="fusermount"
        fi
        if [ -n "$cmd" ]; then
            "$cmd" -u  "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
            "$cmd" -uz "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
        fi
        umount    "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
        umount -l "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
    else
        umount "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
        diskutil unmount force "$p" 2>/dev/null && ! is_mountpoint "$p" && return 0
    fi
    return 1
}

# Repair a stale mount point at an arbitrary path (not necessarily one of ours).
clean_stale_mountpoint() {
    local p
    read -rp "Stale mount point to clean: " p
    [ -z "$p" ] && { echo "Cancelled."; return; }
    # Expand ~
    case "$p" in
        "~"|"~/"*) p="${HOME}${p#\~}" ;;
    esac
    if ! is_mountpoint "$p"; then
        echo "Not a mountpoint: $p"
        return
    fi
    if fuse_unmount "$p"; then
        echo "Unmounted: $p"
        local yn
        read -rp "Remove empty directory '$p'? [y/N] " yn
        case "$yn" in
            y|Y|yes|YES)
                if rmdir "$p" 2>/dev/null; then
                    echo "Directory removed."
                else
                    echo "Could not rmdir (not empty or in use)."
                fi
                ;;
        esac
    else
        echo "Failed to unmount '$p'."
        echo "Try manually:  fusermount3 -uz '$p'   or   umount -l '$p'"
    fi
}

obscure_password() {
    rclone obscure "$1"
}

# ----------------- 6. Credentials -----------------
cred_get() {
    # cred_get <name> <field>
    jq -r --arg n "$1" --arg f "$2" \
        '.[] | select(.name == $n) | .[$f] // empty' "$CRED_FILE"
}

cred_exists() {
    local cnt
    cnt="$(jq --arg n "$1" '[.[] | select(.name == $n)] | length' "$CRED_FILE")"
    [ "$cnt" -gt 0 ]
}

cred_names() {
    jq -r '.[].name' "$CRED_FILE"
}

cred_list() {
    local cnt
    cnt="$(jq 'length' "$CRED_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "  (no credentials configured)"
        return
    fi
    printf "  %-20s %-20s\n" "NAME" "USERNAME"
    printf "  %-20s %-20s\n" "----" "--------"
    jq -r '.[] | "\(.name)\t\(.username)"' "$CRED_FILE" | \
        while IFS=$'\t' read -r n u; do
            printf "  %-20s %-20s\n" "$n" "$u"
        done
}

cred_add() {
    local name user pass1 pass2 obscured
    read -rp "Credential name: " name
    [ -z "$name" ] && { echo "Aborted (empty name)."; return; }
    if cred_exists "$name"; then
        echo "Credential '$name' already exists."
        return
    fi
    read -rp "Username: " user
    read -rsp "Password: " pass1; echo
    read -rsp "Confirm:  " pass2; echo
    if [ "$pass1" != "$pass2" ]; then
        echo "Passwords do not match. Aborted."
        return
    fi
    obscured="$(obscure_password "$pass1")"
    local new
    new="$(jq --arg n "$name" --arg u "$user" --arg p "$obscured" \
        '. + [{"name":$n,"username":$u,"password":$p}]' "$CRED_FILE")"
    json_write "$CRED_FILE" "$new"
    echo "Credential '$name' saved."
}

cred_edit() {
    cred_list
    local name
    read -rp "Name to edit: " name
    [ -z "$name" ] && return
    cred_exists "$name" || { echo "Not found."; return; }
    local cur_user user pass1 pass2 new
    cur_user="$(cred_get "$name" username)"
    read -rp "Username [$cur_user]: " user
    user="${user:-$cur_user}"
    read -rsp "New password (empty = keep current): " pass1; echo
    if [ -z "$pass1" ]; then
        new="$(jq --arg n "$name" --arg u "$user" \
            'map(if .name == $n then .username = $u else . end)' "$CRED_FILE")"
    else
        read -rsp "Confirm: " pass2; echo
        if [ "$pass1" != "$pass2" ]; then
            echo "Passwords do not match. Aborted."
            return
        fi
        local obscured
        obscured="$(obscure_password "$pass1")"
        new="$(jq --arg n "$name" --arg u "$user" --arg p "$obscured" \
            'map(if .name == $n then (.username = $u | .password = $p) else . end)' "$CRED_FILE")"
    fi
    json_write "$CRED_FILE" "$new"
    echo "Credential '$name' updated."
}

cred_delete() {
    cred_list
    local name
    read -rp "Name to delete: " name
    [ -z "$name" ] && return
    cred_exists "$name" || { echo "Not found."; return; }
    if jq -e --arg n "$name" 'any(.[]; .credential == $n)' "$SHARE_FILE" >/dev/null; then
        echo "Cannot delete: credential '$name' is referenced by a share."
        return
    fi
    if jq -e --arg n "$name" 'any(.[]; .credential == $n)' "$MOUNT_FILE" >/dev/null; then
        echo "Cannot delete: credential '$name' is referenced by a mount."
        return
    fi
    local new
    new="$(jq --arg n "$name" 'map(select(.name != $n))' "$CRED_FILE")"
    json_write "$CRED_FILE" "$new"
    echo "Credential '$name' deleted."
}

pick_credential() {
    # Prints chosen credential name to stdout, "" on cancel. Prompts on stderr.
    local cnt
    cnt="$(jq 'length' "$CRED_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "No credentials configured. Add one via 'Manage Credentials' first." >&2
        return 1
    fi
    {
        echo "Available credentials:"
        jq -r '.[] | "  - \(.name) (\(.username))"' "$CRED_FILE"
    } >&2
    local name
    read -rp "Credential name: " name
    [ -z "$name" ] && return 1
    if ! cred_exists "$name"; then
        echo "Credential '$name' not found." >&2
        return 1
    fi
    echo "$name"
}

# ----------------- 7. Shares (rclone serve webdav) -----------------
share_pid_file()  { echo "$RUN_DIR/share-$1.pid"; }
share_log_file()  { echo "$LOG_DIR/share-$1.log"; }
mount_pid_file()  { echo "$RUN_DIR/mount-$1.pid"; }
mount_log_file()  { echo "$LOG_DIR/mount-$1.log"; }

share_exists() {
    local cnt
    cnt="$(jq --arg n "$1" '[.[] | select(.name == $n)] | length' "$SHARE_FILE")"
    [ "$cnt" -gt 0 ]
}

share_list() {
    local cnt
    cnt="$(jq 'length' "$SHARE_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "  (no shares configured)"
        return
    fi
    printf "  %-16s %-22s %-40s %-10s\n" "NAME" "ADDRESS" "LOCAL_PATH" "STATE"
    printf "  %-16s %-22s %-40s %-10s\n" "----" "-------" "----------" "-----"
    jq -r '.[] | "\(.name)\t\(.listen_host):\(.listen_port)\t\(.local_path)"' "$SHARE_FILE" | \
    while IFS=$'\t' read -r n addr p; do
        local state="stopped"
        if is_running "$(share_pid_file "$n")"; then state="running"; fi
        printf "  %-16s %-22s %-40s %-10s\n" "$n" "$addr" "$p" "$state"
    done
}

share_create() {
    local name cred path host port
    read -rp "Share name: " name
    [ -z "$name" ] && return
    if share_exists "$name"; then
        echo "Share '$name' already exists."
        return
    fi
    cred="$(pick_credential)" || return
    read -rp "Local directory to share [$PWD]: " path
    path="${path:-$PWD}"
    if [ ! -d "$path" ]; then
        echo "Directory '$path' does not exist."
        return
    fi
    path="$(canon_path "$path")"
    read -rp "Listen host [127.0.0.1]: " host
    host="${host:-127.0.0.1}"
    read -rp "Listen port [8080]: " port
    port="${port:-8080}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Invalid port: $port"
        return
    fi
    local new
    new="$(jq --arg n "$name" --arg c "$cred" --arg p "$path" \
              --arg h "$host" --argjson po "$port" \
        '. + [{"name":$n,"credential":$c,"local_path":$p,"listen_host":$h,"listen_port":$po}]' \
        "$SHARE_FILE")"
    json_write "$SHARE_FILE" "$new"
    echo "Share '$name' configured: http://${host}:${port}/  ->  $path"
    local yn
    read -rp "Start it now? [Y/n] " yn
    if [[ "${yn:-Y}" != "n" && "${yn:-Y}" != "N" ]]; then
        share_start "$name"
    fi
}

share_start() {
    local name="$1"
    share_exists "$name" || { echo "Share '$name' not found."; return 1; }
    local pid_file log_file
    pid_file="$(share_pid_file "$name")"
    log_file="$(share_log_file "$name")"
    if is_running "$pid_file"; then
        echo "Share '$name' is already running (PID $(cat "$pid_file"))."
        return 0
    fi
    rm -f "$pid_file"

    local row path host port cred user pass_obs pass
    row="$(jq --arg n "$name" '.[] | select(.name == $n)' "$SHARE_FILE")"
    path="$(printf '%s' "$row" | jq -r '.local_path')"
    host="$(printf '%s' "$row" | jq -r '.listen_host')"
    port="$(printf '%s' "$row" | jq -r '.listen_port')"
    cred="$(printf '%s' "$row" | jq -r '.credential')"
    user="$(cred_get "$cred" username)"
    pass_obs="$(cred_get "$cred" password)"
    if [ -z "$user" ] || [ -z "$pass_obs" ]; then
        echo "Credential '$cred' missing or incomplete."
        return 1
    fi
    pass="$(rclone reveal "$pass_obs")"

    # Pass user/pass via environment to avoid exposing them via `ps`.
    # rclone honours RCLONE_<UPPER_FLAG> env vars.
    : > "$log_file"
    # VFS tuning notes:
    #   --dir-cache-time 1s  : default is 5m; that causes WebDAV clients
    #                          (e.g. Obsidian Remotely Save) to see stale
    #                          Last-Modified headers when the underlying
    #                          tree changes. 1s is effectively "always fresh"
    #                          while still de-duplicating bursts of PROPFIND
    #                          calls. Dir cache is lazy-refreshed on access,
    #                          so an idle server costs nothing.
    #   --vfs-refresh        : prime the dir cache on startup so the very
    #                          first PROPFIND already sees the full tree.
    #   --etag-hash auto     : let rclone compute an ETag from the backend's
    #                          hash, which gives WebDAV clients a stable way
    #                          to detect content changes alongside mtime.
    RCLONE_USER="$user" RCLONE_PASS="$pass" \
        nohup "$RCLONE_BIN" serve webdav "$path" \
            --addr "${host}:${port}" \
            --dir-cache-time 1s \
            --vfs-refresh \
            --etag-hash auto \
            --log-file "$log_file" \
            --log-level INFO \
            </dev/null >>"$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    disown "$pid" 2>/dev/null || true
    sleep 1
    if is_running "$pid_file"; then
        echo "Share '$name' started (PID $(cat "$pid_file"))  ->  http://${host}:${port}/"
    else
        echo "Failed to start share '$name'. See $log_file"
        rm -f "$pid_file"
        return 1
    fi
}

share_stop() {
    local name="$1"
    local pid_file
    pid_file="$(share_pid_file "$name")"
    if is_running "$pid_file"; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        # Give it a moment to die gracefully
        local i
        for i in 1 2 3 4 5; do
            is_running "$pid_file" || break
            sleep 0.3
        done
        if is_running "$pid_file"; then
            kill -9 "$(cat "$pid_file")" 2>/dev/null || true
        fi
        rm -f "$pid_file"
        echo "Share '$name' stopped."
    else
        rm -f "$pid_file"
        echo "Share '$name' is not running."
    fi
}

share_delete() {
    local name="$1"
    share_exists "$name" || { echo "Share '$name' not found."; return 1; }
    if is_running "$(share_pid_file "$name")"; then
        share_stop "$name"
    fi
    local new
    new="$(jq --arg n "$name" 'map(select(.name != $n))' "$SHARE_FILE")"
    json_write "$SHARE_FILE" "$new"
    echo "Share '$name' deleted."
}

# ----------------- 8. Mounts (rclone mount) -----------------
mount_exists() {
    local cnt
    cnt="$(jq --arg n "$1" '[.[] | select(.name == $n)] | length' "$MOUNT_FILE")"
    [ "$cnt" -gt 0 ]
}

mount_list() {
    local cnt
    cnt="$(jq 'length' "$MOUNT_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "  (no mounts configured)"
        return
    fi
    printf "  %-16s %-35s %-30s %-10s\n" "NAME" "URL" "MOUNT_POINT" "STATE"
    printf "  %-16s %-35s %-30s %-10s\n" "----" "---" "-----------" "-----"
    jq -r '.[] | "\(.name)\t\(.url)\t\(.mount_point)"' "$MOUNT_FILE" | \
    while IFS=$'\t' read -r n u p; do
        local state="unmounted"
        if is_running "$(mount_pid_file "$n")"; then state="mounted"; fi
        printf "  %-16s %-35s %-30s %-10s\n" "$n" "$u" "$p" "$state"
    done
}

mount_create() {
    local name cred url point
    read -rp "Mount name: " name
    [ -z "$name" ] && return
    if mount_exists "$name"; then
        echo "Mount '$name' already exists."
        return
    fi
    cred="$(pick_credential)" || return
    read -rp "WebDAV URL (e.g. http://10.0.0.1:8080/): " url
    [ -z "$url" ] && { echo "URL required."; return; }
    read -rp "Mount point [$HOME/quickDAV/$name]: " point
    point="${point:-$HOME/quickDAV/$name}"
    local new
    new="$(jq --arg n "$name" --arg c "$cred" --arg u "$url" --arg p "$point" \
        '. + [{"name":$n,"credential":$c,"url":$u,"mount_point":$p}]' \
        "$MOUNT_FILE")"
    json_write "$MOUNT_FILE" "$new"
    echo "Mount '$name' configured."
    local yn
    read -rp "Mount now? [Y/n] " yn
    if [[ "${yn:-Y}" != "n" && "${yn:-Y}" != "N" ]]; then
        mount_start "$name"
    fi
}

mount_start() {
    local name="$1"
    mount_exists "$name" || { echo "Mount '$name' not found."; return 1; }
    local pid_file log_file
    pid_file="$(mount_pid_file "$name")"
    log_file="$(mount_log_file "$name")"
    if is_running "$pid_file"; then
        echo "Mount '$name' is already mounted (PID $(cat "$pid_file"))."
        return 0
    fi
    rm -f "$pid_file"

    local row url cred point user pass
    row="$(jq --arg n "$name" '.[] | select(.name == $n)' "$MOUNT_FILE")"
    url="$(printf '%s' "$row"  | jq -r '.url')"
    cred="$(printf '%s' "$row" | jq -r '.credential')"
    point="$(printf '%s' "$row"| jq -r '.mount_point')"
    user="$(cred_get "$cred" username)"
    pass="$(cred_get "$cred" password)"  # already obscured for rclone
    if [ -z "$user" ] || [ -z "$pass" ]; then
        echo "Credential '$cred' missing or incomplete."
        return 1
    fi

    if ! ensure_fuse; then
        echo "Mount '$name' aborted: FUSE userland is not available."
        return 1
    fi
    mkdir -p "$point"

    # Use a connection string so we do not need to persist a rclone remote
    # per mount. The password is the rclone-obscured form (not plaintext).
    local conn
    conn=":webdav,url='${url}',vendor='other',user='${user}',pass='${pass}':"

    : > "$log_file"
    # Mirror the serve-side cache tuning so the FUSE view also picks up
    # remote changes within a second rather than minutes.
    nohup "$RCLONE_BIN" mount "$conn" "$point" \
        --vfs-cache-mode writes \
        --dir-cache-time 1s \
        --vfs-refresh \
        --log-file "$log_file" \
        --log-level INFO \
        </dev/null >>"$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    disown "$pid" 2>/dev/null || true
    sleep 2
    if is_running "$pid_file"; then
        echo "Mount '$name' active at $point (PID $(cat "$pid_file"))."
    else
        echo "Failed to mount '$name'. See $log_file"
        rm -f "$pid_file"
        return 1
    fi
}

mount_stop() {
    local name="$1"
    mount_exists "$name" || { echo "Mount '$name' not found."; return 1; }
    local row point pid_file
    row="$(jq --arg n "$name" '.[] | select(.name == $n)' "$MOUNT_FILE")"
    point="$(printf '%s' "$row" | jq -r '.mount_point')"
    pid_file="$(mount_pid_file "$name")"

    if is_mountpoint "$point"; then
        if fuse_unmount "$point"; then
            :
        else
            echo "Warning: could not unmount '$point' cleanly."
            echo "         Try manually:  fusermount3 -uz '$point'"
        fi
    fi

    if is_running "$pid_file"; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do
            is_running "$pid_file" || break
            sleep 0.3
        done
        is_running "$pid_file" && kill -9 "$(cat "$pid_file")" 2>/dev/null || true
    fi
    rm -f "$pid_file"
    echo "Mount '$name' stopped."
}

mount_delete() {
    local name="$1"
    mount_exists "$name" || { echo "Mount '$name' not found."; return 1; }
    if is_running "$(mount_pid_file "$name")"; then
        mount_stop "$name"
    fi
    local new
    new="$(jq --arg n "$name" 'map(select(.name != $n))' "$MOUNT_FILE")"
    json_write "$MOUNT_FILE" "$new"
    echo "Mount '$name' deleted."
}

# ----------------- 9. Refresh -----------------
refresh_all() {
    echo "Stopping all shares and mounts..."
    local n
    for n in $(jq -r '.[].name' "$MOUNT_FILE"); do
        mount_stop "$n" || true
    done
    for n in $(jq -r '.[].name' "$SHARE_FILE"); do
        share_stop "$n" || true
    done

    echo "Starting all shares and mounts..."
    for n in $(jq -r '.[].name' "$SHARE_FILE"); do
        share_start "$n" || true
    done
    for n in $(jq -r '.[].name' "$MOUNT_FILE"); do
        mount_start "$n" || true
    done
    echo "Refresh complete."
}

# ----------------- 9b. Maintenance (status / update / clear / uninstall) -----------------
# SCRIPT_PATH: absolute path of the running script, or empty when started via
# 'curl ... | bash' (BASH_SOURCE[0] is empty there). Many maintenance ops
# need a real on-disk file; they use ensure_local_script to install one when
# SCRIPT_PATH is empty.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH="$(canon_path "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH=""
fi
LOCAL_SCRIPT_PATH="$INSTALL_BIN_DIR/setup_quickDAV.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/ashton2914/script/main/setup_quickDAV.sh"

# Install (or refresh) a local copy of this script at $LOCAL_SCRIPT_PATH.
# Source selection:
#   1. If we are already running from $LOCAL_SCRIPT_PATH       -> no-op.
#   2. If SCRIPT_PATH points at an on-disk script elsewhere    -> copy it.
#   3. Otherwise (curl|bash, or file missing)                  -> download
#      from $QUICKDAV_SCRIPT_URL (defaults to $DEFAULT_SCRIPT_URL).
install_local_script() {
    mkdir -p "$INSTALL_BIN_DIR"
    local tmp source_desc
    tmp="$(mktemp)"

    if [ -n "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" = "$LOCAL_SCRIPT_PATH" ] && [ -f "$LOCAL_SCRIPT_PATH" ]; then
        echo "Already installed: $LOCAL_SCRIPT_PATH (currently running from it)."
        rm -f "$tmp"
        return 0
    fi

    if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
        cp "$SCRIPT_PATH" "$tmp"
        source_desc="copied from $SCRIPT_PATH"
    else
        need_curl
        local url="${QUICKDAV_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"
        echo "Downloading setup_quickDAV.sh (set QUICKDAV_SCRIPT_URL to override)..."
        if ! download_with_fallback "$tmp" "$url"; then
            echo "Failed to download script from $url"
            rm -f "$tmp"
            return 1
        fi
        source_desc="downloaded from $url"
    fi

    if [ ! -s "$tmp" ] || ! head -n 1 "$tmp" | grep -q '^#!' \
       || ! bash -n "$tmp" 2>/dev/null; then
        echo "Script validation failed (empty, missing shebang, or syntax error)."
        rm -f "$tmp"
        return 1
    fi

    if ! mv "$tmp" "$LOCAL_SCRIPT_PATH"; then
        echo "Failed to write $LOCAL_SCRIPT_PATH"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$LOCAL_SCRIPT_PATH"
    echo "Installed local script ($source_desc):"
    echo "  $LOCAL_SCRIPT_PATH"
    return 0
}

# Return (via stdout) a path to an executable copy of this script on disk,
# installing $LOCAL_SCRIPT_PATH if necessary. Returns non-zero on failure.
ensure_local_script() {
    if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] && [ -x "$SCRIPT_PATH" ]; then
        printf '%s' "$SCRIPT_PATH"
        return 0
    fi
    if [ -f "$LOCAL_SCRIPT_PATH" ] && [ -x "$LOCAL_SCRIPT_PATH" ]; then
        printf '%s' "$LOCAL_SCRIPT_PATH"
        return 0
    fi
    echo "No on-disk script found (running via curl|bash?)." >&2
    echo "Installing a local copy first..." >&2
    install_local_script >&2 || return 1
    printf '%s' "$LOCAL_SCRIPT_PATH"
}

show_status() {
    echo
    echo "--- quickDAV status ---"
    echo "  Config dir : $CONFIG_DIR"
    echo "  Bin dir    : $INSTALL_BIN_DIR"
    local rv jv
    rv="$("$RCLONE_BIN" version 2>/dev/null | head -n 1)"
    jv="$("$JQ_BIN" --version 2>/dev/null)"
    echo "  rclone     : $RCLONE_BIN ${rv:+($rv)}"
    echo "  jq         : $JQ_BIN ${jv:+($jv)}"

    echo
    echo "Credentials:"
    cred_list

    echo
    echo "Shares:"
    local sc
    sc="$(jq 'length' "$SHARE_FILE")"
    if [ "$sc" -eq 0 ]; then
        echo "  (none)"
    else
        jq -r '.[] | "\(.name)\t\(.listen_host):\(.listen_port)\t\(.local_path)\t\(.credential)"' "$SHARE_FILE" | \
        while IFS=$'\t' read -r n a p c; do
            local pf state pid
            pf="$(share_pid_file "$n")"
            if is_running "$pf"; then state="running"; pid="$(cat "$pf")"; else state="stopped"; pid="-"; fi
            printf "  - %s\n      addr   : http://%s/\n      path   : %s\n      cred   : %s\n      state  : %s (PID %s)\n      log    : %s\n" \
                "$n" "$a" "$p" "$c" "$state" "$pid" "$(share_log_file "$n")"
        done
    fi

    echo
    echo "Mounts:"
    local mc
    mc="$(jq 'length' "$MOUNT_FILE")"
    if [ "$mc" -eq 0 ]; then
        echo "  (none)"
    else
        jq -r '.[] | "\(.name)\t\(.url)\t\(.mount_point)\t\(.credential)"' "$MOUNT_FILE" | \
        while IFS=$'\t' read -r n u p c; do
            local pf state pid
            pf="$(mount_pid_file "$n")"
            if is_running "$pf"; then state="mounted"; pid="$(cat "$pf")"; else state="unmounted"; pid="-"; fi
            printf "  - %s\n      url    : %s\n      point  : %s\n      cred   : %s\n      state  : %s (PID %s)\n      log    : %s\n" \
                "$n" "$u" "$p" "$c" "$state" "$pid" "$(mount_log_file "$n")"
        done
    fi
    echo
}

# Print rclone short version (e.g. "v1.66.0"), empty on failure.
rclone_short_version() {
    local bin="$1"
    [ -x "$bin" ] || return 1
    "$bin" version 2>/dev/null | head -n 1 | awk '{print $2}'
}

update_rclone() {
    need_curl
    if [ ! -x "$RCLONE_BIN" ]; then
        echo "rclone is not installed yet. Restart the script to bootstrap it."
        return 1
    fi
    local cur_ver
    cur_ver="$(rclone_short_version "$RCLONE_BIN")"
    echo "Current rclone: $RCLONE_BIN (${cur_ver:-unknown})"

    # If the active rclone is not the one we manage, do not overwrite it.
    if [ "$RCLONE_BIN" != "$INSTALL_BIN_DIR/rclone" ]; then
        echo
        echo "This rclone is provided by your system (not managed by quickDAV)."
        echo "Update it through your OS package manager, e.g.:"
        echo "    sudo apt-get install --only-upgrade rclone"
        local yn
        read -rp "Install a private copy into '$INSTALL_BIN_DIR' instead? [y/N] " yn
        case "$yn" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled."; return 0 ;;
        esac
    fi

    # Build URL list (mirrors install_rclone()).
    local urls=()
    [ -n "$QUICKDAV_RCLONE_URL" ] && urls+=("$QUICKDAV_RCLONE_URL")
    urls+=("https://downloads.rclone.org/rclone-current-${OS_TYPE}-${ARCH_TYPE}.zip")
    local latest
    latest="$(latest_rclone_version)"
    if [ -n "$latest" ]; then
        urls+=("https://github.com/rclone/rclone/releases/download/${latest}/rclone-${latest}-${OS_TYPE}-${ARCH_TYPE}.zip")
    fi

    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$INSTALL_BIN_DIR"

    echo "Downloading rclone (will try ${#urls[@]} source(s); set QUICKDAV_RCLONE_URL to override)..."
    if ! download_with_fallback "$tmp/rclone.zip" "${urls[@]}"; then
        echo "Update failed: could not download rclone from any source."
        rm -rf "$tmp"
        return 1
    fi
    extract_zip "$tmp/rclone.zip" "$tmp"
    local found
    found="$(find "$tmp" -type f -name rclone | head -n 1)"
    if [ -z "$found" ]; then
        echo "Update failed: rclone binary not found in archive."
        rm -rf "$tmp"
        return 1
    fi
    chmod +x "$found"
    local new_ver
    new_ver="$(rclone_short_version "$found")"
    echo "Downloaded rclone: ${new_ver:-unknown}"

    # If we're replacing the SAME path with the SAME version, skip.
    if [ "$RCLONE_BIN" = "$INSTALL_BIN_DIR/rclone" ] \
       && [ -n "$cur_ver" ] && [ -n "$new_ver" ] && [ "$cur_ver" = "$new_ver" ]; then
        echo "Already up to date: $cur_ver"
        rm -rf "$tmp"
        return 0
    fi

    # Heads-up about live processes still holding the old binary.
    local running=0 pf
    if [ -d "$RUN_DIR" ]; then
        for pf in "$RUN_DIR"/*.pid; do
            [ -f "$pf" ] || continue
            is_running "$pf" && running=$((running + 1))
        done
    fi

    # Backup any previous private copy we are about to replace.
    if [ -f "$INSTALL_BIN_DIR/rclone" ]; then
        local bak="$INSTALL_BIN_DIR/rclone.bak.$(date +%Y%m%d%H%M%S)"
        cp "$INSTALL_BIN_DIR/rclone" "$bak"
        echo "Backed up old binary to: $bak"
    fi

    if ! mv "$found" "$INSTALL_BIN_DIR/rclone"; then
        echo "Update failed: could not install new rclone binary."
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    RCLONE_BIN="$INSTALL_BIN_DIR/rclone"

    echo "rclone updated: ${cur_ver:-unknown} -> ${new_ver:-unknown}"
    echo "Active path   : $RCLONE_BIN"
    if [ "$running" -gt 0 ]; then
        echo "Note: $running running share/mount process(es) still use the old binary."
        echo "      Use option 6 (Refresh) to restart them with the new version."
    fi
    if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
        echo "Hint: '$INSTALL_BIN_DIR' is not on PATH; add it so 'rclone' on your"
        echo "      shell refers to this version:"
        echo "          export PATH=\"$INSTALL_BIN_DIR:\$PATH\""
    fi
}

clear_all_shares() {
    local cnt
    cnt="$(jq 'length' "$SHARE_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "No shares to clear."
        return
    fi
    echo "This will STOP and DELETE all $cnt share(s)."
    local yn
    read -rp "Type 'yes' to confirm: " yn
    [ "$yn" = "yes" ] || { echo "Cancelled."; return; }
    local n
    for n in $(jq -r '.[].name' "$SHARE_FILE"); do
        share_stop "$n" || true
    done
    json_write "$SHARE_FILE" '[]'
    rm -f "$RUN_DIR"/share-*.pid
    echo "All shares cleared."
}

clear_all_mounts() {
    local cnt
    cnt="$(jq 'length' "$MOUNT_FILE")"
    if [ "$cnt" -eq 0 ]; then
        echo "No mounts to clear."
        return
    fi
    echo "This will UNMOUNT and DELETE all $cnt mount(s)."
    local yn
    read -rp "Type 'yes' to confirm: " yn
    [ "$yn" = "yes" ] || { echo "Cancelled."; return; }
    local n
    for n in $(jq -r '.[].name' "$MOUNT_FILE"); do
        mount_stop "$n" || true
    done
    json_write "$MOUNT_FILE" '[]'
    rm -f "$RUN_DIR"/mount-*.pid
    echo "All mounts cleared."
}

uninstall_all() {
    echo "This will:"
    echo "  - Disable autostart (if enabled)"
    echo "  - Stop all running shares and mounts"
    echo "  - Delete config directory: $CONFIG_DIR"
    local will_rm_rclone="no" will_rm_jq="no" will_rm_local="no"
    if [ "$RCLONE_BIN" = "$INSTALL_BIN_DIR/rclone" ] && [ -x "$INSTALL_BIN_DIR/rclone" ]; then
        echo "  - Remove private rclone binary: $INSTALL_BIN_DIR/rclone"
        will_rm_rclone="yes"
    fi
    if [ "$JQ_BIN" = "$INSTALL_BIN_DIR/jq" ] && [ -x "$INSTALL_BIN_DIR/jq" ]; then
        echo "  - Remove private jq binary:     $INSTALL_BIN_DIR/jq"
        will_rm_jq="yes"
    fi
    if [ -f "$LOCAL_SCRIPT_PATH" ]; then
        echo "  - Remove local script copy:     $LOCAL_SCRIPT_PATH"
        will_rm_local="yes"
    fi
    local yn
    read -rp "Type 'yes' to confirm uninstall: " yn
    [ "$yn" = "yes" ] || { echo "Cancelled."; return; }

    autostart_disable >/dev/null 2>&1 || true

    local n
    if [ -f "$MOUNT_FILE" ]; then
        for n in $(jq -r '.[].name' "$MOUNT_FILE" 2>/dev/null); do
            mount_stop "$n" || true
        done
    fi
    if [ -f "$SHARE_FILE" ]; then
        for n in $(jq -r '.[].name' "$SHARE_FILE" 2>/dev/null); do
            share_stop "$n" || true
        done
    fi

    rm -rf "$CONFIG_DIR"
    [ "$will_rm_rclone" = "yes" ] && rm -f "$INSTALL_BIN_DIR/rclone"
    [ "$will_rm_jq"     = "yes" ] && rm -f "$INSTALL_BIN_DIR/jq"
    [ "$will_rm_local"  = "yes" ] && rm -f "$LOCAL_SCRIPT_PATH"

    echo "Uninstall complete."
    if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "$LOCAL_SCRIPT_PATH" ]; then
        local yn2
        read -rp "Also remove this script ($SCRIPT_PATH)? [y/N] " yn2
        case "$yn2" in
            y|Y|yes|YES) rm -f "$SCRIPT_PATH" && echo "Script removed." ;;
            *) echo "Script kept at: $SCRIPT_PATH" ;;
        esac
    fi
    exit 0
}

# ----------------- 9c. Non-interactive boot mode -----------------
# Start every configured share and mount, then exit. Used by systemd/launchd.
boot_start_all() {
    set +e
    echo "[quickDAV] boot: starting all shares and mounts..."
    local n started=0 failed=0
    if [ -f "$SHARE_FILE" ]; then
        for n in $(jq -r '.[].name' "$SHARE_FILE" 2>/dev/null); do
            if share_start "$n"; then started=$((started + 1)); else failed=$((failed + 1)); fi
        done
    fi
    if [ -f "$MOUNT_FILE" ]; then
        for n in $(jq -r '.[].name' "$MOUNT_FILE" 2>/dev/null); do
            if mount_start "$n"; then started=$((started + 1)); else failed=$((failed + 1)); fi
        done
    fi
    echo "[quickDAV] boot: done ($started started, $failed failed)."
    set -e
    return 0
}

# Stop everything (used as systemd ExecStop).
boot_stop_all() {
    set +e
    echo "[quickDAV] shutdown: stopping all mounts and shares..."
    local n
    if [ -f "$MOUNT_FILE" ]; then
        for n in $(jq -r '.[].name' "$MOUNT_FILE" 2>/dev/null); do
            mount_stop "$n" || true
        done
    fi
    if [ -f "$SHARE_FILE" ]; then
        for n in $(jq -r '.[].name' "$SHARE_FILE" 2>/dev/null); do
            share_stop "$n" || true
        done
    fi
    echo "[quickDAV] shutdown: done."
    set -e
    return 0
}

# ----------------- 9d. Autostart (systemd user / launchd) -----------------
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SYSTEMD_UNIT_NAME="quickdav.service"
SYSTEMD_UNIT_PATH="$SYSTEMD_USER_DIR/$SYSTEMD_UNIT_NAME"
LAUNCHD_LABEL="com.user.quickdav"
LAUNCHD_PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

autostart_supported() {
    if [ "$OS_TYPE" = "linux" ]; then
        command -v systemctl >/dev/null 2>&1
    else
        command -v launchctl >/dev/null 2>&1
    fi
}

autostart_unit_path() {
    if [ "$OS_TYPE" = "linux" ]; then echo "$SYSTEMD_UNIT_PATH"; else echo "$LAUNCHD_PLIST_PATH"; fi
}

autostart_status() {
    if ! autostart_supported; then
        echo "  Autostart not supported on this system."
        return 1
    fi
    if [ "$OS_TYPE" = "linux" ]; then
        if [ -f "$SYSTEMD_UNIT_PATH" ]; then
            echo "  Unit file : $SYSTEMD_UNIT_PATH (installed)"
        else
            echo "  Unit file : not installed"
        fi
        if systemctl --user is-enabled "$SYSTEMD_UNIT_NAME" >/dev/null 2>&1; then
            echo "  Enabled   : yes"
        else
            echo "  Enabled   : no"
        fi
        if systemctl --user is-active "$SYSTEMD_UNIT_NAME" >/dev/null 2>&1; then
            echo "  Active    : yes"
        else
            echo "  Active    : no"
        fi
        if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
            echo "  Linger    : yes  (runs at machine boot, before login)"
        else
            echo "  Linger    : no   (only starts after first user login)"
            echo "              Enable with:  sudo loginctl enable-linger $USER"
        fi
    else
        if [ -f "$LAUNCHD_PLIST_PATH" ]; then
            echo "  Plist     : $LAUNCHD_PLIST_PATH (installed)"
        else
            echo "  Plist     : not installed"
        fi
        if launchctl list 2>/dev/null | grep -q "$LAUNCHD_LABEL"; then
            echo "  Loaded    : yes"
        else
            echo "  Loaded    : no"
        fi
    fi
}

autostart_enable() {
    if ! autostart_supported; then
        echo "Autostart not supported on this system."
        return 1
    fi
    local effective_script
    effective_script="$(ensure_local_script)" || {
        echo "Cannot enable autostart without a local script copy."
        return 1
    }
    chmod +x "$effective_script" 2>/dev/null || true

    if [ "$OS_TYPE" = "linux" ]; then
        mkdir -p "$SYSTEMD_USER_DIR"
        cat > "$SYSTEMD_UNIT_PATH" <<EOF
[Unit]
Description=quickDAV - WebDAV shares and mounts (rclone)
After=default.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=${INSTALL_BIN_DIR}:/usr/local/bin:/usr/bin:/bin
ExecStart=${effective_script} --boot
ExecStop=${effective_script} --stop-all

[Install]
WantedBy=default.target
EOF
        chmod 644 "$SYSTEMD_UNIT_PATH"
        systemctl --user daemon-reload
        if systemctl --user enable --now "$SYSTEMD_UNIT_NAME"; then
            echo "Autostart enabled: $SYSTEMD_UNIT_PATH"
            echo "             via: $effective_script"
        else
            echo "Warning: 'systemctl --user enable --now' returned non-zero."
            echo "         Check:  systemctl --user status $SYSTEMD_UNIT_NAME"
        fi
        if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
            echo
            echo "Note: services only start after you log in for the first time."
            echo "      To start at machine boot, enable linger (one-time, needs sudo):"
            echo "          sudo loginctl enable-linger $USER"
        fi
    else
        mkdir -p "$(dirname "$LAUNCHD_PLIST_PATH")"
        mkdir -p "$LOG_DIR"
        cat > "$LAUNCHD_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${effective_script}</string>
        <string>--boot</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>${INSTALL_BIN_DIR}:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key><string>${LOG_DIR}/autostart.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/autostart.log</string>
</dict>
</plist>
EOF
        launchctl unload "$LAUNCHD_PLIST_PATH" 2>/dev/null || true
        if launchctl load "$LAUNCHD_PLIST_PATH"; then
            echo "Autostart enabled: $LAUNCHD_PLIST_PATH"
            echo "             via: $effective_script"
        else
            echo "Failed to load LaunchAgent."
            return 1
        fi
    fi
}

autostart_disable() {
    if ! autostart_supported; then
        echo "Autostart not supported on this system."
        return 1
    fi
    if [ "$OS_TYPE" = "linux" ]; then
        systemctl --user disable --now "$SYSTEMD_UNIT_NAME" 2>/dev/null || true
        rm -f "$SYSTEMD_UNIT_PATH"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "Autostart disabled."
    else
        launchctl unload "$LAUNCHD_PLIST_PATH" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST_PATH"
        echo "Autostart disabled."
    fi
}

# ----------------- 10. Sub-menus -----------------
menu_credentials() {
    set +e
    while true; do
        echo
        echo "--- Manage Credentials ---"
        cred_list
        echo
        echo " 1) Add"
        echo " 2) Edit"
        echo " 3) Delete"
        echo " 0) Back"
        local c
        read -rp "Select> " c
        case "$c" in
            1) cred_add ;;
            2) cred_edit ;;
            3) cred_delete ;;
            0|"") set -e; return ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

menu_shares() {
    set +e
    while true; do
        echo
        echo "--- Manage Shares ---"
        share_list
        echo
        echo " 1) Start a share"
        echo " 2) Stop a share"
        echo " 3) Delete a share"
        echo " 4) Show share log"
        echo " 0) Back"
        local c n
        read -rp "Select> " c
        case "$c" in
            1) read -rp "Name: " n; [ -n "$n" ] && share_start "$n" ;;
            2) read -rp "Name: " n; [ -n "$n" ] && share_stop  "$n" ;;
            3) read -rp "Name: " n; [ -n "$n" ] && share_delete "$n" ;;
            4) read -rp "Name: " n
               [ -n "$n" ] && {
                   local f; f="$(share_log_file "$n")"
                   if [ -f "$f" ]; then tail -n 40 "$f"; else echo "No log: $f"; fi
               } ;;
            0|"") set -e; return ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

menu_mounts() {
    set +e
    while true; do
        echo
        echo "--- Manage Mounts ---"
        mount_list
        echo
        echo " 1) Mount"
        echo " 2) Unmount"
        echo " 3) Delete a mount"
        echo " 4) Show mount log"
        echo " 5) Clean stale mountpoint (fix 'Transport endpoint is not connected')"
        echo " 0) Back"
        local c n
        read -rp "Select> " c
        case "$c" in
            1) read -rp "Name: " n; [ -n "$n" ] && mount_start "$n" ;;
            2) read -rp "Name: " n; [ -n "$n" ] && mount_stop  "$n" ;;
            3) read -rp "Name: " n; [ -n "$n" ] && mount_delete "$n" ;;
            4) read -rp "Name: " n
               [ -n "$n" ] && {
                   local f; f="$(mount_log_file "$n")"
                   if [ -f "$f" ]; then tail -n 40 "$f"; else echo "No log: $f"; fi
               } ;;
            5) clean_stale_mountpoint ;;
            0|"") set -e; return ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

menu_autostart() {
    set +e
    while true; do
        echo
        echo "--- Autostart (run at boot/login) ---"
        autostart_status
        echo
        echo " 1) Enable autostart"
        echo " 2) Disable autostart"
        echo " 3) Show unit/plist path"
        echo " 4) View unit/plist contents"
        echo " 5) Install / refresh local script copy ($LOCAL_SCRIPT_PATH)"
        echo " 0) Back"
        local c f
        read -rp "Select> " c
        case "$c" in
            1) autostart_enable ;;
            2) autostart_disable ;;
            3) autostart_unit_path ;;
            4) f="$(autostart_unit_path)"
               if [ -f "$f" ]; then cat "$f"; else echo "Not installed: $f"; fi ;;
            5) install_local_script ;;
            0|"") set -e; return ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ----------------- 11. Main menu -----------------
main_menu() {
    set +e
    while true; do
        echo
        echo "============================================="
        echo " quickDAV - WebDAV Share/Mount Manager"
        echo " Config: $CONFIG_DIR"
        echo "============================================="
        echo "  1) Manage Credentials"
        echo "  2) Share          (create a new share)"
        echo "  3) Manage Shares  (list / start / stop / delete)"
        echo "  4) Mount          (create a new mount)"
        echo "  5) Manage Mounts  (list / mount / unmount / delete)"
        echo "  6) Refresh shares and mounts"
        echo "  7) Show status"
        echo "  8) Manage Autostart (run at boot/login)"
        echo " 88) Update rclone"
        echo " 91) Clear ALL shares"
        echo " 92) Clear ALL mounts"
        echo " 99) Uninstall quickDAV"
        echo "  0) Exit"
        echo "============================================="
        local c
        read -rp "Select: " c
        case "$c" in
            1)  menu_credentials ;;
            2)  share_create ;;
            3)  menu_shares ;;
            4)  mount_create ;;
            5)  menu_mounts ;;
            6)  refresh_all ;;
            7)  show_status ;;
            8)  menu_autostart ;;
            88) update_rclone ;;
            91) clear_all_shares ;;
            92) clear_all_mounts ;;
            99) uninstall_all ;;
            0|"") echo "Bye."; exit 0 ;;
            *)  echo "Invalid choice." ;;
        esac
    done
}

# ----------------- 12. Bootstrap -----------------
ensure_dependencies
ensure_config

# Non-interactive entry points (used by systemd/launchd autostart units).
case "${1:-}" in
    --boot|boot|start-all)
        boot_start_all
        exit 0
        ;;
    --stop-all|stop-all)
        boot_stop_all
        exit 0
        ;;
    --help|-h|help)
        cat <<USAGE
Usage: $0 [OPTION]

With no arguments, launches the interactive menu.

  --boot, start-all   Start all configured shares and mounts (non-interactive).
  --stop-all          Stop all running shares and mounts.
  --help              Show this message.
USAGE
        exit 0
        ;;
    "")
        : # fall through to interactive
        ;;
    *)
        echo "Unknown argument: $1"
        echo "Run '$0 --help' for usage."
        exit 1
        ;;
esac

# Reminder if our private bin dir is not yet on PATH
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]] && \
   { [ "$RCLONE_BIN" = "$INSTALL_BIN_DIR/rclone" ] || [ "$JQ_BIN" = "$INSTALL_BIN_DIR/jq" ]; }; then
    echo "Note: '$INSTALL_BIN_DIR' is not in PATH."
    echo "      Add this to your shell rc to use rclone/jq directly:"
    echo "          export PATH=\"$INSTALL_BIN_DIR:\$PATH\""
fi

main_menu
