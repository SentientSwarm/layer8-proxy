#!/usr/bin/env bash
# op-writeback.sh — sourceable function that writes a (key, value) pair back
# to the vault item that backs a 1Password Environment.
#
# Per design §4.2.5 + ADR-0006 D9: rotation toolkit hooks call this AFTER the
# local rotation has succeeded. Local-rotation success is authoritative; this
# write-back is best-effort. Failure here logs but does NOT roll back the
# local rotation (caller can retry the 1P write separately).
#
# Why `op item edit` instead of `op environment update`: the 1P beta CLI
# does not expose `op environment update` as of 2026-05-09. Each Environment
# is backed by a vault item; editing the item is the working path until the
# dedicated subcommand ships.
#
# Usage (from a sourcing script):
#   . "$SITE_DIR/scripts/lib/op-writeback.sh"
#   op_writeback "$op_environment_vault_item" "OPERATOR_TOKEN" "$NEW_VALUE"
#   case $? in
#       0) echo "  ✓ wrote to 1P" ;;
#       1) : ;;  # silent skip (no vault item id, or no op CLI)
#       *) echo "  ⚠ wrote-back failed; retry manually" >&2 ;;
#   esac
#
# Return codes:
#   0  → wrote successfully
#   1  → skipped (vault_item arg empty, OR `op` CLI not on PATH).
#        Silent — caller should not warn.
#   2  → attempted but op item edit failed. Caller should warn.

# op_writeback <vault_item_id> <key> <value>
op_writeback() {
    local vault_item="$1"
    local key="$2"
    local value="$3"

    [[ -n "$vault_item" ]] || return 1
    command -v op >/dev/null 2>&1 || return 1

    if op item edit "$vault_item" "${key}=${value}" >/dev/null 2>&1; then
        return 0
    fi
    return 2
}
