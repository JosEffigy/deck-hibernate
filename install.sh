#!/usr/bin/env bash
# Download and run the current Deck-Hibernate setup script.
set -Eeuo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/JosEffigy/deck-hibernate/master/deck-hibernate.sh"
TEMP_DIR="$(mktemp -d)"
TEMP_SCRIPT="$TEMP_DIR/deck-hibernate.sh"

cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
    curl --fail --location --proto '=https' --tlsv1.2 "$SCRIPT_URL" -o "$TEMP_SCRIPT"
elif command -v wget >/dev/null 2>&1; then
    wget --https-only -O "$TEMP_SCRIPT" "$SCRIPT_URL"
else
    printf 'Deck-Hibernate online installation requires curl or wget.\n' >&2
    exit 1
fi

chmod 700 "$TEMP_SCRIPT"
"$TEMP_SCRIPT"
