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
    RECEIVED_TOKEN_FILE="$BATS_TEST_TMPDIR/received-token"
    mkdir -p "$SITE_DIR" "$FAKE_BIN" "$FAKE_HOME/.config/op"

    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export RECEIVED_TOKEN_FILE
    unset OP_SERVICE_ACCOUNT_TOKEN
}

# Helpers --------------------------------------------------------------------

# write_site_cfg [op_environment_id [extra_kv ...]]
#   Writes $SITE_DIR/site.cfg with op_environment_id=<arg1> and any
#   additional KEY=VALUE lines passed as further args. Bare call writes
#   an empty file.
write_site_cfg() {
    if [[ $# -ge 1 ]]; then
        printf 'op_environment_id=%s\n' "$1" > "$SITE_DIR/site.cfg"
        shift
        for kv in "$@"; do
            printf '%s\n' "$kv" >> "$SITE_DIR/site.cfg"
        done
    else
        : > "$SITE_DIR/site.cfg"
    fi
}

# fake_op_success <output>
#   Installs a fake `op` that simulates a working beta-channel op:
#     - `op environment read <id>` prints <output> to stdout, exits 0
#     - `op environment --help`    exits 0 (capability probe)
#     - anything else              exits 1 with a sentinel message
#   On every invocation, records the inbound OP_SERVICE_ACCOUNT_TOKEN env
#   var to $RECEIVED_TOKEN_FILE so tests can assert which precedence path
#   resolved the token.
fake_op_success() {
    local output="$1"
    cat > "$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
printf '%s' "\${OP_SERVICE_ACCOUNT_TOKEN:-}" > "$RECEIVED_TOKEN_FILE"
if [[ "\$1 \$2" == "environment read" ]]; then
    cat <<'OUT'
$output
OUT
    exit 0
fi
if [[ "\$1 \$2" == "environment --help" ]]; then
    exit 0
fi
echo "fake-op: unexpected invocation: \$*" >&2
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

# fake_op_failure <stderr-msg> [exit-code]
#   Capability probe still succeeds; only `op environment read` fails.
fake_op_failure() {
    local msg="$1"
    local code="${2:-1}"
    cat > "$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "environment read" ]]; then
    echo "$msg" >&2
    exit $code
fi
if [[ "\$1 \$2" == "environment --help" ]]; then
    exit 0
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
#   Installs a fake `security` binary that prints <token> for any
#   `find-generic-password` call regardless of the -s service name.
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

# fake_security_keyed <expected-service> <token>
#   Installs a fake `security` binary that returns <token> ONLY when called
#   with `-s <expected-service>`. Returns exit 1 (Keychain miss) for any
#   other service name. Used to assert the script passes the configured
#   service name to `security find-generic-password`.
fake_security_keyed() {
    local expected="$1"
    local token="$2"
    cat > "$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
service=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -s) service="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "\$service" == "$expected" ]]; then
    printf '%s' "$token"
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BIN/security"
}

# fake_op_no_environment_subcommand
#   Installs a fake `op` that simulates the stable channel: the binary
#   exists, but `op environment ...` returns "unknown command". Mirrors
#   what stable `op` 2.34.0 actually does (verified 2026-05-08).
fake_op_no_environment_subcommand() {
    cat > "$FAKE_BIN/op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "environment" ]]; then
    echo '[ERROR] unknown command "environment" for "op"' >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/op"
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

@test "fails loudly when op CLI lacks the environment subcommand (stable channel)" {
    write_site_cfg "env_test123"
    fake_op_no_environment_subcommand
    fake_security_miss
    OP_SERVICE_ACCOUNT_TOKEN=ops_test \
        SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"environment"* ]]
    [[ "$output" == *"1password-cli@beta"* ]]
}

@test "uses op_token_file from site.cfg for per-product Linux file path" {
    # Multi-product Linux host: openclaw-site sets op_token_file to a
    # per-product path. The script must use that path, not the default.
    write_site_cfg "env_openclaw" "op_token_file=$HOME/.config/op/openclaw.token"
    fake_op_success $'KEY=value'
    fake_security_miss
    # Token at the configured per-product path. NOT at the default path.
    echo -n "ops_per_product_token" > "$HOME/.config/op/openclaw.token"
    chmod 0600 "$HOME/.config/op/openclaw.token"
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    received="$(<"$RECEIVED_TOKEN_FILE")"
    [ "$received" = "ops_per_product_token" ]
}

@test "uses op_keychain_service from site.cfg for per-product Keychain isolation" {
    # Multi-product host: openclaw on this host has SA scoped to
    # openclaw-mini-1 Env; layer8-proxy on the same host has its own SA
    # scoped to layer8-proxy-mini-1 Env. Each site.cfg names its own
    # Keychain entry to avoid token collision.
    write_site_cfg "env_openclaw" "op_keychain_service=OP_SERVICE_ACCOUNT_TOKEN_OPENCLAW"
    fake_op_success $'OPENCLAW_GATEWAY_TOKEN=xyz'
    fake_security_keyed "OP_SERVICE_ACCOUNT_TOKEN_OPENCLAW" "ops_openclaw_token"
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    received="$(<"$RECEIVED_TOKEN_FILE")"
    [ "$received" = "ops_openclaw_token" ]   # NOT the default Keychain entry
}

@test "rendered .env is mode 0600" {
    write_site_cfg "env_test123"
    fake_op_success $'KEY=value'
    fake_security_miss
    OP_SERVICE_ACCOUNT_TOKEN=ops_test \
        SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SITE_DIR/.env" ]
    # `stat -f %Lp` on macOS, `stat -c %a` on Linux. Use a portable shim.
    if stat -f %Lp "$SITE_DIR/.env" >/dev/null 2>&1; then
        mode="$(stat -f %Lp "$SITE_DIR/.env")"
    else
        mode="$(stat -c %a "$SITE_DIR/.env")"
    fi
    [ "$mode" = "600" ]
}

@test "Linux-style host: file fallback fires when security is unavailable" {
    write_site_cfg "env_test123"
    fake_op_success $'KEY=value'
    fake_security_miss   # security exists but errors — equivalent for the script
                         # to "security not on PATH" (both fail the [[ -n ]] guard)
    echo -n "ops_file_token" > "$HOME/.config/op/service-account-token"
    chmod 0600 "$HOME/.config/op/service-account-token"
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    received="$(<"$RECEIVED_TOKEN_FILE")"
    [ "$received" = "ops_file_token" ]   # proves Keychain branch did NOT resolve
}

@test "renders .env using the file-fallback token (no env, Keychain miss)" {
    write_site_cfg "env_test123"
    fake_op_success $'API_KEY=s3cret\nDEBUG=1'
    fake_security_miss
    # No env var (setup unsets it). Drop a token at the file path.
    echo -n "ops_file_token" > "$HOME/.config/op/service-account-token"
    chmod 0600 "$HOME/.config/op/service-account-token"
    SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SITE_DIR/.env" ]
    rendered="$(<"$SITE_DIR/.env")"
    [[ "$rendered" == *"API_KEY=s3cret"* ]]
    [[ "$rendered" == *"DEBUG=1"* ]]
}

@test "renders .env from a valid env-var token" {
    write_site_cfg "env_test123"
    fake_op_success $'FOO=bar\nBAZ=qux'
    fake_security_miss
    OP_SERVICE_ACCOUNT_TOKEN=ops_test \
        SITE_DIR="$SITE_DIR" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SITE_DIR/.env" ]
    rendered="$(<"$SITE_DIR/.env")"
    [[ "$rendered" == *"FOO=bar"* ]]
    [[ "$rendered" == *"BAZ=qux"* ]]
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
