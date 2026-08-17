[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$ScopeAddress = '192.168.10.111',
    [int]$ScopePort = 5555,
    [string]$OutputDirectory = 'captures/mho98_validation_20260716',
    [switch]$AttOnly,
    [switch]$PhaseOnly,
    [switch]$AttOutputPins,
    [switch]$AttOutputStatic,
    [switch]$HideAnalogChannels,
    [switch]$ScreenshotOnly,
    [string]$ScreenshotFileName = 'screen.png',
    [ValidateRange(0.0, 1.0)][double]$ScreenshotTimeScaleSeconds = 0.0,
    [string]$ScreenshotTriggerSource = '',
    [ValidateRange(0, 4)][int]$ConfigureAnalogChannel = 0
)

$ErrorActionPreference = 'Stop'

$serial = [System.IO.Ports.SerialPort]::new(
    $PortName,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2000
$serial.WriteTimeout = 2000
$serial.NewLine = "`n"

$scope = [System.Net.Sockets.TcpClient]::new()
$scopeStream = $null
$rfActive = $false

function Read-RfLine {
    while ($true) {
        $line = $serial.ReadLine().Trim()
        if ($line -like 'READY RF_FRONTEND*') {
            continue
        }
        return $line
    }
}

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$ExpectedPattern
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
    param([Parameter(Mandatory)][string]$Command)

    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$Command`n")
    $scopeStream.Write($bytes, 0, $bytes.Length)
}

function Read-ScopeLine {
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $scopeStream.ReadByte()
        if ($value -lt 0) {
            throw 'MHO98 closed the SCPI connection.'
        }
        if ($value -eq 10) {
            break
        }
        if ($value -ne 13) {
            $bytes.Add([byte]$value)
        }
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray()).Trim()
}

function Query-Scpi {
    param([Parameter(Mandatory)][string]$Command)

    Send-Scpi $Command
    return Read-ScopeLine
}

function Read-ExactBytes {
    param([Parameter(Mandatory)][int]$Count)

    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $scopeStream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) {
            throw 'MHO98 closed the connection during binary transfer.'
        }
        $offset += $read
    }
    return $buffer
}

function Save-ScopePng {
    param([Parameter(Mandatory)][string]$Path)

    Send-Scpi ':DISP:DATA? PNG'
    $marker = Read-ExactBytes 1
    if ($marker[0] -ne [byte][char]'#') {
        throw "Unexpected screenshot header marker: $($marker[0])"
    }
    $digitByte = Read-ExactBytes 1
    $digitCount = [int][char]$digitByte[0] - [int][char]'0'
    if ($digitCount -lt 1 -or $digitCount -gt 9) {
        throw "Unexpected screenshot length field: $digitCount"
    }
    $lengthBytes = Read-ExactBytes $digitCount
    $length = [int]([System.Text.Encoding]::ASCII.GetString($lengthBytes))
    $png = Read-ExactBytes $length
    [System.IO.File]::WriteAllBytes($Path, $png)

    # RIGOL terminates the IEEE 488.2 binary block with LF.
    $terminator = $scopeStream.ReadByte()
    if ($terminator -ne 10) {
        throw "Unexpected screenshot terminator: $terminator"
    }
    Write-Host "Saved $Path ($length bytes)"
}

function Arm-DigitalEdge {
    param(
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('POS', 'NEG')][string]$Slope = 'POS',
        [Parameter(Mandatory)][double]$TimeScaleSeconds
    )

    Send-Scpi ':STOP'
    Send-Scpi ":TIM:MAIN:SCAL $($TimeScaleSeconds.ToString('G17', [Globalization.CultureInfo]::InvariantCulture))"
    Send-Scpi ':TIM:MAIN:OFFS 0'
    Send-Scpi ':TRIG:MODE EDGE'
    Send-Scpi ":TRIG:EDGE:SOUR $Source"
    Send-Scpi ":TRIG:EDGE:SLOP $Slope"
    Send-Scpi ':TRIG:EDGE:LEV 1.65'
    Send-Scpi ':TRIG:SWE SING'
    Send-Scpi ':SING'
    Start-Sleep -Milliseconds 80
    $status = Query-Scpi ':TRIG:STAT?'
    Write-Host "MHO98 armed: source=$Source slope=$Slope status=$status"
}

function Wait-DigitalCapture {
    param([int]$TimeoutMs = 1500)

    $deadline = [Environment]::TickCount64 + $TimeoutMs
    $nextKeepalive = [Environment]::TickCount64 + 500
    while ([Environment]::TickCount64 -lt $deadline) {
        $status = Query-Scpi ':TRIG:STAT?'
        if ($status -eq 'STOP') {
            Write-Host 'MHO98 trigger captured.'
            return
        }
        if ($rfActive -and [Environment]::TickCount64 -ge $nextKeepalive) {
            Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
            $nextKeepalive = [Environment]::TickCount64 + 500
        }
        Start-Sleep -Milliseconds 50
    }
    throw "MHO98 trigger did not fire within $TimeoutMs ms."
}

function Capture-RfCommand {
    param(
        [Parameter(Mandatory)][string]$TriggerSource,
        [ValidateSet('POS', 'NEG')][string]$TriggerSlope = 'POS',
        [Parameter(Mandatory)][double]$TimeScaleSeconds,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$ExpectedPattern,
        [Parameter(Mandatory)][string]$FileName
    )

    Arm-DigitalEdge $TriggerSource $TriggerSlope $TimeScaleSeconds
    Invoke-RfCommand $Command $ExpectedPattern | Out-Null
    Wait-DigitalCapture
    Save-ScopePng (Join-Path $OutputDirectory $FileName)
    if ($rfActive) {
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    }
}

try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path $OutputDirectory).Path

    $scope.Connect($ScopeAddress, $ScopePort)
    $scopeStream = $scope.GetStream()
    $scopeStream.ReadTimeout = 3000
    $scopeStream.WriteTimeout = 3000
    Write-Host "MHO98: $(Query-Scpi '*IDN?')"

    if ($HideAnalogChannels) {
        foreach ($channel in 1..4) {
            Send-Scpi ":CHANnel$channel`:DISPlay OFF"
        }
    }
    if ($ConfigureAnalogChannel -ne 0) {
        Send-Scpi ":CHANnel$ConfigureAnalogChannel`:DISPlay ON"
        Send-Scpi ":CHANnel$ConfigureAnalogChannel`:COUPling DC"
        Send-Scpi ":CHANnel$ConfigureAnalogChannel`:SCALe 1"
        Send-Scpi ":CHANnel$ConfigureAnalogChannel`:OFFSet 0"
    }
    if ($ScreenshotOnly) {
        if ($ScreenshotTimeScaleSeconds -gt 0.0) {
            Send-Scpi ':STOP'
            Send-Scpi ":TIM:MAIN:SCAL $($ScreenshotTimeScaleSeconds.ToString(
                'G17', [Globalization.CultureInfo]::InvariantCulture))"
            Send-Scpi ':TIM:MAIN:OFFS 0'
        }
        if ($ScreenshotTriggerSource) {
            Send-Scpi ':TRIG:MODE EDGE'
            Send-Scpi ":TRIG:EDGE:SOUR $ScreenshotTriggerSource"
            Send-Scpi ':TRIG:EDGE:SLOP POS'
            Send-Scpi ':TRIG:EDGE:LEV 1.65'
            Send-Scpi ':TRIG:SWE AUTO'
            Send-Scpi ':RUN'
            Start-Sleep -Milliseconds 1500
            Send-Scpi ':STOP'
        }
        Save-ScopePng (Join-Path $OutputDirectory $ScreenshotFileName)
        return
    }

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and
        $status -match 'SOURCE=EXTERNAL'
    if ($status -notmatch 'FAULT=NONE' -or (-not $offState -and -not $externalSafe)) {
        throw "Expected safe OFF state with no fault before capture: $status"
    }

    if ($PhaseOnly) {
        Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' |
            Out-Null
        $rfActive = $true
        Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
        Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null

        Capture-RfCommand 'D10' 'POS' 0.00001 `
            'PHASE ALL 0' '^OK$' '01_phase_all_0.png'
        Capture-RfCommand 'D10' 'POS' 0.00001 `
            'PHASE 1 90' '^OK$' '02_phase_ch1_90.png'
        Capture-RfCommand 'D10' 'POS' 0.00001 `
            'PHASE 2 90' '^OK$' '03_phase_ch2_90.png'
        Invoke-RfCommand 'PHASE 2 337.5' '^OK$' | Out-Null
        Capture-RfCommand 'D10' 'POS' 0.00001 `
            'PHASE 1 22.5' '^OK$' '04_phase_f04.png'

        Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
        Capture-RfCommand 'D9' 'POS' 0.00002 `
            'PHASE 1 90' '^OK$' '05_phase_le_d9.png'
        Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
        Capture-RfCommand 'D11' 'POS' 0.00002 `
            'PHASE 2 337.5' '^OK$' '06_phase_ser_d11.png'

        Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
        Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
        Invoke-RfCommand 'POWER OFF' `
            '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
        $rfActive = $false
        Write-Host 'Focused MAPS D9/D10/D11 capture sequence completed safely.'
        return
    }

    if ($AttOutputStatic) {
        Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
        $rfActive = $true
        Send-Scpi ':TIM:MAIN:SCAL 0.001'
        Send-Scpi ':TIM:MAIN:OFFS 0'
        Send-Scpi ':TRIG:SWE AUTO'

        Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
        Invoke-RfCommand 'ATT 1 0.5' '^OK$' | Out-Null
        Send-Scpi ':RUN'
        Start-Sleep -Milliseconds 150
        Send-Scpi ':STOP'
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
        Save-ScopePng (Join-Path $OutputDirectory '01_att1_0p5_att2_0.png')
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null

        Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
        Invoke-RfCommand 'ATT 2 0.5' '^OK$' | Out-Null
        Send-Scpi ':RUN'
        Start-Sleep -Milliseconds 150
        Send-Scpi ':STOP'
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
        Save-ScopePng (Join-Path $OutputDirectory '02_att1_0_att2_0p5.png')
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null

        Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
        Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
        $rfActive = $false
        Write-Host 'Static ATT QC output captures completed safely.'
        return
    }

    # Startup: ATT safe word followed by MAPS safe word.
    Arm-DigitalEdge 'D3' 'POS' 0.00004
    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
    $rfActive = $true
    Wait-DigitalCapture
    Save-ScopePng (Join-Path $OutputDirectory '01_startup_d3_full.png')
    Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null

    if ($AttOutputPins) {
        Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
        Capture-RfCommand 'D3' 'POS' 0.0001 'ATT 1 0.5' '^OK$' `
            '02_att1_qc_level.png'
        Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
        Capture-RfCommand 'D3' 'POS' 0.0001 'ATT 2 0.5' '^OK$' `
            '03_att2_qc_level.png'
        Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
        return
    }

    # ATT chain: [ch2, ch1], MSB first.
    Capture-RfCommand 'D3' 'POS' 0.00001 'ATT 1 0.5' '^OK$' '02_att_fc04.png'
    Invoke-RfCommand 'ATT 1 31.5' '^OK$' | Out-Null
    Capture-RfCommand 'D3' 'POS' 0.00001 'ATT 2 0.5' '^OK$' '03_att_04fc.png'
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null

    if ($AttOnly) {
        return
    }

    # MAPS chain: ch2=337.5 degrees (111100), ch1=22.5 degrees (000100).
    Invoke-RfCommand 'PHASE 2 337.5' '^OK$' | Out-Null
    Capture-RfCommand 'D10' 'POS' 0.00001 'PHASE 1 22.5' '^OK$' '04_phase_f04.png'
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null

    # LNA enables, one channel at a time.
    Capture-RfCommand 'D14' 'POS' 0.0001 'LNA 1 ON' '^OK$' '05_lna_ch1_on.png'
    Invoke-RfCommand 'LNA 1 OFF' '^OK$' | Out-Null
    Capture-RfCommand 'D15' 'POS' 0.0001 'LNA 2 ON' '^OK$' '06_lna_ch2_on.png'
    Invoke-RfCommand 'LNA 2 OFF' '^OK$' | Out-Null

    # Safe shutdown: LNA falls before ATT max and MAPS zero writes.
    Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null
    Arm-DigitalEdge 'D3' 'POS' 0.00004
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
    $rfActive = $false
    Wait-DigitalCapture
    Save-ScopePng (Join-Path $OutputDirectory '07_safe_shutdown.png')

    $status = Invoke-RfCommand 'STATUS' '^OK '
    if ($status -notmatch 'STATE=EXTERNAL_SAFE' -or
        $status -notmatch 'POWER=OFF' -or
        $status -notmatch 'SOURCE=EXTERNAL' -or
        $status -notmatch 'FAULT=NONE' -or
        $status -notmatch 'CH1_LNA=OFF' -or
        $status -notmatch 'CH2_LNA=OFF') {
        throw "Unexpected final safe state: $status"
    }
    Write-Host 'Digital validation capture sequence completed safely.'
}
finally {
    if ($serial.IsOpen) {
        if ($rfActive) {
            try {
                $serial.Write("SAFE`n")
                Start-Sleep -Milliseconds 100
                Write-Warning 'SAFE was sent during cleanup; external rails remain physically applied.'
            }
            catch {
                Write-Warning "Could not send SAFE during cleanup: $($_.Exception.Message)"
            }
        }
        $serial.Close()
    }
    $serial.Dispose()
    if ($null -ne $scopeStream) {
        $scopeStream.Dispose()
    }
    $scope.Dispose()
}
