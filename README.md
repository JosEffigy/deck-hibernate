# Deck-Hibernate

Suspend-then-hibernate installer for CachyOS and Arch Linux gaming handhelds. It makes a device sleep normally, then hibernate after a while (15 minutes by default) to reduce battery drain and heat. It is suitable for Steam Deck hardware running CachyOS or another supported Arch-based setup.

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
- Makes backups and writes a setup log before changing things.

## Before you run it

- For CachyOS or Arch Linux only.
- You need internet and `curl` or `wget` for the online install.
- It **does not** install missing packages. If a needed system tool is missing, it stops and tells you.
- It changes sleep, swap, and boot settings. Reboot when it tells you to.

After rebooting, just use your normal Suspend button. It sleeps first, then hibernates after the delay you chose.
