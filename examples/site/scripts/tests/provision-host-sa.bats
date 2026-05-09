#!/usr/bin/env bats
#
# Tests for provision-host-sa.sh.
#
# Test infrastructure mirrors render-env-from-1password.bats:
#   - Fake `op` binary on PATH simulates whoami / environment read /
#     service-account create
#   - Each test runs in a fresh BATS_TEST_TMPDIR
#
# The script's responsibility is to validate inputs, probe 1P state,
# create the SA, and emit a deploy recipe. It does NOT touch any host
# Keychain itself (that's the operator's step using the recipe).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../provision-host-sa.sh"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    export PATH="$FAKE_BIN:$PATH"
}

# Helpers --------------------------------------------------------------------

# fake_op_full <signed_in> <env_accessible> <sa_create_succeeds>
#   Composite fake covering the three subcommands provision-host-sa.sh uses.
#   Arguments are "yes"/"no". For sa_create=yes, prints a fake ops_ token.
fake_op_full() {
    local signed_in="$1"
    local env_ok="$2"
    local sa_ok="$3"
    cat > "$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
case "\$1" in
    whoami)
        if [[ "$signed_in" == "yes" ]]; then
            echo '{"user_uuid":"USER123","name":"jxstanford"}'
            exit 0
        else
            echo "[ERROR] not signed in" >&2
            exit 1
        fi
        ;;
    environment)
        # \$2 = "read" or "--help"
        if [[ "\$2" == "read" ]]; then
            if [[ "$env_ok" == "yes" ]]; then
                echo "FAKE_KEY=value"
                exit 0
            else
                echo "[ERROR] environment not found or not accessible" >&2
                exit 1
            fi
        fi
        if [[ "\$2" == "--help" ]]; then
            exit 0
        fi
        ;;
    service-account)
        # \$2 = "create"
        if [[ "\$2" == "create" ]]; then
            if [[ "$sa_ok" == "yes" ]]; then
                echo "ops_eyJzaWduSW5BZGRyZXNzIjoieXl5In0.fake_jwt_payload.fake_signature_padding_to_get_to_about_700_chars_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
                exit 0
            else
                echo "[ERROR] service-account create failed" >&2
                exit 1
            fi
        fi
        ;;
esac
echo "fake-op: unexpected invocation: \$*" >&2
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

# Tests ----------------------------------------------------------------------

@test "fails loudly when --host is missing" {
    fake_op_full yes yes yes
    run "$SCRIPT" --product openclaw --environment env_x --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"--host"* ]]
}

@test "fails loudly when --product is missing" {
    fake_op_full yes yes yes
    run "$SCRIPT" --host mini-1 --environment env_x --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"--product"* ]]
}

@test "fails loudly when --environment is missing" {
    fake_op_full yes yes yes
    run "$SCRIPT" --host mini-1 --product openclaw --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"--environment"* ]]
}

@test "fails loudly when --vault is missing" {
    fake_op_full yes yes yes
    run "$SCRIPT" --host mini-1 --product openclaw --environment env_x
    [ "$status" -ne 0 ]
    [[ "$output" == *"--vault"* ]]
}

@test "fails loudly when not signed into 1P" {
    fake_op_full no yes yes
    run "$SCRIPT" --host mini-1 --product openclaw --environment env_x --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"sign in"* || "$output" == *"signin"* || "$output" == *"signed in"* ]]
}

@test "fails loudly when Environment is not accessible" {
    fake_op_full yes no yes
    run "$SCRIPT" --host mini-1 --product openclaw --environment env_x --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"Environment"* ]]
    [[ "$output" == *"env_x"* ]]
}

@test "fails loudly when SA creation fails" {
    fake_op_full yes yes no
    run "$SCRIPT" --host mini-1 --product openclaw --environment env_x --vault Operations
    [ "$status" -ne 0 ]
    [[ "$output" == *"service-account"* || "$output" == *"Service Account"* ]]
}

@test "happy path: emits deploy recipe with host-prefixed Keychain name and non-interactive form" {
    fake_op_full yes yes yes
    run "$SCRIPT" --host mini-1 --product openclaw --environment env_xxxxx --vault Operations
    [ "$status" -eq 0 ]
    # Naming convention: OP_SERVICE_ACCOUNT_TOKEN_<HOST>_<PRODUCT>, uppercased,
    # hyphens → underscores
    [[ "$output" == *"OP_SERVICE_ACCOUNT_TOKEN_MINI_1_OPENCLAW"* ]]
    # SA name: <host>-<product> (preserves hyphens)
    [[ "$output" == *"mini-1-openclaw"* ]]
    # Non-interactive deploy recipe — must pass token via -w "$TOKEN", NOT
    # via the interactive prompt (PASS_MAX 128-char gotcha)
    [[ "$output" == *'-w "$TOKEN"'* || "$output" == *'-w "${TOKEN}"'* ]]
    # site.cfg snippet
    [[ "$output" == *"op_environment_id=env_xxxxx"* ]]
    [[ "$output" == *"op_keychain_service=OP_SERVICE_ACCOUNT_TOKEN_MINI_1_OPENCLAW"* ]]
}

@test "happy path: handles multi-segment hostnames (jx-mbp-m5)" {
    fake_op_full yes yes yes
    run "$SCRIPT" --host jx-mbp-m5 --product hermes --environment env_y --vault Operations
    [ "$status" -eq 0 ]
    [[ "$output" == *"OP_SERVICE_ACCOUNT_TOKEN_JX_MBP_M5_HERMES"* ]]
    [[ "$output" == *"jx-mbp-m5-hermes"* ]]
}
