<#
.SYNOPSIS
    Creates a "Launch Claude" shortcut on the Desktop with the Claude icon.
    After running, right-click the shortcut → "Pin to taskbar".
#>

$scriptPath   = "$PSScriptRoot\launch-claude.ps1"
$iconPath     = "$env:LOCALAPPDATA\AnthropicClaude\app.ico"
$shortcutPath = "$env:USERPROFILE\Desktop\Launch Claude.lnk"

$wsh      = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)

$shortcut.TargetPath       = "powershell.exe"
$shortcut.Arguments        = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation     = $iconPath
$shortcut.Description      = "Spin up a new Claude Desktop instance"
$shortcut.Save()

Write-Host "Shortcut created: $shortcutPath" -ForegroundColor Green
Write-Host ""
Write-Host "Next: right-click 'Launch Claude' on your Desktop → 'Pin to taskbar'" -ForegroundColor Cyan
