[CmdletBinding()]
param(
    [string]$PortName = "COM4",
    [string]$ScopeAddress = "192.168.10.111",
    [int]$ScopePort = 5555,
    [ValidateRange(3, 120)][int]$HoldSeconds = 15,
    [string]$OutputDirectory = "captures/internal_power_lna_load_20260729"
)

$ErrorActionPreference = "Stop"
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.NewLine = "`n"
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$scope = [Net.Sockets.TcpClient]::new()
$scopeStream = $null
$rfActive = $false
$measurements = [Collections.Generic.List[object]]::new()

function Read-RfLine {
    while ($true) {
        $line = $serial.ReadLine().Trim()
        if ($line -like "READY RF_FRONTEND*") { continue }
        return $line
    }
}

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern
    )

    Write-Host "> $Command"
    $serial.Write("$Command`n")
    $line = Read-RfLine
    Write-Host "< $line"
    if ($line -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $line"
    }
    return $line
}

function Send-Scpi {
    param([Parameter(Mandatory = $true)][string]$Command)
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Command`n")
    $scopeStream.Write($bytes, 0, $bytes.Length)
}

function Read-ScopeLine {
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $scopeStream.ReadByte()
        if ($value -lt 0) { throw "MHO98 closed the SCPI connection." }
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

function Read-ExactBytes {
    param([Parameter(Mandatory = $true)][int]$Count)
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $scopeStream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw "MHO98 closed during binary transfer." }
        $offset += $read
    }
    return $buffer
}

function Save-ScopePng {
    param([Parameter(Mandatory = $true)][string]$Path)
    Send-Scpi ":DISP:DATA? PNG"
    $marker = Read-ExactBytes 1
    if ($marker[0] -ne [byte][char]"#") {
        throw "Unexpected screenshot marker: $($marker[0])"
    }
    $digitBytes = Read-ExactBytes 1
    $digitCount = [int][char]$digitBytes[0] - [int][char]"0"
    $lengthBytes = Read-ExactBytes $digitCount
    $length = [int]([Text.Encoding]::ASCII.GetString($lengthBytes))
    $png = Read-ExactBytes $length
    [IO.File]::WriteAllBytes($Path, $png)
    if ($scopeStream.ReadByte() -ne 10) {
        throw "Unexpected screenshot terminator."
    }
    Write-Host "Saved $Path"
}

function Get-ScopeNumber {
    param([Parameter(Mandatory = $true)][string]$Command)
    return [double]::Parse((Query-Scpi $Command), $Invariant)
}

function Start-ScopeWindow {
    param([double]$TimeScaleSeconds = 0.01)
    Send-Scpi ":STOP"
    Send-Scpi ":TIM:MAIN:SCAL $($TimeScaleSeconds.ToString('G17', $Invariant))"
    Send-Scpi ":TIM:MAIN:OFFS 0"
    Send-Scpi ":TRIG:SWE AUTO"
    Send-Scpi ":RUN"
}

function Get-RailMeasurement {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][int]$Index
    )

    Invoke-RfCommand "KEEPALIVE" "^OK KEEPALIVE$" | Out-Null
    Start-ScopeWindow 0.001
    Start-Sleep -Milliseconds 350
    Send-Scpi ":STOP"
    $row = [pscustomobject]@{
        timestamp = [DateTimeOffset]::Now.ToString("o")
        state = $State
        index = $Index
        plus_vavg_v = Get-ScopeNumber ":MEAS:ITEM? VAVG,CHAN1"
        plus_vmin_v = Get-ScopeNumber ":MEAS:ITEM? VMIN,CHAN1"
        plus_vmax_v = Get-ScopeNumber ":MEAS:ITEM? VMAX,CHAN1"
        minus_vavg_v = Get-ScopeNumber ":MEAS:ITEM? VAVG,CHAN2"
        minus_vmin_v = Get-ScopeNumber ":MEAS:ITEM? VMIN,CHAN2"
        minus_vmax_v = Get-ScopeNumber ":MEAS:ITEM? VMAX,CHAN2"
    }
    $measurements.Add($row)
    Invoke-RfCommand "KEEPALIVE" "^OK KEEPALIVE$" | Out-Null
    Write-Host (
        "{0} +V={1:F4} V -V={2:F4} V" -f
        $State, $row.plus_vavg_v, $row.minus_vavg_v
    )
    return $row
}

function Set-ProbeRatio {
    param(
        [ValidateSet(1, 2)][int]$Channel,
        [Parameter(Mandatory = $true)][double]$Ratio
    )
    Send-Scpi ":CHAN$Channel`:PROB $($Ratio.ToString('G17', $Invariant))"
    # Changing the probe ratio scales the displayed volts/div on the MHO98.
    # Restore 1 V/div in actual probe-tip units for adequate rail resolution.
    Send-Scpi ":CHAN$Channel`:SCAL 1"
    Send-Scpi ":CHAN$Channel`:OFFS 0"
    Start-Sleep -Milliseconds 150
}

function Correct-ProbeRatioIfNeeded {
    param(
        [ValidateSet(1, 2)][int]$Channel,
        [Parameter(Mandatory = $true)][double]$MeasuredVoltage,
        [Parameter(Mandatory = $true)][double]$ExpectedMagnitude
    )

    $magnitude = [Math]::Abs($MeasuredVoltage)
    $ratio = Get-ScopeNumber ":CHAN$Channel`:PROB?"
    if ($magnitude -ge 2.8 -and $magnitude -le 3.6) {
        return $false
    }
    if ($magnitude -ge 0.28 -and $magnitude -le 0.36) {
        $newRatio = $ratio * 10.0
        Write-Warning "CH$Channel probe ratio corrected: $ratio -> $newRatio"
        Set-ProbeRatio $Channel $newRatio
        return $true
    }
    throw "CH$Channel rail is outside the recognizable range: $MeasuredVoltage V"
}

try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

    $scope.Connect($ScopeAddress, $ScopePort)
    $scopeStream = $scope.GetStream()
    $scopeStream.ReadTimeout = 4000
    $scopeStream.WriteTimeout = 4000
    Write-Host "MHO98: $(Query-Scpi '*IDN?')"

    foreach ($channel in 1, 2) {
        Send-Scpi ":CHAN$channel`:DISP ON"
        Send-Scpi ":CHAN$channel`:COUP DC"
        Send-Scpi ":CHAN$channel`:SCAL 1"
        Send-Scpi ":CHAN$channel`:OFFS 0"
    }
    foreach ($channel in 3, 4) {
        Send-Scpi ":CHAN$channel`:DISP OFF"
    }

    $serial.Open()
    Start-Sleep -Milliseconds 500
    $serial.DiscardInBuffer()
    $status = Invoke-RfCommand "STATUS" "^OK "
    if ($status -notmatch "STATE=OFF" -or
        $status -notmatch "SOURCE=NONE" -or
        $status -notmatch "FAULT=NONE") {
        throw "Expected safe OFF state before test: $status"
    }

    Invoke-RfCommand "POWER ON" "^OK POWER=ON SOURCE=INTERNAL$" | Out-Null
    $rfActive = $true
    Invoke-RfCommand "ATT ALL 31.5" "^OK$" | Out-Null
    Invoke-RfCommand "PHASE ALL 0" "^OK$" | Out-Null
    Invoke-RfCommand "LNA ALL OFF" "^OK$" | Out-Null

    $baseline = Get-RailMeasurement "LNA_OFF" 0
    $probeChanged = Correct-ProbeRatioIfNeeded 1 $baseline.plus_vavg_v 3.3
    $probeChanged = (Correct-ProbeRatioIfNeeded 2 $baseline.minus_vavg_v 3.3) -or
        $probeChanged
    if ($probeChanged) {
        $baseline = Get-RailMeasurement "LNA_OFF_PROBE_CORRECTED" 0
    }
    if ($baseline.plus_vavg_v -lt 2.8 -or $baseline.plus_vavg_v -gt 3.6) {
        throw "Positive rail is out of range before LNA load: $($baseline.plus_vavg_v) V"
    }
    if ($baseline.minus_vavg_v -gt -2.8 -or $baseline.minus_vavg_v -lt -3.6) {
        throw "Negative rail is out of range before LNA load: $($baseline.minus_vavg_v) V"
    }

    Start-ScopeWindow 0.01
    Start-Sleep -Milliseconds 150
    Invoke-RfCommand "LNA ALL ON" "^OK$" | Out-Null
    Start-Sleep -Milliseconds 100
    Invoke-RfCommand "KEEPALIVE" "^OK KEEPALIVE$" | Out-Null
    Send-Scpi ":STOP"
    Save-ScopePng (Join-Path $OutputDirectory "01_lna_all_on_transition.png")

    for ($index = 1; $index -le $HoldSeconds; $index++) {
        $row = Get-RailMeasurement "LNA_ALL_ON" $index
        if ($row.plus_vavg_v -lt 2.8 -or $row.plus_vavg_v -gt 3.6) {
            throw "Positive rail left safe range under load: $($row.plus_vavg_v) V"
        }
        if ($row.minus_vavg_v -gt -2.8 -or $row.minus_vavg_v -lt -3.6) {
            throw "Negative rail left safe range under load: $($row.minus_vavg_v) V"
        }
        Start-Sleep -Milliseconds 250
    }

    Start-ScopeWindow 0.01
    Start-Sleep -Milliseconds 150
    Invoke-RfCommand "LNA ALL OFF" "^OK$" | Out-Null
    Start-Sleep -Milliseconds 100
    Invoke-RfCommand "KEEPALIVE" "^OK KEEPALIVE$" | Out-Null
    Send-Scpi ":STOP"
    Save-ScopePng (Join-Path $OutputDirectory "02_lna_all_off_transition.png")
    Get-RailMeasurement "LNA_OFF_AFTER_LOAD" 0 | Out-Null

    Send-Scpi ":STOP"
    Send-Scpi ":TIM:MAIN:SCAL 0.01"
    Send-Scpi ":TIM:MAIN:OFFS 0"
    Send-Scpi ":TRIG:MODE EDGE"
    Send-Scpi ":TRIG:EDGE:SOUR CHAN1"
    Send-Scpi ":TRIG:EDGE:SLOP NEG"
    Send-Scpi ":TRIG:EDGE:LEV 1.5"
    Send-Scpi ":TRIG:SWE SING"
    Send-Scpi ":SING"
    Start-Sleep -Milliseconds 100
    Invoke-RfCommand "SAFE" "^OK SAFE$" | Out-Null
    $rfActive = $false
    Start-Sleep -Milliseconds 300
    Send-Scpi ":STOP"
    Save-ScopePng (Join-Path $OutputDirectory "03_safe_power_off.png")

    $status = Invoke-RfCommand "STATUS" "^OK "
    if ($status -notmatch "STATE=OFF" -or
        $status -notmatch "SOURCE=NONE" -or
        $status -notmatch "FAULT=NONE" -or
        $status -notmatch "CH1_LNA=OFF" -or
        $status -notmatch "CH2_LNA=OFF") {
        throw "Unexpected final state: $status"
    }

    $measurements |
        Export-Csv -LiteralPath (Join-Path $OutputDirectory "rail_measurements.csv") `
            -NoTypeInformation -Encoding utf8
    [pscustomobject]@{
        scope = Query-Scpi "*IDN?"
        channel_1_probe_ratio = Get-ScopeNumber ":CHAN1:PROB?"
        channel_2_probe_ratio = Get-ScopeNumber ":CHAN2:PROB?"
        hold_seconds = $HoldSeconds
        final_frontend_status = $status
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $OutputDirectory "test_setup.json") `
            -Encoding utf8

    Write-Host "LNA load validation completed safely: $OutputDirectory"
}
finally {
    if ($serial.IsOpen) {
        if ($rfActive) {
            try {
                $serial.Write("SAFE`n")
                Start-Sleep -Milliseconds 100
                Write-Warning "SAFE sent during cleanup."
            }
            catch {
                Write-Warning "Could not send SAFE: $($_.Exception.Message)"
            }
        }
        $serial.Close()
    }
    $serial.Dispose()
    if ($null -ne $scopeStream) { $scopeStream.Dispose() }
    $scope.Dispose()
}
