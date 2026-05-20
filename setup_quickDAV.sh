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

install_rclone() {
    if [ -x "$RCLONE_BIN" ]; then return 0; fi
    need_curl
    mkdir -p "$INSTALL_BIN_DIR"
    local tmp url
    tmp="$(mktemp -d)"
    url="https://downloads.rclone.org/rclone-current-${OS_TYPE}-${ARCH_TYPE}.zip"
    echo "Downloading rclone from $url ..."
    curl -fL --progress-bar -o "$tmp/rclone.zip" "$url"
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
    local url="https://github.com/jqlang/jq/releases/latest/download/jq-${JQ_OS}-${ARCH_TYPE}"
    echo "Downloading jq from $url ..."
    curl -fL --progress-bar -o "$INSTALL_BIN_DIR/jq" "$url"
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

check_fuse() {
    if [ "$OS_TYPE" = "linux" ]; then
        if command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1; then
            return 0
        fi
        echo "Warning: FUSE userland not found."
        echo "  On Debian/Ubuntu: install 'fuse3' package."
        echo "  On RHEL/Fedora:   install 'fuse3' package."
        echo "Mount will likely fail until FUSE is available."
        return 0
    else
        if [ -d /Library/Filesystems/macfuse.fs ] \
           || [ -d /Library/Filesystems/osxfuse.fs ] \
           || [ -d /Library/Filesystems/fuse-t.fs ]; then
            return 0
        fi
        echo "Warning: macFUSE / FUSE-T not detected."
        echo "  Install macFUSE: https://osxfuse.github.io/ (requires admin)"
        echo "  or FUSE-T:       https://www.fuse-t.org/"
        return 0
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
    RCLONE_USER="$user" RCLONE_PASS="$pass" \
        nohup "$RCLONE_BIN" serve webdav "$path" \
            --addr "${host}:${port}" \
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

    check_fuse
    mkdir -p "$point"

    # Use a connection string so we do not need to persist a rclone remote
    # per mount. The password is the rclone-obscured form (not plaintext).
    local conn
    conn=":webdav,url='${url}',vendor='other',user='${user}',pass='${pass}':"

    : > "$log_file"
    nohup "$RCLONE_BIN" mount "$conn" "$point" \
        --vfs-cache-mode writes \
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

    if [ "$OS_TYPE" = "linux" ]; then
        if command -v fusermount3 >/dev/null 2>&1; then
            fusermount3 -u "$point" 2>/dev/null || true
        elif command -v fusermount >/dev/null 2>&1; then
            fusermount -u "$point" 2>/dev/null || true
        fi
    else
        umount "$point" 2>/dev/null || diskutil unmount force "$point" 2>/dev/null || true
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
        echo " 1) Manage Credentials"
        echo " 2) Share          (create a new share)"
        echo " 3) Manage Shares  (list / start / stop / delete)"
        echo " 4) Mount          (create a new mount)"
        echo " 5) Manage Mounts  (list / mount / unmount / delete)"
        echo " 6) Refresh shares and mounts"
        echo " 0) Exit"
        echo "============================================="
        local c
        read -rp "Select [0-6]: " c
        case "$c" in
            1) menu_credentials ;;
            2) share_create ;;
            3) menu_shares ;;
            4) mount_create ;;
            5) menu_mounts ;;
            6) refresh_all ;;
            0|"") echo "Bye."; exit 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ----------------- 12. Bootstrap -----------------
ensure_dependencies
ensure_config

# Reminder if our private bin dir is not yet on PATH
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]] && \
   { [ "$RCLONE_BIN" = "$INSTALL_BIN_DIR/rclone" ] || [ "$JQ_BIN" = "$INSTALL_BIN_DIR/jq" ]; }; then
    echo "Note: '$INSTALL_BIN_DIR' is not in PATH."
    echo "      Add this to your shell rc to use rclone/jq directly:"
    echo "          export PATH=\"$INSTALL_BIN_DIR:\$PATH\""
fi

main_menu
