#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the GitHub Pages site from README.md with MkDocs Material.
#   ./docs.sh build   -> static site in .site/out/
#   ./docs.sh serve   -> live preview on http://127.0.0.1:8000
# Needs: pip install -r docs-requirements.txt
set -euo pipefail
cd "$(dirname "$0")"
rm -rf .site/docs && mkdir -p .site/docs
cp README.md .site/docs/index.md
cp -r assets environment-values manifests validate.sh .site/docs/
case "${1:-build}" in
  build) mkdocs build --strict ;;
  serve) mkdocs serve ;;
  *) echo "usage: $0 [build|serve]" >&2; exit 1 ;;
esac
