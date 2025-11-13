#!/usr/bin/env bash

set -euo pipefail

# Use provided image name
IMAGE_NAME=${1:?"Usage: $0 <image-name>"}

echo "==> Running tests in Docker image: $IMAGE_NAME"
echo ""

# Run the internal test script (mounting local version for quick iteration)
docker run --rm --platform linux/amd64 \
  -v "$(pwd)/run_tests.sh:/workspace/run_tests.sh" \
  "$IMAGE_NAME" bash /workspace/run_tests.sh
