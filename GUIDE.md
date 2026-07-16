# Session Launcher — Setup Guide

Session Launcher is a small web page that runs on your own computer. Once it's set up, you can open it from any phone or browser and run Claude Code sessions from there. It stays private to your own Tailscale network, so no one else can reach it.

This guide walks you through the whole thing. You don't need to know how to code.

## What you need

- **A computer that stays on.** A Mac desktop that's always powered on is ideal. A Mac laptop works too, but only while it's open and awake — when it sleeps, the portal goes dark. A Windows PC works if you set up WSL2 first (see the Windows step below).
- **A Claude account with Claude Code.** You need a Pro or Max plan. You can add more than one account later if you have them.
- **Your phone.** This is where you'll open the portal once it's running.

## If you're on Windows: do this first

Windows can't run Session Launcher on its own. It needs WSL2, which is a Linux environment that lives inside Windows. Setting it up takes a few minutes.

1. Click the Start menu, type `PowerShell`, right-click it, and choose **Run as administrator**.
2. Type this and press Enter:
   ```
   wsl --install
   ```
3. Restart your computer when it asks you to.
4. After the restart, open the **Ubuntu** app from the Start menu. It finishes setting itself up and asks you to pick a username and password. Write these down.
5. You're now in a Linux window. Run the one command below from there.

Mac users can skip all of this.

## The one command

Open your Terminal (on a Mac) or the Ubuntu window (on Windows), paste this in, and press Enter:

```
bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh)
```

That's it. From here the setup asks you questions and does the work. Here's what each step does so nothing catches you off guard.

> **Why `bash <(curl …)` and not `curl … | bash`?** The setup has to ask you a
> couple of things — your Mac password (if it needs to install Homebrew) and
> your Claude sign-in. The form above keeps your keyboard wired straight to the
> installer, so those prompts work smoothly instead of looking like a freeze.

## What the setup will do

**1. Check your machine.** It confirms your computer can run the portal. If you're on a laptop, it warns you that the portal only works while the laptop is awake.

**2. Install the basics for you.** It installs the few background tools the portal needs. You don't have to do anything here — it handles it and checks each one worked.

**3. Sign in to Claude.** It installs Claude Code, then opens a **separate window** with three simple steps for signing in — accept the colour prompt with Return, sign in through the browser, and type `/exit` when you're done. The setup window waits and continues on its own the moment you're signed in, so you never have to remember what to do next.

**4. Add another Claude account?** It asks if you want to add a second Claude login. This is optional. If you do, it signs that one in too, and asks again until you say no. Every account you add shows up in the portal automatically, so you can switch between them from your phone.

**Engineering defaults.** Right after accounts, it configures every signed-in Claude account so your launched sessions run as **engineering orchestrators**: Opus 4.8 at ultracode effort, with the `eng-harness` conductor skill (and its `superpowers` + `zero-trust-verification` dependencies) installed, plus an instruction to delegate routine subagent work to Sonnet. This is the team standard — high-effort by default so you don't get low-quality answers from a weaker model.

**Private backup of your work.** After you pick your projects folder, it checks whether your `agentic-os` is backed up to a repo you personally own. If not, it signs you into GitHub and creates a **private** repo `<you>/agentic-os` under your own account, then keeps it current with an hourly backup. This backup is **private to you** — the yourdoctorsonline org and your teammates can't see it. It only ever *pushes* a snapshot (including uncommitted work) one-way, so it never merges, never conflicts, and never touches your working branches.

**5. Sign in to Tailscale.** Tailscale is the private network that connects your phone to your computer. It installs Tailscale and opens the sign-in. **Sign in with the same account on your computer and on your phone.** This is the single most important step. If your computer and phone are on two different Tailscale accounts, they can't see each other and nothing works.

**6. Install the portal.** It sets up the portal and makes it start on its own whenever your computer boots. If it ever crashes, it restarts itself. You don't have to babysit it.

**7. Choose your projects folder.** It asks where your projects live and suggests a folder for you. This is where your Claude sessions open by default. Pick the folder you keep your work in, or accept the suggestion.

**8. Final checklist and QR code.** It runs through a checklist so you can see everything is working, then prints your portal link and a QR code.

## On your phone

1. Open the link the setup printed. The quickest way is to scan the QR code with your phone's camera.
2. Add it to your home screen so it opens like an app:
   - **iPhone (Safari):** tap the **Share** button, then **Add to Home Screen.**
   - **Android (Chrome):** tap the **⋮** menu (top-right), then **Add to Home screen** (or **Install app**).

Now the portal has its own icon on your phone, like an app.

> **On Windows/WSL only:** the portal lives inside WSL, which shuts down when you
> close every Ubuntu window. To keep it reachable, leave one Ubuntu window open
> (or set WSL to start on boot via Task Scheduler), and keep the PC awake — same
> as a Mac laptop needs to stay awake and plugged in.

## If something isn't working

- **The portal won't load.** Check that your computer is on and awake. If it went to sleep, the portal is off. Wake it and try again.
- **Your phone can't find the portal.** This is the most common problem, and it's almost always the same cause: your phone and your computer are signed in to Tailscale with two different accounts. Open the Tailscale app on both and make sure the account matches exactly.
- **Something got half set up.** Running the one command again is always safe. It skips anything that's already done and picks up where it left off.

## One safety note

Your portal is private to your own Tailscale network. Only your own devices can reach it. **Never run `tailscale funnel`.** That command would put your terminal on the public internet, where anyone could find it. The portal is safe because it stays on your private network — keep it that way.
