[CmdletBinding()]
param(
    [string]$ScopeAddress = "192.168.10.111",
    [int]$ScopePort = 5555,
    [ValidateRange(10, 300)][int]$DurationSeconds = 120,
    [string]$OutputCsv = "captures/internal_rf_phase_att_matrix_20260729/rail_monitor.csv"
)

$ErrorActionPreference = "Stop"
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$scope = [Net.Sockets.TcpClient]::new()
$stream = $null
$rows = [Collections.Generic.List[object]]::new()

function Send-Scpi {
    param([Parameter(Mandatory = $true)][string]$Command)
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Command`n")
    $stream.Write($bytes, 0, $bytes.Length)
}

function Read-ScopeLine {
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw "MHO98 closed the connection." }
        if ($value -eq 10) { break }
        if ($value -ne 13) { $bytes.Add([byte]$value) }
    }
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray()).Trim()
}

function Query-Scpi {
    param([Parameter(Mandatory = $true)][string]$Command)
    Send-Scpi $Command
    return Read-ScopeLine
}

function Get-ScopeNumber {
    param([Parameter(Mandatory = $true)][string]$Command)
    return [double]::Parse((Query-Scpi $Command), $Invariant)
}

try {
    $directory = Split-Path -Parent $OutputCsv
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $scope.Connect($ScopeAddress, $ScopePort)
    $stream = $scope.GetStream()
    $stream.ReadTimeout = 3000
    $stream.WriteTimeout = 3000
    Write-Host "MHO98: $(Query-Scpi '*IDN?')"

    foreach ($channel in 1, 2) {
        Send-Scpi ":CHAN$channel`:DISP ON"
        Send-Scpi ":CHAN$channel`:PROB 10"
        Send-Scpi ":CHAN$channel`:COUP DC"
        Send-Scpi ":CHAN$channel`:SCAL 1"
        Send-Scpi ":CHAN$channel`:OFFS 0"
    }
    Send-Scpi ":TIM:MAIN:SCAL 0.001"
    Send-Scpi ":TRIG:SWE AUTO"
    Send-Scpi ":RUN"

    $started = [DateTimeOffset]::Now
    $stopAt = $started.AddSeconds($DurationSeconds)
    $index = 0
    while ([DateTimeOffset]::Now -lt $stopAt) {
        ++$index
        $rows.Add([pscustomobject]@{
            timestamp = [DateTimeOffset]::Now.ToString("o")
            elapsed_s = ([DateTimeOffset]::Now - $started).TotalSeconds
            plus_vavg_v = Get-ScopeNumber ":MEAS:ITEM? VAVG,CHAN1"
            minus_vavg_v = Get-ScopeNumber ":MEAS:ITEM? VAVG,CHAN2"
        })
        Start-Sleep -Milliseconds 300
    }
}
finally {
    if ($null -ne $stream) {
        try { Send-Scpi ":STOP" } catch {}
        $stream.Dispose()
    }
    $scope.Dispose()
    $rows | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding utf8
    Write-Host "Saved $OutputCsv ($($rows.Count) samples)"
}
