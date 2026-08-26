#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SCRIPT_UNDER_TEST="$TEST_ROOT/setup_go.sh"
sed 's/\r$//' "$SCRIPT_DIR/setup_go.sh" > "$SCRIPT_UNDER_TEST"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/bash
case "$1" in
    -s) echo "Linux" ;;
    -m) echo "x86_64" ;;
esac
EOF

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
for ARG in "$@"; do
    case "$ARG" in
        *"?mode=json")
            echo '[{"version":"go1.25.0"}]'
            exit 0
            ;;
        https://go.dev/dl/*.tar.gz)
            echo "$ARG" >> "$CURL_LOG"
            ;;
    esac
done

while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        : > "$1"
        break
    fi
    shift
done
EOF

cat > "$FAKE_BIN/tar" <<'EOF'
#!/bin/bash
mkdir -p "$HOME/.local/go"
EOF

chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/curl" "$FAKE_BIN/tar"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

prepare_case() {
    local NAME="$1"
    local CASE_DIR="$TEST_ROOT/$NAME"

    mkdir -p "$CASE_DIR/home"
    export HOME="$CASE_DIR/home"
    export CURL_LOG="$CASE_DIR/curl.log"
    : > "$CURL_LOG"
}

execute_script() {
    local INPUT="$1"

    set +e
    OUTPUT=$(printf '%b' "$INPUT" | PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)
    STATUS=$?
    set -e
}

assert_successful_download() {
    local NAME="$1"
    local INPUT="$2"
    local EXPECTED_URL="$3"

    prepare_case "$NAME"
    execute_script "$INPUT"
    if [ "$STATUS" -eq 0 ] && grep -Fxq "$EXPECTED_URL" "$CURL_LOG"; then
        pass "$NAME"
    else
        fail "$NAME (status=$STATUS, output=$OUTPUT)"
    fi
}

assert_successful_download \
    "installs numeric version" \
    '1\n1.24.6\n' \
    'https://go.dev/dl/go1.24.6.linux-amd64.tar.gz'

assert_successful_download \
    "installs go-prefixed version" \
    '1\ngo1.24.6\n' \
    'https://go.dev/dl/go1.24.6.linux-amd64.tar.gz'

assert_successful_download \
    "empty version installs latest" \
    '1\n\n' \
    'https://go.dev/dl/go1.25.0.linux-amd64.tar.gz'

assert_successful_download \
    "repair installs selected version" \
    '3\n1.24.6\n' \
    'https://go.dev/dl/go1.24.6.linux-amd64.tar.gz'

prepare_case "rejects invalid version before cleanup"
mkdir -p "$HOME/.local/go"
echo "keep" > "$HOME/.local/go/marker"
execute_script '1\nlatest\n'
if [ "$STATUS" -ne 0 ] \
    && [[ "$OUTPUT" == *"Invalid Go version"* ]] \
    && [ -f "$HOME/.local/go/marker" ]; then
    pass "rejects invalid version before cleanup"
else
    fail "rejects invalid version before cleanup (status=$STATUS, output=$OUTPUT)"
fi

prepare_case "repair validates version before uninstall"
mkdir -p "$HOME/.local/go"
echo "keep" > "$HOME/.local/go/marker"
execute_script '3\nlatest\n'
if [ "$STATUS" -ne 0 ] \
    && [[ "$OUTPUT" == *"Invalid Go version"* ]] \
    && [ -f "$HOME/.local/go/marker" ]; then
    pass "repair validates version before uninstall"
else
    fail "repair validates version before uninstall (status=$STATUS, output=$OUTPUT)"
fi

echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]