# Deck-Hibernate

![Deck-Hibernate banner](assets/deck-hibernate-banner.png)

Suspend-then-hibernate installer for CachyOS/Arch gaming handhelds and Bazzite. It makes a device sleep normally, then hibernate after a while (15 minutes by default) to reduce battery drain and heat.

## Install

Run this in Konsole/Terminal on the handheld:

```bash
curl -fsSL https://raw.githubusercontent.com/JosEffigy/deck-hibernate/main/install.sh | bash
```

Enter your password when asked, choose how many minutes to wait, then reboot when it finishes.

## What it changes

- Creates or uses swap space to save your open apps and games.
- Makes the normal **Suspend** action sleep first, then hibernate after your chosen delay.
- Sets up boot/resume settings so the handheld can wake back up where you left off.
- Optional: hibernates automatically at 15% battery after a short warning period.
- Makes backups and writes a setup log before changing things.

## Before you run it

- Supports CachyOS/Arch and Bazzite. Bazzite is detected automatically: versions before 44 use the pre-44 path; 44 and newer use the OpenGamepadUI/InputPlumber-era path.
- On Bazzite, it creates a persistent Btrfs swapfile and disables zram so normal systemd hibernation can resume after a reboot. It does not use HHD, so pre-44 installs do not depend on HHD's dynamic hibernation.
- You need internet and `curl` or `wget` for the online install.
- It **does not** install missing packages. If a needed system tool is missing, it stops and tells you.
- It changes sleep, swap, and boot settings. Reboot when it tells you to.
- The optional low-battery setting checks the real battery level; it does not listen for Steam's exact on-screen warning. It waits for battery-change events from UPower when available, otherwise from the Linux power system. At 15% while discharging, it waits 30 seconds and checks again before hibernating.
- Low-battery hibernation is an emergency safeguard. When it triggers, it ignores app sleep blockers so it can protect your session. Only enable it if you are comfortable with it hibernating during a game or download.

After rebooting, just use your normal Suspend button. It sleeps first, then hibernates after the delay you chose.
