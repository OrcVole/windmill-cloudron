#!/bin/bash
# Anonymity gate — no box hostname, private-mirror URL, internal stack URL, token, or personal
# email may appear in any tracked file. Run before every push. Exits non-zero on any hit.
set -uo pipefail
cd "$(dirname "$0")/.."

# Patterns that must never appear in tracked files. (This script's own list is the only place
# these substrings live; it is excluded from the scan.)
patterns=(
  'haggis\.top'
  'wanderingmonster'
  'palladium'
  'reranker\.haggis'
  'alba\.win'
  'most\+'
  'ghp_[A-Za-z0-9]{20,}'
  'gho_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'BEGIN [A-Z ]*PRIVATE KEY'
)

self="test/secret-scan.sh"
hits=0
while IFS= read -r f; do
  [ "$f" = "$self" ] && continue
  case "$f" in logo.png|*.png|LICENSE) continue;; esac
  for p in "${patterns[@]}"; do
    if grep -InE "$p" "$f" >/dev/null 2>&1; then
      echo "LEAK: pattern '/$p/' in $f"
      grep -InE "$p" "$f" | head -3
      hits=$((hits+1))
    fi
  done
done < <(git ls-files)

if [ "$hits" -ne 0 ]; then
  echo "SECRET-SCAN FAIL: $hits hit(s)"; exit 1
fi
echo "SECRET-SCAN PASS: tracked files are clean"
