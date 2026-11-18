# Run ONCE: saves your Anthropic API key encrypted for your Windows account only (not in the website folder).
#   powershell -ExecutionPolicy Bypass -File scripts\set-api-key.ps1
$dir = Join-Path $env:USERPROFILE '.current-canvas'
New-Item -ItemType Directory -Force $dir | Out-Null
$sec = Read-Host 'Paste your Anthropic API key (input is hidden)' -AsSecureString
if ($sec.Length -lt 20) { Write-Host 'That does not look like an API key. Nothing saved.'; exit 1 }
ConvertFrom-SecureString $sec | Set-Content (Join-Path $dir 'anthropic.key')
Write-Host "Saved to $dir\anthropic.key (encrypted; only your Windows user can read it)."
