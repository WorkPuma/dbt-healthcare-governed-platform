#!/usr/bin/env python3
"""Remove duplicate elementary.volume_anomalies blocks and fix orphan test blocks."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "models"

ELEM_BLOCK = re.compile(
    r"\n      - elementary\.volume_anomalies:\n"
    r"          arguments:\n"
    r"            timestamp_column: [^\n]+\n"
    r"          config:\n"
    r"            severity: warn\n"
    r'            tags: \["elementary", "freshness"\]',
    re.MULTILINE,
)


def dedupe_model_section(section: str) -> str:
    seen = False

    def repl(m: re.Match[str]) -> str:
        nonlocal seen
        if seen:
            return ""
        seen = True
        return m.group(0)

    return ELEM_BLOCK.sub(repl, section)


def dedupe_file(path: Path) -> bool:
    text = path.read_text()
    original = text

    # Remove orphan tests blocks not under a model/source (sources.yml damage)
    text = re.sub(
        r"\n  # =+ BackendBaaS.*?\n    tests:\n"
        r"      - elementary\.volume_anomalies:.*?"
        r'tags: \["elementary", "freshness"\]\n\n\n',
        "\n  # ============================================\n"
        "  # BackendBaaS BIPlatform Source - AI_Outreach Outreach\n"
        "  # ============================================\n\n",
        text,
        flags=re.DOTALL,
        count=1,
    )

    parts = re.split(r"(?= {2}- name: )", text)
    if len(parts) <= 1:
        new_text = text
    else:
        head, *rest = parts
        new_rest = [dedupe_model_section(p) for p in rest]
        new_text = head + "".join(new_rest)

    if new_text != original:
        path.write_text(new_text)
        return True
    return False


def main() -> None:
    changed = 0
    for yml in MODELS.rglob("*.yml"):
        if dedupe_file(yml):
            print("deduped", yml.relative_to(ROOT))
            changed += 1
    print("files changed:", changed)


if __name__ == "__main__":
    main()
