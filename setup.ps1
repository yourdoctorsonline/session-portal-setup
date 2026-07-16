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

# 2) Is a Linux distribution actually installed? Fresh WSL has none.
$env:WSL_UTF8 = '1'   # make `wsl -l -q` emit clean UTF-8 (not UTF-16 with null bytes)
$distros = @()
# @(...) forces an array, so a single distro doesn't collapse to a string (where
# $distros[0] would return its first CHARACTER instead of the distro name).
try { $distros = @( (wsl.exe -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ } ) } catch {}
if ($distros.Count -eq 0) {
  Say "WSL is installed, but there's no Linux distribution yet." 'Yellow'
  Say 'Do this once, then run this same command again:'
  Say '  1. Run:  wsl --install -d Ubuntu' 'Green'
  Say '  2. Finish the Ubuntu setup (pick a username + password).'
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
