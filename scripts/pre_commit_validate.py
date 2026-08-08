#!/usr/bin/env python3
"""
Pre-commit validation gate — mirrors CircleCI PR checks.

Runs on every `git commit` via the pre-commit framework.
Target: < 20 seconds on a warm dbt project.

Uses dbt Fusion (`dbtf`) when on PATH; otherwise dbt-core (`dbt`). Override with DBT_CLI.

Checks:
  [1] dbt parse          — syntax + ref validation, produces target/manifest.json (CircleCI: validate job)
  [2] Full-refresh guard — CDC/audit models must not enable full_refresh (CircleCI: full-refresh-guard)
  [3] Seed integrity     — staged seed CSVs must have updated METADATA.yml hashes (CircleCI: seed-integrity-guard)

Exit codes:
  0 — All checks passed
  1 — One or more checks failed
"""

import os
import re
import subprocess
import sys
from pathlib import Path


# CodeAnt: duplicated-literal constants
LBL_FULL_REFRESH_GUARD = 'full-refresh guard'
LBL_SEED_INTEGRITY = 'seed integrity'

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from dbt_executable import resolve_dbt_cli


def find_project_root() -> Path:
    """Walk up from CWD to find dbt_project.yml."""
    cwd = Path.cwd()
    for parent in [cwd] + list(cwd.parents):
        if (parent / "dbt_project.yml").exists():
            return parent
    script_dir = Path(__file__).resolve().parent
    return script_dir.parent


def run_cmd(cmd: list[str], cwd: Path, timeout: int = 120) -> tuple[int, str]:
    """Run a command and return (exit_code, combined_output)."""
    try:
        result = subprocess.run(
            cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout
        )
        output = (result.stdout or "") + (result.stderr or "")
        return result.returncode, output.strip()
    except subprocess.TimeoutExpired:
        return 1, f"Command timed out after {timeout}s: {' '.join(cmd)}"
    except FileNotFoundError:
        return 1, f"Command not found: {cmd[0]}"


def get_staged_files(cwd: Path) -> list[str]:
    """Return list of staged file paths relative to repo root."""
    rc, output = run_cmd(["git", "diff", "--cached", "--name-only"], cwd)
    if rc != 0:
        return []
    return [f.strip() for f in output.splitlines() if f.strip()]


class CheckResult:
    def __init__(self, name: str, passed: bool, message: str = ""):
        self.name = name
        self.passed = passed
        self.message = message


def check_dbt_parse(root: Path) -> CheckResult:
    """[1] dbt parse — syntax validation, ~5s (up to 120s if warehouse cold)."""
    rc, output = run_cmd([resolve_dbt_cli(), "parse"], root, timeout=120)
    if rc != 0:
        errors = [l for l in output.splitlines() if "error" in l.lower() or "Error" in l]
        return CheckResult("dbt parse", False, "\n".join(errors[-10:]) or output[-500:])
    return CheckResult("dbt parse", True)


def check_full_refresh_guard(root: Path) -> CheckResult:
    """[2] CDC/audit models must not set full_refresh=true."""
    cdc_dir = root / "models" / "healthcare" / "raf" / "cdc"
    if not cdc_dir.exists():
        return CheckResult(LBL_FULL_REFRESH_GUARD, True, "No CDC directory found — skipped")

    violations = []
    for pattern, label in [("*.sql", "SQL"), ("*.yml", "YAML")]:
        for f in sorted(cdc_dir.rglob(pattern)):
            content = f.read_text(encoding="utf-8", errors="replace")
            if label == "SQL":
                if re.search(r"full_refresh\s*[:=]\s*(true|True|TRUE)", content):
                    violations.append(str(f.relative_to(root)))
            else:
                if re.search(r"full_refresh:\s*true", content, re.IGNORECASE):
                    violations.append(str(f.relative_to(root)))

    if violations:
        return CheckResult(
            LBL_FULL_REFRESH_GUARD, False,
            "CDC/audit models with full_refresh=true:\n  " + "\n  ".join(violations)
        )
    return CheckResult(LBL_FULL_REFRESH_GUARD, True)


def check_seed_integrity(root: Path, staged_files: list[str]) -> CheckResult:
    """[3] Staged seed CSVs must include METADATA.yml hash updates."""
    csv_changed = [f for f in staged_files if f.startswith("seeds/") and f.endswith(".csv")]
    meta_changed = [f for f in staged_files if f.endswith("METADATA.yml")]

    if not csv_changed:
        return CheckResult(LBL_SEED_INTEGRITY, True, "No seed CSVs staged")

    if csv_changed and not meta_changed:
        return CheckResult(
            LBL_SEED_INTEGRITY, False,
            f"Seed CSV files staged but METADATA.yml not updated.\n"
            f"  Changed: {', '.join(csv_changed)}\n"
            f"  Run: python scripts/verify_seed_hashes.py --update"
        )

    # METADATA.yml is staged — validate actual hashes
    rc, output = run_cmd([sys.executable, "scripts/verify_seed_hashes.py"], root, timeout=30)
    if rc != 0:
        return CheckResult(LBL_SEED_INTEGRITY, False, output[-500:])
    return CheckResult(LBL_SEED_INTEGRITY, True)


def main() -> int:
    root = find_project_root()
    staged = get_staged_files(root)

    print("=" * 60)
    print("Pre-commit validation (mirrors CircleCI PR checks)")
    print(f"  Project: {root}")
    print(f"  Staged files: {len(staged)}")
    print("=" * 60)

    results: list[CheckResult] = []

    # [1] dbt parse — must run first since it produces the manifest
    print("\n[1/3] dbt parse...")
    r = check_dbt_parse(root)
    results.append(r)
    status = "PASS" if r.passed else "FAIL"
    print(f"  [{status}] {r.name}")
    if r.message and not r.passed:
        for line in r.message.splitlines():
            print(f"    {line}")

    # [2-3] Independent checks
    independent_checks = [
        (LBL_FULL_REFRESH_GUARD, lambda: check_full_refresh_guard(root)),
        (LBL_SEED_INTEGRITY, lambda: check_seed_integrity(root, staged)),
    ]

    for i, (name, check_fn) in enumerate(independent_checks, 2):
        print(f"\n[{i}/3] {name}...")
        result = check_fn()
        results.append(result)
        status = "PASS" if result.passed else "FAIL"
        print(f"  [{status}] {result.name}")
        if result.message and not result.passed:
            for line in result.message.splitlines():
                print(f"    {line}")

    print("\n" + "=" * 60)
    passed = sum(1 for r in results if r.passed)
    failed = [r for r in results if not r.passed]

    if failed:
        print(f"FAILED: {len(failed)} check(s) failed, {passed} passed")
        print("Fix the issues above before committing.")
        print("To bypass (emergency): git commit --no-verify")
        return 1
    else:
        print(f"PASSED: All {passed} checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
