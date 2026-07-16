# Session Launcher

Session Launcher is a web page that runs on your own computer and lets you start and control Claude Code sessions from any phone or browser. It stays private to your own Tailscale network, so only your devices can reach it. One command sets the whole thing up.

## Setup

**On a Mac,** open Terminal and run:

```
bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh)
```

**On Windows,** open PowerShell and run:

```
irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
```

The setup asks you a few questions and handles the rest.

## What it sets up

- Claude Code, signed in — add as many accounts as you have, and switch between them from the portal
- Tailscale, the private network that links your phone to your computer
- The portal itself, which starts on boot and restarts itself if it crashes
- Your projects folder, so sessions open where your work lives

## Windows

Windows needs WSL2 (a Linux layer) to run the portal. The command above handles it — if WSL isn't installed yet it tells you to run `wsl --install`, reboot, and paste the command again. The [setup guide](GUIDE.md) has the details.

## Full guide

See [GUIDE.md](GUIDE.md) for the step-by-step walkthrough, phone setup, and troubleshooting.
