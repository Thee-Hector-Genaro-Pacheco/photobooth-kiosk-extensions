#!/usr/bin/env python3
"""
scripts/install-photobooth-ar-hook.py - Safe installer for Photobooth-App Capture AR Hook.

Injects the minimal, reversible AR processing hook into Photobooth-App's
process_image_inner() function inside:
  photobooth/services/mediaprocessing/processes.py

Execution Order Guarantee:
  captured still
      ↓
  Image.open + pad (context.image established)
      ↓
  config.image_filter (selected photo filter applied to photographed scene)
      ↓
  [AR EXTENSION HOOK] (fresh face detection & AR compositing on still)
      ↓
  config.img_frame_enable (selected theme frame applied topmost)
      ↓
  mediaitem.processed (final presenter & QR code output)

Key Safety Guarantees:
- Idempotent: detects existing injection marker and prevents duplicate hooks.
- Non-invasive: creates a timestamped backup before modifying target.
- Syntax validated: verifies with ast.parse() before writing back to disk.
- Reversible: provides --uninstall flag to cleanly remove the hook.
- Standard library only (zero external dependencies).
"""

import argparse
import ast
from datetime import datetime
import os
from pathlib import Path
import shutil
import sys

DEFAULT_TARGET = Path(
    "/home/firme-booth1/.local/share/pipx/venvs/photobooth-app/lib/python3.13/site-packages/photobooth/services/mediaprocessing/processes.py"
)

HOOK_START_MARKER = "    # === BEGIN AR EXTENSION HOOK ===\n"
HOOK_END_MARKER = "    # === END AR EXTENSION HOOK ===\n"

HOOK_CODE = (
    "    # === BEGIN AR EXTENSION HOOK ===\n"
    "    # Apply selected AR face effect to captured still (after filter, before frame)\n"
    "    if not preview:\n"
    "        try:\n"
    "            import sys\n"
    "            from pathlib import Path\n"
    "            _ext_scripts = Path('/home/firme-booth1/photobooth-kiosk-extensions/scripts')\n"
    "            if _ext_scripts.is_dir() and str(_ext_scripts) not in sys.path:\n"
    "                sys.path.insert(0, str(_ext_scripts))\n"
    "            import ar_engine\n"
    "            context.image = ar_engine.apply_ar_to_still(context.image)\n"
    "        except Exception as _ar_err:\n"
    "            pass\n"
    "    # === END AR EXTENSION HOOK ===\n"
)


def install_hook(target_path: Path, dry_run: bool = False) -> int:
    if not target_path.is_file():
        sys.stderr.write(f"Error: Target file does not exist: {target_path}\n")
        return 1

    try:
        content = target_path.read_text(encoding="utf-8")
    except Exception as err:
        sys.stderr.write(f"Error reading {target_path}: {err}\n")
        return 1

    # Idempotency check
    if HOOK_START_MARKER in content:
        print(f"[OK] AR extension hook is already installed in: {target_path}")
        print("     File is up to date (idempotent).")
        return 0

    # Locate injection point: right before 'if config.img_frame_enable'
    # This guarantees the preferred processing order:
    # captured still -> photo filter -> AR still overlay -> decorative frame -> final save/presenter/QR
    anchor = "    if config.img_frame_enable"
    pos = content.find(anchor)
    if pos == -1:
        # Fallback anchor: right before 'if config.texts_enable'
        fallback_anchor = "    if config.texts_enable"
        pos = content.find(fallback_anchor)
        if pos == -1:
            sys.stderr.write(
                f"Error: Could not locate injection anchor '{anchor}' in {target_path}. Aborting.\n"
            )
            return 1

    new_content = content[:pos] + HOOK_CODE + content[pos:]

    # Validate syntax before writing
    try:
        ast.parse(new_content)
    except SyntaxError as syn_err:
        sys.stderr.write(f"Error: Generated code has syntax error: {syn_err}. Aborting.\n")
        return 1

    if dry_run:
        print(f"[DRY RUN] Would inject AR hook into: {target_path}")
        return 0

    # Create backup
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = target_path.with_name(f"{target_path.name}.bak.{timestamp}")
    try:
        shutil.copy2(target_path, backup_path)
        print(f"[BACKUP] Created backup: {backup_path}")
    except Exception as err:
        sys.stderr.write(f"Error creating backup: {err}\n")
        return 1

    # Write patched file
    try:
        target_path.write_text(new_content, encoding="utf-8")
        print(f"[INSTALLED] Successfully injected AR capture hook into: {target_path}")
    except Exception as err:
        sys.stderr.write(f"Error writing to {target_path}: {err}\n")
        return 1

    return 0


def uninstall_hook(target_path: Path, dry_run: bool = False) -> int:
    if not target_path.is_file():
        sys.stderr.write(f"Error: Target file does not exist: {target_path}\n")
        return 1

    try:
        content = target_path.read_text(encoding="utf-8")
    except Exception as err:
        sys.stderr.write(f"Error reading {target_path}: {err}\n")
        return 1

    start_pos = content.find(HOOK_START_MARKER)
    if start_pos == -1:
        print(f"[OK] No AR hook found in: {target_path}")
        return 0

    end_pos = content.find(HOOK_END_MARKER, start_pos)
    if end_pos == -1:
        sys.stderr.write(f"Error: Found start marker but missing end marker in {target_path}.\n")
        return 1

    end_pos += len(HOOK_END_MARKER)
    new_content = content[:start_pos] + content[end_pos:]

    # Validate syntax
    try:
        ast.parse(new_content)
    except SyntaxError as syn_err:
        sys.stderr.write(f"Error: Syntax error after hook removal: {syn_err}. Aborting.\n")
        return 1

    if dry_run:
        print(f"[DRY RUN] Would remove AR hook from: {target_path}")
        return 0

    # Create backup
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = target_path.with_name(f"{target_path.name}.bak.{timestamp}")
    try:
        shutil.copy2(target_path, backup_path)
        print(f"[BACKUP] Created backup: {backup_path}")
    except Exception as err:
        sys.stderr.write(f"Error creating backup: {err}\n")
        return 1

    try:
        target_path.write_text(new_content, encoding="utf-8")
        print(f"[UNINSTALLED] Successfully removed AR capture hook from: {target_path}")
    except Exception as err:
        sys.stderr.write(f"Error writing to {target_path}: {err}\n")
        return 1

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install or uninstall Photobooth-App Capture AR Hook"
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=DEFAULT_TARGET,
        help=f"Target processes.py file (default: {DEFAULT_TARGET})",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove previously injected AR capture hook",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate the installation without writing any changes",
    )

    args = parser.parse_args()

    if args.uninstall:
        return uninstall_hook(args.target, dry_run=args.dry_run)
    else:
        return install_hook(args.target, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
