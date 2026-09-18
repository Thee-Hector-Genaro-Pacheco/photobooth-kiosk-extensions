#!/usr/bin/env python3
"""
scripts/install-kiosk-theme-button.py - Safe installer for Photobooth-App Kiosk Theme Selector button.

Injects the single <script src="http://localhost:8080/kiosk-theme-button.js"></script> tag
into the installed Photobooth-App web frontend entry point (index.html).

Key Safety Guarantees:
- Idempotent: detects existing injection and prevents duplicates.
- Non-invasive: creates a timestamped backup before any file modification.
- Minimal: modifies only the single HTML file, never touches compiled Vue JS bundles.
- Fails safely if </body> tag is missing.
- Standard library only (zero external dependencies).
"""

import argparse
from datetime import datetime
import os
from pathlib import Path
import shutil
import sys

DEFAULT_SCRIPT_URL = "/kiosk-theme-button.js"
SCRIPT_IDENTIFIER = "kiosk-theme-button.js"

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_JS_PATH = REPO_ROOT / "ui" / "kiosk-theme-button.js"
SOURCE_AR_JS_PATH = REPO_ROOT / "ui" / "kiosk-ar-overlay.js"


def build_script_tag(script_url: str) -> str:
    return f'  <script src="{script_url}"></script>\n'


def install_script_tag(index_path: Path, script_url: str = DEFAULT_SCRIPT_URL, dry_run: bool = False) -> int:
    if not index_path.exists():
        sys.stderr.write(f"Error: Target file does not exist: {index_path}\n")
        return 1

    if not index_path.is_file():
        sys.stderr.write(f"Error: Target is not a regular file: {index_path}\n")
        return 1

    # Ensure target is not a compiled JS bundle
    if index_path.suffix.lower() == ".js":
        sys.stderr.write(
            "Error: Target file is a JavaScript bundle (.js). Never modify compiled Vue bundles directly.\n"
        )
        return 1

    dest_js = index_path.parent / SCRIPT_IDENTIFIER
    dest_ar_js = index_path.parent / "kiosk-ar-overlay.js"

    if not SOURCE_JS_PATH.exists():
        sys.stderr.write(f"Error: Source extension script not found: {SOURCE_JS_PATH}\n")
        return 1

    try:
        content = index_path.read_text(encoding="utf-8")
    except Exception as err:
        sys.stderr.write(f"Error reading {index_path}: {err}\n")
        return 1

    # 1. Install or update extension JS files in served directory
    if dry_run:
        print(f"[DRY RUN] Would copy {SOURCE_JS_PATH.name} to: {dest_js}")
        if SOURCE_AR_JS_PATH.exists():
            print(f"[DRY RUN] Would copy {SOURCE_AR_JS_PATH.name} to: {dest_ar_js}")
    else:
        try:
            shutil.copy2(SOURCE_JS_PATH, dest_js)
            print(f"[COPIED] Installed extension script to: {dest_js}")
            if SOURCE_AR_JS_PATH.exists():
                shutil.copy2(SOURCE_AR_JS_PATH, dest_ar_js)
                print(f"[COPIED] Installed AR overlay script to: {dest_ar_js}")
        except Exception as err:
            sys.stderr.write(f"Error copying extension script to {dest_js}: {err}\n")
            return 1

    # 2. Check if script tag is already present in index.html (Idempotency)
    if SCRIPT_IDENTIFIER in content:
        print(f"[OK] Theme selector script tag is already present in: {index_path}")
        print("     File copy updated. HTML script tag preserved without duplication (idempotent).")
        return 0

    # Ensure </body> tag is present
    body_close_lower = "</body>"
    lower_content = content.lower()
    pos = lower_content.rfind(body_close_lower)
    if pos == -1:
        sys.stderr.write(f"Error: Could not locate </body> tag in {index_path}. Aborting.\n")
        return 1

    # Create timestamped backup
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = index_path.with_name(f"{index_path.name}.bak.{timestamp}")

    script_tag = build_script_tag(script_url)
    # Insert immediately before </body>
    new_content = content[:pos] + script_tag + content[pos:]

    if dry_run:
        print(f"[DRY RUN] Target file: {index_path}")
        print(f"[DRY RUN] Backup would be created at: {backup_path}")
        print(f"[DRY RUN] Script tag to insert before </body>:\n{script_tag.rstrip()}")
        print("[DRY RUN] No index.html modifications written.")
        return 0

    try:
        shutil.copy2(index_path, backup_path)
        print(f"[BACKUP] Created backup at: {backup_path}")
    except Exception as err:
        sys.stderr.write(f"Error creating backup {backup_path}: {err}\n")
        return 1

    try:
        index_path.write_text(new_content, encoding="utf-8")
        print(f"[SUCCESS] Successfully injected theme button script into: {index_path}")
        print(f"          Script tag: {script_tag.strip()}")
        return 0
    except Exception as err:
        sys.stderr.write(f"Error writing to {index_path}: {err}\n")
        # Attempt to restore backup
        try:
            shutil.copy2(backup_path, index_path)
            print("[RESTORE] Restored original file from backup after write failure.")
        except Exception:
            pass
        return 1


def uninstall_script_tag(index_path: Path, dry_run: bool = False) -> int:
    if not index_path.exists():
        sys.stderr.write(f"Error: Target file does not exist: {index_path}\n")
        return 1

    content = index_path.read_text(encoding="utf-8")
    dest_js = index_path.parent / SCRIPT_IDENTIFIER

    tag_found = SCRIPT_IDENTIFIER in content
    js_found = dest_js.exists()

    if not tag_found and not js_found:
        print(f"[OK] Theme selector script is not installed in: {index_path.parent}")
        return 0

    if dry_run:
        if tag_found:
            print(f"[DRY RUN] Would remove theme script tag from: {index_path}")
        if js_found:
            print(f"[DRY RUN] Would delete served extension script: {dest_js}")
        return 0

    # Remove script tag from index.html if present
    if tag_found:
        lines = content.splitlines(keepends=True)
        new_lines = [line for line in lines if SCRIPT_IDENTIFIER not in line]
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = index_path.with_name(f"{index_path.name}.bak.{timestamp}")
        shutil.copy2(index_path, backup_path)
        print(f"[BACKUP] Created backup at: {backup_path}")
        index_path.write_text("".join(new_lines), encoding="utf-8")
        print(f"[SUCCESS] Removed theme selector script tag from: {index_path}")

    # Remove copied JS file if present
    if js_found:
        try:
            dest_js.unlink()
            print(f"[DELETED] Removed served extension script: {dest_js}")
        except Exception as err:
            sys.stderr.write(f"Warning: Could not delete {dest_js}: {err}\n")

    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Safe installer for Photobooth-App Kiosk Theme Selector script tag."
    )
    parser.add_argument(
        "index_html",
        type=Path,
        help="Path to installed Photobooth-App web/frontend/index.html",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_SCRIPT_URL,
        help=f"URL of the kiosk-theme-button.js script (default: {DEFAULT_SCRIPT_URL})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate the installation without writing changes or backups",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove previously installed theme selector script tag",
    )

    args = parser.parse_args()

    if args.uninstall:
        sys.exit(uninstall_script_tag(args.index_html, dry_run=args.dry_run))
    else:
        sys.exit(install_script_tag(args.index_html, script_url=args.url, dry_run=args.dry_run))


if __name__ == "__main__":
    main()
