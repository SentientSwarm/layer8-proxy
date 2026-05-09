#!/usr/bin/env bats
#
# Tests for lib/op-writeback.sh — the sourceable write-back function used by
# the rotate-* scripts to propagate rotated values to 1P.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib/op-writeback.sh"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    export PATH="$FAKE_BIN:$PATH"
}

# Helpers --------------------------------------------------------------------

fake_op_item_edit_succeeds() {
    cat > "$FAKE_BIN/op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "item" && "$2" == "edit" ]]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

fake_op_item_edit_fails() {
    cat > "$FAKE_BIN/op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "item" && "$2" == "edit" ]]; then
    echo "[ERROR] item not found" >&2
    exit 1
fi
exit 1
EOF
    chmod +x "$FAKE_BIN/op"
}

# Tests ----------------------------------------------------------------------

@test "returns 1 (skip) when vault_item is empty" {
    fake_op_item_edit_succeeds
    . "$LIB"
    set +e
    op_writeback "" "KEY" "value"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
}

@test "returns 1 (skip) when op CLI is not on PATH" {
    # No fake_op installed; scrub PATH at call time so command -v op fails.
    . "$LIB"
    set +e
    PATH="" op_writeback "vault_item_x" "KEY" "value"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
}

@test "returns 0 on successful op item edit" {
    fake_op_item_edit_succeeds
    . "$LIB"
    set +e
    op_writeback "vault_item_x" "OPERATOR_TOKEN" "lk_abc.xyz"
    rc=$?
    set -e
    [ "$rc" -eq 0 ]
}

@test "returns 2 on op item edit failure" {
    fake_op_item_edit_fails
    . "$LIB"
    set +e
    op_writeback "vault_item_x" "OPERATOR_TOKEN" "lk_abc.xyz"
    rc=$?
    set -e
    [ "$rc" -eq 2 ]
}
