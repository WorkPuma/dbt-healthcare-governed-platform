#!/usr/bin/env python3
"""Fail if any provider_bonus model SELECTs current_timestamp() into a column."""
import re
import sys
import pathlib

BONUS = pathlib.Path('models/provider_bonus')
PATTERN = re.compile(r'current_timestamp\s*\(\s*\)\s+as\s+\w+', re.IGNORECASE)
violations = []
for sql in BONUS.rglob('*.sql'):
    text = sql.read_text(encoding='utf-8')
    for m in PATTERN.finditer(text):
        violations.append(f'{sql}: {m.group(0)}')
if violations:
    print('\n'.join(violations))
    sys.exit(1)
