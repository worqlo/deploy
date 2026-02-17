#!/bin/bash
# =============================================================================
# Worqlo License & SBOM Generator
# =============================================================================
# Generates THIRD_PARTY_LICENSES.md and sbom-backend.json for customer deployment.
# Run from backend repo root (where pyproject.toml is) after: pip install .
# Exits 1 if any dependency uses GPL or AGPL (copyleft gate).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/deploy}"
LICENSES_FILE="$OUTPUT_DIR/THIRD_PARTY_LICENSES.md"
SBOM_FILE="$OUTPUT_DIR/sbom-backend.json"

# GPL/AGPL gate: fail if any dependency uses GPL or AGPL (LGPL is allowed)
check_copyleft() {
    local json
    json=$(pip-licenses --format=json 2>/dev/null) || {
        echo "ERROR: pip-licenses failed. Install with: pip install pip-licenses" >&2
        exit 1
    }
    if echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pkg in data:
    lic = (pkg.get('License') or '').upper()
    # LGPL is allowed; fail only on GPL or AGPL
    if 'LGPL' in lic:
        continue
    if 'GPL' in lic or 'AGPL' in lic:
        print(f\"{pkg.get('Name', '?')}: {pkg.get('License', '')}\")
        sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
        return 0
    else
        echo "ERROR: GPL/AGPL license detected. Copyleft licenses are not allowed." >&2
        echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pkg in data:
    lic = (pkg.get('License') or '').upper()
    if 'LGPL' in lic:
        continue
    if 'GPL' in lic or 'AGPL' in lic:
        print(f\"  {pkg.get('Name', '?')} {pkg.get('Version', '')}: {pkg.get('License', '')}\", file=sys.stderr)
" 2>/dev/null
        return 1
    fi
}

# Generate license list (markdown)
echo "Generating $LICENSES_FILE ..."
pip-licenses --format=markdown > "$LICENSES_FILE"

# Generate CycloneDX SBOM
echo "Generating $SBOM_FILE ..."
if command -v cyclonedx-py &>/dev/null; then
    cyclonedx-py environment -o "$SBOM_FILE" --no-validate 2>/dev/null || {
        echo "WARNING: cyclonedx-py failed. Install with: pip install cyclonedx-bom" >&2
        rm -f "$SBOM_FILE"
    }
else
    echo "WARNING: cyclonedx-py not found. Install with: pip install cyclonedx-bom" >&2
fi

# GPL/AGPL gate
echo "Checking for GPL/AGPL (copyleft gate) ..."
check_copyleft

echo "Done. License files: $LICENSES_FILE, $SBOM_FILE"
