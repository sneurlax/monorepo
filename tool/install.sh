#!/bin/sh
# Compiles monorepo to a native executable and installs it.
#
#   tool/install.sh [directory]
#
# The default directory is $HOME/.local/bin. The compiled binary starts
# without resolving dependencies, unlike a path activation.
set -eu

dest=${1:-"$HOME/.local/bin"}
root=$(cd "$(dirname "$0")/.." && pwd)

export DASH__SUPPRESS_ANALYTICS=true
export FLUTTER_SUPPRESS_ANALYTICS=true

cd "$root"
# Prefer the local pub cache; fall back to the network when it lacks a package.
dart pub get --offline >/dev/null 2>&1 || dart pub get
mkdir -p "$dest"
dart compile exe bin/monorepo.dart -o "$dest/monorepo.tmp"
mv "$dest/monorepo.tmp" "$dest/monorepo"

echo "Installed $("$dest/monorepo" --version) at $dest/monorepo"
found=$(command -v monorepo 2>/dev/null || true)
if [ "$found" != "$dest/monorepo" ]; then
  if [ -n "$found" ]; then
    echo "Note: monorepo on PATH resolves to $found, which comes first."
  else
    echo "Note: $dest is not on PATH."
  fi
fi
