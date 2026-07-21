# Session Launcher - Windows bootstrap.
# -----------------------------------------------------------------------------
# PowerShell can't run the Mac/Linux installer directly. Pasting the bash
# one-liner into PowerShell gives "The '<' operator is reserved for future use."
# because it's bash syntax, not PowerShell. This script runs the installer for
# you INSIDE WSL (Ubuntu) - guiding you through installing WSL first if missing.
#
# Run it in PowerShell with:
#   irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
#
# Optional (skip the in-installer menu):
#   $env:SL_PRESET='portal'; irm .../setup.ps1 | iex        # full | harness | portal
#
# PowerShell 5.1+ (Windows built-in) compatible. No external modules.
# -----------------------------------------------------------------------------
[CmdletBinding()]
param(
  # full | harness | portal — passed to the Linux installer as SETUP_PRESET.
  [ValidateSet('full','harness','portal')]
  [string]$Preset = $env:SL_PRESET,
  # Print what would run and change nothing (testable off-Windows).
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$SetupUrl = 'https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh'

function Say([string]$m, [string]$c = 'White') { Write-Host $m -ForegroundColor $c }

function Show-WslSetupHelp {
  Say ''
  Say "WSL isn't set up on this PC yet - that's the Linux layer the portal needs." 'Yellow'
  Say 'Set it up once, then run this same command again:'
  Say '  1. Right-click Start and open  Terminal (Admin)  (or PowerShell as Admin)'
  Say '  2. Run:  wsl --install' 'Green'
  Say '  3. Reboot when it asks. Open Ubuntu from Start, pick a username + password.'
  Say '  4. Paste the Windows command here again.'
}

# Build the SETUP_* environment prefix passed into the Linux installer. Preset comes
# from -Preset/$env:SL_PRESET; any SETUP_* vars already in the environment ride along
# so Windows users get the same knobs as Mac (SETUP_RUSTDESK, SETUP_WORKSPACE_REPO...).
function Get-SetupEnvPrefix {
  $parts = @()
  if ($Preset) { $parts += "SETUP_PRESET=$Preset" }
  Get-ChildItem Env: | Where-Object { $_.Name -like 'SETUP_*' } | ForEach-Object {
    # single-quote the value for bash; escape embedded single quotes safely
    $v = $_.Value -replace "'", "'\''"
    $parts += ("{0}='{1}'" -f $_.Name, $v)
  }
  if ($parts.Count -gt 0) { ($parts -join ' ') + ' ' } else { '' }
}

# The one bash command run inside WSL. Uses process substitution `bash <(curl ...)`
# rather than `bash -c "$(...)"` ON PURPOSE: it contains NO double-quotes, so Windows
# PowerShell 5.1's native-argument passing (which mangles embedded double-quotes)
# hands it to wsl.exe as one clean argument. Bash evaluates it inside WSL, keeping the
# terminal wired to the installer's prompts (sign-in, Tailscale). Env assignments only
# use single quotes, which pass through PS's arg wrapping cleanly.
function Get-InnerBashCommand {
  $envPrefix = Get-SetupEnvPrefix
  "$envPrefix" + 'bash <(curl -fsSL ' + $SetupUrl + ')'
}

Say ''
Say 'Session Launcher - Windows setup' 'Cyan'
Say "PowerShell can't run the installer itself, so this runs it inside WSL (Ubuntu)."
if ($Preset) { Say ("Preset: {0}" -f $Preset) 'Cyan' }
Say ''

# 1) Is the wsl.exe command present at all? (The stub ships on every Windows, so this
#    passing is necessary-but-not-sufficient - step 2 does the real check.)
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Show-WslSetupHelp
  return
}

# 2) Is WSL REALLY installed with a usable distro? Run `wsl -l -q` and check BOTH the
#    exit code AND that it named a real distro. Read $LASTEXITCODE ourselves under a
#    relaxed EAP so a non-zero native exit doesn't throw/abort under PS 7.4+. Strip
#    non-printable / UTF-16 noise so a not-installed stub's blank output can't
#    masquerade as a distro name.
Say 'Checking WSL... (the first check can take up to a minute while WSL starts)'
$env:WSL_UTF8 = '1'
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wslRaw = wsl.exe -l -q 2>&1
$wslExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

$distros = @( $wslRaw | ForEach-Object { ("$_" -replace '[^\x20-\x7E]', '').Trim() } | Where-Object { $_ } )
$wslText = "$wslRaw"
if ($wslExit -ne 0 -or $distros.Count -eq 0 -or $wslText -match 'not installed|no installed distrib|has no installed') {
  Show-WslSetupHelp
  return
}

# 3) Launch the bash installer inside WSL as a login shell.
$inner = Get-InnerBashCommand
Say ("Using your WSL distro: {0}" -f $distros[0]) 'Cyan'
if ($DryRun) {
  Say ''
  Say '[DryRun] WSL detected; would launch inside WSL (bash command shown on its own line):' 'Yellow'
  Say '  wsl.exe -e bash -lc'
  Say ("    {0}" -f $inner)
  return
}
Say 'Launching the installer inside WSL...' 'Cyan'
Say ''
# curl ships with current Ubuntu; if yours lacks it, run once in Ubuntu:
#   sudo apt-get update && sudo apt-get install -y curl
wsl.exe -e bash -lc $inner
