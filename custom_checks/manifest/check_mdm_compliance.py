"""
MDM Compliance Check for dbt-bouncer

This custom check validates that models referencing certain source tables
also reference the corresponding MDM (Master Data Management) tables.

Rules:
- If a model references athenahealth.*.appointment -> must also reference mdm.appointment_type
- If a model references athenahealth.*.provider -> must also reference mdm.provider
- If a model references athenahealth.*.department -> must also reference mdm.department
- If a model references athenahealth.*.patient -> must also reference mdm.patient
- If a model references athenahealth.*.insurancepackage -> must also reference mdm.insurance_package

Exemptions:
- Models with meta.mdm_exempt: true are skipped
- Models with meta.mdm_exempt_<rule_name>: true skip that specific rule

Usage in dbt-bouncer.yml:
    custom_checks_dir: custom_checks
    manifest_checks:
      - name: check_mdm_source_compliance
        include: ^models/
"""

from typing import TYPE_CHECKING, List, Literal, Optional
from pydantic import Field
from dbt_bouncer.check_base import BaseCheck

if TYPE_CHECKING:
    import warnings
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=UserWarning)
        from dbt_bouncer.parsers import DbtBouncerModelBase, DbtBouncerSourceBase


# MDM Compliance Rules Configuration
# Each rule defines:
#   - source_patterns: patterns in source dependencies that trigger the rule
#   - mdm_patterns: patterns that must be present if source_patterns are found
#   - description: human-readable description for error messages
#   - exemption_key: meta key to exempt from this specific rule

MDM_RULES = [
    {
        "name": "appointment_type",
        "source_patterns": [
            "athenahealth.athenaone.appointment",
            "athenahealth.athenaone.appointmenttype",
            "athena.appointment",  # Legacy federated
            "athena.appointmenttype",
        ],
        "mdm_patterns": [
            "mdm.reference_data.appointment_type",
            "mdm.appointment_type",
        ],
        "description": "Models referencing appointment data must join to MDM appointment_type",
        "exemption_key": "mdm_exempt_appointment",
    },
    {
        "name": "provider",
        "source_patterns": [
            "athenahealth.athenaone.provider",
            "athena.provider",
        ],
        "mdm_patterns": [
            "mdm.reference_data.provider",
            "mdm.provider",
        ],
        "description": "Models referencing provider data must join to MDM provider",
        "exemption_key": "mdm_exempt_provider",
    },
    {
        "name": "department",
        "source_patterns": [
            "athenahealth.athenaone.department",
            "athena.department",
        ],
        "mdm_patterns": [
            "mdm.reference_data.location",
            "mdm.location",
            "mdm.department",
        ],
        "description": "Models referencing department data must join to MDM location",
        "exemption_key": "mdm_exempt_department",
    },
    {
        "name": "patient",
        "source_patterns": [
            "athenahealth.athenaone.patient",
            "athena.patient",
        ],
        "mdm_patterns": [
            "mdm.reference_data.patient",
            "mdm.patient",
        ],
        "description": "Models referencing patient data must join to MDM patient",
        "exemption_key": "mdm_exempt_patient",
    },
    {
        "name": "insurance",
        "source_patterns": [
            "athenahealth.athenaone.insurancepackage",
            "athenahealth.athenaone.patientinsurance",
            "athena.insurancepackage",
            "athena.patientinsurance",
        ],
        "mdm_patterns": [
            "mdm.reference_data.insurance",
            "mdm.insurance",
            "mdm.insurance_package",
        ],
        "description": "Models referencing insurance data must join to MDM insurance",
        "exemption_key": "mdm_exempt_insurance",
    },
]


def _get_source_dependencies(model: "DbtBouncerModelBase") -> List[str]:
    """
    Extract source dependencies from a model's depends_on.nodes.
    
    Source dependencies in manifest.json are formatted as:
    source.{project_name}.{source_name}.{table_name}
    
    We extract and return normalized source references like:
    {source_name}.{table_name}
    """
    source_deps = []
    
    if not hasattr(model, "depends_on") or model.depends_on is None:
        return source_deps
    
    nodes = getattr(model.depends_on, "nodes", []) or []
    
    for node in nodes:
        if node.startswith("source."):
            # source.healthcare_analytics.athenahealth.appointment
            # -> athenahealth.appointment
            parts = node.split(".")
            if len(parts) >= 4:
                # Join source_name.table_name (skip "source" and project_name)
                source_ref = ".".join(parts[2:])
                source_deps.append(source_ref.lower())
    
    return source_deps


def _check_pattern_match(source_deps: List[str], patterns: List[str]) -> bool:
    """
    Check if any source dependency matches any of the given patterns.
    Patterns can be partial matches (e.g., "athenahealth" matches "athenahealth.athenaone.appointment")
    """
    for dep in source_deps:
        for pattern in patterns:
            pattern_lower = pattern.lower()
            # Check for exact match or if the dependency contains the pattern
            if pattern_lower in dep or dep in pattern_lower:
                return True
    return False


def _is_model_exempt(model: "DbtBouncerModelBase", exemption_key: Optional[str] = None) -> bool:
    """
    Check if a model is exempt from MDM compliance checks.
    
    A model is exempt if:
    - meta.mdm_exempt is True (global exemption)
    - meta.<exemption_key> is True (rule-specific exemption)
    """
    meta = {}
    
    # Get meta from model config
    if hasattr(model, "config") and model.config is not None:
        meta = getattr(model.config, "meta", {}) or {}
    
    # Also check direct meta attribute
    if hasattr(model, "meta") and model.meta:
        meta.update(model.meta)
    
    # Check global exemption
    if meta.get("mdm_exempt", False):
        return True
    
    # Check rule-specific exemption
    if exemption_key and meta.get(exemption_key, False):
        return True
    
    return False


class CheckMdmSourceCompliance(BaseCheck):
    """
    Check that models referencing source tables requiring MDM 
    also include the corresponding MDM source in their dependencies.
    
    This validates at the model dependency level (manifest.json),
    not at the data level. It ensures developers have properly
    joined MDM tables in their model SQL.
    
    Parameters:
        None required - rules are defined in MDM_RULES constant
    
    Receives at execution time:
        model: The dbt model being checked
        sources: All sources in the project (for reference)
    
    Example YAML config:
        manifest_checks:
          - name: check_mdm_source_compliance
            include: ^models/(marts|intermediate|healthcare)
    """
    
    model: "DbtBouncerModelBase" = Field(default=None)
    sources: List["DbtBouncerSourceBase"] = Field(default=[])
    name: Literal["check_mdm_source_compliance"]
    
    def execute(self) -> None:
        """Execute the MDM compliance check."""
        
        # Skip if model is globally exempt
        if _is_model_exempt(self.model):
            return
        
        # Get all source dependencies for this model
        source_deps = _get_source_dependencies(self.model)
        
        if not source_deps:
            # Model doesn't reference any sources - nothing to check
            return
        
        violations = []
        
        for rule in MDM_RULES:
            # Skip if model is exempt from this specific rule
            if _is_model_exempt(self.model, rule.get("exemption_key")):
                continue
            
            # Check if model references any source that triggers this rule
            needs_mdm = _check_pattern_match(source_deps, rule["source_patterns"])
            
            if needs_mdm:
                # Check if model also references the required MDM source
                has_mdm = _check_pattern_match(source_deps, rule["mdm_patterns"])
                
                if not has_mdm:
                    violations.append({
                        "rule": rule["name"],
                        "description": rule["description"],
                        "source_patterns": rule["source_patterns"],
                        "required_mdm": rule["mdm_patterns"],
                    })
        
        # If there are violations, fail the check
        if violations:
            model_name = self.model.name
            model_path = getattr(self.model, "original_file_path", "unknown")
            
            violation_messages = []
            for v in violations:
                violation_messages.append(
                    f"  - {v['rule']}: {v['description']}\n"
                    f"    Required MDM: {', '.join(v['required_mdm'])}"
                )
            
            error_msg = (
                f"MDM Compliance Violation in model `{model_name}` ({model_path}):\n"
                f"{chr(10).join(violation_messages)}\n\n"
                f"To fix: Add the required MDM source to your model's SQL using {{ source('mdm', 'table_name') }}\n"
                f"To exempt: Add `meta: mdm_exempt: true` to the model's YAML config"
            )
            
            assert False, error_msg
