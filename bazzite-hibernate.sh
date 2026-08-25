#!/usr/bin/env bash
set -Eeuo pipefail

# Deck-Hibernate — Bazzite (Fedora Atomic) path. Version: release-1.0.5
# Bazzite 44+ uses OpenGamepadUI/InputPlumber; earlier releases may use HHD.
# Both use this independent, persistent swap + systemd configuration route.

DEFAULT_DELAY_MINUTES=15
IMAGE_PERCENT=30
SWAP_PERCENT=55
MIN_SWAP_GIB=6
FREE_RESERVE_GIB=2
LOW_BATTERY_PERCENT=15
LOW_BATTERY_DELAY_SECONDS=30
STATE_DIR=/var/lib/deck-hibernate
BACKUP_ROOT="$STATE_DIR/backups"
LOG_FILE=/var/log/deck-hibernate-bazzite-setup.log
SWAP_DIR=/var/swap
SWAP_FILE="$SWAP_DIR/deck-hibernate.swap"
SLEEP_CONF=/etc/systemd/sleep.conf.d/99-deck-hibernate.conf
SUSPEND_DROPIN_DIR=/etc/systemd/system/systemd-suspend.service.d
SUSPEND_DROPIN="$SUSPEND_DROPIN_DIR/99-deck-hibernate.conf"
ZRAM_CONF=/etc/systemd/zram-generator.conf
LOW_BATTERY_CHECK=/usr/local/lib/deck-hibernate/low-battery-check
LOW_BATTERY_WATCHER=/usr/local/lib/deck-hibernate/low-battery-watch
LOW_BATTERY_SERVICE=/etc/systemd/system/deck-hibernate-low-battery.service

as_root() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || { echo 'sudo is required.' >&2; exit 1; }
    sudo -k
    sudo -v
    exec sudo -n -- "$0"
}
as_root

[[ -r /etc/os-release ]] || { echo '/etc/os-release is missing'; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    bazzite) ;;
    *) echo "This Bazzite installer was started on '${ID:-unknown}', not Bazzite."; exit 1 ;;
esac

BAZZITE_MAJOR="${VERSION_ID%%.*}"
[[ "$BAZZITE_MAJOR" =~ ^[0-9]+$ ]] || { echo "Could not determine Bazzite version from VERSION_ID=${VERSION_ID:-unknown}."; exit 1; }
if (( BAZZITE_MAJOR >= 44 )); then
    BAZZITE_GENERATION='44+ (OpenGamepadUI/InputPlumber)'
else
    BAZZITE_GENERATION='pre-44 (HHD-era)'
fi

ask_delay() {
    local reply
    HIBERNATE_DELAY="${DEFAULT_DELAY_MINUTES}min"
    [[ -r /dev/tty && -w /dev/tty ]] || return 0
    while :; do
        printf 'Minutes before hibernating [%s]: ' "$DEFAULT_DELAY_MINUTES" >/dev/tty
        IFS= read -r reply </dev/tty || reply=''
        reply="${reply//[[:space:]]/}"
        [[ -z "$reply" ]] && reply="$DEFAULT_DELAY_MINUTES"
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 )); then
            HIBERNATE_DELAY="${reply}min"
            return 0
        fi
        printf 'Enter a whole number of minutes (1 or more).\n' >/dev/tty
    done
}
ask_delay

LOW_BATTERY_MODE=keep
ask_low_battery() {
    local reply
    compgen -G '/sys/class/power_supply/BAT*/capacity' >/dev/null || return 0
    [[ -r /dev/tty && -w /dev/tty ]] || return 0
    if systemctl is-enabled --quiet deck-hibernate-low-battery.service 2>/dev/null; then
        printf 'Automatic low-battery hibernation is already enabled. Keep it enabled? [Y/n] ' >/dev/tty
        read -r reply </dev/tty || reply=''
        case "$reply" in [Nn]|[Nn][Oo]) LOW_BATTERY_MODE=disable ;; *) LOW_BATTERY_MODE=enable ;; esac
    else
        printf 'Hibernate automatically at %s%% battery? It waits %s seconds first. [y/N] ' "$LOW_BATTERY_PERCENT" "$LOW_BATTERY_DELAY_SECONDS" >/dev/tty
        read -r reply </dev/tty || reply=''
        case "$reply" in [Yy]|[Yy][Ee][Ss]) LOW_BATTERY_MODE=enable ;; esac
    fi
}
ask_low_battery

mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec 3>&1 4>&2
exec >>"$LOG_FILE" 2>&1
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_DIR"
CURRENT_STEP=initialization
SUCCESS=0

on_exit() {
    local rc=$?
    if (( rc != 0 && SUCCESS == 0 )); then
        printf '\nBazzite setup failed during: %s\nSee %s for details.\n' "$CURRENT_STEP" "$LOG_FILE" >&4
    fi
}
trap on_exit EXIT

backup_file() {
    local file=$1 target
    [[ -e "$file" ]] || return 0
    target="$BACKUP_DIR$file"
    mkdir -p "$(dirname "$target")"
    [[ -e "$target" ]] || cp -a -- "$file" "$target"
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }

CURRENT_STEP='checking Bazzite support'
for cmd in systemctl findmnt btrfs swapon mkswap awk df rpm-ostree semanage restorecon blkid; do require_cmd "$cmd"; done
[[ -r /sys/power/state ]] || { echo '/sys/power/state is unavailable'; exit 1; }
grep -qw disk /sys/power/state || { echo 'This kernel does not expose hibernation.'; exit 1; }
grep -qw mem /sys/power/state || { echo 'This kernel does not expose suspend.'; exit 1; }
SYSTEMD_SLEEP=''
for path in /usr/lib/systemd/systemd-sleep /lib/systemd/systemd-sleep; do
    [[ -x "$path" ]] && SYSTEMD_SLEEP="$path" && break
done
[[ -n "$SYSTEMD_SLEEP" ]] || { echo 'systemd-sleep binary not found.'; exit 1; }

SWAP_FSTYPE="$(findmnt -n -o FSTYPE -T /var)"
[[ "$SWAP_FSTYPE" == btrfs ]] || { echo "Bazzite support currently requires Btrfs for /var; found $SWAP_FSTYPE."; exit 1; }
MEM_KIB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
[[ "$MEM_KIB" =~ ^[0-9]+$ ]] || { echo 'Could not determine RAM size.'; exit 1; }
IMAGE_BYTES=$(( MEM_KIB * 1024 * IMAGE_PERCENT / 100 ))
TARGET_SWAP_KIB=$(( MEM_KIB * SWAP_PERCENT / 100 ))
MIN_SWAP_KIB=$(( MIN_SWAP_GIB * 1024 * 1024 ))
(( TARGET_SWAP_KIB < MIN_SWAP_KIB )) && TARGET_SWAP_KIB=$MIN_SWAP_KIB
printf 'Bazzite %s detected: %s\n' "$VERSION_ID" "$BAZZITE_GENERATION" >&4
if (( BAZZITE_MAJOR < 44 )); then
    printf 'Pre-44 note: this uses its own persistent systemd swap/resume setup, not HHD dynamic hibernation.\n' >&4
fi

CURRENT_STEP='creating Bazzite hibernation swap'
AVAILABLE_KIB="$(df -Pk /var | awk 'NR==2 {print $4}')"
NEEDED_KIB=$(( TARGET_SWAP_KIB + FREE_RESERVE_GIB * 1024 * 1024 ))
(( AVAILABLE_KIB >= NEEDED_KIB )) || { echo "Not enough free space: need ${NEEDED_KIB} KiB, have ${AVAILABLE_KIB} KiB."; exit 1; }

if [[ ! -e "$SWAP_DIR" ]]; then
    btrfs subvolume create "$SWAP_DIR"
elif ! btrfs subvolume show "$SWAP_DIR" >/dev/null 2>&1; then
    echo "$SWAP_DIR exists but is not a Btrfs subvolume; refusing to alter it."
    exit 1
fi
semanage fcontext -a -t var_t "$SWAP_DIR(/.*)?" 2>/dev/null || semanage fcontext -m -t var_t "$SWAP_DIR(/.*)?"
restorecon -RFv "$SWAP_DIR" >/dev/null

if [[ -f "$SWAP_FILE" ]] && ! grep -Fq "$SWAP_FILE" /proc/swaps; then
    echo "Managed swapfile exists but is inactive: $SWAP_FILE. Refusing to overwrite it."
    exit 1
fi
if [[ ! -f "$SWAP_FILE" ]]; then
    btrfs filesystem mkswapfile --size "$(( TARGET_SWAP_KIB * 1024 ))" --uuid clear "$SWAP_FILE"
    semanage fcontext -a -t swapfile_t "$SWAP_FILE" 2>/dev/null || semanage fcontext -m -t swapfile_t "$SWAP_FILE"
    restorecon -v "$SWAP_FILE" >/dev/null
fi
chmod 600 "$SWAP_FILE"
grep -Fq "$SWAP_FILE" /proc/swaps || swapon "$SWAP_FILE"
backup_file /etc/fstab
if ! awk -v path="$SWAP_FILE" '$1==path && $3=="swap" {found=1} END {exit !found}' /etc/fstab; then
    printf '\n# Deck-Hibernate Bazzite swap\n%s none swap defaults,nofail 0 0\n' "$SWAP_FILE" >>/etc/fstab
fi

CURRENT_STEP='configuring Bazzite resume'
RESUME_OFFSET="$(btrfs inspect-internal map-swapfile -r "$SWAP_FILE")"
[[ "$RESUME_OFFSET" =~ ^[0-9]+$ ]] || { echo "Could not determine resume offset for $SWAP_FILE."; exit 1; }
RESUME_SOURCE="$(findmnt -n -o SOURCE -T "$SWAP_FILE")"
RESUME_SOURCE="${RESUME_SOURCE%%[*}"
RESUME_SOURCE="$(readlink -f "$RESUME_SOURCE")"
[[ -b "$RESUME_SOURCE" ]] || { echo "Swap backing device is not a block device: $RESUME_SOURCE"; exit 1; }
RESUME_UUID="$(blkid -s UUID -o value "$RESUME_SOURCE" 2>/dev/null || true)"
[[ -n "$RESUME_UUID" ]] || { echo "Could not obtain UUID for $RESUME_SOURCE."; exit 1; }
RESUME_ARG="resume=UUID=$RESUME_UUID"
OFFSET_ARG="resume_offset=$RESUME_OFFSET"
rpm-ostree kargs --append-if-missing="$RESUME_ARG" --append-if-missing="$OFFSET_ARG"
rpm-ostree kargs | grep -Fxq "$RESUME_ARG" || { echo "rpm-ostree did not retain $RESUME_ARG"; exit 1; }
rpm-ostree kargs | grep -Fxq "$OFFSET_ARG" || { echo "rpm-ostree did not retain $OFFSET_ARG"; exit 1; }

CURRENT_STEP='disabling zram for persistent hibernation'
backup_file "$ZRAM_CONF"
: >"$ZRAM_CONF"

CURRENT_STEP='configuring suspend-then-hibernate'
mkdir -p "$(dirname "$SLEEP_CONF")" "$SUSPEND_DROPIN_DIR"
backup_file "$SLEEP_CONF"
backup_file "$SUSPEND_DROPIN"
cat >"$SLEEP_CONF" <<EOF
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=$HIBERNATE_DELAY
EOF
cat >"$SUSPEND_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=$SYSTEMD_SLEEP suspend-then-hibernate
EOF
systemctl daemon-reload
systemd-analyze verify "$SUSPEND_DROPIN" >/dev/null

case "$LOW_BATTERY_MODE" in
    enable)
        CURRENT_STEP='configuring low-battery hibernation'
        mkdir -p "$(dirname "$LOW_BATTERY_CHECK")"
        backup_file "$LOW_BATTERY_CHECK"
        backup_file "$LOW_BATTERY_WATCHER"
        backup_file "$LOW_BATTERY_SERVICE"
        cat >"$LOW_BATTERY_CHECK" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
threshold=$LOW_BATTERY_PERCENT
wait_seconds=$LOW_BATTERY_DELAY_SECONDS
low_and_discharging() {
    local battery status capacity lowest=101 found=0
    for battery in /sys/class/power_supply/BAT*; do
        [[ -r "\$battery/status" && -r "\$battery/capacity" ]] || continue
        status="\$(<"\$battery/status")"; capacity="\$(<"\$battery/capacity")"
        [[ "\$status" == Discharging && "\$capacity" =~ ^[0-9]+$ ]] || continue
        found=1; (( capacity < lowest )) && lowest=\$capacity
    done
    (( found && lowest <= threshold ))
}
low_and_discharging || exit 0
logger -t deck-hibernate-low-battery "Battery is low; hibernating in \${wait_seconds} seconds unless AC is connected."
sleep "\$wait_seconds"
low_and_discharging || exit 0
exec systemctl hibernate --ignore-inhibitors
EOF
        cat >"$LOW_BATTERY_WATCHER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
checker=$LOW_BATTERY_CHECK
"\$checker"
watch_upower() {
    dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='/org/freedesktop/UPower/devices'" |
        while IFS= read -r line; do [[ "\$line" == signal* ]] && "\$checker"; done
}
watch_kernel() {
    udevadm monitor --kernel --subsystem-match=power_supply |
        while IFS= read -r line; do [[ "\$line" == *power_supply* ]] && "\$checker"; done
}
case "\${1:-kernel}" in upower) watch_upower ;; kernel) watch_kernel ;; *) exit 2 ;; esac
EOF
        chmod 700 "$LOW_BATTERY_CHECK" "$LOW_BATTERY_WATCHER"
        LOW_BATTERY_EVENT_SOURCE=kernel
        if command -v dbus-monitor >/dev/null 2>&1 && busctl --system list 2>/dev/null | awk '$1 == "org.freedesktop.UPower" {found=1} END {exit !found}'; then
            LOW_BATTERY_EVENT_SOURCE=upower
        else
            require_cmd udevadm
        fi
        cat >"$LOW_BATTERY_SERVICE" <<EOF
[Unit]
Description=Hibernate Bazzite on low battery
[Service]
Type=simple
ExecStart=$LOW_BATTERY_WATCHER $LOW_BATTERY_EVENT_SOURCE
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemd-analyze verify "$LOW_BATTERY_SERVICE" >/dev/null
        systemctl enable --now deck-hibernate-low-battery.service
        ;;
    disable)
        systemctl disable --now deck-hibernate-low-battery.service 2>/dev/null || true
        ;;
esac

SUCCESS=1
cat >&4 <<EOF

Bazzite suspend-then-hibernate is configured.
Version path: $BAZZITE_GENERATION
Swap: $SWAP_FILE
Delay: $HIBERNATE_DELAY
Low-battery safeguard: $LOW_BATTERY_MODE

Reboot now. After that, test hibernation once with: systemctl hibernate
Then use the normal Suspend button; it will sleep first, then hibernate.
Backups: $BACKUP_DIR
EOF
