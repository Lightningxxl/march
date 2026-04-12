#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELIXIR_DIR="$ROOT_DIR/elixir"
TARGET_REPO_INPUT="${1:-${MARCH_TARGET_REPO:-$PWD}}"

required_files=(
  "MARCH.yml"
  "PLANNER.md"
  "BUILDER.md"
  "AUDITOR.md"
)

if ! command -v mise >/dev/null 2>&1; then
  echo "error: mise is not installed. Install from https://mise.jdx.dev/"
  exit 1
fi

if [[ ! -d "$TARGET_REPO_INPUT" ]]; then
  echo "error: target repo not found: $TARGET_REPO_INPUT"
  exit 1
fi

TARGET_REPO="$(cd "$TARGET_REPO_INPUT" && pwd)"

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$TARGET_REPO/$required_file" ]]; then
    echo "error: missing $required_file at $TARGET_REPO/$required_file"
    exit 1
  fi
done

echo "Starting March:"
echo "  repo: $TARGET_REPO"

cd "$ELIXIR_DIR"
mise trust
mise install
mise exec -- mix deps.get
mise exec -- mix build
exec mise exec -- ./bin/march \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "$TARGET_REPO"
