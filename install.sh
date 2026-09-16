#!/usr/bin/env bash
# Install iMerge into ~/Applications and open it.
#
# One command:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/iMerge/main/install.sh | bash
#
# From a clone:
#   ./install.sh
set -euo pipefail

REPO_URL="${IMERGE_REPO:-https://github.com/OWNER/iMerge.git}"
APP_DIR="${IMERGE_APP_DIR:-$HOME/Applications}"
CLONE_DIR="${IMERGE_SRC:-$HOME/.cache/imerge/src}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iMerge is a Mac app. This installer only runs on macOS." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode command line tools are required." >&2
  echo "Install them with:  xcode-select --install" >&2
  exit 1
fi

src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${here}/iMerge.xcodeproj/project.pbxproj" ]]; then
    src="${here}"
    echo "Building from ${src}"
  fi
fi

if [[ -z "${src}" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "git is required to download iMerge." >&2
    exit 1
  fi
  echo "Cloning ${REPO_URL}"
  rm -rf "${CLONE_DIR}"
  mkdir -p "$(dirname "${CLONE_DIR}")"
  git clone --depth 1 "${REPO_URL}" "${CLONE_DIR}"
  src="${CLONE_DIR}"
fi

echo "Building iMerge (this takes a minute the first time)…"
if ! xcodebuild \
  -project "${src}/iMerge.xcodeproj" \
  -scheme iMerge \
  -configuration Release \
  -derivedDataPath "${src}/DerivedData" \
  -destination "platform=macOS" \
  build \
  >/tmp/imerge-build.log 2>&1; then
  echo "Build failed. Last log lines:" >&2
  tail -40 /tmp/imerge-build.log >&2
  exit 1
fi

app="${src}/DerivedData/Build/Products/Release/iMerge.app"
if [[ ! -d "${app}" ]]; then
  echo "Build finished but iMerge.app was not found. Last log lines:" >&2
  tail -20 /tmp/imerge-build.log >&2
  exit 1
fi

mkdir -p "${APP_DIR}"
rm -rf "${APP_DIR}/iMerge.app"
cp -R "${app}" "${APP_DIR}/iMerge.app"

echo "Installed to ${APP_DIR}/iMerge.app"
open "${APP_DIR}/iMerge.app"
