[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$PlutoUri = 'ip:192.168.2.1',
    [string]$LibiioDirectory = 'tmp/libiio-v0.26/Windows-VS-2022-x64',
    [string]$OutputDirectory = 'captures/pluto_dual_passband_20260727',
    [ValidateRange(325, 6000)][double]$StartFrequencyMHz = 2000.0,
    [ValidateRange(325, 6000)][double]$StopFrequencyMHz = 2600.0,
    [ValidateRange(1, 500)][double]$StepFrequencyMHz = 25.0,
    [ValidateRange(-3, 71)][int]$RxGainDb = 20,
    [ValidateRange(-89, 0)][double]$TxGainDb = -10.0,
    [ValidateRange(0.0, 1.0)][double]$DdsScale = 0.25,
    [ValidateRange(4096, 262144)][int]$SampleCount = 16384,
    [ValidateRange(0.0, 31.5)][double]$FrontendAttenuationDb = 0.0
)

$ErrorActionPreference = 'Stop'
if ($StopFrequencyMHz -lt $StartFrequencyMHz) {
    throw 'StopFrequencyMHz must be greater than or equal to StartFrequencyMHz.'
}

$iioAttr = (Resolve-Path (Join-Path $LibiioDirectory 'iio_attr.exe')).Path
$iioReadDev = (Resolve-Path (Join-Path $LibiioDirectory 'iio_readdev.exe')).Path
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$serial.NewLine = "`n"
$rfActive = $false
$plutoStateSaved = $false

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

    Write-Host "> $Command"
    $serial.Write("$Command`n")
    $line = Read-RfLine
    Write-Host "< $line"
    if ($line -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $line"
    }
    return $line
}

function Get-IioAttribute {
    param(
        [ValidateSet('Input', 'Output')][string]$Direction,
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Attribute
    )

    $directionFlag = if ($Direction -eq 'Input') { '-i' } else { '-o' }
    $value = & $iioAttr -u $PlutoUri $directionFlag -c $Device $Channel $Attribute
    if ($LASTEXITCODE -ne 0) {
        throw "iio_attr read failed: $Device/$Channel/$Attribute"
    }
    return ($value | Select-Object -Last 1).Trim()
}

function Set-IioAttribute {
    param(
        [ValidateSet('Input', 'Output')][string]$Direction,
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Attribute,
        [Parameter(Mandatory)][string]$Value
    )

    $directionFlag = if ($Direction -eq 'Input') { '-i' } else { '-o' }
    & $iioAttr -u $PlutoUri $directionFlag -c $Device $Channel $Attribute $Value |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "iio_attr write failed: $Device/$Channel/$Attribute=$Value"
    }
}

function Save-IioCapture {
    param([Parameter(Mandatory)][string]$Path)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $iioReadDev
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-u', $PlutoUri, '-T', '5000', '-b', '8192',
        '-s', [string]$SampleCount, 'cf-ad9361-lpc',
        'voltage0', 'voltage1', 'voltage2', 'voltage3'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start iio_readdev.' }
    $file = [IO.File]::Create($Path)
    try {
        $process.StandardOutput.BaseStream.CopyTo($file)
    }
    finally {
        $file.Dispose()
    }
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "iio_readdev failed ($($process.ExitCode)): $stderr"
    }
    $process.Dispose()

    $expectedBytes = $SampleCount * 8
    $actualBytes = (Get-Item -LiteralPath $Path).Length
    if ($actualBytes -ne $expectedBytes) {
        throw "Unexpected capture length: expected $expectedBytes, got $actualBytes"
    }
}

function Measure-Tone {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateSet(0, 1)][int]$Channel,
        [Parameter(Mandatory)][double]$ToneFrequencyHz,
        [Parameter(Mandatory)][double]$SampleRateHz
    )

    $count = [int]($Bytes.Length / 8)
    $offset = if ($Channel -eq 0) { 0 } else { 4 }
    $omega = 2.0 * [Math]::PI * $ToneFrequencyHz / $SampleRateHz
    $stepCos = [Math]::Cos(-$omega)
    $stepSin = [Math]::Sin(-$omega)
    $rotCos = 1.0
    $rotSin = 0.0
    $positiveReal = 0.0
    $positiveImag = 0.0
    $negativeReal = 0.0
    $negativeImag = 0.0
    $peak = 0
    $clipCount = 0

    for ($sample = 0; $sample -lt $count; ++$sample) {
        $base = $sample * 8 + $offset
        $i = [int][BitConverter]::ToInt16($Bytes, $base)
        $q = [int][BitConverter]::ToInt16($Bytes, $base + 2)
        $positiveReal += $i * $rotCos - $q * $rotSin
        $positiveImag += $i * $rotSin + $q * $rotCos
        $negativeReal += $i * $rotCos + $q * $rotSin
        $negativeImag += -$i * $rotSin + $q * $rotCos
        $absI = [Math]::Abs($i)
        $absQ = [Math]::Abs($q)
        $peak = [Math]::Max($peak, [Math]::Max($absI, $absQ))
        if ($absI -ge 2040 -or $absQ -ge 2040) { ++$clipCount }

        $nextCos = $rotCos * $stepCos - $rotSin * $stepSin
        $rotSin = $rotSin * $stepCos + $rotCos * $stepSin
        $rotCos = $nextCos
    }

    $positive = [Math]::Sqrt(
        $positiveReal * $positiveReal + $positiveImag * $positiveImag) / $count
    $negative = [Math]::Sqrt(
        $negativeReal * $negativeReal + $negativeImag * $negativeImag) / $count
    $amplitude = [Math]::Max($positive, $negative)
    $toneDbfs = if ($amplitude -gt 0.0) {
        20.0 * [Math]::Log10($amplitude / 2048.0)
    }
    else {
        -999.0
    }

    return [pscustomobject]@{
        tone_dbfs = [Math]::Round($toneDbfs, 3)
        peak_code = $peak
        clipped_samples = $clipCount
    }
}

try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path $OutputDirectory).Path

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and
        $status -match 'SOURCE=EXTERNAL'
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    if ($status -notmatch 'FAULT=NONE' -or
        (-not $externalSafe -and -not $offState)) {
        throw "Expected safe OFF state with no fault: $status"
    }

    $originalTxLo = Get-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency'
    $originalRxLo = Get-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency'
    $originalRx0Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode'
    $originalRx0Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalRx1Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode'
    $originalRx1Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain'
    $originalTxGain = Get-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalDds = [Collections.Generic.List[object]]::new()
    foreach ($channelIndex in 0..3) {
        $channelName = "altvoltage$channelIndex"
        $originalDds.Add([pscustomobject]@{
            channel = $channelName
            frequency = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'frequency'
            scale = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale'
            phase = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'phase'
            raw = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw'
        })
    }
    $ddsFrequency = [double](Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'frequency')
    $sampleRate = [double](Get-IioAttribute Input 'cf-ad9361-lpc' 'voltage0' 'sampling_frequency')
    $plutoStateSaved = $true

    $desiredIfHz = 1000000.0
    if ($ddsFrequency -le 0.0 -or $desiredIfHz -ge $sampleRate / 2.0) {
        throw "Unsupported DDS/sample-rate combination: DDS=$ddsFrequency Fs=$sampleRate"
    }

    Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' 'manual'
    Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' 'manual'
    Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' ([string]$RxGainDb)
    Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' ([string]$RxGainDb)
    Set-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain' (
        $TxGainDb.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))

    $ddsScaleText = $DdsScale.ToString(
        '0.000000', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($channelName in @('altvoltage1', 'altvoltage3')) {
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw' '0'
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale' '0.000000'
    }
    foreach ($channelName in @('altvoltage0', 'altvoltage2')) {
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'frequency' (
            [string][Math]::Round($ddsFrequency))
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale' $ddsScaleText
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw' '1'
    }
    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'phase' '90000'
    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage2' 'phase' '0'

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' |
        Out-Null
    $rfActive = $true
    $frontendAtt = $FrontendAttenuationDb.ToString(
        '0.0', [Globalization.CultureInfo]::InvariantCulture)
    Invoke-RfCommand "ATT ALL $frontendAtt" '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null

    $rows = [Collections.Generic.List[object]]::new()
    $pointCount = [int][Math]::Floor(
        ($StopFrequencyMHz - $StartFrequencyMHz) / $StepFrequencyMHz) + 1
    for ($index = 0; $index -lt $pointCount; ++$index) {
        $targetMHz = $StartFrequencyMHz + $index * $StepFrequencyMHz
        $targetRfHz = [Math]::Round($targetMHz * 1000000.0)
        $txLoHz = [Math]::Round($targetRfHz - $ddsFrequency)
        $rxLoHz = [Math]::Round($targetRfHz - $desiredIfHz)

        Set-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency' ([string]$txLoHz)
        Set-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency' ([string]$rxLoHz)
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
        Start-Sleep -Milliseconds 150

        $actualTxLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency')
        $actualRxLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency')
        $actualRfHz = $actualTxLo + $ddsFrequency
        $toneFrequencyHz = $actualRfHz - $actualRxLo
        if ([Math]::Abs($actualRfHz - $targetRfHz) -gt 10000.0 -or
            [Math]::Abs($toneFrequencyHz - $desiredIfHz) -gt 10000.0) {
            throw (
                'PLUTO LO readback mismatch; another application may be controlling it. ' +
                "targetRF=$targetRfHz actualRF=$actualRfHz IF=$toneFrequencyHz")
        }
        $capturePath = Join-Path $OutputDirectory (
            'iq_{0:D2}_{1:F3}MHz.bin' -f ($index + 1), ($actualRfHz / 1000000.0))
        Save-IioCapture $capturePath
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null

        $bytes = [IO.File]::ReadAllBytes($capturePath)
        $ch1 = Measure-Tone $bytes 0 $toneFrequencyHz $sampleRate
        $ch2 = Measure-Tone $bytes 1 $toneFrequencyHz $sampleRate
        $rows.Add([pscustomobject]@{
            index = $index + 1
            target_frequency_mhz = [Math]::Round($targetMHz, 6)
            actual_frequency_mhz = [Math]::Round($actualRfHz / 1000000.0, 6)
            if_frequency_hz = [Math]::Round($toneFrequencyHz, 3)
            ch1_tone_dbfs = $ch1.tone_dbfs
            ch2_tone_dbfs = $ch2.tone_dbfs
            ch1_peak_code = $ch1.peak_code
            ch2_peak_code = $ch2.peak_code
            ch1_clipped_samples = $ch1.clipped_samples
            ch2_clipped_samples = $ch2.clipped_samples
        })
        Write-Host (
            '[{0}/{1}] {2:F3} MHz: CH1={3:F3} dBFS CH2={4:F3} dBFS' -f
            ($index + 1), $pointCount, ($actualRfHz / 1000000.0),
            $ch1.tone_dbfs, $ch2.tone_dbfs)
    }

    $ch1Max = ($rows | Measure-Object -Property ch1_tone_dbfs -Maximum).Maximum
    $ch2Max = ($rows | Measure-Object -Property ch2_tone_dbfs -Maximum).Maximum
    $normalizedRows = foreach ($row in $rows) {
        [pscustomobject]@{
            index = $row.index
            target_frequency_mhz = $row.target_frequency_mhz
            actual_frequency_mhz = $row.actual_frequency_mhz
            if_frequency_hz = $row.if_frequency_hz
            ch1_tone_dbfs = $row.ch1_tone_dbfs
            ch2_tone_dbfs = $row.ch2_tone_dbfs
            ch1_relative_db = [Math]::Round($row.ch1_tone_dbfs - $ch1Max, 3)
            ch2_relative_db = [Math]::Round($row.ch2_tone_dbfs - $ch2Max, 3)
            channel_delta_db = [Math]::Round(
                $row.ch1_tone_dbfs - $row.ch2_tone_dbfs, 3)
            ch1_peak_code = $row.ch1_peak_code
            ch2_peak_code = $row.ch2_peak_code
            ch1_clipped_samples = $row.ch1_clipped_samples
            ch2_clipped_samples = $row.ch2_clipped_samples
        }
    }
    $csvPath = Join-Path $OutputDirectory 'dual_channel_passband.csv'
    $normalizedRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation

    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        pluto_uri = $PlutoUri
        start_frequency_mhz = $StartFrequencyMHz
        stop_frequency_mhz = $StopFrequencyMHz
        step_frequency_mhz = $StepFrequencyMHz
        point_count = $pointCount
        sample_rate_sps = $sampleRate
        dds_frequency_hz = $ddsFrequency
        dds_scale = $DdsScale
        tx_gain_db = $TxGainDb
        rx_gain_db = $RxGainDb
        external_attenuator_db = 20.0
        frontend_attenuation_db = $FrontendAttenuationDb
        frontend_phase_deg = 0.0
        lna1 = 'ON'
        lna2 = 'ON'
        calibrated = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (
        Join-Path $OutputDirectory 'measurement_setup.json')

    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
        Out-Null
    $rfActive = $false
    Write-Host "Dual-channel passband sweep completed: $csvPath"
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-Warning 'SAFE sent during cleanup; external rails remain applied.'
        }
        catch {
            Write-Warning "Could not send SAFE: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()

    if ($plutoStateSaved) {
        try {
            $rx0GainNumber = [regex]::Match(
                $originalRx0Gain, '-?\d+(\.\d+)?').Value
            $rx1GainNumber = [regex]::Match(
                $originalRx1Gain, '-?\d+(\.\d+)?').Value
            Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' 'manual'
            Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' 'manual'
            Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' $rx0GainNumber
            Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' $rx1GainNumber
            Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' $originalRx0Mode
            Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' $originalRx1Mode
            $txGainNumber = [regex]::Match(
                $originalTxGain, '-?\d+(\.\d+)?').Value
            Set-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain' $txGainNumber
            foreach ($ddsState in $originalDds) {
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'raw' '0'
                $savedFrequency = [double]$ddsState.frequency
                if ($savedFrequency -ge 0.0 -and
                    $savedFrequency -le $sampleRate / 2.0) {
                    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'frequency' $ddsState.frequency
                }
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'phase' $ddsState.phase
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'scale' $ddsState.scale
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'raw' $ddsState.raw
            }
            Set-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency' $originalTxLo
            Set-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency' $originalRxLo
            Write-Host 'Restored original Pluto LO and RX gain settings.'
        }
        catch {
            Write-Warning "Could not fully restore Pluto settings: $($_.Exception.Message)"
        }
    }
}
