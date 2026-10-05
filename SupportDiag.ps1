#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Start','Status','Collect','Stop')][string]$Action='Start',
    [ValidateRange(1,1440)][int]$Minutes=60,
    [ValidateRange(5,300)][int]$SampleSeconds=10,
    [ValidateRange(30,3600)][int]$EventSeconds=120,
    [switch]$DownloadOnly,
    [switch]$Offline,
    [string]$Ref='main',
    [string]$Root='C:\ProgramData\WindowsSupportDiag',
    [string]$Run,
    [string]$Destination
)
$ErrorActionPreference='Stop'
$Repository='nil3232/windows-support-diag'
function Get-RunDirectory {
    if ($Run) {
        $selected=Get-Item -LiteralPath $Run
        if (-not $selected.PSIsContainer -or -not (Test-Path -LiteralPath (Join-Path $selected.FullName 'run.json'))) { throw 'Invalid run directory.' }
        return $selected
    }
    $selected=Get-ChildItem -LiteralPath (Join-Path $Root 'Runs') -Directory -ErrorAction SilentlyContinue |
        Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'run.json')} |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $selected) { throw 'No diagnostic runs found.' }
    $selected
}
function Get-TaskForRun($Directory) {
    $state=Get-Content -LiteralPath (Join-Path $Directory.FullName 'run.json') -Raw | ConvertFrom-Json
    if ($state.TaskName -notlike 'WindowsSupportDiag-*') { throw 'Unexpected task name.' }
    Get-ScheduledTask -TaskName $state.TaskName -ErrorAction SilentlyContinue
}
function Install-Collector {
    $tools=Join-Path $Root 'Tools\v1.0.0'
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict diagnostics directory permissions.' }
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    if ($Offline -and -not (Test-Path -LiteralPath (Join-Path $tools 'manifest.json'))) {
        $localManifest=Join-Path $PSScriptRoot 'manifest.json'
        $localCollector=Join-Path $PSScriptRoot 'Collector.ps1'
        if (-not (Test-Path -LiteralPath $localManifest) -or -not (Test-Path -LiteralPath $localCollector)) { throw 'Offline package not found. Place Collector.ps1 and manifest.json beside SupportDiag.ps1 or use DownloadOnly first.' }
        $package=Get-Content -LiteralPath $localManifest -Raw | ConvertFrom-Json
        if ($package.Version -ne '1.0.0' -or (Get-FileHash -LiteralPath $localCollector -Algorithm SHA256).Hash -ne $package.Files.'Collector.ps1') { throw 'Offline package integrity check failed.' }
        Copy-Item -LiteralPath $localCollector -Destination (Join-Path $tools 'Collector.ps1') -Force
        Copy-Item -LiteralPath $localManifest -Destination (Join-Path $tools 'manifest.json') -Force
    }
    if (-not $Offline) {
        if ($Ref -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid GitHub ref.' }
        $oldProtocol=[Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol=$oldProtocol -bor [Net.SecurityProtocolType]::Tls12
            $base="https://raw.githubusercontent.com/$Repository/$Ref"
            Invoke-WebRequest "$base/manifest.json" -UseBasicParsing -TimeoutSec 60 -OutFile (Join-Path $tools 'manifest.download.json')
            $manifest=Get-Content -LiteralPath (Join-Path $tools 'manifest.download.json') -Raw | ConvertFrom-Json
            if ($manifest.Version -ne '1.0.0' -or $manifest.Files.'Collector.ps1' -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid package manifest.' }
            $temporary=Join-Path $tools 'Collector.download.ps1'
            Invoke-WebRequest "$base/Collector.ps1" -UseBasicParsing -TimeoutSec 60 -OutFile $temporary
            if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $manifest.Files.'Collector.ps1') { throw 'Collector SHA256 mismatch. Nothing executed.' }
            Move-Item -LiteralPath $temporary -Destination (Join-Path $tools 'Collector.ps1') -Force
            Move-Item -LiteralPath (Join-Path $tools 'manifest.download.json') -Destination (Join-Path $tools 'manifest.json') -Force
        } finally { [Net.ServicePointManager]::SecurityProtocol=$oldProtocol }
    }
    $manifest=Get-Content -LiteralPath (Join-Path $tools 'manifest.json') -Raw | ConvertFrom-Json
    $collector=Join-Path $tools 'Collector.ps1'
    if ($manifest.Version -ne '1.0.0' -or (Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash -ne $manifest.Files.'Collector.ps1') { throw 'Cached collector integrity check failed.' }
    $launcher=Join-Path $Root 'SupportDiag.ps1'
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($launcher)) { Copy-Item -LiteralPath $PSCommandPath -Destination $launcher -Force }
    $collector
}
if ($Action -eq 'Start' -or $DownloadOnly) {
    $collector=Install-Collector
    if ($DownloadOnly) { Write-Host "Downloaded and checked. Offline launch: & '$Root\SupportDiag.ps1' -Offline -Minutes $Minutes"; return }
    & $collector -Start -Minutes $Minutes -SampleSeconds $SampleSeconds -EventSeconds $EventSeconds -OutputRoot (Join-Path $Root 'Runs')
    $directory=Get-RunDirectory
    $waitUntil=(Get-Date).AddMinutes(2)
    while (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'READY.txt'))) {
        $task=Get-TaskForRun $directory
        if (-not $task -or $task.State -ne 'Running' -or (Get-Date) -gt $waitUntil) {
            Write-Warning "READY not confirmed yet. Check Status and errors.txt in $($directory.FullName)."
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Host 'READY: collection is independent of this PowerShell window and RDP session.'
    Write-Host "Get report later: & '$Root\SupportDiag.ps1' -Action Collect"
    return
}
$directory=Get-RunDirectory
$task=Get-TaskForRun $directory
$archive=Join-Path $directory.FullName 'Report.zip'
if ($Action -eq 'Status') {
    [pscustomobject]@{Run=$directory.FullName;TaskState=$(if($task){[string]$task.State}else{'Absent'});Ready=(Test-Path (Join-Path $directory.FullName 'READY.txt'));Complete=(Test-Path (Join-Path $directory.FullName 'COMPLETE.txt'));Report=$archive}
    if (Test-Path -LiteralPath (Join-Path $directory.FullName 'heartbeat.json')) { Get-Content (Join-Path $directory.FullName 'heartbeat.json') -Raw }
    return
}
# Collect returns only a finished archive; Stop requests an early finish.
if ($Action -eq 'Stop') { New-Item -ItemType File -Path (Join-Path $directory.FullName 'STOP') -Force | Out-Null }
if ($task -and $task.State -eq 'Running') {
    if ($Action -eq 'Collect') { throw 'Collection is still running. Wait for completion or use -Action Stop.' }
    $deadline=(Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 2
        $task=Get-TaskForRun $directory
    } while ($task -and $task.State -eq 'Running' -and (Get-Date) -lt $deadline)
    if ($task -and $task.State -eq 'Running') { throw 'Collector is still finishing. Run Collect later; saved files are retained.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'COMPLETE.txt'))) {
    & (Join-Path $directory.FullName 'Collector.ps1') -Finalize -OutputRoot $directory.FullName
}
if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'COMPLETE.txt')) -or -not (Test-Path -LiteralPath $archive)) { throw 'Report incomplete. Check errors.txt in the run folder.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($name in @('README.txt','run.json','summary.html')) { if ($name -notin @($zip.Entries.FullName)) { throw "Missing archive entry: $name" } }
} finally { $zip.Dispose() }
if (-not $Destination) { $Destination=Join-Path $Root ("Report-{0}-{1}.zip" -f $env:COMPUTERNAME,$directory.Name) }
$target=[IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
if ($target -ne [IO.Path]::GetFullPath($archive)) { Copy-Item -LiteralPath $archive -Destination $target -Force }
Get-Item -LiteralPath $target | Select-Object FullName,Length,LastWriteTime
