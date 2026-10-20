# One-time install on the headless PC (run elevated). Expects this folder's
# files plus bin\pgsql\bin (pg_dump + DLLs) and bin\age\age.exe already copied to C:\TPNBackup.
$ErrorActionPreference = 'Stop'
$Root = 'C:\TPNBackup'

'aws-0-ap-southeast-1.pooler.supabase.com|5432|postgres.xjlqfpnzobfqxetgkkai|postgres' |
    Set-Content (Join-Path $Root 'conn.txt') -Encoding ASCII
'age1tsc3nm72ep330nsdvyhhkve2jhel2knk7l3mq5y526mam8ts8c5qzmnlga' |
    Set-Content (Join-Path $Root 'recipient.txt') -Encoding ASCII
New-Item -ItemType Directory -Force (Join-Path $Root 'dumps'), (Join-Path $Root 'secrets') | Out-Null

# Only Administrators and SYSTEM can read anything in here (the password lives in secrets\).
# Set the root only, then make everything below inherit it (/T on the grant leaves files with an empty ACL).
icacls $Root /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' /Q | Out-Null
icacls "$Root\*" /reset /T /Q | Out-Null

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Root\backup.ps1`""
$trigger  = New-ScheduledTaskTrigger -Daily -At 3:00am
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Hours 1) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'TPN OS Backup (nightly)' -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description 'pg_dump of TPN OS Supabase, age-encrypted, keeps 30. See C:\TPNBackup\backup.log' -Force | Out-Null
Get-ScheduledTask 'TPN OS Backup (nightly)' | Select-Object TaskName, State, @{n='Next';e={(Get-ScheduledTaskInfo $_).NextRunTime}}
