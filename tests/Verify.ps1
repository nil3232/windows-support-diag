#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in 'Collector.ps1','SupportDiag.ps1') {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    if ($name -eq 'Collector.ps1' -or $name -eq 'SupportDiag.ps1') {
        foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($function.Extent.Text)) }
    }
}
$OutputRoot=Join-Path $root ('test-output\'+[guid]::NewGuid().ToString('N'))
if (-not (Test-TaskActive ([pscustomobject]@{State='Running'})) -or -not (Test-TaskActive ([pscustomobject]@{State='Queued'})) -or (Test-TaskActive ([pscustomobject]@{State='Ready'})) -or (Test-TaskActive $null)) { throw 'Task lifecycle guard failed.' }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$SampleSeconds=10; $EventSeconds=120; $recovered=$false
$state=[pscustomobject]@{StartUTC=[datetime]::UtcNow.ToString('o')}
Save-Text 'run.json' ($state | ConvertTo-Json)
Save-Text 'sample.txt' 'first'; Save-Text 'sample.txt' 'second'; Save-Text 'sample.txt' 'third'
if ([IO.File]::ReadAllText((Join-Path $OutputRoot 'sample.txt')) -ne 'third' -or [IO.File]::ReadAllText((Join-Path $OutputRoot 'sample.txt.previous')) -ne 'second') { throw 'Atomic replacement failed.' }
try { Commit-File (Join-Path $OutputRoot 'absent.tmp') (Join-Path $OutputRoot 'sample.txt'); throw 'Expected failure.' } catch [Management.Automation.MethodInvocationException] {}
if ([IO.File]::ReadAllText((Join-Path $OutputRoot 'sample.txt')) -ne 'third') { throw 'Failed write damaged saved data.' }
@([pscustomobject]@{Time='2026-10-05T12:00:00Z';CPUPercent=10;AvailableMB=1000},[pscustomobject]@{Time='2026-10-05T12:00:10Z';CPUPercent=30;AvailableMB=800}) | Export-Csv (Join-Path $OutputRoot 'load.csv') -NoTypeInformation
Flush-File (Join-Path $OutputRoot 'load.csv')
Package-Report 'test'; Package-Report 'repeat test'
$summary=Get-Content (Join-Path $OutputRoot 'summary.json') -Raw | ConvertFrom-Json
if ($summary.CPUAveragePercent -ne 20 -or $summary.MinimumAvailableMemoryMB -ne 800 -or $summary.SampleCount -ne 2) { throw 'Summary metrics failed.' }
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $OutputRoot 'Report.zip'))
try { foreach($name in 'load.csv','summary.html','summary.json','run.json') { if ($name -notin @($zip.Entries.FullName)) { throw "Missing $name" } }; if (@($zip.Entries | Where-Object FullName -like 'Report*').Count) { throw 'Archive included itself.' } } finally {$zip.Dispose()}
$script:diskPrevious=@{}; $script:frame=0
function Get-CimInstance {
    param($ClassName,$OperationTimeoutSec)
    $script:frame++
    if ($script:frame -eq 1) { [pscustomobject]@{Name='C:';Timestamp_PerfTime=1000;Frequency_PerfTime=1000;AvgDisksecPerRead=100;AvgDisksecPerRead_Base=10;AvgDisksecPerWrite=200;AvgDisksecPerWrite_Base=20;DiskBytesPersec=10000;CurrentDiskQueueLength=0} }
    else { [pscustomobject]@{Name='C:';Timestamp_PerfTime=11000;Frequency_PerfTime=1000;AvgDisksecPerRead=120;AvgDisksecPerRead_Base=20;AvgDisksecPerWrite=260;AvgDisksecPerWrite_Base=40;DiskBytesPersec=20000;CurrentDiskQueueLength=1} }
}
$first=Get-DiskSample 'first'; $second=Get-DiskSample 'second'
if ($null -ne $first.AvgDisksecPerRead -or [math]::Abs($second.AvgDisksecPerRead-0.002) -gt 0.0000001 -or [math]::Abs($second.AvgDisksecPerWrite-0.003) -gt 0.0000001 -or $second.DiskBytesPersec -ne 1000) { throw 'Raw disk counter conversion failed.' }
if ((Run-NativeRead "$env:SystemRoot\System32\hostname.exe").Trim() -ne $env:COMPUTERNAME) { throw 'Native output failed.' }
$watch=[Diagnostics.Stopwatch]::StartNew()
try { Run-NativeRead "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 30' 1; throw 'Expected timeout.' } catch { if ($_ -notlike '*Diagnostic command timed out*') { throw } }
if ($watch.Elapsed.TotalSeconds -gt 6) { throw 'Timeout bound exceeded.' }
$manifest=Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
if ((Get-FileHash (Join-Path $root 'Collector.ps1') -Algorithm SHA256).Hash -ne $manifest.Files.'Collector.ps1') { throw 'Published manifest mismatch.' }
Write-Host "PASS: PowerShell $($PSVersionTable.PSVersion); syntax, durable snapshots, failed-write preservation, summary/archive, disk deltas, native output/timeout, manifest."
