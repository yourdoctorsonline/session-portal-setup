# Session Launcher - Windows bootstrap.
#
# PowerShell can't run the Mac/Linux installer directly. Pasting the bash
# one-liner into PowerShell gives:
#     The '<' operator is reserved for future use.
# because `bash <(curl ...)` is bash syntax, not PowerShell. This script runs the
# installer for you INSIDE WSL (Ubuntu) - installing WSL first if it's missing.
#
# Run it in PowerShell with:
#   irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex

$ErrorActionPreference = 'Stop'
$SetupUrl = 'https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh'

function Say([string]$m, [string]$c = 'White') { Write-Host $m -ForegroundColor $c }

Say ''
Say 'Session Launcher - Windows setup' 'Cyan'
Say "PowerShell can't run the installer itself, so this runs it inside WSL (Ubuntu)."
Say ''

# 1) Is WSL available at all?
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Say "WSL (the Linux layer Windows needs) isn't installed yet." 'Yellow'
  Say 'Do this once, then run this same command again:'
  Say '  1. Right-click Start, open "Terminal (Admin)" (or "Windows PowerShell (Admin)")'
  Say '  2. Run:  wsl --install' 'Green'
  Say '  3. Reboot when asked, then finish the Ubuntu setup (pick a username + password).'
  return
}

# 2) Is WSL REALLY installed with a usable distro? The bare `wsl.exe` stub ships
#    on every Windows, so `Get-Command wsl.exe` passing does NOT mean WSL is
#    installed. We must run a wsl command and check BOTH its exit code AND that it
#    named a real distro. On a machine without WSL, `wsl -l -q` returns non-zero
#    and/or blank+UTF-16-noise output — if we don't catch that, the launch below
#    triggers Windows' own timed "Press any key to install… Operation aborted"
#    prompt (which is exactly what a teammate hit).
Say 'Checking WSL... (the first check can take up to a minute while WSL starts)'
$env:WSL_UTF8 = '1'   # ask wsl for clean UTF-8 output
# Read $LASTEXITCODE ourselves — don't let a non-zero native exit throw under
# $ErrorActionPreference=Stop (PowerShell 7.4+ would abort the whole script).
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$wslRaw = wsl.exe -l -q 2>&1
$wslExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
# Strip null bytes / non-printable junk so a not-installed stub's blank/UTF-16
# noise can't masquerade as a distro name (that's the "Using your WSL distro: "
# with an empty name bug).
$distros = @( $wslRaw | ForEach-Object { ("$_" -replace '[^\x20-\x7E]', '').Trim() } | Where-Object { $_ } )
# Also catch the "not installed" MESSAGE itself (some Windows builds print it with
# a zero exit code, which would otherwise look like a distro named after the error).
$wslText = "$wslRaw"
if ($wslExit -ne 0 -or $distros.Count -eq 0 -or $wslText -match 'not installed|no installed distrib|has no installed') {
  Say ''
  Say "WSL isn't set up on this PC yet — that's the Linux layer the portal needs." 'Yellow'
  Say 'Set it up once, then run this same command again:'
  Say '  1. Right-click Start and open  Terminal (Admin)  (or PowerShell as Admin)'
  Say '  2. Run:  wsl --install' 'Green'
  Say '  3. Reboot when it asks. Open Ubuntu from Start, pick a username + password.'
  Say '  4. Paste the Windows command here again.'
  return
}

# 3) Run the bash installer inside WSL. The whole bash command is ONE quoted
#    string, so PowerShell never sees the `<` - bash handles it inside WSL, where
#    `bash <(curl ...)` keeps your keyboard wired to the prompts.
Say ("Using your WSL distro: {0}" -f $distros[0]) 'Cyan'
Say 'Launching the installer inside WSL...' 'Cyan'
Say ''
# curl ships with current Ubuntu; if yours lacks it, run once in Ubuntu:
#   sudo apt-get update && sudo apt-get install -y curl
wsl.exe -e bash -lc "bash <(curl -fsSL $SetupUrl)"
