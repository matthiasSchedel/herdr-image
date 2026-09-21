#!/bin/bash
set -euo pipefail

ROOT=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
BIN_DIR="${HOME:?HOME is required}/.local/bin"
ZSH_DIR="$HOME/.local/share/zsh/site-functions"

link_file() {
  local source="$1" target="$2"
  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    printf 'already linked: %s\n' "$target"
    return 0
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    printf 'install: refusing to replace %s\n' "$target" >&2
    return 1
  fi
  ln -s "$source" "$target"
  printf 'linked: %s -> %s\n' "$target" "$source"
}

mkdir -p "$BIN_DIR" "$ZSH_DIR"
link_file "$ROOT/bin/image" "$BIN_DIR/image"
link_file "$ROOT/bin/agent-shot" "$BIN_DIR/agent-shot"
link_file "$ROOT/completions/_image" "$ZSH_DIR/_image"

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nAdd %s to PATH, then restart your shell.\n' "$BIN_DIR" ;;
esac

printf '\nInstalled. Keep this checkout in place because the links point into it.\n'
