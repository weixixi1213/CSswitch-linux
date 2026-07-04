#!/usr/bin/env python3
"""Create or repair a local-only Claude Science OAuth state for Linux sandboxes.

This mirrors the repository's Node/Rust logic closely enough for headless Linux
usage:
  - writes encryption.key if missing
  - writes exactly one .oauth-tokens/*.enc in operon's v2 format
  - writes active-org.json
  - reuses an intact virtual login instead of rotating org_uuid every run
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


KEY_NAMES = (
    "ANTHROPIC_API_KEY_ENCRYPTION_KEY",
    "OAUTH_ENCRYPTION_KEY",
    "JWT_SIGNING_SECRET",
    "USER_SECRET_ENCRYPTION_KEY",
)
AAD = b"v2:oauth"
HKDF_INFO = b"operon:aes-256-gcm:oauth"


def real_ancestor(path: Path) -> Path:
    current = path.expanduser()
    tail = []
    while not current.exists():
        tail.append(current.name)
        parent = current.parent
        if parent == current:
            break
        current = parent
    base = current.resolve() if current.exists() else current
    for name in reversed(tail):
        base = base / name
    return base


def assert_not_symlink(path: Path) -> None:
    try:
        if path.is_symlink():
            raise SystemExit(f"refusing to follow symlink: {path}")
    except FileNotFoundError:
        return


def safe_write(path: Path, data: bytes, mode: int) -> None:
    assert_not_symlink(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
        os.chmod(path, mode)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def b64_32() -> str:
    return base64.b64encode(os.urandom(32)).decode("ascii")


def looks_like_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        uuid.UUID(value)
        return True
    except Exception:
        return False


def token_not_expired(value: object) -> bool:
    if not isinstance(value, str) or len(value) < 10:
        return False
    try:
        token_day = value[:10]
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        return token_day >= today
    except Exception:
        return False


def parse_key_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key and value:
            values[key] = value
    return values


def derive_key(oauth_key_b64: str) -> bytes:
    raw = base64.b64decode(oauth_key_b64.strip())
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"",
        info=HKDF_INFO,
    )
    return hkdf.derive(raw)


def encrypt_token_v2(plaintext: bytes, oauth_key_b64: str) -> str:
    key = derive_key(oauth_key_b64)
    iv = os.urandom(12)
    body = AESGCM(key).encrypt(iv, plaintext, AAD)
    return "v2:" + base64.b64encode(iv + body).decode("ascii")


def decrypt_token_v2(payload: str, oauth_key_b64: str) -> bytes:
    if not payload.startswith("v2:"):
        raise ValueError("missing v2 prefix")
    raw = base64.b64decode(payload[3:])
    if len(raw) < 12 + 16:
        raise ValueError("ciphertext too short")
    iv = raw[:12]
    ciphertext = raw[12:]
    key = derive_key(oauth_key_b64)
    return AESGCM(key).decrypt(iv, ciphertext, AAD)


def unique_enc_file(auth_dir: Path) -> Optional[Path]:
    token_dir = auth_dir / ".oauth-tokens"
    try:
        files = sorted(
            path for path in token_dir.iterdir() if path.is_file() and path.suffix == ".enc"
        )
    except FileNotFoundError:
        return None
    return files[0] if len(files) == 1 else None


def read_active_org_uuid(auth_dir: Path) -> Optional[str]:
    try:
        payload = json.loads((auth_dir / "active-org.json").read_text(encoding="utf-8"))
    except Exception:
        return None
    org_uuid = payload.get("org_uuid")
    return org_uuid if looks_like_uuid(org_uuid) else None


def scan_org_dirs(auth_dir: Path) -> list[str]:
    orgs_dir = auth_dir / "orgs"
    try:
        names = sorted(
            path.name for path in orgs_dir.iterdir() if path.is_dir() and looks_like_uuid(path.name)
        )
    except FileNotFoundError:
        return []
    return names


def parse_oauth_key(auth_dir: Path) -> Optional[str]:
    key = parse_key_file(auth_dir / "encryption.key").get("OAUTH_ENCRYPTION_KEY")
    if not key:
        return None
    try:
        if len(base64.b64decode(key.strip())) < 16:
            return None
    except Exception:
        return None
    return key


def decode_token_blob(auth_dir: Path) -> Optional[dict]:
    key = parse_oauth_key(auth_dir)
    enc = unique_enc_file(auth_dir)
    if not key or not enc:
        return None
    try:
        payload = decrypt_token_v2(enc.read_text(encoding="utf-8").strip(), key)
        blob = json.loads(payload.decode("utf-8"))
        return blob if isinstance(blob, dict) else None
    except Exception:
        return None


def login_intact(resolved: Path, email: str) -> bool:
    if (resolved / "encryption.key").is_symlink():
        return False
    if (resolved / ".oauth-tokens").is_symlink():
        return False
    if (resolved / "active-org.json").is_symlink():
        return False
    active_org = read_active_org_uuid(resolved)
    blob = decode_token_blob(resolved)
    if not active_org or not blob:
        return False
    if blob.get("email") != email:
        return False
    if blob.get("provider") != "claude_ai":
        return False
    if not blob.get("access_token"):
        return False
    if not looks_like_uuid(blob.get("account_uuid")):
        return False
    if blob.get("org_uuid") != active_org:
        return False
    if not token_not_expired(blob.get("token_expires_at")):
        return False
    return True


def resolve_guarded(
    auth_dir: Path,
    email: str,
    sandbox_root: Path,
    real_cred_dir: Path,
) -> Path:
    resolved = real_ancestor(auth_dir)
    real_root = real_ancestor(real_cred_dir)
    sandbox = real_ancestor(sandbox_root)
    if resolved == real_root or real_root in resolved.parents:
        raise SystemExit(f"refusing to write real credential dir: {real_root}")
    if not (resolved == sandbox or sandbox in resolved.parents):
        raise SystemExit(f"auth dir resolved outside sandbox root: {resolved} not under {sandbox}")
    if not email.endswith("localhost.invalid"):
        raise SystemExit("email must end with localhost.invalid")
    return resolved


def write_login(
    resolved: Path,
    email: str,
    prefer_org: Optional[str],
    prefer_account: Optional[str],
) -> dict[str, str]:
    resolved.mkdir(parents=True, exist_ok=True)
    os.chmod(resolved, 0o700)

    key_file = resolved / "encryption.key"
    assert_not_symlink(key_file)
    keys = parse_key_file(key_file)
    oauth_key = keys.get("OAUTH_ENCRYPTION_KEY")
    try:
        oauth_usable = oauth_key is not None and len(base64.b64decode(oauth_key.strip())) >= 16
    except Exception:
        oauth_usable = False
    if not oauth_usable:
        keys.pop("OAUTH_ENCRYPTION_KEY", None)
    for key_name in KEY_NAMES:
        keys.setdefault(key_name, b64_32())
    key_blob = "".join(f"{key_name}={keys[key_name]}\n" for key_name in KEY_NAMES)
    safe_write(key_file, key_blob.encode("utf-8"), 0o600)

    account_uuid = prefer_account if looks_like_uuid(prefer_account) else str(uuid.uuid4())
    org_uuid = prefer_org if looks_like_uuid(prefer_org) else str(uuid.uuid4())
    blob = {
        "access_token": "sk-ant-virtual-" + os.urandom(24).hex(),
        "refresh_token": "",
        "api_key": None,
        "token_expires_at": "2099-01-01T00:00:00.000Z",
        "provider": "claude_ai",
        "scopes": "user:inference user:file_upload user:profile user:mcp_servers user:plugins",
        "email": email,
        "account_uuid": account_uuid,
        "subscription_type": "max",
        "rate_limit_tier": None,
        "seat_tier": None,
        "org_uuid": org_uuid,
        "billing_type": None,
        "has_extra_usage_enabled": False,
    }
    enc_body = encrypt_token_v2(
        json.dumps(blob, separators=(",", ":")).encode("utf-8"),
        keys["OAUTH_ENCRYPTION_KEY"],
    )

    token_dir = resolved / ".oauth-tokens"
    assert_not_symlink(token_dir)
    token_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(token_dir, 0o700)
    for path in token_dir.glob("*.enc"):
        assert_not_symlink(path)
        path.unlink()

    enc_name = re.sub(r"[^a-zA-Z0-9_-]", "", account_uuid) + ".enc"
    enc_file = token_dir / enc_name
    safe_write(enc_file, enc_body.encode("utf-8"), 0o600)

    active_org = json.dumps({"org_uuid": org_uuid}, indent=2).encode("utf-8") + b"\n"
    safe_write(resolved / "active-org.json", active_org, 0o600)

    return {
        "auth_dir": str(resolved),
        "account_uuid": account_uuid,
        "org_uuid": org_uuid,
        "enc_file": str(enc_file),
    }


def ensure_virtual_login(
    auth_dir: Path,
    email: str,
    sandbox_root: Path,
    real_cred_dir: Path,
) -> dict[str, str]:
    resolved = resolve_guarded(auth_dir, email, sandbox_root, real_cred_dir)
    if login_intact(resolved, email):
        blob = decode_token_blob(resolved)
        enc = unique_enc_file(resolved)
        return {
            "ok": True,
            "action": "reused",
            "auth_dir": str(resolved),
            "email": email,
            "account_uuid": str(blob["account_uuid"]),
            "org_uuid": str(blob["org_uuid"]),
            "enc_file": str(enc),
        }

    blob = decode_token_blob(resolved)
    active_org = read_active_org_uuid(resolved)
    org_candidates = scan_org_dirs(resolved)

    prefer_org = active_org
    if not prefer_org and blob and looks_like_uuid(blob.get("org_uuid")):
        prefer_org = str(blob["org_uuid"])
    if not prefer_org:
        if len(org_candidates) == 1:
            prefer_org = org_candidates[0]
        elif len(org_candidates) > 1:
            raise SystemExit(
                "multiple historical org directories exist but no active org could be determined"
            )

    prefer_account = None
    if blob and looks_like_uuid(blob.get("account_uuid")):
        prefer_account = str(blob["account_uuid"])

    result = write_login(resolved, email, prefer_org, prefer_account)
    action = "repaired" if (active_org or blob or org_candidates) else "created"
    return {
        "ok": True,
        "action": action,
        "email": email,
        **result,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--auth-dir", required=True)
    parser.add_argument("--sandbox-root")
    parser.add_argument("--real-cred-dir")
    parser.add_argument("--email", default="virtual@localhost.invalid")
    args = parser.parse_args()

    auth_dir = Path(args.auth_dir)
    sandbox_root = Path(args.sandbox_root) if args.sandbox_root else auth_dir.parent
    real_cred_dir = Path(args.real_cred_dir) if args.real_cred_dir else Path.home() / ".claude-science"

    result = ensure_virtual_login(auth_dir, args.email, sandbox_root, real_cred_dir)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
