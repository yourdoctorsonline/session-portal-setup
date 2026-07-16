# Session Launcher

Session Launcher is a web page that runs on your own computer and lets you start and control Claude Code sessions from any phone or browser. It stays private to your own Tailscale network, so only your devices can reach it. One command sets the whole thing up.

## Setup

Paste **all four lines** into your **Terminal** (Mac) or **PowerShell** (Windows) and press Enter. The same command works on both — it detects your system and runs the right installer:

```
echo " \`" > /dev/null # " <#
curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh | bash
exit #> > $null
irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
```

Copy all four lines exactly (including the odd-looking first line — it's what makes one command work on both). The setup asks you a few questions and handles the rest. On a Mac, the terminal window closes itself when it finishes (your link + QR print first).

Prefer a plain single-platform command? **Mac/Linux:** `bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh)` — **Windows PowerShell:** `irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex`

## What it sets up

- Claude Code, signed in — add as many accounts as you have, and switch between them from the portal
- Tailscale, the private network that links your phone to your computer
- The portal itself, which starts on boot and restarts itself if it crashes
- Your projects folder, so sessions open where your work lives

## Windows

Windows needs WSL2 (a Linux layer) to run the portal. The command above handles it — if WSL isn't installed yet it tells you to run `wsl --install`, reboot, and paste the command again. The [setup guide](GUIDE.md) has the details.

## Full guide

See [GUIDE.md](GUIDE.md) for the step-by-step walkthrough, phone setup, and troubleshooting.
