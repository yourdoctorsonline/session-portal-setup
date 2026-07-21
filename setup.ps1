# Session Launcher - Windows bootstrap.
# -----------------------------------------------------------------------------
# One PowerShell command that takes a Windows PC from nothing to a running Session
# Launcher. If WSL2 isn't installed, it installs it for you (elevating via UAC),
# then AUTO-RESUMES after the one required reboot and finishes the install inside
# Ubuntu - you never have to paste the command a second time.
#
# Run it in PowerShell with:
#   irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex
#
# Options are set via ENVIRONMENT VARIABLES (see below), because `irm ... | iex` runs
# this text inline and cannot pass -parameters:
#   $env:SL_PRESET='portal'; irm .../setup.ps1 | iex     # full | harness | portal
#   $env:SL_DRYRUN='1';      irm .../setup.ps1 | iex     # print what would run, do nothing
#
# PowerShell 5.1+ (Windows built-in) compatible. No external modules.
# -----------------------------------------------------------------------------
#
# NB: no param()/[ValidateSet] block ON PURPOSE. Under `irm | iex`, Invoke-Expression
# executes this text inline in the caller's scope - it does not bind a param block, and
# applying a [ValidateSet] attribute to an unset $Preset throws "The attribute cannot be
# added because variable Preset with value  would no longer be valid." So config is read
# from $env:* and validated by hand.
$ErrorActionPreference = 'Stop'
$SetupUrl = 'https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh'
$SelfUrl  = 'https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1'

function Say([string]$m, [string]$c = 'White') { Write-Host $m -ForegroundColor $c }

# --- config from environment (irm|iex-safe) ----------------------------------
$Preset   = "$($env:SL_PRESET)".Trim().ToLower()
$DryRun   = ($env:SL_DRYRUN -eq '1')
$IsResume = ($env:SL_RESUME -eq '1')   # set by the RunOnce auto-resume after the reboot
$ValidPresets = @('full','harness','portal')
if ($Preset -and ($ValidPresets -notcontains $Preset)) {
  Say ("Ignoring unknown preset '{0}' - use one of: {1}" -f $Preset, ($ValidPresets -join ', ')) 'Yellow'
  $Preset = ''
}

# Am I running elevated (Administrator)? wsl --install needs it.
function Test-Admin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# Rebuild the `irm | iex` bootstrap command, preserving SL_PRESET so the preset survives
# an elevation or a post-reboot resume. -Resume also sets SL_RESUME so the resumed run
# knows to pause for Ubuntu's one-time user/password setup.
function Get-BootstrapCommand([bool]$Resume) {
  $pre = ''
  if ($Preset) { $pre += "`$env:SL_PRESET='$Preset'; " }
  if ($Resume) { $pre += "`$env:SL_RESUME='1'; " }
  "$pre" + "irm $SelfUrl | iex"
}

# Relaunch this bootstrap in an elevated PowerShell (triggers the UAC prompt).
function Invoke-SelfElevated {
  $cmd = Get-BootstrapCommand $false
  Start-Process -FilePath 'powershell.exe' -Verb RunAs `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $cmd)
}

# Register a one-shot auto-resume: at the next sign-in (after the reboot), Windows runs
# the bootstrap again ONCE and deletes the key - no loop risk (RunOnce, not Run).
function Register-ResumeAfterReboot {
  $inner = Get-BootstrapCommand $true
  $val = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
  $rk  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  if (-not (Test-Path $rk)) { New-Item -Path $rk -Force | Out-Null }
  New-ItemProperty -Path $rk -Name 'SessionLauncherResume' -Value $val -PropertyType String -Force | Out-Null
}

# WSL missing -> install it and arrange the auto-resume. Elevates first if needed.
function Install-WslAndArrangeResume {
  if ($DryRun) {
    Say ''
    Say '[DryRun] WSL is not usable; would:' 'Yellow'
    Say '  - relaunch elevated (UAC) if not already admin'
    Say '  - register a one-shot RunOnce auto-resume:'
    Say ("      {0}" -f (Get-BootstrapCommand $true))
    Say '  - run:  wsl.exe --install'
    Say '  - ask you to reboot; the install then resumes automatically at next sign-in'
    return
  }
  if (-not (Test-Admin)) {
    Say ''
    Say 'Setting up WSL needs administrator rights.' 'Yellow'
    Say 'A Windows security (UAC) prompt will appear - click Yes.'
    Invoke-SelfElevated
    Say 'A new administrator window has opened - it continues from there. You can close this one.'
    return
  }
  # Elevated + WSL missing: arrange the resume BEFORE installing, then install.
  Register-ResumeAfterReboot
  Say ''
  Say 'Installing WSL2 + Ubuntu now (this can take several minutes)...' 'Cyan'
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  wsl.exe --install
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  Say ''
  if ($code -eq 0) {
    Say 'WSL is installed. Two quick things and you are done:' 'Green'
    Say '  1. RESTART your PC now  (Start > Power > Restart).' 'Green'
    Say '  2. After you sign back in, an Ubuntu window opens once - pick a username + password.'
    Say ''
    Say 'Then the Session Launcher install CONTINUES ON ITS OWN - you do NOT paste anything'
    Say 'again. (It resumes automatically at your next sign-in.)' 'Green'
  } else {
    Say ("wsl --install returned a non-zero code ({0})." -f $code) 'Yellow'
    Say 'Finish it by hand, then re-run the Windows command:'
    Say '  1. In this admin window run:  wsl --install' 'Green'
    Say '  2. Reboot, set the Ubuntu username/password, then paste the Windows command again.'
  }
}

# Build the SETUP_* environment prefix passed into the Linux installer. Preset comes from
# $env:SL_PRESET; any SETUP_* vars already set ride along so Windows users get the same
# knobs as Mac (SETUP_RUSTDESK, SETUP_WORKSPACE_REPO...).
function Get-SetupEnvPrefix {
  $parts = @()
  if ($Preset) { $parts += "SETUP_PRESET=$Preset" }
  Get-ChildItem Env: | Where-Object { $_.Name -like 'SETUP_*' } | ForEach-Object {
    $v = $_.Value -replace "'", "'\''"
    $parts += ("{0}='{1}'" -f $_.Name, $v)
  }
  if ($parts.Count -gt 0) { ($parts -join ' ') + ' ' } else { '' }
}

# The one bash command run inside WSL. Uses process substitution `bash <(curl ...)` rather
# than `bash -c "$(...)"` ON PURPOSE: it contains NO double-quotes, so Windows PowerShell
# 5.1's native-argument passing (which mangles embedded double-quotes) hands it to wsl.exe
# as one clean argument. Bash evaluates it inside WSL, keeping the terminal wired to the
# installer's prompts. Env assignments use only single quotes, which pass through cleanly.
function Get-InnerBashCommand {
  $envPrefix = Get-SetupEnvPrefix
  "$envPrefix" + 'bash <(curl -fsSL ' + $SetupUrl + ')'
}

Say ''
Say 'Session Launcher - Windows setup' 'Cyan'
Say "PowerShell can't run the installer itself, so this runs it inside WSL (Ubuntu)."
if ($Preset)   { Say ("Preset: {0}" -f $Preset) 'Cyan' }
if ($IsResume) { Say 'Resuming after the WSL install + reboot.' 'Cyan' }
Say ''

# 1) Is the wsl.exe command present at all? (The stub ships on every Windows, so this
#    passing is necessary-but-not-sufficient - step 2 does the real check.)
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Install-WslAndArrangeResume
  return
}

# 2) Is WSL REALLY installed with a usable distro? Run `wsl -l -q` and check BOTH the exit
#    code AND that it named a real distro. Read $LASTEXITCODE ourselves under a relaxed EAP
#    so a non-zero native exit doesn't throw/abort under PS 7.4+. Strip non-printable /
#    UTF-16 noise so a not-installed stub's blank output can't masquerade as a distro name.
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
  Install-WslAndArrangeResume
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
# On a post-reboot resume, Ubuntu's one-time user/password window may still be open. Let
# the user finish it before we run anything inside the distro.
if ($IsResume) {
  Say ''
  Say 'Welcome back. If an Ubuntu window is still asking you to create a username and' 'Cyan'
  Say 'password, finish that first (it only asks once).'
  [void](Read-Host 'Press Enter when Ubuntu is ready to continue')
}
Say 'Launching the installer inside WSL...' 'Cyan'
Say ''
# curl ships with current Ubuntu; if yours lacks it, run once in Ubuntu:
#   sudo apt-get update && sudo apt-get install -y curl
wsl.exe -e bash -lc $inner
