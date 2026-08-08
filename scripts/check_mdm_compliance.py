#!/usr/bin/env python3
"""
MDM Compliance Check - Standalone Script

Validates that dbt models referencing source tables also include the 
corresponding MDM (Master Data Management) source in their dependencies.

Usage:
    python scripts/check_mdm_compliance.py [--manifest target/manifest.json]

Run after `dbt parse` to generate the manifest.json.
"""

import json
import sys
import argparse
from pathlib import Path
from typing import List, Dict, Any, Optional


# MDM Compliance Rules
# Each rule defines which source patterns require which MDM patterns
# 
# Source patterns match against normalized dependencies from manifest.json
# e.g., source.healthcare_analytics.athenahealth.athenaone.appointment -> athenahealth.athenaone.appointment
#
# Databricks Unity Catalog structure:
#   - AthenaHealth data: athenahealth.athenaone.* (managed Delta Lake replica)
#   - MDM reference data: mdm.reference_data.* (governed reference tables)
#
# Legacy federated sources (should be migrated to athenahealth.*):
#   - athena.* (federated catalog - deprecated)
#   - snowflake.* (federated via snowflake_int_stage)

MDM_RULES = [
    {
        "name": "appointment_type",
        "source_patterns": [
            # Primary: athenahealth managed catalog
            "athenahealth.athenaone.appointment",
            "athenahealth.athenaone.appointmenttype",
            # Legacy: federated athena (should migrate)
            "athena.appointment",
            "athena.appointmenttype",
        ],
        "mdm_patterns": [
            "mdm.reference_data.appointment_type",
            "mdm.appointment_type",  # Alias
        ],
        "description": "Models referencing appointment data must join to MDM appointment_type (mdm.reference_data.appointment_type)",
        "exemption_key": "mdm_exempt_appointment",
    },
    {
        "name": "provider",
        "source_patterns": [
            # Primary: athenahealth managed catalog
            "athenahealth.athenaone.provider",
            # Legacy: federated athena (should migrate)
            "athena.provider",
        ],
        "mdm_patterns": [
            "mdm.reference_data.provider",
            "mdm.provider",  # Alias
        ],
        "description": "Models referencing provider data must join to MDM provider (mdm.reference_data.provider)",
        "exemption_key": "mdm_exempt_provider",
    },
    {
        "name": "department",
        "source_patterns": [
            # Primary: athenahealth managed catalog
            "athenahealth.athenaone.department",
            # Legacy: federated athena (should migrate)
            "athena.department",
        ],
        "mdm_patterns": [
            "mdm.reference_data.location",
            "mdm.location",  # Alias
            "mdm.department",  # Alias
        ],
        "description": "Models referencing department data must join to MDM location (mdm.reference_data.location)",
        "exemption_key": "mdm_exempt_department",
    },
    {
        "name": "patient",
        "source_patterns": [
            # Primary: athenahealth managed catalog
            "athenahealth.athenaone.patient",
            # Legacy: federated athena (should migrate)
            "athena.patient",
        ],
        "mdm_patterns": [
            "mdm.reference_data.patient",
            "mdm.patient",  # Alias
        ],
        "description": "Models referencing patient data must join to MDM patient (mdm.reference_data.patient)",
        "exemption_key": "mdm_exempt_patient",
    },
    {
        "name": "insurance",
        "source_patterns": [
            # Primary: athenahealth managed catalog
            "athenahealth.athenaone.insurancepackage",
            "athenahealth.athenaone.patientinsurance",
            # Legacy: federated athena (should migrate)
            "athena.insurancepackage",
            "athena.patientinsurance",
        ],
        "mdm_patterns": [
            "mdm.reference_data.insurance",
            "mdm.insurance",  # Alias
            "mdm.insurance_package",  # Alias
        ],
        "description": "Models referencing insurance data must join to MDM insurance (mdm.reference_data.insurance)",
        "exemption_key": "mdm_exempt_insurance",
    },
]


def get_source_dependencies(node: Dict[str, Any]) -> List[str]:
    """
    Extract source dependencies from a model's depends_on.nodes.
    
    Source dependencies in manifest.json are formatted as:
    source.{project_name}.{source_name}.{table_name}
    
    Returns normalized source references like: {source_name}.{table_name}
    """
    source_deps = []
    depends_on = node.get("depends_on", {})
    nodes = depends_on.get("nodes", []) or []
    
    for dep in nodes:
        if dep.startswith("source."):
            # source.healthcare_analytics.athenahealth.athenaone.appointment
            # -> athenahealth.athenaone.appointment
            parts = dep.split(".")
            if len(parts) >= 4:
                # Skip "source" and project_name, join the rest
                source_ref = ".".join(parts[2:])
                source_deps.append(source_ref.lower())
    
    return source_deps


def check_pattern_match(source_deps: List[str], patterns: List[str]) -> bool:
    """Check if any source dependency matches any of the given patterns.
    
    Uses exact string matching to avoid false positives.
    e.g., 'athena.patient' should NOT match 'athena.patientinsurance'
    e.g., 'athena.patient' should NOT match 'mdm.patient' (different sources!)
    """
    for dep in source_deps:
        for pattern in patterns:
            pattern_lower = pattern.lower()
            # Exact match only
            if dep == pattern_lower:
                return True
    return False


def is_model_exempt(node: Dict[str, Any], exemption_key: Optional[str] = None) -> bool:
    """
    Check if a model is exempt from MDM compliance checks.
    
    A model is exempt if:
    - config.meta.mdm_exempt is True (global exemption)
    - config.meta.<exemption_key> is True (rule-specific exemption)
    """
    config = node.get("config", {})
    meta = config.get("meta", {}) or {}
    
    # Also check top-level meta
    top_meta = node.get("meta", {}) or {}
    meta.update(top_meta)
    
    # Check global exemption
    if meta.get("mdm_exempt", False):
        return True
    
    # Check rule-specific exemption
    if exemption_key and meta.get(exemption_key, False):
        return True
    
    return False


def check_mdm_compliance(manifest_path: str) -> List[Dict[str, Any]]:
    """
    Check all models in the manifest for MDM compliance violations.
    
    Returns a list of violations with details.
    """
    manifest_file = Path(manifest_path)
    if not manifest_file.exists():
        print(f"ERROR: Manifest file not found: {manifest_path}")
        print("Run 'dbt parse' first to generate the manifest.")
        sys.exit(1)
    
    with open(manifest_file, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    
    nodes = manifest.get("nodes", {})
    violations = []
    
    for node_id, node in nodes.items():
        # Only check models
        if node.get("resource_type") != "model":
            continue
        
        # Skip globally exempt models
        if is_model_exempt(node):
            continue
        
        model_name = node.get("name", "unknown")
        model_path = node.get("original_file_path", "unknown")
        
        # Get source dependencies
        source_deps = get_source_dependencies(node)
        
        if not source_deps:
            continue
        
        # Check each rule
        for rule in MDM_RULES:
            # Skip if model is exempt from this specific rule
            if is_model_exempt(node, rule.get("exemption_key")):
                continue
            
            # Check if model references any source that triggers this rule
            needs_mdm = check_pattern_match(source_deps, rule["source_patterns"])
            
            if needs_mdm:
                # Check if model also references the required MDM source
                has_mdm = check_pattern_match(source_deps, rule["mdm_patterns"])
                
                if not has_mdm:
                    violations.append({
                        "model": model_name,
                        "path": model_path,
                        "rule": rule["name"],
                        "description": rule["description"],
                        "source_patterns": rule["source_patterns"],
                        "required_mdm": rule["mdm_patterns"],
                        "actual_sources": source_deps,
                    })
    
    return violations


def main():
    parser = argparse.ArgumentParser(
        description="Check dbt models for MDM compliance violations"
    )
    parser.add_argument(
        "--manifest",
        default="target/manifest.json",
        help="Path to manifest.json (default: target/manifest.json)"
    )
    parser.add_argument(
        "--warn-only",
        action="store_true",
        help="Exit with 0 even if violations found (just warn)"
    )
    args = parser.parse_args()
    
    print("=" * 70)
    print("MDM Compliance Check")
    print("=" * 70)
    
    violations = check_mdm_compliance(args.manifest)
    
    if not violations:
        print("\n[PASS] All models are MDM compliant!")
        print("=" * 70)
        sys.exit(0)
    
    # Group violations by model
    by_model: Dict[str, List[Dict]] = {}
    for v in violations:
        model_key = f"{v['model']} ({v['path']})"
        if model_key not in by_model:
            by_model[model_key] = []
        by_model[model_key].append(v)
    
    print(f"\n[FAIL] Found {len(violations)} MDM compliance violation(s) in {len(by_model)} model(s):\n")
    
    for model_key, model_violations in by_model.items():
        print(f"  Model: {model_key}")
        for v in model_violations:
            print(f"    - Rule: {v['rule']}")
            print(f"      {v['description']}")
            print(f"      Required MDM: {', '.join(v['required_mdm'])}")
        print()
    
    print("-" * 70)
    print("To fix: Add the required MDM source to your model's SQL:")
    print("  {{ source('mdm', 'appointment_type') }}")
    print()
    print("To exempt a model, add to its YAML config:")
    print("  config:")
    print("    meta:")
    print("      mdm_exempt: true")
    print("      mdm_exempt_reason: 'Reason for exemption'")
    print("=" * 70)
    
    if args.warn_only:
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
