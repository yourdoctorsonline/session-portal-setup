# Session Launcher — Setup Guide

Session Launcher is a small web page that runs on your own computer. Once it's set up, you can open it from any phone or browser and run Claude Code sessions from there. It stays private to your own Tailscale network, so no one else can reach it.

This guide walks you through the whole thing. You don't need to know how to code.

## What you need

- **A computer that stays on.** A Mac desktop that's always powered on is ideal. A Mac laptop works too, but only while it's open and awake — when it sleeps, the portal goes dark. A Windows PC works if you set up WSL2 first (see the Windows step below).
- **A Claude account with Claude Code.** You need a Pro or Max plan. You can add more than one account later if you have them.
- **Your phone.** This is where you'll open the portal once it's running.

## The one command — Mac or Windows

Paste **all four lines** into your **Terminal** (on a Mac) or **PowerShell** (on Windows), and press Enter. The same command works on both — it detects your system and runs the right installer.

```
echo " \`" > /dev/null # " <#
curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh | bash
exit #> > $null
irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
```

**Copy all four lines exactly**, including the odd-looking first line — that line is what lets one command work on both systems. From here the setup asks you a few questions and does the rest.

- **On a Mac:** it runs the installer, then closes that terminal window when it's finished. Your link and QR code are printed just before it closes — that's normal.
- **On Windows:** it runs in PowerShell. Windows needs WSL2 (a Linux layer) to run the portal — if you don't have it yet, the command tells you to run `wsl --install`, reboot, finish the quick Ubuntu setup (pick a username + password), then paste the same command again.

### If the one command doesn't work

Run the plain command for your system instead:

- **Mac / Linux / inside the Ubuntu (WSL) window:**
  ```
  bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh)
  ```
- **Windows PowerShell:**
  ```
  irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
  ```

> If you pasted a command and saw `The '<' operator is reserved for future use`, you used the **Mac** command in **PowerShell** — use the Windows one above (or the combined four-line command).

## What the setup will do

**1. Check your machine.** It confirms your computer can run the portal. If you're on a laptop, it warns you that the portal only works while the laptop is awake.

**2. Install the basics for you.** It installs the few background tools the portal needs. You don't have to do anything here — it handles it and checks each one worked.

**3. Sign in to Claude.** It installs Claude Code, then opens a **separate Claude window** for signing in — while the setup window shows you the three simple steps to follow there: press Return at the colour prompt, sign in through the browser, and type `/exit` when you're done. The setup window waits and continues on its own the moment you're signed in, so you never have to remember what to do next.

**4. Add another Claude account?** It asks if you want to add a second Claude login. This is optional. If you do, it signs that one in too, and asks again until you say no. Every account you add shows up in the portal automatically, so you can switch between them from your phone.

**Engineering defaults.** Right after accounts, it configures every signed-in Claude account so your launched sessions run as **engineering orchestrators**: Opus 4.8 at ultracode effort, plus an instruction to delegate routine subagent work to Sonnet. This is the team standard — high-effort by default so you don't get low-quality answers from a weaker model. It also installs a curated **skill toolkit** that every session uses *automatically* (you never have to invoke them):

- **eng-harness** — the quality conductor for any build/fix/refactor (with its `superpowers` + `zero-trust-verification` deps).
- **caveman** — trims filler from replies for ~65% fewer output tokens; code, commands and errors stay exact.
- **ponytail** — nudges the agent to write the *least* code that solves the task.
- **taste** (`design-taste-frontend`) — anti-slop frontend design for landing pages and redesigns.
- **human-copywriting** — reader-facing copy with zero AI tells.

`caveman` and `ponytail` are always on; the rest kick in when the work matches them.

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
