#!/usr/bin/env python3
"""
Nightly encrypted backup of the CRM database.

Runs pg_dump against the Supabase Postgres database, encrypts the dump with
a symmetric key nobody but you holds, and writes it into backups/. Meant to
be run by the GitHub Actions workflow in .github/workflows/backup.yml, but
you can also run it by hand:

    export SUPABASE_DB_URL="postgresql://postgres:...@....supabase.co:5432/postgres"
    export BACKUP_ENCRYPTION_KEY="<fernet key, see README>"
    python3 scripts/backup.py

Why encrypt before it ever gets committed: this repo may be private, but git
history is effectively permanent (deleting a file later doesn't remove it
from history without a disruptive rewrite). Encrypting means that even a
committed backup file is useless to anyone without the key, which is kept
only as a GitHub Actions secret and never checked into the repo itself.
"""

import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet

REPO_ROOT = Path(__file__).resolve().parent.parent
BACKUP_DIR = REPO_ROOT / "backups"


def main():
    db_url = os.environ.get("SUPABASE_DB_URL")
    key = os.environ.get("BACKUP_ENCRYPTION_KEY")

    if not db_url or not key:
        sys.exit("Set SUPABASE_DB_URL and BACKUP_ENCRYPTION_KEY environment variables first.")

    BACKUP_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    plain_dump = BACKUP_DIR / f"_tmp_{timestamp}.sql"
    encrypted_out = BACKUP_DIR / f"backup_{timestamp}.sql.enc"

    print(f"Dumping database to {plain_dump} ...")
    result = subprocess.run(
        ["pg_dump", db_url, "--no-owner", "--no-privileges", "-f", str(plain_dump)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"pg_dump failed:\n{result.stderr}")

    print("Encrypting dump ...")
    fernet = Fernet(key.encode())
    plaintext = plain_dump.read_bytes()
    encrypted_out.write_bytes(fernet.encrypt(plaintext))
    plain_dump.unlink()  # never leave the unencrypted dump on disk

    print(f"Wrote {encrypted_out.relative_to(REPO_ROOT)} ({encrypted_out.stat().st_size} bytes)")

    # Keep the backups folder from growing forever — 7 day free-tier snapshot
    # plus these gives good coverage without piling up years of dumps.
    keep_last = 30
    all_backups = sorted(BACKUP_DIR.glob("backup_*.sql.enc"))
    for old in all_backups[:-keep_last]:
        old.unlink()
        print(f"Pruned old backup {old.name}")


def decrypt(path: str, key: str, out_path: str):
    """Helper for restoring: python3 scripts/backup.py --decrypt <file> <key> <out.sql>"""
    fernet = Fernet(key.encode())
    data = Path(path).read_bytes()
    Path(out_path).write_bytes(fernet.decrypt(data))
    print(f"Decrypted to {out_path} — restore with: psql <DB_URL> -f {out_path}")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--decrypt":
        decrypt(sys.argv[2], os.environ["BACKUP_ENCRYPTION_KEY"], sys.argv[3])
    else:
        main()
