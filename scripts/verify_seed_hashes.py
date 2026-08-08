#!/usr/bin/env python3
"""
Verify (or update) SHA-256 checksums for dbt seed CSV files.

Usage:
    python scripts/verify_seed_hashes.py          # Verify all seed hashes
    python scripts/verify_seed_hashes.py --update  # Recompute and update METADATA.yml

Exit codes:
    0 - All checksums match
    1 - One or more checksums do not match
    2 - Missing files or configuration errors

This script is called by:
  - Bitbucket Pipelines (seed guard step)
  - Prefect raf_pipeline_orchestrator.py (validate_seed_checksums task)
  - Manual verification
"""

import argparse
import hashlib
import sys
from pathlib import Path

import yaml

# Seed directories relative to dbt project root
SEED_DIRS = [
    "seeds/cms_hcc_v28",
    "seeds/raf_reference",
    "seeds/provider_bonus",
]


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hash of a file.

    Normalizes line endings to LF before hashing so checksums
    are consistent across Windows (CRLF) and Linux (LF) — critical
    because Bitbucket Pipelines run on Linux but developers work
    on Windows.
    """
    h = hashlib.sha256()
    with open(path, "rb") as f:
        data = f.read()
    # Normalize CRLF -> LF for cross-platform consistency
    data = data.replace(b"\r\n", b"\n")
    h.update(data)
    return h.hexdigest()


def find_project_root() -> Path:
    """Find the dbt project root by looking for dbt_project.yml."""
    # Try current directory first, then walk up
    cwd = Path.cwd()
    for parent in [cwd] + list(cwd.parents):
        if (parent / "dbt_project.yml").exists():
            return parent
    # Fallback: assume script is in scripts/ under project root
    script_dir = Path(__file__).resolve().parent
    return script_dir.parent


def verify_hashes(project_root: Path) -> tuple[int, int, list[str]]:
    """
    Verify all seed CSV hashes against METADATA.yml.

    Returns:
        (total_checked, total_passed, list of error messages)
    """
    total_checked = 0
    total_passed = 0
    errors = []

    for seed_dir in SEED_DIRS:
        full_dir = project_root / seed_dir
        metadata_path = full_dir / "METADATA.yml"

        if not metadata_path.exists():
            errors.append(f"METADATA.yml not found: {metadata_path}")
            continue

        with open(metadata_path) as f:
            metadata = yaml.safe_load(f)

        files_section = metadata.get("files", {})

        for filename, info in files_section.items():
            csv_path = full_dir / filename
            total_checked += 1

            if not csv_path.exists():
                errors.append(f"Missing seed file: {csv_path}")
                continue

            expected_hash = info.get("sha256", "")
            actual_hash = sha256_file(csv_path)

            if actual_hash == expected_hash:
                total_passed += 1
            else:
                errors.append(
                    f"Hash mismatch: {filename}\n"
                    f"  Expected: {expected_hash}\n"
                    f"  Actual:   {actual_hash}"
                )

        # Check for CSV files not listed in METADATA.yml
        for csv_file in sorted(full_dir.glob("*.csv")):
            if csv_file.name not in files_section:
                errors.append(
                    f"Unlisted seed file: {csv_file.name} "
                    f"(not in {metadata_path.name})"
                )

    return total_checked, total_passed, errors


def update_hashes(project_root: Path) -> None:
    """Recompute SHA-256 hashes and update METADATA.yml files in place."""
    for seed_dir in SEED_DIRS:
        full_dir = project_root / seed_dir
        metadata_path = full_dir / "METADATA.yml"

        if not metadata_path.exists():
            print(f"No METADATA.yml in {full_dir}, skipping")
            continue

        with open(metadata_path) as f:
            metadata = yaml.safe_load(f)

        files_section = metadata.get("files", {})
        updated = 0

        for filename, info in files_section.items():
            csv_path = full_dir / filename
            if not csv_path.exists():
                print(f"  WARNING: {filename} not found, skipping")
                continue

            new_hash = sha256_file(csv_path)
            old_hash = info.get("sha256", "")

            if new_hash != old_hash:
                info["sha256"] = new_hash
                updated += 1
                print(f"  Updated: {filename}")
            else:
                print(f"  Unchanged: {filename}")

        if updated > 0:
            with open(metadata_path, "w") as f:
                yaml.dump(metadata, f, default_flow_style=False, sort_keys=False)
            print(f"  Wrote {metadata_path} ({updated} file(s) updated)")
        else:
            print(f"  No changes needed in {metadata_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Verify or update SHA-256 checksums for dbt seed CSV files."
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="Recompute and update METADATA.yml hashes instead of verifying",
    )
    args = parser.parse_args()

    project_root = find_project_root()
    print(f"dbt project root: {project_root}")
    print()

    if args.update:
        print("Updating seed hashes...")
        update_hashes(project_root)
        print()
        print("Done. Remember to commit the updated METADATA.yml files.")
        sys.exit(0)

    # Verify mode
    print("Verifying seed checksums...")
    print()

    total_checked, total_passed, errors = verify_hashes(project_root)

    print(f"Checked: {total_checked}")
    print(f"Passed:  {total_passed}")
    print(f"Failed:  {len(errors)}")
    print()

    if errors:
        print("ERRORS:")
        for err in errors:
            print(f"  {err}")
        print()
        print("Seed checksum verification FAILED.")
        print("Run 'python scripts/verify_seed_hashes.py --update' to update hashes.")
        sys.exit(1)
    else:
        print("All seed checksums match. PASSED.")
        sys.exit(0)


if __name__ == "__main__":
    main()
