# Run this yourself (not through Claude):  ssh -t headless powershell -NoProfile -File C:\TPNBackup\set-password.ps1
# It asks for the Supabase database password without echoing it and saves it
# to C:\TPNBackup\secrets\pgpass.conf, which only Administrators and SYSTEM can read.
$Root = $PSScriptRoot
$h, $port, $user, $db = (Get-Content (Join-Path $Root 'conn.txt') -TotalCount 1).Trim().Split('|')
$sec = Read-Host -AsSecureString "Supabase DB password for $user"
$pw  = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
if (-not $pw) { Write-Host 'Nothing entered, nothing changed.'; exit 1 }
# pgpass format: escape \ and : inside the password
$pw = $pw.Replace('\', '\\').Replace(':', '\:')
$dir = Join-Path $Root 'secrets'
New-Item -ItemType Directory -Force $dir | Out-Null
[IO.File]::WriteAllText((Join-Path $dir 'pgpass.conf'), "${h}:${port}:${db}:${user}:$pw`n")
Remove-Variable pw, sec
Write-Host 'Saved. Test it with:  schtasks /Run /TN "TPN OS Backup (nightly)"  then read C:\TPNBackup\backup.log'
