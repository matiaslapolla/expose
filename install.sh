#!/bin/sh
# Install expose into $PREFIX/bin (default ~/.local/bin).
set -eu

PREFIX=${PREFIX:-$HOME/.local}
REF=${EXPOSE_REF:-main}
URL=https://raw.githubusercontent.com/matiaslapolla/expose/$REF/bin/expose

mkdir -p "$PREFIX/bin"
curl -fsSL "$URL" -o "$PREFIX/bin/expose"
chmod +x "$PREFIX/bin/expose"
echo "installed $PREFIX/bin/expose"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "note: $PREFIX/bin is not on your PATH" ;;
esac
command -v jq >/dev/null || echo "note: expose needs jq"
command -v tailscale >/dev/null || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] ||
  echo "note: expose needs the tailscale CLI"
