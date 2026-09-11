#!/usr/bin/env python3
"""
scripts/deploy-production-frames.py - Idempotent deployer for Photobooth-App production frame assets.

Copies canonical production frame PNG assets from ui/assets/themes/ into
Photobooth-App's userdata directory (default: /home/firme-booth1/photobooth/userdata/).

Safety Guarantees:
- Idempotent: safe to run repeatedly; skips identical files.
- Copy, never move: leaves source artwork completely untouched.
- Non-destructive: never deletes any existing userdata files.
- Overwrite-safe: overwrites only same-named production theme files when updating.
- Validates source files exist before proceeding; fails clearly if any source file is missing.
- Standard library only (zero external dependencies).
"""

import argparse
import os
from pathlib import Path
import shutil
import sys
from typing import List, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "ui" / "assets" / "themes"
DEFAULT_USERDATA_DIR = Path("/home/firme-booth1/photobooth/userdata")

# Canonical production frame files required by Photobooth-App
CANONICAL_FRAME_FILES: List[str] = [
    "modern-gold-frame-v2.png",
    "tropical-frame-v1.png",
    "black-and-gold-frame-v1.png",
    "floral-frame-v1.png",
    "confetti-frame-v1.png",
    "halloween-frame-v1.png",
    "thanksgiving-frame-v1.png",
    "christmas-frame-v1.png",
    "new-year-frame-v1.png",
]


def verify_source_files(source_dir: Path) -> List[Path]:
    """Verify all canonical production frame files exist in source directory."""
    missing: List[str] = []
    source_paths: List[Path] = []

    for fname in CANONICAL_FRAME_FILES:
        p = source_dir / fname
        if not p.is_file():
            missing.append(fname)
        else:
            source_paths.append(p)

    if missing:
        sys.stderr.write(f"Error: Missing {len(missing)} canonical production frame file(s) in {source_dir}:\n")
        for m in missing:
            sys.stderr.write(f"  - {m}\n")
        sys.exit(1)

    return source_paths


def deploy_frames(source_dir: Path, target_dir: Path, dry_run: bool = False) -> Tuple[int, int, int]:
    """
    Deploy canonical frames to userdata directory idempotently.
    Returns (copied_count, unchanged_count, total_count).
    """
    source_paths = verify_source_files(source_dir)

    if dry_run:
        print(f"[DRY RUN] Source directory: {source_dir}")
        print(f"[DRY RUN] Target directory: {target_dir}")
    else:
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except Exception as err:
            sys.stderr.write(f"Error creating target directory {target_dir}: {err}\n")
            sys.exit(1)

    copied = 0
    unchanged = 0

    print("=" * 70)
    print(f"Deploying Canonical Production Frames to: {target_dir}")
    print("=" * 70)

    for src_path in source_paths:
        fname = src_path.name
        dst_path = target_dir / fname

        # Check if already present and identical in size
        if dst_path.is_file() and dst_path.stat().st_size == src_path.stat().st_size:
            unchanged += 1
            print(f"  [UP-TO-DATE] {fname} ({src_path.stat().st_size:,} bytes)")
            continue

        if dry_run:
            copied += 1
            print(f"  [WOULD COPY] {fname} -> {dst_path}")
            continue

        try:
            # Copy with metadata preservation, never move
            shutil.copy2(src_path, dst_path)
            copied += 1
            print(f"  [COPIED]     {fname} ({src_path.stat().st_size:,} bytes) -> {dst_path}")
        except Exception as err:
            sys.stderr.write(f"Error copying {fname} to {dst_path}: {err}\n")
            sys.exit(1)

    print("-" * 70)
    total = len(source_paths)
    if dry_run:
        print(f"[DRY RUN] Summary: {copied} would be copied, {unchanged} already up-to-date (Total: {total})")
    else:
        print(f"Summary: {copied} copied, {unchanged} up-to-date (Total: {total})")
    print("=" * 70)

    return copied, unchanged, total


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Deploy canonical Photobooth-App production frames to userdata."
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=DEFAULT_USERDATA_DIR,
        help=f"Target userdata directory (default: {DEFAULT_USERDATA_DIR})",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=SOURCE_DIR,
        help=f"Source directory containing canonical frames (default: {SOURCE_DIR})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate the copy operations without modifying target directory",
    )

    args = parser.parse_args()
    deploy_frames(args.source, args.target, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
