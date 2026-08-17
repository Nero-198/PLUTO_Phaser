[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(3, 30)][int]$HoldSeconds = 10,
    [ValidateRange(1, 10)][int]$ContrastCycles = 2,
    [switch]$BothChannels,
    [string]$StateFile = 'tmp/att2_demo_state.json',
    [string]$StopFile = 'tmp/att2_demo.stop',
    [string]$LogFile = 'captures/att2_demo_log.csv'
)

$ErrorActionPreference = 'Stop'
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$serial.NewLine = "`n"
$rfActive = $false
$logRows = [System.Collections.Generic.List[object]]::new()

function Read-RfLine {
    while ($true) {
        $line = $serial.ReadLine().Trim()
        if ($line -like 'READY RF_FRONTEND*') { continue }
        return $line
    }
}

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$ExpectedPattern
    )

    $serial.Write("$Command`n")
    $line = Read-RfLine
    if ($line -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $line"
    }
    return $line
}

function Write-DemoState {
    param(
        [Parameter(Mandatory)][string]$Status,
        [double]$AttenuationDb,
        [int]$RemainingSeconds,
        [string]$Label
    )

    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        status = $Status
        label = $Label
        attenuation_db = $AttenuationDb
        remaining_seconds = $RemainingSeconds
        lna1 = if ($Status -eq 'running' -and $BothChannels) { 'ON' } else { 'OFF' }
        lna2 = if ($Status -eq 'running') { 'ON' } else { 'OFF' }
        expected_observation = if ($AttenuationDb -eq 0.0) {
            if ($BothChannels) {
                'CH1/CH2 RF levels should be highest'
            }
            else {
                'CH2 RF level should be highest'
            }
        }
        elseif ($AttenuationDb -eq 31.5) {
            if ($BothChannels) {
                'CH1/CH2 RF levels should be lowest'
            }
            else {
                'CH2 RF level should be lowest'
            }
        }
        else {
            if ($BothChannels) {
                'CH1/CH2 RF levels should follow the attenuation step'
            }
            else {
                'CH2 RF level should follow the attenuation step'
            }
        }
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile
}

function Hold-Attenuation {
    param(
        [Parameter(Mandatory)][double]$AttenuationDb,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$StepIndex,
        [Parameter(Mandatory)][int]$StepCount
    )

    $attenuation = $AttenuationDb.ToString(
        '0.0', [Globalization.CultureInfo]::InvariantCulture)
    $channelTarget = if ($BothChannels) { 'ALL' } else { '2' }
    $channelLabel = if ($BothChannels) { 'ATT1/2' } else { 'ATT2' }
    Invoke-RfCommand "ATT $channelTarget $attenuation" '^OK$' | Out-Null
    $startedAt = Get-Date
    $logRows.Add([pscustomobject]@{
        timestamp = $startedAt.ToString('o')
        step = $StepIndex
        label = $Label
        attenuation_db = $AttenuationDb
        lna1 = if ($BothChannels) { 'ON' } else { 'OFF' }
        lna2 = 'ON'
    })

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Cyan
    Write-Host ("STEP {0}/{1}: {2}" -f $StepIndex, $StepCount, $Label) `
        -ForegroundColor Cyan
    $lnaLabel = if ($BothChannels) { 'LNA1/2=ON' } else { 'LNA2=ON' }
    Write-Host ("{0}={1} dB, {2}" -f $channelLabel, $attenuation, $lnaLabel) `
        -ForegroundColor Yellow
    if ($AttenuationDb -eq 0.0) {
        Write-Host 'EXPECT: CH2 RF LEVEL HIGH' -ForegroundColor Green
    }
    elseif ($AttenuationDb -eq 31.5) {
        Write-Host 'EXPECT: CH2 RF LEVEL LOW' -ForegroundColor Magenta
    }
    else {
        Write-Host 'EXPECT: intermediate CH2 RF level'
    }
    Write-Host ('=' * 68) -ForegroundColor Cyan

    for ($remaining = $HoldSeconds; $remaining -gt 0; --$remaining) {
        if (Test-Path -LiteralPath $StopFile) {
            throw 'ATT2 demo stopped by request.'
        }
        Write-DemoState 'running' $AttenuationDb $remaining $Label
        Write-Host ("  remaining {0,2} s" -f $remaining)
        Start-Sleep -Milliseconds 500
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
        Start-Sleep -Milliseconds 500
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    }
}

try {
    $stateDirectory = Split-Path -Parent $StateFile
    $logDirectory = Split-Path -Parent $LogFile
    if ($stateDirectory) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    if ($logDirectory) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and
        $status -match 'SOURCE=EXTERNAL'
    if ($status -notmatch 'FAULT=NONE' -or
        (-not $offState -and -not $externalSafe)) {
        throw "Expected safe OFF state with no fault: $status"
    }

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' |
        Out-Null
    $rfActive = $true
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    if ($BothChannels) {
        Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null
    }
    else {
        Invoke-RfCommand 'LNA 2 ON' '^OK$' | Out-Null
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    for ($cycle = 1; $cycle -le $ContrastCycles; ++$cycle) {
        $steps.Add([pscustomobject]@{
            attenuation_db = 31.5
            label = "CONTRAST $cycle LOW RF"
        })
        $steps.Add([pscustomobject]@{
            attenuation_db = 0.0
            label = "CONTRAST $cycle HIGH RF"
        })
    }
    foreach ($attenuation in @(31.5, 24.0, 16.0, 8.0, 0.0,
                               8.0, 16.0, 24.0, 31.5)) {
        $steps.Add([pscustomobject]@{
            attenuation_db = $attenuation
            label = 'STAIRCASE'
        })
    }

    for ($index = 0; $index -lt $steps.Count; ++$index) {
        Hold-Attenuation `
            -AttenuationDb $steps[$index].attenuation_db `
            -Label $steps[$index].label `
            -StepIndex ($index + 1) `
            -StepCount $steps.Count
    }

    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
        Out-Null
    $rfActive = $false
    Write-DemoState 'complete' 31.5 0 'SAFE'
    Write-Host ''
    Write-Host 'Demo complete; ATT1/2=31.5 dB, LNA1/2=OFF, EXTERNAL_SAFE.' `
        -ForegroundColor Green
}
finally {
    if ($logRows.Count -gt 0) {
        $logRows | Export-Csv -LiteralPath $LogFile -NoTypeInformation
    }
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-DemoState 'stopped' 31.5 0 'SAFE'
            Write-Warning 'SAFE sent during cleanup; external rails remain applied.'
        }
        catch {
            Write-Warning "Could not send SAFE: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
