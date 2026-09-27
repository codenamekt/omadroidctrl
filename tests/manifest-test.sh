#!/usr/bin/env bash
# Mirrors the checks omarchy-plugin-validate enforces, so CI can run without Omarchy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/manifest.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
jq -e . "$M" >/dev/null || fail "manifest.json is not valid JSON"
jq -e '.schemaVersion == 1' "$M" >/dev/null || fail "schemaVersion must be 1"
for f in id name version author description kinds entryPoints license; do
  jq -e --arg f "$f" 'has($f)' "$M" >/dev/null || fail "missing $f"
done
jq -e '.id == "io.github.codenamekt.omadroidctrl" and (.id | startswith("omarchy.") | not)' "$M" >/dev/null || fail "id"
jq -e '.kinds == ["bar-widget"] and .entryPoints.barWidget == "Panel.qml"' "$M" >/dev/null || fail "kinds/entryPoints"
[[ -f "$ROOT/Panel.qml" ]] || fail "entry point Panel.qml missing"
jq -e '.barWidget.defaultSection == "right"' "$M" >/dev/null || fail "defaultSection"
# Every schema key has a default and vice versa.
jq -e '(.barWidget.schema | map(.key) | sort) == (.barWidget.defaults | keys | sort)' "$M" >/dev/null || fail "schema keys and defaults differ"
jq -e '[.barWidget.schema[] | select(.type == "enum") | (.defaultValue as $d | .options | index($d)) != null] | all' "$M" >/dev/null || fail "an enum default is not among its options"
[[ -z $(find "$ROOT" -name .git -prune -o -type l -print -quit) ]] || fail "symlinks are not allowed in a plugin"
[[ -x "$ROOT/omadroidctrl-helper" ]] || fail "helper is not executable"
echo "manifest tests passed"
