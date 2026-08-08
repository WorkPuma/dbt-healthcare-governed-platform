#!/usr/bin/env python3
"""
Pre-push validation gate — runs manifest-dependent checks before push.

Runs on `git push` via the pre-commit framework (hook-type: pre-push).
Target: < 90 seconds (reuses manifest from dbt parse).

Checks:
  [1] Manifest refresh     — reuse target/manifest.json from pre-commit, or run dbt parse if stale
  [2] dbt compile (slim)   — compile modified+ models (dbtf/dbt per DBT_CLI / PATH; CircleCI: slim-ci)
  [3] MDM compliance       — source → MDM dependency rules (CircleCI: mdm-compliance)

Notes:
  - dbt compile is DISABLED by default (too slow for a push hook against remote warehouse).
    Enable with: DBT_COMPILE_ON_PUSH=1 git push
    Even when enabled, failures are non-blocking (warnings only).
  - For full runtime validation (actual execution), use scripts/local_slim_build.py manually.

Exit codes:
  0 — All checks passed
  1 — One or more checks failed
"""

import os
import subprocess
import sys
import time
from pathlib import Path


# CodeAnt: duplicated-literal constants
MANIFEST_JSON = 'manifest.json'
LBL_DBT_COMPILE_SLIM = 'dbt compile (slim)'
LBL_MDM_COMPLIANCE = 'MDM compliance'

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from dbt_executable import resolve_dbt_cli


def find_project_root() -> Path:
    cwd = Path.cwd()
    for parent in [cwd] + list(cwd.parents):
        if (parent / "dbt_project.yml").exists():
            return parent
    return Path(__file__).resolve().parent.parent


def run_cmd(cmd: list[str], cwd: Path, timeout: int = 300) -> tuple[int, str]:
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


class CheckResult:
    def __init__(self, name: str, passed: bool, message: str = "", skipped: bool = False):
        self.name = name
        self.passed = passed
        self.message = message
        self.skipped = skipped


def ensure_manifest(root: Path) -> CheckResult:
    """[1] Ensure target/manifest.json exists — reuse from pre-commit or run dbt parse."""
    manifest = root / "target" / MANIFEST_JSON
    max_age_seconds = 600  # 10 minutes

    if manifest.exists():
        age = time.time() - manifest.stat().st_mtime
        if age < max_age_seconds:
            return CheckResult(
                "Manifest (cached)", True,
                f"Reusing target/manifest.json ({int(age)}s old, from pre-commit dbt parse)"
            )

    rc, output = run_cmd([resolve_dbt_cli(), "parse"], root, timeout=120)
    if rc != 0:
        errors = [l for l in output.splitlines() if "error" in l.lower()]
        return CheckResult("dbt parse", False, "\n".join(errors[-15:]) or output[-800:])
    if not manifest.exists():
        return CheckResult("dbt parse", False, "Parse succeeded but target/manifest.json not found")
    return CheckResult("Manifest (refreshed via dbt parse)", True)


def check_dbt_compile_slim(root: Path) -> CheckResult:
    """[2] dbt compile --select state:modified+ to catch Jinja/SQL errors beyond parse."""
    manifest = root / "target" / MANIFEST_JSON
    state_dir = root / ".state"
    prod_manifest = state_dir / MANIFEST_JSON

    if not manifest.exists():
        return CheckResult(
            LBL_DBT_COMPILE_SLIM, True,
            "No target/manifest.json — skipped (dbt parse must run first)",
            skipped=True,
        )

    if not prod_manifest.exists():
        # No production state — fall back to compiling changed files that
        # still exist on disk (excludes deletions).
        rc, diff_out = run_cmd(
            ["git", "diff", "--name-only", "--diff-filter=d", "HEAD~1", "--", "models/"],
            root, timeout=10,
        )
        if rc != 0 or not diff_out.strip():
            return CheckResult(
                LBL_DBT_COMPILE_SLIM, True,
                "No .state/ dir and no modified models detected — skipped. "
                "Use 'python scripts/local_slim_build.py --download-state' to enable state:modified+",
            )

        changed_models = []
        for line in diff_out.strip().splitlines():
            line = line.strip()
            if line.startswith("models/") and line.endswith(".sql"):
                model_path = root / line
                if model_path.exists():
                    changed_models.append(Path(line).stem)

        if not changed_models:
            return CheckResult(
                LBL_DBT_COMPILE_SLIM, True, "No modified SQL models on disk"
            )

        selector = " ".join(changed_models)
        rc, output = run_cmd(
            ["dbt", "compile", "--select", selector], root, timeout=300
        )
        if rc != 0:
            errors = extract_errors(output)
            return CheckResult(f"dbt compile ({len(changed_models)} models)", False, errors)
        return CheckResult(f"dbt compile ({len(changed_models)} models)", True)

    # Best path: use dbt state comparison with production manifest
    rc, output = run_cmd(
        [resolve_dbt_cli(), "compile", "--select", "state:modified+", "--state", str(state_dir)],
        root, timeout=300,
    )
    if rc != 0:
        errors = extract_errors(output)
        return CheckResult("dbt compile (state:modified+)", False, errors)

    compiled_count = sum(1 for l in output.splitlines() if "Compiled node" in l)
    return CheckResult(
        "dbt compile (state:modified+)", True,
        f"Compiled {compiled_count} modified+ model(s) successfully"
    )


def extract_errors(output: str) -> str:
    """Pull error lines from dbt output for concise reporting."""
    error_lines = [
        l for l in output.splitlines()
        if any(kw in l.lower() for kw in ["error", "not found", "fail", "compilation"])
    ]
    return "\n".join(error_lines[-15:]) or output[-800:]


def check_mdm_compliance(root: Path) -> CheckResult:
    """[3] MDM compliance — source dependencies must include MDM tables."""
    script = root / "scripts" / "check_mdm_compliance.py"
    manifest = root / "target" / MANIFEST_JSON

    if not script.exists():
        return CheckResult(LBL_MDM_COMPLIANCE, True, "Script not found — skipped", skipped=True)
    if not manifest.exists():
        return CheckResult(LBL_MDM_COMPLIANCE, True, "No manifest — skipped", skipped=True)

    rc, output = run_cmd(
        [sys.executable, str(script), "--manifest", str(manifest)],
        root, timeout=30
    )
    if rc != 0:
        fail_lines = [l for l in output.splitlines() if "FAIL" in l or "VIOLATION" in l]
        return CheckResult(LBL_MDM_COMPLIANCE, False, "\n".join(fail_lines) or output[-500:])
    return CheckResult(LBL_MDM_COMPLIANCE, True)


def main() -> int:
    root = find_project_root()
    total_checks = 3

    print("=" * 60)
    print("Pre-push validation (mirrors CircleCI manifest-dependent checks)")
    print(f"  Project: {root}")
    print("=" * 60)

    results: list[CheckResult] = []
    manifest_ok = False

    # [1] Ensure manifest exists (reuse from pre-commit or re-parse)
    print(f"\n[1/{total_checks}] Ensure manifest...")
    r = ensure_manifest(root)
    results.append(r)
    manifest_ok = r.passed
    status = "PASS" if r.passed else "FAIL"
    print(f"  [{status}] {r.name}")
    if r.message:
        print(f"    {r.message}")

    if not manifest_ok:
        print("\n  No manifest available — skipping dependent checks")

    # [2] dbt compile (slim) — non-blocking; catches Jinja/SQL errors beyond parse
    #     For full runtime validation use: python scripts/local_slim_build.py
    compile_enabled = os.environ.get("DBT_COMPILE_ON_PUSH", "").lower() in ("1", "true", "yes")
    print(f"\n[2/{total_checks}] dbt compile (slim)...")
    if not compile_enabled:
        r = CheckResult(
            LBL_DBT_COMPILE_SLIM, True,
            "Skipped (set DBT_COMPILE_ON_PUSH=1 to enable, or use scripts/local_slim_build.py)",
            skipped=True,
        )
    elif not manifest_ok:
        r = CheckResult(LBL_DBT_COMPILE_SLIM, True, "Skipped (no manifest)", skipped=True)
    else:
        r = check_dbt_compile_slim(root)
        if not r.passed:
            # Non-blocking: demote to warning so push is not blocked
            print(f"  [WARN] {r.name} (non-blocking)")
            if r.message:
                for line in r.message.splitlines()[:10]:
                    print(f"    {line}")
            r = CheckResult(r.name, True, r.message, skipped=False)
    results.append(r)
    if r.skipped:
        print(f"  [SKIP] {r.name}: {r.message}")
    elif r.passed:
        status = "PASS"
        print(f"  [{status}] {r.name}")
        if r.message:
            for line in r.message.splitlines()[:10]:
                print(f"    {line}")

    # [3] Remaining manifest-dependent checks
    manifest_checks = [
        (LBL_MDM_COMPLIANCE, check_mdm_compliance),
    ]

    for i, (name, check_fn) in enumerate(manifest_checks, 3):
        print(f"\n[{i}/{total_checks}] {name}...")
        if not manifest_ok:
            r = CheckResult(name, True, "Skipped (no manifest)", skipped=True)
        else:
            r = check_fn(root)
        results.append(r)

        if r.skipped:
            print(f"  [SKIP] {r.name}: {r.message}")
        else:
            status = "PASS" if r.passed else "FAIL"
            print(f"  [{status}] {r.name}")
            if r.message and not r.passed:
                for line in r.message.splitlines()[:10]:
                    print(f"    {line}")

    print("\n" + "=" * 60)
    failed = [r for r in results if not r.passed and not r.skipped]
    skipped = [r for r in results if r.skipped]
    passed = [r for r in results if r.passed]

    if failed:
        print(f"FAILED: {len(failed)} check(s) failed, {len(passed)} passed, {len(skipped)} skipped")
        print("Fix the issues above before pushing.")
        print("To bypass (emergency): git push --no-verify")
        return 1
    else:
        print(f"PASSED: {len(passed)} passed, {len(skipped)} skipped")
        return 0


if __name__ == "__main__":
    sys.exit(main())
