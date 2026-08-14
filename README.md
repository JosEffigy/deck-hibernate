# Deck-Hibernate

Set up **suspend-then-hibernate** for CachyOS and Arch Linux handhelds. Ordinary suspend requests—including ones from Steam/Game Mode—first suspend, then hibernate after a configurable delay (15 minutes by default).

The setup is designed to be re-runnable. It makes a timestamped backup before changing a system configuration file and records its state and log under `/var/lib/cachyos-handheld-hibernate` and `/var/log/cachyos-handheld-hibernate-setup.log`.

## Install online

Run the bootstrap installer as your normal user:

```bash
curl -fsSL https://raw.githubusercontent.com/JosEffigy/deck-hibernate/master/install.sh | bash
```

It downloads `deck-hibernate.sh` over HTTPS and starts it. The setup script prompts for your sudo password, asks how many minutes to wait before hibernating, and asks you to reboot when it finishes.

If you prefer to inspect the download before running it:

```bash
curl -fL https://raw.githubusercontent.com/JosEffigy/deck-hibernate/master/deck-hibernate.sh -o deck-hibernate.sh
less deck-hibernate.sh
bash deck-hibernate.sh
```

## What it configures

- Checks that the running system is CachyOS or Arch Linux and that the kernel supports both suspend and hibernation.
- Chooses a suitable persistent swap area when available, skipping zram and volatile encrypted swap. If needed, it creates a managed swapfile under `/var/lib/cachyos-handheld-hibernate/swap/`.
- Adds persistent swap configuration to `/etc/fstab` when necessary.
- Adds the kernel `resume=` and `resume_offset=` parameters required to restore a hibernation image.
- Supports `mkinitcpio` and `dracut`; it refuses to guess when Booster is detected.
- Supports Limine, systemd-boot, GRUB, and rEFInd boot-manager configurations.
- Configures systemd so normal suspend requests use `suspend-then-hibernate`, including the delay you choose.
- Enables a small systemd service that limits the hibernation-image target to 30% of RAM to reduce SSD writes.
- Rebuilds the initramfs and boot entries, then verifies the generated configuration.

## Requirements and cautions

- Use this only on CachyOS or Arch Linux systems with a kernel that exposes both `mem` and `disk` sleep states.
- The script needs `sudo`, `systemd`, and the usual storage tools. It also needs either `mkinitcpio` or `dracut`, plus a supported boot manager.
- It changes boot, initramfs, swap, and systemd configuration, then requires a restart. Review the script before use if you have a custom disk-encryption, swap, or boot setup.
- When creating swap, it supports Btrfs, ext2/3/4, XFS, and F2FS root filesystems. It reserves 2 GiB of free space before creating a swapfile.
- The setup log is stored at `/var/log/cachyos-handheld-hibernate-setup.log`; backups are stored under `/var/lib/cachyos-handheld-hibernate/backups/`.

## Local installation

```bash
git clone https://github.com/JosEffigy/deck-hibernate.git
cd deck-hibernate
bash deck-hibernate.sh
```

After rebooting, use the device's normal suspend action. It should suspend first and hibernate after the selected delay.

## Upgrading from 1.0

Release 1.0 could stop at `printf: write error: Invalid argument` while calculating the resume location. Version 1.0.1 removes that unnecessary live-kernel write and relies on the persistent resume parameters that take effect after reboot. Rerun the online installer above to apply the fix.

## Files

- `deck-hibernate.sh` — the main configuration script.
- `install.sh` — a small online bootstrap installer.
- `deck-hibernate-release-1.0.1.zip` — the current release archive.
- `deck-hibernate-release-1.0.zip` — the original release archive.
