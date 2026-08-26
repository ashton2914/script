# Go Version Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users install a specified Go release interactively while retaining latest-version installation as the default.

**Architecture:** Keep the existing numbered action menu. Add version selection and normalization before any destructive installation step, then reuse the normalized `goX.Y.Z` value in the existing archive URL construction.

**Tech Stack:** Bash, curl, portable shell test harness

## Global Constraints

- Support Linux amd64/arm64 and macOS amd64/arm64.
- Accept `1.24.6` and `go1.24.6`; normalize both to `go1.24.6`.
- An empty version response installs the latest stable release.
- Validate input before removing an existing installation.
- Preserve the existing install/uninstall/repair menu and rootless paths.

---

### Task 1: Interactive Go Version Selection

**Files:**
- Create: `tests/setup_go_test.sh`
- Modify: `setup_go.sh`

**Interfaces:**
- Consumes: A version line from standard input after the existing action selection.
- Produces: `GO_VERSION` in normalized `goX.Y.Z` form and a download URL of `https://go.dev/dl/${GO_VERSION}.${OS_TYPE}-${ARCH_TYPE}.tar.gz`.

- [ ] **Step 1: Write the failing behavior tests**

Create a standalone Bash test harness that prepends fake `uname`, `curl`, and `tar` commands to `PATH`, uses a temporary `HOME`, and runs the real `setup_go.sh`. Include assertions for these inputs and outcomes:

```text
Input "1\n1.24.6\n"   -> download URL contains go1.24.6.linux-amd64.tar.gz
Input "1\ngo1.24.6\n" -> download URL contains go1.24.6.linux-amd64.tar.gz
Input "1\n\n"         -> metadata lookup occurs and URL contains fake latest go1.25.0
Input "3\n1.24.6\n"   -> repair reuses the selected version without a second prompt
Input "1\nlatest\n"   -> nonzero exit, format error, existing ~/.local/go marker remains
Input "3\nlatest\n"   -> nonzero exit, format error, existing ~/.local/go marker remains
```

The fake `curl` must emit `[{"version":"go1.25.0"}]` for the metadata endpoint and record archive URLs in `$CURL_LOG`. The fake `tar` must create `$HOME/.local/go` without extracting an archive.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
bash tests/setup_go_test.sh
```

Expected: FAIL because the current script never prompts for a specified version and always resolves the latest release.

- [ ] **Step 3: Implement minimal version selection**

In `setup_go.sh`, make `install_go` prompt before cleanup:

```bash
read -p "Enter Go version (e.g. 1.24.6, leave blank for latest): " REQUESTED_VERSION
```

For an empty response, retain the metadata lookup. For a nonempty response, strip one leading `go`, validate the remainder with Bash regex `^[0-9]+\.[0-9]+\.[0-9]+$`, then assign `GO_VERSION="go${REQUESTED_VERSION}"`. On validation failure, print an error with an example and return nonzero before `rm -rf "$GOROOT_DIR"`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
bash tests/setup_go_test.sh
```

Expected: all six behavior tests pass with no real network access or changes outside temporary directories.

- [ ] **Step 5: Run syntax validation**

Run:

```bash
bash -n setup_go.sh tests/setup_go_test.sh
```

Expected: exit code 0 and no output.

- [ ] **Step 6: Review the final diff**

Run:

```bash
git diff --check
git diff -- setup_go.sh tests/setup_go_test.sh
```

Expected: no whitespace errors; changes are limited to version selection and its tests.