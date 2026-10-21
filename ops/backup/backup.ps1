# TPN OS nightly backup: pg_dump (custom format) piped straight into age,
# so no unencrypted copy ever touches the disk. Keeps the newest $Keep dumps.
# Runs as SYSTEM from the "TPN OS Backup (nightly)" scheduled task.
#
# Files next to this script:
#   conn.txt              host|port|user|dbname[|sslmode]   (not secret; sslmode defaults to require)
#   recipient.txt         age public key (age1...). The private key is NOT here.
#   secrets\pgpass.conf   host:port:db:user:password  (admin/SYSTEM-only ACL)
param([int]$Keep = 30)

$ErrorActionPreference = 'Stop'
$Root    = $PSScriptRoot
$Dumps   = Join-Path $Root 'dumps'
$Log     = Join-Path $Root 'backup.log'
$PgDump  = Join-Path $Root 'bin\pgsql\bin\pg_dump.exe'
$Age     = Join-Path $Root 'bin\age\age.exe'

function Write-Log($status, $msg) {
    $line = '{0}  {1,-4}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $status, $msg
    Add-Content -Path $Log -Value $line -Encoding ASCII
}

$tmp = $null
$err = Join-Path $Root 'last-pg_dump-stderr.txt'
try {
    New-Item -ItemType Directory -Force $Dumps | Out-Null
    $h, $port, $user, $db, $ssl = (Get-Content (Join-Path $Root 'conn.txt') -TotalCount 1).Trim().Split('|')
    $recipient = (Get-Content (Join-Path $Root 'recipient.txt') | Where-Object { $_ -match '^age1' } | Select-Object -First 1).Trim()
    if (-not $recipient) { throw 'recipient.txt has no age1... public key' }
    $env:PGPASSFILE = Join-Path $Root 'secrets\pgpass.conf'
    if (-not (Test-Path $env:PGPASSFILE)) { throw 'secrets\pgpass.conf is missing' }
    $env:PGSSLMODE = if ($ssl) { $ssl } else { 'require' }
    $env:PGCONNECT_TIMEOUT = '30'

    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $final = Join-Path $Dumps "tpn-os-$stamp.dump.age"
    $tmp   = "$final.partial"

    # cmd's pipe is binary-safe; PowerShell 5.1's pipe between native exes is not.
    $cmd = "`"$PgDump`" --format=custom --no-password --host=$h --port=$port --username=$user --dbname=$db 2> `"$err`" | `"$Age`" --encrypt --recipient $recipient --output `"$tmp`""
    & cmd.exe /d /c $cmd
    $ageExit = $LASTEXITCODE

    $errText = if (Test-Path $err) { (Get-Content $err -Raw) } else { '' }
    if ($errText -and $errText.Trim()) { throw "pg_dump: $($errText.Trim() -replace '\s+', ' ')" }
    if ($ageExit -ne 0) { throw "age exited $ageExit" }
    $size = (Get-Item $tmp).Length
    if ($size -lt 10KB) { throw "dump is only $size bytes, treating as failed" }

    Move-Item $tmp $final
    $tmp = $null

    $old = Get-ChildItem $Dumps -Filter 'tpn-os-*.dump.age' | Sort-Object Name -Descending | Select-Object -Skip $Keep
    $old | Remove-Item -Force
    Write-Log 'OK' ("{0}  {1:N0} KB  (pruned {2})" -f (Split-Path $final -Leaf), ($size / 1KB), @($old).Count)
}
catch {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    Write-Log 'FAIL' $_.Exception.Message
    exit 1
}
finally {
    if (Test-Path $err) { Remove-Item $err -Force }
}
