#requires -Version 5.1
# Windows Server 2019: SYSTEM collection plus automatic packaging after reboot.
[CmdletBinding()]
param([switch]$Start, [switch]$Finalize, [ValidateRange(1,1440)][int]$Minutes=60,
      [string]$OutputRoot='C:\ProgramData\WindowsSupportDiag\Runs', [string]$TaskName,
      [ValidateRange(5,300)][int]$SampleSeconds=10, [ValidateRange(30,3600)][int]$EventSeconds=120)
$ErrorActionPreference='Stop'
function Get-DiskSample([string]$Stamp) {
    foreach ($disk in @(Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk -OperationTimeoutSec 5)) {
        $old=$script:diskPrevious[$disk.Name]
        $read=$null; $write=$null; $bytes=$null
        if ($old -and $disk.Timestamp_PerfTime -gt $old.Timestamp_PerfTime) {
            $elapsed=([double]$disk.Timestamp_PerfTime-[double]$old.Timestamp_PerfTime)/[double]$disk.Frequency_PerfTime
            $readBase=[double]$disk.AvgDisksecPerRead_Base-[double]$old.AvgDisksecPerRead_Base
            $writeBase=[double]$disk.AvgDisksecPerWrite_Base-[double]$old.AvgDisksecPerWrite_Base
            if ($readBase -gt 0 -and $disk.AvgDisksecPerRead -ge $old.AvgDisksecPerRead) {
                $read=([double]$disk.AvgDisksecPerRead-[double]$old.AvgDisksecPerRead)/[double]$disk.Frequency_PerfTime/$readBase
            }
            if ($writeBase -gt 0 -and $disk.AvgDisksecPerWrite -ge $old.AvgDisksecPerWrite) {
                $write=([double]$disk.AvgDisksecPerWrite-[double]$old.AvgDisksecPerWrite)/[double]$disk.Frequency_PerfTime/$writeBase
            }
            if ($disk.DiskBytesPersec -ge $old.DiskBytesPersec) {
                $bytes=([double]$disk.DiskBytesPersec-[double]$old.DiskBytesPersec)/$elapsed
            }
        }
        $script:diskPrevious[$disk.Name]=$disk
        [pscustomobject]@{Time=$Stamp;Name=$disk.Name;AvgDisksecPerRead=$read;AvgDisksecPerWrite=$write;CurrentDiskQueueLength=$disk.CurrentDiskQueueLength;DiskBytesPersec=$bytes}
    }
}
function Write-Summary {
    $samples=@()
    if (Test-Path -LiteralPath (Join-Path $OutputRoot 'load.csv')) { $samples=@(Import-Csv (Join-Path $OutputRoot 'load.csv')) }
    $summary=[ordered]@{Version='1.0.0';ComputerName=$env:COMPUTERNAME;StartUTC=$state.StartUTC;FinishedUTC=[datetime]::UtcNow.ToString('o');SampleCount=$samples.Count;RebootDetected=$recovered}
    if ($samples.Count) {
        $cpu=$samples | Measure-Object CPUPercent -Average -Maximum
        $memory=$samples | Measure-Object AvailableMB -Minimum
        $summary.FirstSample=$samples[0].Time; $summary.LastSample=$samples[-1].Time
        $summary.CPUAveragePercent=[math]::Round($cpu.Average,2); $summary.CPUMaximumPercent=$cpu.Maximum
        $summary.MinimumAvailableMemoryMB=$memory.Minimum
    }
    Save-Text 'summary.json' ($summary | ConvertTo-Json)
    $rows=foreach($key in $summary.Keys) {
        '<tr><th>{0}</th><td>{1}</td></tr>' -f [Net.WebUtility]::HtmlEncode($key),[Net.WebUtility]::HtmlEncode([string]$summary[$key])
    }
    Save-Text 'summary.html' ('<!doctype html><html lang="en"><meta charset="utf-8"><title>Windows Support Diagnostics</title><style>body{font:16px system-ui;margin:40px;max-width:1000px;background:#f5f7fa;color:#172033}table{border-collapse:collapse;background:white}th,td{text-align:left;padding:12px;border-bottom:1px solid #ddd}h1{color:#2057aa}</style><h1>Windows Support Diagnostics</h1><table>'+($rows -join '')+'</table><p>Measurements describe the observed interval, not an earlier incident. CPU peaks are sampled. Process CPU values are cumulative seconds. Disk latency is in seconds; blank means no valid delta. Inspect errors.txt, event logs and CSV files before drawing conclusions. This report contains private system information; it is not uploaded automatically.</p></html>')
}
function Flush-File([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}
function Commit-File([string]$Temporary,[string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        [IO.File]::Replace($Temporary,$Destination,"$Destination.previous",$true)
    } else { [IO.File]::Move($Temporary,$Destination) }
}
function Save-Text([string]$Name,[string]$Text) {
    $path=Join-Path $OutputRoot $Name
    $temporary="$path.tmp"
    $encoding=New-Object Text.UTF8Encoding($false)
    $bytes=$encoding.GetBytes($Text)
    $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    Commit-File $temporary $path
}
function Run-NativeRead([string]$Executable,[string]$Arguments='',[int]$TimeoutSeconds=5) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=$Arguments
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            # Only terminate the diagnostic command started by this function.
            $process.Kill()
            [void]$process.WaitForExit(2000)
            throw "Diagnostic command timed out: $Executable"
        }
        if ($process.ExitCode -ne 0) { throw "$Executable exit $($process.ExitCode): $($stderr.Result) $($stdout.Result)" }
        $stdout.Result
    } finally { $process.Dispose() }
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as administrator.' }
if ($Start) {
    if ($Finalize) { throw 'Use either -Start or -Finalize.' }
    if (@(Get-ScheduledTask -TaskName 'WindowsSupportDiag-*' -ErrorAction SilentlyContinue).Count) {
        throw 'A CB-Logon task already exists. Check the existing run before starting another collector.'
    }
    $run=Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    # Restrict collected user names and event data to administrators and SYSTEM.
    & icacls.exe $run /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict output directory permissions.' }
    $copy=Join-Path $run 'Collector.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy
    Flush-File $copy
    $name='WindowsSupportDiag-'+[guid]::NewGuid().ToString('N')
    $OutputRoot=$run
    $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5).LastBootUpTime.ToUniversalTime().ToString('o')
    Save-Text 'run.json' ([pscustomobject]@{StartUTC=[datetime]::UtcNow.ToString('o');OriginalBootUTC=$boot;TaskName=$name;Minutes=$Minutes;SampleSeconds=$SampleSeconds;EventSeconds=$EventSeconds;Version='1.0.0'} | ConvertTo-Json)
    $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Minutes {1} -OutputRoot "{2}" -TaskName "{3}" -SampleSeconds {4} -EventSeconds {5}' -f $copy,$Minutes,$run,$name,$SampleSeconds,$EventSeconds
    $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $args
    $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay='PT30S'
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($Minutes+30)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $name
    Write-Host "Collector started for $Minutes minutes. Output: $run"
    Write-Host "Finish early: New-Item -ItemType File -Path '$run\STOP'"
    Write-Host "Task: $name"
    Write-Host 'Do not disconnect until READY.txt appears in the run folder.'
    Write-Host 'After reboot, the SYSTEM task automatically preserves this run and builds Report.zip.'
    return
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$state=Get-Content -LiteralPath (Join-Path $OutputRoot 'run.json') -Raw | ConvertFrom-Json
$SampleSeconds=$state.SampleSeconds; $EventSeconds=$state.EventSeconds
$begin=[datetime]::Parse($state.StartUTC).ToLocalTime()
$TaskName=$state.TaskName
$boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5).LastBootUpTime.ToUniversalTime().ToString('o')
$recovered=($boot -ne $state.OriginalBootUTC)
if ($Finalize) {
    $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and [string]$task.State -in @('Running','Queued')) { throw 'Collector is running or queued. Use the STOP file; do not finalize concurrently.' }
}
$succeeded=$false
function Capture([string]$Name,[scriptblock]$Code) {
    try { Save-Text $Name (& $Code | Out-String -Width 240) }
    catch { "$(Get-Date -Format o) $Name : $_" | Add-Content (Join-Path $OutputRoot 'errors.txt') }
}
function Events([string]$Phase) {
    $channels=@('System','Application','Microsoft-Windows-User Profile Service/Operational',
      'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
      'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational',
      'Microsoft-Windows-Winlogon/Operational','Microsoft-Windows-GroupPolicy/Operational')
    foreach($channel in $channels) {
        Save-Text 'heartbeat.json' ([pscustomobject]@{TimeUTC=[datetime]::UtcNow.ToString('o');Stage="events:$channel"} | ConvertTo-Json -Compress)
        $safe=$channel -replace '[\\/ ]','_'
        try {
            $info=Get-WinEvent -ListLog $channel
            if (-not $info.IsEnabled) { throw 'Channel disabled; left disabled.' }
            if (-not $info.RecordCount) { continue }
            $recordId=(Get-WinEvent -LogName $channel -MaxEvents 1).RecordId
            if ($Phase -eq 'checkpoint' -and $eventRecords.ContainsKey($channel) -and $eventRecords[$channel] -eq $recordId) { continue }
        } catch { "$(Get-Date -Format o) $channel : $_" | Add-Content (Join-Path $OutputRoot 'errors.txt'); continue }
        Capture "$Phase-$safe.txt" {
            Get-WinEvent -FilterHashtable @{LogName=$channel;StartTime=$begin.AddHours(-24)} -MaxEvents 3000 |
              Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message | Format-List
        }
        try {
            $dest=Join-Path $OutputRoot "$Phase-$safe.evtx"
            $temporary="$dest.tmp"
            $cutoff=[math]::Max(0,[long]$recordId-10000)
            $query="*[System[EventRecordID > $cutoff and TimeCreated[timediff(@SystemTime) <= 86400000]]]"
            Run-NativeRead "$env:SystemRoot\System32\wevtutil.exe" ('epl "{0}" "{1}" /q:"{2}" /ow:true' -f $channel,$temporary,$query) 20 | Out-Null
            Flush-File $temporary
            Commit-File $temporary $dest
            $eventRecords[$channel]=$recordId
        } catch { $_ | Out-String | Add-Content (Join-Path $OutputRoot 'errors.txt') }
    }
    # Selected authentication events only; do not export the entire Security log.
    Capture "$Phase-authentication.txt" {
        Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624,4625,4634,4647,4778,4779;StartTime=$begin.AddHours(-24)} -MaxEvents 3000 |
          Select-Object TimeCreated,Id,Message | Format-List
    }
}
function Package-Report([string]$Reason) {
    Save-Text 'README.txt' (@("Started: $($state.StartUTC)","Finished UTC: $([datetime]::UtcNow.ToString('o'))","Reason: $Reason","Sampling target: $SampleSeconds seconds; event snapshots: $EventSeconds seconds. Collection delays can increase intervals.",
      'CSV writes are flushed to disk; snapshots are replaced only after successful write and flush. Previous snapshots retained as .previous.',
      'Process CPU is cumulative CPU seconds. Disk latency values are seconds.',
      'Event exports: last 24 hours, EVTX also limited to last 10000 record IDs; text limited to newest 3000 events/channel. Unchanged checkpoints skipped. errors.txt lists failures/unavailable logs.',
      'No passwords, process command lines, screenshots, memory dumps or user documents collected. Events may contain sensitive application text.',
      'Contains user names, IPs, profile paths. No automatic upload.',
      'Hard power-off can lose the last sample, unexported events or buffered storage writes. No absolute durability guarantee.') -join "`r`n")
    Write-Summary
    $temporary=Join-Path $OutputRoot 'Report.building.zip'
    $files=@(Get-ChildItem -LiteralPath $OutputRoot -File | Where-Object { $_.Name -notlike 'Report*' -and $_.Extension -ne '.tmp' })
    Compress-Archive -LiteralPath $files.FullName -DestinationPath $temporary -CompressionLevel Fastest -Force
    Flush-File $temporary
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($temporary)
    try {
        $names=@($archive.Entries | ForEach-Object { $_.FullName })
        foreach($required in @('README.txt','run.json')) { if ($required -notin $names) { throw "Archive missing $required" } }
    } finally { $archive.Dispose() }
    Commit-File $temporary (Join-Path $OutputRoot 'Report.zip')
    Save-Text 'COMPLETE.txt' "Report ready. $Reason"
}
$eventRecords=@{}; $script:diskPrevious=@{}
try {
    if ($recovered -or $Finalize) {
        Save-Text 'recovery.json' ([pscustomobject]@{TimeUTC=[datetime]::UtcNow.ToString('o');OriginalBootUTC=$state.OriginalBootUTC;CurrentBootUTC=$boot;RebootDetected=$recovered} | ConvertTo-Json)
        Capture 'recovery-system.txt' { Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 | Select-Object Caption,LastBootUpTime,FreePhysicalMemory | Format-List }
        Capture 'recovery-quser.txt' { Run-NativeRead "$env:SystemRoot\System32\quser.exe" }
        Capture 'recovery-qwinsta.txt' { Run-NativeRead "$env:SystemRoot\System32\qwinsta.exe" }
        Events 'recovery'
        Package-Report 'Finalized after reboot or manual recovery; pre-interruption files retained.'
        $succeeded=$true
        return
    }
    Capture 'inventory-system.txt' {
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName,CurrentBuild,UBR | Format-List
        Get-Date -Format o; Get-TimeZone | Format-List
        Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime,TotalVisibleMemorySize,FreePhysicalMemory | Format-List
        Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,NumberOfLogicalProcessors,TotalPhysicalMemory,Domain,PartOfDomain | Format-List
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,Size,FreeSpace | Format-Table
        Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30 | Format-Table
    }
    Capture 'profiles.txt' { Get-CimInstance Win32_UserProfile | Select-Object SID,LocalPath,Loaded,Status,LastUseTime,Special | Format-Table }
    Capture 'services-start.txt' { Get-CimInstance Win32_Service | Select-Object Name,State,StartMode,ProcessId | Format-Table }
    Capture 'network.txt' { ipconfig.exe /all; route.exe print; Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table }
    Capture 'logon-settings.txt' {
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' | Select-Object Shell,Userinit | Format-List
        Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' | Select-Object fDenyTSConnections | Format-List
        Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' | Select-Object PortNumber,UserAuthentication,SecurityLayer | Format-List
    }
    Events 'start'
    if (-not (Test-Path -LiteralPath (Join-Path $OutputRoot 'start-System.evtx'))) { throw 'System baseline not saved. Check errors.txt.' }
    $deadline=$begin.AddMinutes($Minutes)
    $nextEvents=(Get-Date).AddSeconds($EventSeconds)
    do {
        $stamp=Get-Date -Format o
        Save-Text 'heartbeat.json' ([pscustomobject]@{Time=$stamp;Stage='sampling'} | ConvertTo-Json -Compress)
        try {
            $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5
            $cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 5
            $mem=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 5
            if ($null -eq $os -or $null -eq $cpu -or $null -eq $mem) { throw 'Missing OS or performance counter result.' }
            [pscustomobject]@{Time=$stamp;CPUPercent=$cpu.PercentProcessorTime;FreeMemoryKB=$os.FreePhysicalMemory;AvailableMB=$mem.AvailableMBytes;CommittedPercent=$mem.PercentCommittedBytesInUse;PagesPerSec=$mem.PagesPersec} |
              Export-Csv (Join-Path $OutputRoot 'load.csv') -Append -NoTypeInformation -Encoding UTF8
            Flush-File (Join-Path $OutputRoot 'load.csv')
            Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30 @{n='Time';e={$stamp}},Id,ProcessName,SessionId,CPU,WorkingSet64,PrivateMemorySize64,Handles |
              Export-Csv (Join-Path $OutputRoot 'processes.csv') -Append -NoTypeInformation -Encoding UTF8
            Flush-File (Join-Path $OutputRoot 'processes.csv')
            Get-DiskSample $stamp |
              Export-Csv (Join-Path $OutputRoot 'disk-load.csv') -Append -NoTypeInformation -Encoding UTF8
            Flush-File (Join-Path $OutputRoot 'disk-load.csv')
            "`r`n=== $stamp ===" | Out-File (Join-Path $OutputRoot 'sessions.txt') -Append -Encoding utf8
            foreach ($command in @('quser.exe','qwinsta.exe')) {
                try { Run-NativeRead "$env:SystemRoot\System32\$command" | Out-File (Join-Path $OutputRoot 'sessions.txt') -Append -Encoding utf8 }
                catch { "$stamp $command : $_" | Add-Content (Join-Path $OutputRoot 'errors.txt') }
            }
            Flush-File (Join-Path $OutputRoot 'sessions.txt')
        } catch { "$stamp $_" | Add-Content (Join-Path $OutputRoot 'errors.txt') }
        if (-not (Test-Path -LiteralPath (Join-Path $OutputRoot 'READY.txt')) -and (Test-Path -LiteralPath (Join-Path $OutputRoot 'load.csv'))) {
            Save-Text 'READY.txt' "Baseline and load sample saved at $([datetime]::UtcNow.ToString('o')). SYSTEM collector running; RDP may be disconnected."
        }
        Save-Text 'heartbeat.json' ([pscustomobject]@{TimeUTC=[datetime]::UtcNow.ToString('o');Stage='sample-complete'} | ConvertTo-Json -Compress)
        if ((Get-Date) -ge $nextEvents) { Events 'checkpoint'; $nextEvents=(Get-Date).AddSeconds($EventSeconds) }
        Start-Sleep -Seconds $SampleSeconds
    } while ((Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $OutputRoot 'STOP')))
    Capture 'services-end.txt' { Get-CimInstance Win32_Service | Select-Object Name,State,StartMode,ProcessId | Format-Table }
    Events 'end'
    Package-Report 'Normal completion or STOP request.'
    $succeeded=$true
} catch { $_ | Out-String | Add-Content (Join-Path $OutputRoot 'errors.txt') }
finally {
    if ($succeeded -and $TaskName -like 'WindowsSupportDiag-*') {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
        catch { "Task cleanup: $_" | Add-Content (Join-Path $OutputRoot 'errors.txt') }
    }
}
if (-not $succeeded) { exit 1 }
