<#
.SYNOPSIS
    Spin up an additional Claude Desktop instance with isolated profile.

.DESCRIPTION
    Pressing the button with nothing open launches the persistent core instance
    (instance-1). Pressing it when Claude is already open always creates a brand
    new fresh clone — ephemeral instances are never reused. Run -Cleanup to
    remove accumulated stopped instances when they pile up.

.PARAMETER Instance
    Force a specific instance number. Omit for auto behaviour described above.

.PARAMETER SyncConfig
    Copy claude_desktop_config.json from the base profile into every existing
    instance directory, then exit (does not launch anything).

.PARAMETER List
    Show all existing instances and whether Claude is currently running for
    each, then exit.

.PARAMETER FixAuth
    Re-copy auth-related files (config.json, cookies, device registry) from
    the base profile into every existing instance, then exit. Use this after
    a Claude Desktop update breaks login in existing instances.

.PARAMETER Cleanup
    Delete all stopped non-core instances (anything above instance-1 that is not
    currently running). Safe to run at any time; running instances are never touched.

.EXAMPLE
    .\launch-claude.ps1
    .\launch-claude.ps1 -SyncConfig
    .\launch-claude.ps1 -FixAuth
    .\launch-claude.ps1 -Cleanup
    .\launch-claude.ps1 -List
#>

param(
    [int]$Instance = 0,
    [switch]$SyncConfig,
    [switch]$List,
    [switch]$FixAuth,     # re-copy auth files into all existing instances
    [switch]$Cleanup      # delete all stopped non-core instances (keeps instance-1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The taskbar shortcut runs this hidden, so surface failures instead of dying silently.
$LogFile = Join-Path $PSScriptRoot "launch-claude.log"

trap {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$stamp  ERROR: $($_.Exception.Message)`r`n$($_.InvocationInfo.PositionMessage)`r`n"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`n`nDetails logged to:`n$LogFile",
            "Launch Claude - Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
    exit 1
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$BaseProfile   = "$env:APPDATA\Claude"
$InstancesRoot = "$env:APPDATA\Claude-instances"
$ClaudeExe     = "$env:LOCALAPPDATA\AnthropicClaude\claude.exe"

# Snapshot of auth files captured whenever the base profile is fully closed.
# Used to seed new instances when the live base profile has its cookies locked.
# Named with a leading underscore so it is never treated as an instance.
$SeedProfile = "$InstancesRoot\_seed"
$AuthItems   = @(
    "config.json", "Local State", "ant-device-registry.json", "ant-did",
    "Local Storage", "Network", "Partitions"
)

# Files/dirs copied from base profile when creating a new instance.
# Caches are skipped — they're large and regenerated automatically.
$FilesToCopy = @(
    "claude_desktop_config.json",
    "config.json",
    "Local State",
    "Preferences",
    "ant-did",                      # legacy pre-update device id
    "ant-device-registry.json",     # device id format introduced ~Aug 2026
    "git-worktrees.json"
)
$DirsToCopy = @(
    "Local Storage",
    "Network",
    "IndexedDB",
    "Session Storage",
    "Partitions"                    # auth cookies live here post-update
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-AllInstances {
    if (-not (Test-Path $InstancesRoot)) { return [object[]]@() }
    [object[]]@(
        Get-ChildItem $InstancesRoot -Directory |
            Where-Object { $_.Name -match "^instance-(\d+)$" } |
            Sort-Object { [int]($_.Name -replace "instance-", "") }
    )
}

function Get-InstancePath([int]$n) {
    return "$InstancesRoot\instance-$n"
}

# Claude spawns ~9 processes per window, so querying WMI per process took ~26s
# with several windows open. One CIM query for all of them takes ~0.5s. Cached
# because running state cannot change before we launch at the end of the script.
$script:RunningCache = $null

function Get-RunningInstanceNumbers {
    if ($null -ne $script:RunningCache) { return $script:RunningCache }

    $nums = New-Object System.Collections.Generic.List[int]
    try {
        $cmdlines = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
            Select-Object -ExpandProperty CommandLine
        foreach ($cmd in $cmdlines) {
            if ($cmd -match "instance-(\d+)") {
                $n = [int]$Matches[1]
                if (-not $nums.Contains($n)) { [void]$nums.Add($n) }
            }
        }
    } catch { }

    $script:RunningCache = $nums
    return $nums
}

# Regenerable cache folders — copying these adds a minute+ to launch for no benefit.
$ExcludeSegments = @(
    "Cache", "Code Cache", "GPUCache", "Cache_Data",
    "DawnGraphiteCache", "DawnWebGPUCache", "Shared Dictionary", "Crashpad"
)

# Copies a file or directory tree, skipping caches and anything locked by a
# running Claude. Emits profile-relative paths of anything skipped, formatted
# as "<relative path> :: <reason>". Callers wrap in @() so an empty result is
# still countable.
function Copy-Resilient {
    param([string]$Src, [string]$Dest, [string]$Label)

    $skipped = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $Src)) { return $skipped }

    $srcItem = Get-Item $Src -Force
    if (-not $srcItem.PSIsContainer) {
        try {
            $parent = Split-Path $Dest -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $Src $Dest -Force -ErrorAction Stop
        }
        catch { [void]$skipped.Add("$Label :: $($_.Exception.Message)") }
        return $skipped
    }

    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $rootLen = $srcItem.FullName.Length
    foreach ($child in Get-ChildItem $Src -Recurse -Force -ErrorAction SilentlyContinue) {
        $rel = $child.FullName.Substring($rootLen).TrimStart('\')
        if (($rel -split '\\') | Where-Object { $ExcludeSegments -contains $_ }) { continue }

        $target = Join-Path $Dest $rel
        if ($child.PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        } else {
            try {
                # The parent may not exist yet if enumeration returned this file
                # before its directory, so ensure it before copying.
                $parent = Split-Path $target -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item $child.FullName $target -Force -ErrorAction Stop
            }
            catch { [void]$skipped.Add("$Label\$rel :: $($_.Exception.Message)") }
        }
    }
    return $skipped
}

# True when the base profile's cookie DB can be opened, i.e. the original Claude
# app is not running.
function Test-BaseUnlocked {
    $cookies = "$BaseProfile\Network\Cookies"
    if (-not (Test-Path $cookies)) { return $false }
    try {
        $probe = [IO.File]::Open($cookies, "Open", "Read", "None")
        $probe.Close()
        return $true
    } catch { return $false }
}

# Refreshes the seed snapshot, but only while the base profile is fully closed,
# so a known-good seed is never overwritten with a partial one.
function Update-Seed {
    if (-not (Test-BaseUnlocked)) { return $false }
    foreach ($i in $AuthItems) {
        $src = "$BaseProfile\$i"
        if (Test-Path $src) {
            [void]@(Copy-Resilient -Src $src -Dest "$SeedProfile\$i" -Label $i)
        }
    }
    return $true
}

# Unlocked profiles that can donate files the live base profile holds open:
# stopped instances plus the seed snapshot, newest first.
function Get-DonorInstances {
    $running = @(Get-RunningInstanceNumbers)
    $donors  = [System.Collections.ArrayList]::new()
    foreach ($inst in @(Get-AllInstances)) {
        if ($running -notcontains [int]($inst.Name -replace "instance-", "")) { [void]$donors.Add($inst) }
    }
    if (Test-Path $SeedProfile) { [void]$donors.Add((Get-Item $SeedProfile -Force)) }
    @($donors) | Sort-Object LastWriteTime -Descending
}

# Recovers files that were locked in the base profile by sourcing them from the
# most recently used stopped instance. Returns the number recovered.
function Repair-SkippedFiles {
    param([string]$Dest, [string[]]$Skipped)

    $donors = @(Get-DonorInstances)
    if ($donors.Count -eq 0) { return 0 }

    $recovered = 0
    foreach ($entry in $Skipped) {
        $rel = ($entry -split " :: ")[0]
        foreach ($donor in $donors) {
            $cand = Join-Path $donor.FullName $rel
            if (-not (Test-Path $cand)) { continue }
            try {
                $probe = [IO.File]::Open($cand, "Open", "Read", "None")
                $probe.Close()
                $target = Join-Path $Dest $rel
                $parent = Split-Path $target -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item $cand $target -Force -ErrorAction Stop
                Add-Content -Path $LogFile -Value "    recovered $rel from $($donor.Name)"
                $recovered++
                break
            } catch { continue }
        }
    }
    return $recovered
}

function New-Instance([int]$n) {
    $dest = Get-InstancePath $n
    Write-Host "Creating instance $n at: $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($f in $FilesToCopy + $DirsToCopy) {
        $src = "$BaseProfile\$f"
        if (Test-Path $src) {
            foreach ($s in @(Copy-Resilient -Src $src -Dest "$dest\$f" -Label $f)) { [void]$skipped.Add($s) }
        }
    }

    if ($skipped.Count -eq 0) {
        Write-Host "Instance $n created." -ForegroundColor Green
        return
    }

    # Anything locked is almost always the session cookie DBs held open by a
    # running Claude. Without cookies the new window lands on a login screen, so
    # source them from a stopped instance instead.
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$stamp  instance-$n : $($skipped.Count) file(s) locked in base profile:"
    foreach ($s in $skipped) { Add-Content -Path $LogFile -Value "    $s" }

    $recovered = Repair-SkippedFiles -Dest $dest -Skipped $skipped.ToArray()
    $missing   = $skipped.Count - $recovered

    if ($missing -eq 0) {
        Write-Host "Instance $n created ($recovered locked file(s) recovered - see log for sources)." -ForegroundColor Green
    } else {
        Write-Host "Instance $n created ($recovered recovered, $missing unavailable - you may see a login screen)." -ForegroundColor Yellow
        Write-Host "Tip: fully quit Claude from the system tray, then relaunch to refresh auth." -ForegroundColor Yellow
    }
}

function Sync-Config {
    $src = "$BaseProfile\claude_desktop_config.json"
    if (-not (Test-Path $src)) {
        Write-Error "Base config not found: $src"
        return
    }
    $instances = @(Get-AllInstances)
    if ($instances.Count -eq 0) {
        Write-Host "No instances found in $InstancesRoot" -ForegroundColor Yellow
        return
    }
    foreach ($inst in $instances) {
        $dest = "$($inst.FullName)\claude_desktop_config.json"
        Copy-Item $src $dest -Force
        Write-Host "Synced config -> $($inst.Name)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# -List
# ---------------------------------------------------------------------------
if ($List) {
    $instances = @(Get-AllInstances)
    if ($instances.Count -eq 0) {
        Write-Host "No instances found. Run without flags to create one." -ForegroundColor Yellow
        exit 0
    }
    $running = @(Get-RunningInstanceNumbers)
    Write-Host ""
    Write-Host "  Claude instances in $InstancesRoot" -ForegroundColor Cyan
    Write-Host "  $(("-") * 50)"
    foreach ($inst in $instances) {
        $n = [int]($inst.Name -replace "instance-", "")
        $status = if ($running -contains $n) { "[running]" } else { "[stopped]" }
        $color  = if ($running -contains $n) { "Green" } else { "Gray" }
        Write-Host ("  instance-{0,-4} {1}" -f $n, $status) -ForegroundColor $color
    }
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# -SyncConfig
# ---------------------------------------------------------------------------
if ($SyncConfig) {
    Sync-Config
    exit 0
}

# ---------------------------------------------------------------------------
# -FixAuth  (re-copy auth files into every existing instance)
# ---------------------------------------------------------------------------
if ($FixAuth) {
    $authFiles = @("config.json", "Local State", "ant-device-registry.json", "ant-did")
    $authDirs  = @("Network", "Partitions")

    $instances = @(Get-AllInstances)
    if ($instances.Count -eq 0) {
        Write-Host "No instances found in $InstancesRoot" -ForegroundColor Yellow
        exit 0
    }
    $lockedTotal = 0
    foreach ($inst in $instances) {
        Write-Host "Fixing auth for $($inst.Name)..." -ForegroundColor Cyan
        foreach ($item in $authFiles + $authDirs) {
            $src = "$BaseProfile\$item"
            if (Test-Path $src) {
                $lockedTotal += @(Copy-Resilient -Src $src -Dest "$($inst.FullName)\$item" -Label $item).Count
            }
        }
        Write-Host "  Done." -ForegroundColor Green
    }
    Write-Host ""
    if ($lockedTotal -gt 0) {
        Write-Host "$lockedTotal file(s) were locked and skipped." -ForegroundColor Yellow
        Write-Host "Fully quit Claude (system tray) and re-run -FixAuth to copy them." -ForegroundColor Yellow
    } else {
        Write-Host "Auth refreshed on all instances. Restart any open Claude windows." -ForegroundColor Cyan
    }
    exit 0
}

# ---------------------------------------------------------------------------
# -Cleanup
# ---------------------------------------------------------------------------
if ($Cleanup) {
    $running = @(Get-RunningInstanceNumbers)
    $instances = @(Get-AllInstances)
    $removed   = 0
    foreach ($inst in $instances) {
        $n = [int]($inst.Name -replace "instance-", "")
        if ($n -eq 1) { continue }                        # never touch core instance
        if ($running -contains $n) {
            Write-Host "Skipping $($inst.Name) (running)" -ForegroundColor Yellow
            continue
        }
        Remove-Item $inst.FullName -Recurse -Force
        Write-Host "Removed $($inst.Name)" -ForegroundColor Green
        $removed++
    }
    if ($removed -eq 0) { Write-Host "Nothing to clean up." -ForegroundColor Cyan }
    else                { Write-Host "$removed instance(s) removed." -ForegroundColor Cyan }
    exit 0
}

# ---------------------------------------------------------------------------
# Validate exe
# ---------------------------------------------------------------------------
if (-not (Test-Path $ClaudeExe)) {
    Write-Error "Claude exe not found at: $ClaudeExe`nUpdate `$ClaudeExe in this script if your install path differs."
    exit 1
}

# ---------------------------------------------------------------------------
# Refresh the auth seed while we still can (no-op if base Claude is running)
# ---------------------------------------------------------------------------
if (Update-Seed) {
    Write-Host "Auth seed refreshed from base profile." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Resolve instance number
# ---------------------------------------------------------------------------
if ($Instance -le 0) {
    $running = @(Get-RunningInstanceNumbers)
    if ($running.Count -eq 0) {
        # Nothing open — launch the persistent core instance
        $Instance = 1
    } else {
        # Something already open — always create a fresh new instance
        $allNums = @(Get-AllInstances | ForEach-Object { [int]($_.Name -replace "instance-", "") })
        $Instance = if ($allNums.Count -gt 0) { ($allNums | Measure-Object -Maximum).Maximum + 1 } else { 2 }
    }
}

$instancePath = Get-InstancePath $Instance

# ---------------------------------------------------------------------------
# Create / reuse instance
# ---------------------------------------------------------------------------
if ($Instance -eq 1) {
    # Core instance — persistent, reuse if it exists
    if (-not (Test-Path $instancePath)) {
        New-Instance $Instance
    } else {
        Write-Host "Opening core instance at: $instancePath" -ForegroundColor Cyan
    }
} else {
    # Ephemeral instance — always start fresh. If a leftover folder can't be
    # removed (files still locked by a dying process), move to the next number
    # rather than failing the launch.
    while (Test-Path $instancePath) {
        try {
            Remove-Item $instancePath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "instance-$Instance is locked, trying next number..." -ForegroundColor Yellow
            $Instance++
            $instancePath = Get-InstancePath $Instance
        }
    }
    New-Instance $Instance
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
Write-Host "Launching Claude instance $Instance..." -ForegroundColor Cyan
Start-Process -FilePath $ClaudeExe -ArgumentList "--user-data-dir=`"$instancePath`""
Write-Host "Done." -ForegroundColor Green
