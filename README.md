# Session Launcher

Session Launcher is a web page that runs on your own computer and lets you start and control Claude Code sessions from any phone or browser. It stays private to your own Tailscale network, so only your devices can reach it. One command sets the whole thing up.

## Setup

On a Mac, open Terminal and run:

```
bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh)
```

The setup asks you a few questions and handles the rest.

> Use `bash <(curl …)`, not `curl … | bash`. The setup needs to ask you things
> (your Mac password for Homebrew, the Claude sign-in), and piping into `bash`
> hands your keyboard to the pipe instead of the installer, so those prompts
> can't reach you.

## What it sets up

- Claude Code, signed in — add as many accounts as you have, and switch between them from the portal
- Tailscale, the private network that links your phone to your computer
- The portal itself, which starts on boot and restarts itself if it crashes
- Your projects folder, so sessions open where your work lives

## Windows

Windows needs a one-time WSL2 pre-step before the command above. The [setup guide](GUIDE.md) walks you through it.

## Full guide

See [GUIDE.md](GUIDE.md) for the step-by-step walkthrough, phone setup, and troubleshooting.
