#!/usr/bin/env bats
#
# Tests for migrate-env-to-1password.sh.
#
# Per the 2026-05-09 design ripple sweep: this script does NOT auto-write to
# 1P. The beta CLI's `op environment update` doesn't exist; the supported
# write path is `op item edit` against the Environment's backing vault item,
# which has uncertain field semantics for arbitrary KEY=value pairs.
#
# So the script's job is to:
#   - Parse the source .env (skip comments, blank lines, malformed lines)
#   - Back up the source to .env.pre-1password.bak (mode 0600)
#   - Print the parsed entries in a paste-ready format for the operator to
#     enter into the 1P UI (Developer → Environments → click → Edit)
#
# This is a one-shot operator ceremony anyway, so the manual paste step is
# acceptable. Future work (when `op environment update` ships) can swap in
# auto-write without touching the parse/backup logic.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../migrate-env-to-1password.sh"
    WORK="$BATS_TEST_TMPDIR"
    cd "$WORK"
}

# Helpers --------------------------------------------------------------------

write_env() {
    cat > "$WORK/.env" <<'EOF'
# Comment line (should be skipped)
KEY1=value1
KEY2=hello world
# Another comment

KEY3=multi=equals=ok
EMPTY=
KEY4=trailing whitespace
EOF
}

# Tests ----------------------------------------------------------------------

@test "fails loudly when --env-file is missing" {
    write_env
    run "$SCRIPT" --environment env_x
    [ "$status" -ne 0 ]
    [[ "$output" == *"--env-file"* ]]
}

@test "fails loudly when --environment is missing" {
    write_env
    run "$SCRIPT" --env-file "$WORK/.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--environment"* ]]
}

@test "fails loudly when source .env file does not exist" {
    run "$SCRIPT" --env-file "$WORK/.env" --environment env_x
    [ "$status" -ne 0 ]
    [[ "$output" == *".env"* ]]
}

@test "happy path: parses .env, creates backup, prints paste-ready entries" {
    write_env
    run "$SCRIPT" --env-file "$WORK/.env" --environment env_xxxxx
    [ "$status" -eq 0 ]

    # Backup created with mode 0600
    [ -f "$WORK/.env.pre-1password.bak" ]
    if stat -f %Lp "$WORK/.env.pre-1password.bak" >/dev/null 2>&1; then
        backup_mode="$(stat -f %Lp "$WORK/.env.pre-1password.bak")"
    else
        backup_mode="$(stat -c %a "$WORK/.env.pre-1password.bak")"
    fi
    [ "$backup_mode" = "600" ]

    # Backup matches source exactly
    cmp -s "$WORK/.env" "$WORK/.env.pre-1password.bak"

    # Paste-ready output contains the parsed entries
    [[ "$output" == *"KEY1=value1"* ]]
    [[ "$output" == *"KEY2=hello world"* ]]
    [[ "$output" == *"KEY3=multi=equals=ok"* ]]

    # Output mentions the target Environment
    [[ "$output" == *"env_xxxxx"* ]]

    # Output does NOT contain comment lines from the source
    [[ "$output" != *"# Comment line"* ]]
}

@test "idempotency: re-run produces no extra side effects" {
    write_env
    run "$SCRIPT" --env-file "$WORK/.env" --environment env_x
    [ "$status" -eq 0 ]
    first_backup_mtime="$(stat -f %m "$WORK/.env.pre-1password.bak" 2>/dev/null || stat -c %Y "$WORK/.env.pre-1password.bak")"

    sleep 1   # ensure mtime would differ if rewritten

    run "$SCRIPT" --env-file "$WORK/.env" --environment env_x
    [ "$status" -eq 0 ]
    second_backup_mtime="$(stat -f %m "$WORK/.env.pre-1password.bak" 2>/dev/null || stat -c %Y "$WORK/.env.pre-1password.bak")"

    # Backup wasn't rewritten on second run (already exists, source unchanged)
    [ "$first_backup_mtime" = "$second_backup_mtime" ]
}

@test "does not delete the source .env file" {
    write_env
    run "$SCRIPT" --env-file "$WORK/.env" --environment env_x
    [ "$status" -eq 0 ]
    [ -f "$WORK/.env" ]
}
