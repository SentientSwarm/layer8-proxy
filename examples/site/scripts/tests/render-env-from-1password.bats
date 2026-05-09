#!/usr/bin/env bats
#
# Tests for render-env-from-1password.sh.
#
# Test infrastructure:
#   - Each test runs in a fresh TEST_TMP directory (BATS_TEST_TMPDIR)
#   - Fake `op` binary on PATH lets us simulate `op environment read` outcomes
#   - Fake `security` binary on PATH simulates Keychain hits/misses
#   - HOME pointed at TEST_TMP so file-fallback path is sandboxed
#
# Each test is self-contained: setup() creates a clean SITE_DIR, fake binaries,
# and a fake home; teardown() is implicit via BATS_TEST_TMPDIR cleanup.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../render-env-from-1password.sh"
    SITE_DIR="$BATS_TEST_TMPDIR/site"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$SITE_DIR" "$FAKE_BIN" "$FAKE_HOME/.config/op"

    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    unset OP_SERVICE_ACCOUNT_TOKEN
}

# Helpers --------------------------------------------------------------------

# write_site_cfg [op_environment_id]
#   Writes $SITE_DIR/site.cfg. If arg given, sets op_environment_id=<arg>.
write_site_cfg() {
    if [[ $# -ge 1 ]]; then
        printf 'op_environment_id=%s\n' "$1" > "$SITE_DIR/site.cfg"
    else
        : > "$SITE_DIR/site.cfg"
    fi
}

# fake_op_success <output>
#   Installs a fake `op` that prints <output> to stdout for `op environment read`
#   and exits 0. All other invocations exit 1 with a sentinel message.
fake_op_success() {
    local output="$1"
    cat > "$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "environment read" ]]; then
    cat <<'OUT'
$output
OUT
    exit 0
fi
echo "fake-op: unexpected invocation: \$*" >&2
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

# fake_op_failure <stderr-msg> [exit-code]
fake_op_failure() {
    local msg="$1"
    local code="${2:-1}"
    cat > "$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "environment read" ]]; then
    echo "$msg" >&2
    exit $code
fi
echo "fake-op: unexpected invocation: \$*" >&2
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

# fake_security_miss
#   Installs a fake `security` binary that always exits 1 (no Keychain hit).
fake_security_miss() {
    cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$FAKE_BIN/security"
}

# fake_security_hit <token>
#   Installs a fake `security` binary that prints <token> on
#   `find-generic-password -s OP_SERVICE_ACCOUNT_TOKEN -w`.
fake_security_hit() {
    local token="$1"
    cat > "$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "find-generic-password" ]]; then
    printf '%s' "$token"
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BIN/security"
}

# Tests ----------------------------------------------------------------------

@test "fails loudly when site.cfg is missing" {
    fake_op_success ""    # never reached
    fake_security_miss
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"site.cfg"* ]]
}

@test "fails loudly when site.cfg lacks op_environment_id" {
    write_site_cfg                      # empty site.cfg
    fake_op_success ""
    fake_security_miss
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"op_environment_id"* ]]
}

@test "fails loudly when no SA token is resolvable" {
    write_site_cfg "env_test123"
    fake_op_success ""
    fake_security_miss                  # Keychain returns nothing
    # No file at $HOME/.config/op/service-account-token (FAKE_HOME is empty)
    # No env var (setup unsets it)
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Service Account token"* ]]
    [[ "$output" == *"Keychain"* ]]
    [[ "$output" == *"$HOME/.config/op/service-account-token"* ]]
}
