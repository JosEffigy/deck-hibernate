#!/usr/bin/env bash
# Download and run the current Deck-Hibernate setup script.
set -Eeuo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/JosEffigy/deck-hibernate/main/deck-hibernate.sh"
BAZZITE_SCRIPT_URL="https://raw.githubusercontent.com/JosEffigy/deck-hibernate/main/bazzite-hibernate.sh"
TEMP_DIR="$(mktemp -d)"
TEMP_SCRIPT="$TEMP_DIR/deck-hibernate.sh"
BAZZITE_SCRIPT="$TEMP_DIR/bazzite-hibernate.sh"

cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
    curl --fail --location --proto '=https' --tlsv1.2 "$SCRIPT_URL" -o "$TEMP_SCRIPT"
    curl --fail --location --proto '=https' --tlsv1.2 "$BAZZITE_SCRIPT_URL" -o "$BAZZITE_SCRIPT"
elif command -v wget >/dev/null 2>&1; then
    wget --https-only -O "$TEMP_SCRIPT" "$SCRIPT_URL"
    wget --https-only -O "$BAZZITE_SCRIPT" "$BAZZITE_SCRIPT_URL"
else
    printf 'Deck-Hibernate online installation requires curl or wget.\n' >&2
    exit 1
fi

chmod 700 "$TEMP_SCRIPT"
chmod 700 "$BAZZITE_SCRIPT"

if [[ -r /etc/os-release ]] && grep -Eq '^ID=bazzite$' /etc/os-release; then
    "$BAZZITE_SCRIPT"
else
    "$TEMP_SCRIPT"
fi
