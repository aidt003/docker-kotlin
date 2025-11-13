#!/usr/bin/env bash

set -euo pipefail

# Verify we're in the right directory
if [ ! -d "project" ] || [ ! -f "Dockerfile" ]; then
    echo "❌ Error: Must run from template root directory!"
    exit 1
fi

OUTPUT_NAME="${1:-pre-edit}"
OUTPUT_FILE="${OUTPUT_NAME}.zip"

echo "==> Creating minimal pre-edit package: ${OUTPUT_FILE}"
rm -f "${OUTPUT_FILE}"

zip -r "${OUTPUT_FILE}" . \
  -x "*.git/*" \
  -x "*/.git/*" \
  -x "*.gradle/*" \
  -x "*/.gradle/*" \
  -x "*/build/*" \
  -x "**/build/*" \
  -x ".idea/*" \
  -x "*/.idea/*" \
  -x "*.iml" \
  -x "*/*.iml" \
  -x ".DS_Store" \
  -x "*/.DS_Store" \
  -x "*.swp" \
  -x "*~" \
  -x "*.swo" \
  -x "*.apk" \
  -x "*/*.apk" \
  -x "apks/*" \
  -x "*.aab" \
  -x "*/*.aab" \
  -x ".kotlin/*" \
  -x "*/.kotlin/*" \
  -x "test-results/*" \
  -x "test-report/*" \
  -x "*.log" \
  -x "*.hprof" \
  -x ".vscode/*" \
  -x "captures/*" \
  -x ".externalNativeBuild/*" \
  -x "*.jks" \
  -x "*.keystore" \
  -x "google-services.json"

echo "Created ${OUTPUT_FILE}"
echo "Archive size: $(du -h "${OUTPUT_FILE}" | cut -f1)"