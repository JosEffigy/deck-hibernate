#!/usr/bin/env bash
set -Eeuo pipefail

# Deck-Hibernate
# CachyOS/Arch handheld suspend -> hibernate setup.
# Prompts only for sudo authentication, the delay, and the final keypress.
# Designed to be re-runnable.
# Version: release-1.0.1

DEFAULT_DELAY_MINUTES=15
HIBERNATE_DELAY="${DEFAULT_DELAY_MINUTES}min"
IMAGE_PERCENT=30
SWAP_PERCENT=55
MIN_SWAP_GIB=6
FREE_RESERVE_GIB=2

STATE_DIR="/var/lib/cachyos-handheld-hibernate"
BACKUP_ROOT="$STATE_DIR/backups"
LOG_FILE="/var/log/cachyos-handheld-hibernate-setup.log"
SWAP_DIR="$STATE_DIR/swap"
SWAP_FILE="$SWAP_DIR/hibernate.swap"
SLEEP_CONF="/etc/systemd/sleep.conf.d/99-cachyos-handheld-suspend-then-hibernate.conf"
SUSPEND_OVERRIDE_DIR="/etc/systemd/system/systemd-suspend.service.d"
SUSPEND_OVERRIDE="$SUSPEND_OVERRIDE_DIR/99-cachyos-suspend-then-hibernate.conf"
IMAGE_SERVICE="/etc/systemd/system/cachyos-hibernate-image-size.service"
DRACUT_CONF="/etc/dracut.conf.d/99-cachyos-hibernate.conf"

# Keep the user's terminal available while logging setup details quietly.
exec 3>&1 4>&2

as_root() {
    if (( EUID == 0 )); then
        return 0
    fi

    command -v sudo >/dev/null 2>&1 || {
        printf 'sudo is required to run Deck-Hibernate.\n' >&4
        exit 1
    }

    # Always invalidate any cached sudo timestamp so a normal-user launch
    # asks for the administrator password immediately at the start.
    sudo -k
    sudo -v

    # Re-exec the actual downloaded/local script as root without prompting twice.
    exec sudo -n -- "$0"
}
as_root

ask_delay() {
    local value

    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        HIBERNATE_DELAY="${DEFAULT_DELAY_MINUTES}min"
        return 0
    fi

    while :; do
        printf 'Minutes before hibernating [%s]: ' "$DEFAULT_DELAY_MINUTES" > /dev/tty
        IFS= read -r value < /dev/tty || value=''
        value="${value//[[:space:]]/}"

        if [[ -z "$value" ]]; then
            value="$DEFAULT_DELAY_MINUTES"
        fi

        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )); then
            HIBERNATE_DELAY="${value}min"
            return 0
        fi

        printf 'Please enter a whole number of minutes (1 or more), or press Enter for %s.\n' "$DEFAULT_DELAY_MINUTES" > /dev/tty
    done
}
ask_delay

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$BACKUP_ROOT"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_DIR"

CURRENT_STEP="initialization"
SETUP_SUCCEEDED=0
FAILURE_REPORTED=0
on_exit() {
    local rc=$?
    if (( rc != 0 && SETUP_SUCCEEDED == 0 && FAILURE_REPORTED == 0 )); then
        printf '\nSetup failed during: %s\nSee %s for details.\n' "$CURRENT_STEP" "$LOG_FILE" >&4
    fi
}
trap on_exit EXIT

fail() {
    local rc=${1:-1}
    FAILURE_REPORTED=1
    printf '\nSetup failed during: %s\nSee %s for details.\n' "$CURRENT_STEP" "$LOG_FILE" >&4
    exit "$rc"
}
trap 'rc=$?; echo "ERROR at line $LINENO while: $CURRENT_STEP (exit $rc)"; fail "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
backup_file() {
    local f=$1
    [[ -e "$f" ]] || return 0
    local dest="$BACKUP_DIR${f}"
    mkdir -p "$(dirname "$dest")"
    [[ -e "$dest" ]] || cp -a -- "$f" "$dest"
}
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; return 1; }
}

CURRENT_STEP="checking distribution and kernel support"
[[ -r /etc/os-release ]] || { echo '/etc/os-release is missing'; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    cachyos|arch) ;;
    *) echo "Unsupported distribution ID: ${ID:-unknown}"; exit 1 ;;
esac
require_cmd systemctl
require_cmd findmnt
require_cmd lsblk
require_cmd swapon
require_cmd mkswap
require_cmd blkid
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd stat
require_cmd df
require_cmd getconf
require_cmd sync
[[ -r /sys/power/state ]] || { echo '/sys/power/state is unavailable'; exit 1; }
grep -qw disk /sys/power/state || { echo 'Running kernel does not expose hibernation (disk)'; exit 1; }
grep -qw mem /sys/power/state || { echo 'Running kernel does not expose suspend (mem)'; exit 1; }

SYSTEMD_SLEEP=""
for p in /usr/lib/systemd/systemd-sleep /lib/systemd/systemd-sleep; do
    [[ -x "$p" ]] && SYSTEMD_SLEEP="$p" && break
done
[[ -n "$SYSTEMD_SLEEP" ]] || { echo 'systemd-sleep binary not found'; exit 1; }

ROOT_FSTYPE="$(findmnt -n -o FSTYPE /)"
ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
ROOT_SOURCE="${ROOT_SOURCE%%[*}"
ROOT_SOURCE="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || printf '%s' "$ROOT_SOURCE")"
SWAP_MOUNT_TARGET="$(findmnt -n -o TARGET -T "$STATE_DIR")"
SWAP_MOUNT_FSTYPE="$(findmnt -n -o FSTYPE -T "$STATE_DIR")"
SWAP_MOUNT_SOURCE="$(findmnt -n -o SOURCE -T "$STATE_DIR")"
SWAP_MOUNT_SOURCE="${SWAP_MOUNT_SOURCE%%[*}"
MEM_KIB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
[[ "$MEM_KIB" =~ ^[0-9]+$ ]] && (( MEM_KIB > 0 )) || { echo 'Could not determine RAM size'; exit 1; }
IMAGE_BYTES=$(( MEM_KIB * 1024 * IMAGE_PERCENT / 100 ))
TARGET_SWAP_KIB=$(( MEM_KIB * SWAP_PERCENT / 100 + 1024 * 1024 ))
MIN_SWAP_KIB=$(( MIN_SWAP_GIB * 1024 * 1024 ))
(( TARGET_SWAP_KIB < MIN_SWAP_KIB )) && TARGET_SWAP_KIB=$MIN_SWAP_KIB
FALLBACK_SWAP_KIB=$(( IMAGE_BYTES / 1024 + 512 * 1024 ))

log "Filesystem: $ROOT_FSTYPE ($ROOT_SOURCE)"
log "Managed swap filesystem: $SWAP_MOUNT_FSTYPE ($SWAP_MOUNT_SOURCE mounted at $SWAP_MOUNT_TARGET)"
log "RAM: ${MEM_KIB} KiB; image target: ${IMAGE_BYTES} bytes; preferred swap: ${TARGET_SWAP_KIB} KiB"

# Detect whether a dm-crypt swap mapping is volatile/random-key and therefore unusable for hibernate.
is_volatile_crypt_swap() {
    local dev=$1 mapper name line _src key opts
    mapper="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
    if [[ "$dev" == /dev/mapper/* ]]; then
        name="${dev##*/}"
    else
        name="$(lsblk -dn -o DM_NAME "$mapper" 2>/dev/null | head -n1 || true)"
    fi
    [[ -n "$name" ]] || return 1
    if [[ -r /etc/crypttab ]]; then
        line="$(awk -v n="$name" '$1==n && $0 !~ /^[[:space:]]*#/ {print; exit}' /etc/crypttab || true)"
        if [[ -n "$line" ]]; then
            read -r _name _src key opts _rest <<<"$line"
            if [[ "${key:-}" =~ ^/dev/(u|h)?random$ ]] || [[ ",${opts:-}," == *,swap,* ]]; then
                return 0
            fi
        fi
    fi
    return 1
}

# Pick the largest currently-active, persistent swap with enough *free* space.
SWAP_PATH=""
SWAP_TYPE=""
SWAP_SIZE_KIB=0
SWAP_FREE_KIB=0
while read -r path typ size used pri; do
    [[ -n "${path:-}" ]] || continue
    [[ "$path" == Filename ]] && continue
    [[ "$path" == /dev/zram* ]] && continue
    [[ "$path" == /dev/ram* ]] && continue
    [[ "$path" == /dev/loop* ]] && continue
    [[ "$size" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] || continue
    free=$(( size - used ))
    (( free > SWAP_FREE_KIB )) || continue
    if [[ "$typ" == partition ]] && is_volatile_crypt_swap "$path"; then
        log "Skipping volatile encrypted swap: $path"
        continue
    fi
    SWAP_PATH="$path"
    SWAP_TYPE="$typ"
    SWAP_SIZE_KIB=$size
    SWAP_FREE_KIB=$free
done < /proc/swaps

USE_EXISTING=0
if [[ -n "$SWAP_PATH" ]] && (( SWAP_FREE_KIB >= TARGET_SWAP_KIB )); then
    USE_EXISTING=1
elif [[ -n "$SWAP_PATH" ]] && (( SWAP_FREE_KIB >= FALLBACK_SWAP_KIB )); then
    # Accept a smaller existing area when it still comfortably exceeds the configured image target.
    USE_EXISTING=1
fi

if (( USE_EXISTING )); then
    log "Using existing persistent swap: $SWAP_PATH (${SWAP_FREE_KIB} KiB free)"
else
    SWAP_PATH=""
    SWAP_TYPE=""
fi

CURRENT_STEP="preparing persistent hibernation swap"
if [[ -z "$SWAP_PATH" ]]; then
    case "$SWAP_MOUNT_FSTYPE" in
        btrfs|ext2|ext3|ext4|xfs|f2fs)
            ;;
        *)
            echo "No suitable persistent swap exists and automatic swapfile creation is not supported on '$SWAP_MOUNT_FSTYPE' at '$SWAP_MOUNT_TARGET'."
            exit 1
            ;;
    esac

    AVAIL_KIB="$(df -Pk "$STATE_DIR" | awk 'NR==2 {print $4}')"
    NEED_KIB=$(( TARGET_SWAP_KIB + FREE_RESERVE_GIB * 1024 * 1024 ))
    (( AVAIL_KIB >= NEED_KIB )) || {
        echo "Not enough free space to create hibernation swap safely. Need ${NEED_KIB} KiB, have ${AVAIL_KIB} KiB."
        exit 1
    }

    if [[ "$SWAP_MOUNT_FSTYPE" == btrfs ]]; then
        require_cmd btrfs
        # A nested subvolume prevents root snapshots (Snapper) from trying to snapshot an active swapfile.
        if [[ ! -e "$SWAP_DIR" ]]; then
            btrfs subvolume create "$SWAP_DIR"
        elif ! btrfs subvolume show "$SWAP_DIR" >/dev/null 2>&1; then
            # Existing ordinary directory is safe only if empty; replace it with a subvolume.
            if [[ -d "$SWAP_DIR" ]] && [[ -z "$(find "$SWAP_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
                rmdir "$SWAP_DIR"
                btrfs subvolume create "$SWAP_DIR"
            else
                echo "$SWAP_DIR exists but is not a usable Btrfs subvolume."
                exit 1
            fi
        fi
    else
        mkdir -p "$SWAP_DIR"
    fi
    chmod 700 "$SWAP_DIR"

    # Reuse our own valid swapfile on reruns; otherwise recreate only our managed path.
    if [[ -f "$SWAP_FILE" ]]; then
        if grep -Fq "$SWAP_FILE" /proc/swaps; then
            swapoff "$SWAP_FILE" || {
                echo "Could not disable active managed swapfile; refusing to remove it: $SWAP_FILE"
                exit 1
            }
        fi
        rm -f "$SWAP_FILE"
    fi

    SWAP_BYTES=$(( TARGET_SWAP_KIB * 1024 ))
    if mkswap --help 2>&1 | grep -q -- '--file'; then
        # util-linux >= 2.41: creates populated swapfiles and sets Btrfs NOCOW automatically.
        mkswap --file --size "$SWAP_BYTES" --label cachyos-hibernate "$SWAP_FILE"
    elif [[ "$SWAP_MOUNT_FSTYPE" == btrfs ]]; then
        # CachyOS with Btrfs normally has btrfs-progs; this path is for older util-linux.
        btrfs filesystem mkswapfile --size "$SWAP_BYTES" --uuid clear "$SWAP_FILE"
        mkswap -L cachyos-hibernate "$SWAP_FILE"
    else
        # Portable fallback. This writes zeros once during setup but guarantees a non-sparse swapfile.
        dd if=/dev/zero of="$SWAP_FILE" bs=4M count=$(( (SWAP_BYTES + 4*1024*1024 - 1) / (4*1024*1024) )) status=none conv=fsync
        chmod 600 "$SWAP_FILE"
        mkswap -L cachyos-hibernate "$SWAP_FILE"
    fi
    chmod 600 "$SWAP_FILE"

    # swapon is also our filesystem capability check; unsupported extent layouts fail here safely.
    swapon "$SWAP_FILE"
    SWAP_PATH="$SWAP_FILE"
    SWAP_TYPE="file"

    backup_file /etc/fstab
    if ! awk -v p="$SWAP_FILE" '$1==p && $3=="swap" {found=1} END{exit !found}' /etc/fstab; then
        printf '\n# CachyOS handheld hibernation swap\n%s none swap defaults,nofail 0 0\n' "$SWAP_FILE" >> /etc/fstab
    fi
    log "Created managed swapfile: $SWAP_FILE"
fi

# Make sure an existing selected swap remains persistent after reboot.
if [[ "$SWAP_TYPE" == file && -f "$SWAP_PATH" ]]; then
    if ! awk -v p="$SWAP_PATH" '$1==p && $3=="swap" {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        printf '\n# CachyOS handheld hibernation swap\n%s none swap defaults,nofail 0 0\n' "$SWAP_PATH" >> /etc/fstab
    fi
elif [[ "$SWAP_TYPE" == partition ]]; then
    if ! awk -v p="$SWAP_PATH" '$1==p && $3=="swap" {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then
        SWAP_UUID="$(blkid -s UUID -o value "$SWAP_PATH" 2>/dev/null || true)"
        if [[ -n "$SWAP_UUID" ]] && ! grep -Eq "^[[:space:]]*UUID=${SWAP_UUID}[[:space:]].*[[:space:]]swap[[:space:]]" /etc/fstab; then
            backup_file /etc/fstab
            printf '\n# CachyOS handheld hibernation swap\nUUID=%s none swap defaults,nofail 0 0\n' "$SWAP_UUID" >> /etc/fstab
        fi
    fi
fi

CURRENT_STEP="calculating hibernation resume location"
resume_spec_for_block() {
    local dev=$1 uuid dm_name real
    # Preserve/find a stable mapper path when available; /dev/dm-X minor numbers can change.
    if [[ "$dev" == /dev/mapper/* ]]; then
        printf '%s' "$dev"
        return
    fi
    real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
    dm_name="$(lsblk -dn -o DM_NAME "$real" 2>/dev/null | head -n1 || true)"
    if [[ -n "$dm_name" && -e "/dev/mapper/$dm_name" ]]; then
        printf '/dev/mapper/%s' "$dm_name"
        return
    fi
    uuid="$(blkid -s UUID -o value "$real" 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
        printf 'UUID=%s' "$uuid"
    else
        printf '%s' "$real"
    fi
}

RESUME_SPEC=""
RESUME_OFFSET=0
RESUME_BLOCKDEV=""

if [[ "$SWAP_TYPE" == file || -f "$SWAP_PATH" ]]; then
    FILE_FSTYPE="$(findmnt -n -o FSTYPE -T "$SWAP_PATH")"
    FILE_SOURCE="$(findmnt -n -o SOURCE -T "$SWAP_PATH")"
    FILE_SOURCE="${FILE_SOURCE%%[*}"
    if [[ "$FILE_SOURCE" == /dev/mapper/* ]]; then
        RESUME_BLOCKDEV="$FILE_SOURCE"
    else
        RESUME_BLOCKDEV="$(readlink -f "$FILE_SOURCE" 2>/dev/null || printf '%s' "$FILE_SOURCE")"
    fi
    RESUME_SPEC="$(resume_spec_for_block "$RESUME_BLOCKDEV")"

    if [[ "$FILE_FSTYPE" == btrfs ]]; then
        require_cmd btrfs
        RESUME_OFFSET="$(btrfs inspect-internal map-swapfile -r "$SWAP_PATH")"
    else
        require_cmd filefrag
        PAGE_BYTES="$(getconf PAGESIZE)"
        [[ "$PAGE_BYTES" =~ ^[0-9]+$ ]] && (( PAGE_BYTES > 0 )) || { echo 'Could not determine kernel page size'; exit 1; }
        RESUME_OFFSET="$(filefrag -v -b"$PAGE_BYTES" "$SWAP_PATH" | awk '$1=="0:" {gsub(/\.\..*/, "", $4); print $4; exit}')"
    fi
    [[ "$RESUME_OFFSET" =~ ^[0-9]+$ ]] || { echo "Could not determine resume_offset for $SWAP_PATH"; exit 1; }
else
    RESUME_BLOCKDEV="$SWAP_PATH"
    RESUME_SPEC="$(resume_spec_for_block "$SWAP_PATH")"
    RESUME_OFFSET=0
fi

[[ -n "$RESUME_SPEC" ]] || { echo 'Could not determine resume device'; exit 1; }
[[ -b "$RESUME_BLOCKDEV" ]] || { echo "Resume backing device is not a block device: $RESUME_BLOCKDEV"; exit 1; }
log "Resume location: $RESUME_SPEC offset=$RESUME_OFFSET backing_device=$RESUME_BLOCKDEV"

# Do not write /sys/power/resume here. Its kernel handler immediately scans for
# a hibernation image, and some kernels reject live reconfiguration with EINVAL.
# The persistent resume= and resume_offset= parameters are installed below and
# become active after the required reboot.

CURRENT_STEP="configuring initramfs resume support"
INITRAMFS_KIND=""
if command -v mkinitcpio >/dev/null 2>&1 && [[ -f /etc/mkinitcpio.conf ]] && compgen -G '/etc/mkinitcpio.d/*.preset' >/dev/null; then
    INITRAMFS_KIND="mkinitcpio"
    backup_file /etc/mkinitcpio.conf
    HOOK_LINE="$(grep -E '^[[:space:]]*HOOKS=' /etc/mkinitcpio.conf | tail -n1 || true)"
    if grep -Eq '(^|[[:space:](])systemd([[:space:])]|$)' <<<"$HOOK_LINE"; then
        log 'mkinitcpio uses the systemd initramfs hook; resume support is built in.'
    elif ! grep -Eq '(^|[[:space:](])resume([[:space:])]|$)' <<<"$HOOK_LINE"; then
        mkinitcpio -H resume >/dev/null 2>&1 || { echo 'mkinitcpio resume hook is unavailable'; exit 1; }
        # Place resume immediately before filesystems. In standard busybox layouts this is after encrypt/lvm/md assembly.
        if grep -Eq '^[[:space:]]*HOOKS=.*[[:space:](]filesystems([[:space:])]|$)' /etc/mkinitcpio.conf; then
            sed -Ei '/^[[:space:]]*HOOKS=/ s/([[:space:](])filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
        else
            sed -Ei '/^[[:space:]]*HOOKS=/ s/[[:space:]]*\)$/ resume)/' /etc/mkinitcpio.conf
        fi
    fi
elif command -v dracut >/dev/null 2>&1; then
    INITRAMFS_KIND="dracut"
    mkdir -p /etc/dracut.conf.d
    backup_file "$DRACUT_CONF"
    cat > "$DRACUT_CONF" <<'EOF'
# CachyOS handheld hibernation
add_dracutmodules+=" resume "
EOF
elif command -v booster >/dev/null 2>&1 || [[ -f /etc/booster.yaml ]]; then
    echo 'Booster initramfs detected without a verified CachyOS hibernation integration path; refusing to guess.'
    exit 1
else
    echo 'Could not identify a supported initramfs generator (mkinitcpio or dracut).'
    exit 1
fi

CURRENT_STEP="detecting and configuring boot manager"
BOOT_KIND=""
BOOT_STATUS="$(bootctl status --no-pager 2>/dev/null || true)"
if grep -qi 'limine' <<<"$BOOT_STATUS" && [[ -f /etc/default/limine ]]; then
    BOOT_KIND="limine"
elif grep -qi 'systemd-boot' <<<"$BOOT_STATUS" && [[ -f /etc/sdboot-manage.conf ]]; then
    BOOT_KIND="systemd-boot"
elif grep -qi 'refind' <<<"$BOOT_STATUS" && [[ -f /boot/refind_linux.conf ]]; then
    BOOT_KIND="refind"
elif grep -qi 'grub' <<<"$BOOT_STATUS" && [[ -f /etc/default/grub ]]; then
    BOOT_KIND="grub"
elif [[ -f /etc/default/limine ]] && command -v limine-mkinitcpio >/dev/null 2>&1; then
    BOOT_KIND="limine"
elif [[ -f /etc/sdboot-manage.conf ]] && command -v sdboot-manage >/dev/null 2>&1; then
    BOOT_KIND="systemd-boot"
elif [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
    BOOT_KIND="grub"
elif [[ -f /boot/refind_linux.conf ]]; then
    BOOT_KIND="refind"
else
    echo 'Could not identify a supported CachyOS boot manager (Limine, systemd-boot, GRUB, rEFInd).'
    exit 1
fi
log "Boot manager: $BOOT_KIND; initramfs: $INITRAMFS_KIND"

# Python is used only for conservative quoted config edits. CachyOS normally ships it.
PYTHON=""
command -v python3 >/dev/null 2>&1 && PYTHON="$(command -v python3)"
[[ -z "$PYTHON" ]] && command -v python >/dev/null 2>&1 && PYTHON="$(command -v python)"
[[ -n "$PYTHON" ]] || { echo 'Python is required to edit boot-manager kernel parameters safely.'; exit 1; }

case "$BOOT_KIND" in
    limine) BOOT_CONF=/etc/default/limine ;;
    systemd-boot) BOOT_CONF=/etc/sdboot-manage.conf ;;
    grub) BOOT_CONF=/etc/default/grub ;;
    refind) BOOT_CONF=/boot/refind_linux.conf ;;
esac
backup_file "$BOOT_CONF"

"$PYTHON" - "$BOOT_KIND" "$BOOT_CONF" "$RESUME_SPEC" "$RESUME_OFFSET" <<'PY'
import os, re, stat, sys, tempfile
kind, path, resume, offset = sys.argv[1:]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

def grub_menu_is_hidden(config):
    """Return whether the existing GRUB defaults intentionally hide the menu."""
    values = {}
    pat = re.compile(r'^\s*(GRUB_TIMEOUT(?:_STYLE)?)\s*=\s*(["\']?)(.*?)\2\s*(?:#.*)?$')
    for line in config:
        m = pat.match(line.rstrip('\n'))
        if m and not line.lstrip().startswith('#'):
            values[m.group(1)] = m.group(3).strip()
    return values.get('GRUB_TIMEOUT_STYLE') == 'hidden' or values.get('GRUB_TIMEOUT') == '0'

grub_was_hidden = kind == 'grub' and grub_menu_is_hidden(lines)

def clean(v):
    # The values CachyOS writes here are ordinary kernel command lines.
    parts = [p for p in v.split() if not (p.startswith('resume=') or p.startswith('resume_offset=') or p == 'hibernate=nocompress')]
    parts += [f'resume={resume}', f'resume_offset={offset}']
    return ' '.join(parts)

out = []
changed = 0
if kind == 'limine':
    pat = re.compile(r'^(\s*KERNEL_CMDLINE\[[^\]]+\]\s*\+?=\s*)(["\'])(.*)\2(\s*(?:#.*)?)$')
    for line in lines:
        m = pat.match(line.rstrip('\n'))
        if m and not line.lstrip().startswith('#'):
            out.append(f'{m.group(1)}{m.group(2)}{clean(m.group(3))}{m.group(2)}{m.group(4)}\n')
            changed += 1
        else:
            out.append(line)
    if not changed:
        out.append(f'\nKERNEL_CMDLINE[default]+="resume={resume} resume_offset={offset}"\n')
        changed = 1
elif kind in ('systemd-boot', 'grub'):
    var = 'LINUX_OPTIONS' if kind == 'systemd-boot' else 'GRUB_CMDLINE_LINUX_DEFAULT'
    pat = re.compile(rf'^(\s*{re.escape(var)}\s*=\s*)(["\'])(.*)\2(\s*(?:#.*)?)$')
    for line in lines:
        m = pat.match(line.rstrip('\n'))
        if m and not line.lstrip().startswith('#'):
            out.append(f'{m.group(1)}{m.group(2)}{clean(m.group(3))}{m.group(2)}{m.group(4)}\n')
            changed += 1
        else:
            out.append(line)
    if not changed:
        out.append(f'\n{var}="resume={resume} resume_offset={offset}"\n')
        changed = 1
elif kind == 'refind':
    # refind_linux.conf lines conventionally contain two quoted fields: title and kernel options.
    pat = re.compile(r'^(\s*"[^"]*"\s+")(.*)("\s*)$')
    for line in lines:
        raw = line.rstrip('\n')
        if raw.lstrip().startswith('#'):
            out.append(line); continue
        m = pat.match(raw)
        if m:
            out.append(f'{m.group(1)}{clean(m.group(2))}{m.group(3)}\n')
            changed += 1
        else:
            out.append(line)
else:
    raise SystemExit('unsupported boot kind')
if not changed:
    raise SystemExit('No boot configuration entries could be updated')
if grub_was_hidden and not grub_menu_is_hidden(out):
    raise SystemExit('Refusing to change an existing hidden GRUB menu')

directory = os.path.dirname(path) or '.'
original = os.stat(path)
fd, temporary = tempfile.mkstemp(prefix=f'.{os.path.basename(path)}.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.writelines(out)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temporary, stat.S_IMODE(original.st_mode))
    if hasattr(os, 'chown'):
        os.chown(temporary, original.st_uid, original.st_gid)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY

grep -Fq "resume=$RESUME_SPEC" "$BOOT_CONF" || { echo "Boot configuration is missing resume=$RESUME_SPEC"; exit 1; }
grep -Fq "resume_offset=$RESUME_OFFSET" "$BOOT_CONF" || { echo "Boot configuration is missing resume_offset=$RESUME_OFFSET"; exit 1; }

CURRENT_STEP="configuring suspend-then-hibernate behavior"
mkdir -p /etc/systemd/sleep.conf.d "$SUSPEND_OVERRIDE_DIR"
backup_file "$SLEEP_CONF"
backup_file "$SUSPEND_OVERRIDE"
backup_file "$IMAGE_SERVICE"

cat > "$SLEEP_CONF" <<EOF
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=$HIBERNATE_DELAY
HibernateOnACPower=yes
EOF

# Turn ordinary Suspend() requests (including Steam/Game Mode callers) into suspend-then-hibernate.
cat > "$SUSPEND_OVERRIDE" <<EOF
[Service]
ExecStart=
ExecStart=$SYSTEMD_SLEEP suspend-then-hibernate
EOF

# Keep hibernation images smaller than the kernel's ~40% default target to reduce SSD writes.
cat > "$IMAGE_SERVICE" <<EOF
[Unit]
Description=Set CachyOS hibernation image size target
ConditionPathExists=/sys/power/image_size
Before=sleep.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $IMAGE_BYTES > /sys/power/image_size'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cachyos-hibernate-image-size.service
printf '%s' "$IMAGE_BYTES" > /sys/power/image_size

CURRENT_STEP="rebuilding initramfs and boot entries"
case "$INITRAMFS_KIND" in
    mkinitcpio)
        if [[ "$BOOT_KIND" == limine ]] && command -v limine-mkinitcpio >/dev/null 2>&1; then
            limine-mkinitcpio
        else
            mkinitcpio -P
        fi
        ;;
    dracut)
        dracut --regenerate-all --force
        ;;
esac

case "$BOOT_KIND" in
    limine)
        # limine-mkinitcpio above updates both initramfs and entries. If dracut was used, use available entry tool/wrapper.
        if [[ "$INITRAMFS_KIND" != mkinitcpio ]]; then
            if command -v limine-mkinitcpio >/dev/null 2>&1; then
                limine-mkinitcpio
            elif command -v limine-entry-tool >/dev/null 2>&1; then
                limine-entry-tool update || limine-entry-tool
            else
                echo 'Limine config was updated but no CachyOS entry regeneration tool is available.'
                exit 1
            fi
        fi
        ;;
    systemd-boot)
        require_cmd sdboot-manage
        sdboot-manage gen
        ;;
    grub)
        require_cmd grub-mkconfig
        mkdir -p /boot/grub
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    refind)
        # CachyOS refind_linux.conf changes take effect directly.
        ;;
esac

CURRENT_STEP="final verification"
# Verify persistent swap, service syntax, and that our generated config points to the intended mode.
grep -Fq 'HibernateDelaySec=' "$SLEEP_CONF"
grep -Fq 'suspend-then-hibernate' "$SUSPEND_OVERRIDE"
systemd-analyze verify "$IMAGE_SERVICE" >/dev/null

if [[ "$SWAP_TYPE" == file || -f "$SWAP_PATH" ]]; then
    grep -Fq "$SWAP_PATH" /proc/swaps || { echo 'Selected swapfile is not active'; exit 1; }
else
    grep -Fq "$SWAP_PATH" /proc/swaps || { echo 'Selected swap device is not active'; exit 1; }
fi

# Save state for diagnostics and future reruns.
cat > "$STATE_DIR/state.env" <<EOF
HIBERNATE_DELAY=$HIBERNATE_DELAY
IMAGE_PERCENT=$IMAGE_PERCENT
IMAGE_BYTES=$IMAGE_BYTES
SWAP_PATH=$SWAP_PATH
SWAP_TYPE=$SWAP_TYPE
RESUME_SPEC=$RESUME_SPEC
RESUME_OFFSET=$RESUME_OFFSET
ROOT_FSTYPE=$ROOT_FSTYPE
BOOT_KIND=$BOOT_KIND
INITRAMFS_KIND=$INITRAMFS_KIND
LAST_BACKUP=$BACKUP_DIR
EOF
chmod 600 "$STATE_DIR/state.env"
sync

log 'Setup completed successfully.'
SETUP_SUCCEEDED=1
trap - ERR
printf 'Successful, please restart system. Press any key to close.\n' >&3
if [[ -r /dev/tty ]]; then
    IFS= read -r -n 1 -s < /dev/tty || true
fi
exit 0
