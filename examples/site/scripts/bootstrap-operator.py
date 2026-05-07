#!/usr/bin/env -S uv run --with argon2-cffi --with pyyaml --quiet python
"""bootstrap-operator.py — mint a locksmith operator credential.

Generates a fresh operator token and writes:
  - locksmith/operators.yaml      (the argon2-hashed credential record;
                                   gitignored, mounted into the container)
  - locksmith/secrets/operator_token.creds  (the wire token, sealed via
                                   secrets.bootstrap.sh; consumed by
                                   register-agents.sh on each invocation)

Token format: lkop_<public_id>.<secret>
  - public_id = base64-url-no-pad of 16 random bytes (22 chars)
  - secret    = base64-url-no-pad of 32 random bytes (43 chars)
  Matches the `<prefix>_<public_id>.<secret>` shape locksmith generates
  natively (src/token.rs::StructuredToken::wire_format).
Hash format:  argon2id PHC string. Cost params are encoded in the PHC, so
  verification works regardless of who generated it.

The locksmith parser splits the wire token on the first '_' to get the
prefix, then on '.' to get (public_id, secret). operators.yaml stores
the BARE public_id (no prefix) — the prefix lives only in the wire token.

Run once per fresh deploy. Re-running OVERWRITES the existing operator
credential — any existing wire token stops working.
"""

from __future__ import annotations

import base64
import os
import secrets
import subprocess
import sys
from pathlib import Path

import yaml
from argon2 import PasswordHasher


def _b64_url_no_pad(nbytes: int) -> str:
    """Random bytes encoded as URL-safe base64, no padding (locksmith's format)."""
    return base64.urlsafe_b64encode(secrets.token_bytes(nbytes)).decode().rstrip("=")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    operators_path = repo_root / "locksmith" / "operators.yaml"
    secrets_dir = repo_root / "locksmith" / "secrets"
    bootstrap_sh = repo_root / "secrets.bootstrap.sh"

    if not bootstrap_sh.exists():
        print(f"ERROR: {bootstrap_sh} not found", file=sys.stderr)
        return 1

    if operators_path.exists():
        confirm = (
            input(
                f"{operators_path} already exists. OVERWRITE and invalidate the "
                f"existing operator token? [y/N] "
            )
            .strip()
            .lower()
        )
        if confirm not in ("y", "yes"):
            print("Aborted.")
            return 1

    # Match locksmith's StructuredToken::generate (src/token.rs):
    # 16 random bytes for public_id, 32 random bytes for secret, both
    # URL-safe base64 with no padding. operators.yaml stores the bare
    # public_id (NO `lkop_` prefix); the prefix only lives in the wire
    # token, where the parser splits on the first '_' to identify the
    # namespace and treats the rest as `<public_id>.<secret>`.
    public_id = _b64_url_no_pad(16)  # 22 chars
    secret = _b64_url_no_pad(32)  # 43 chars
    wire_token = f"lkop_{public_id}.{secret}"

    hasher = PasswordHasher()
    token_hash = hasher.hash(secret)

    operators_doc = {
        "operators": [
            {
                "name": "default",
                "public_id": public_id,  # bare — no lkop_ prefix
                "token_hash": token_hash,
            }
        ]
    }
    operators_path.parent.mkdir(parents=True, exist_ok=True)
    operators_path.write_text(yaml.safe_dump(operators_doc, sort_keys=False))
    operators_path.chmod(0o600)

    secrets_dir.mkdir(parents=True, exist_ok=True)

    if "LOCKSMITH_CREDS_PASSPHRASE" not in os.environ:
        print(
            "WARNING: LOCKSMITH_CREDS_PASSPHRASE not set; secrets.bootstrap.sh "
            "will fail on macOS. Set it before re-running, or seal the token "
            "manually:\n"
            f"  echo -n '{wire_token}' | LOCKSMITH_CREDS_PASSPHRASE=... "
            f"{bootstrap_sh.relative_to(repo_root)} operator_token --from-stdin",
            file=sys.stderr,
        )
        print(f"\nWire token (copy to password manager):\n  {wire_token}\n")
        return 0

    proc = subprocess.run(
        [str(bootstrap_sh), "operator_token", "--from-stdin"],
        input=wire_token,
        text=True,
        cwd=repo_root,
        capture_output=True,
    )
    if proc.returncode != 0:
        print(f"ERROR: secrets.bootstrap.sh failed:\n{proc.stderr}", file=sys.stderr)
        print(
            f"\nWire token (save it now — it won't be regenerated):\n  {wire_token}\n"
        )
        return 1

    print(f"✓ Wrote operator credential to {operators_path}")
    print("✓ Sealed wire token to locksmith/secrets/operator_token.creds")
    print()
    print("Next steps:")
    print("  1. ./deploy.sh   (rebuilds locksmith config + restarts daemon)")
    print("  2. ./scripts/register-agents.sh   (uses the sealed operator token)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
