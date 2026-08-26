# Go Version Selection Design

## Goal

Allow `setup_go.sh` users to choose a Go version during installation while preserving the current interactive menu and latest-version default.

## Behavior

- After selecting `install` or `repair`, prompt for a Go version.
- An empty response installs the latest stable version using the existing Go download metadata lookup.
- Accept specified versions as either `1.24.6` or `go1.24.6` and normalize both to `go1.24.6`.
- Reject values outside the numeric Go release format before changing an existing installation.
- Build the archive URL from the normalized version and detected OS/architecture.
- If a syntactically valid release does not exist, preserve the current explicit `curl -f` download failure.
- Keep uninstall behavior and the existing numbered menu unchanged.

## Implementation Boundary

Version selection and normalization belong in a small shell function used by `install_go`. `repair_go` resolves and validates the version first, then calls `uninstall_go` followed by `install_go` with the resolved version so destructive work never precedes validation.

## Error Handling

Invalid input exits with a clear format example. Latest-version lookup failure and archive download failure retain explicit nonzero exits. Version validation happens before the existing Go installation is removed.

## Verification

Automated shell tests will isolate network and filesystem effects and verify:

- Empty input resolves through the latest-version lookup.
- `1.24.6` and `go1.24.6` normalize to the same archive version.
- Invalid input is rejected before installation cleanup.
- The selected version, OS, and architecture produce the expected download URL.