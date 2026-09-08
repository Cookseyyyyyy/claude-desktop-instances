<#
.SYNOPSIS
    Push the current claude_desktop_config.json to all Claude instances.

.DESCRIPTION
    Copies %APPDATA%\Claude\claude_desktop_config.json into every instance
    directory under %APPDATA%\Claude-instances\. Run this after editing your
    MCP server config so all instances pick it up on next launch.
#>

& "$PSScriptRoot\launch-claude.ps1" -SyncConfig
