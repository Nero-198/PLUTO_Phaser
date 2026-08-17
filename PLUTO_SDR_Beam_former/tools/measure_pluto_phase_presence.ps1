[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$PlutoUri = 'ip:192.168.2.1',
    [string]$LibiioDirectory = 'tmp/libiio-v0.26/Windows-VS-2022-x64',
    [string]$OutputDirectory = 'captures/pluto_phase_presence',
    [ValidateRange(325, 6000)][double]$RfFrequencyMHz = 2400.0,
    [ValidateRange(-3, 71)][int]$RxGainDb = 30,
    [ValidateRange(-89, 0)][double]$TxGainDb = -20.0,
    [double]$Tx2GainDb = [double]::NaN,
    [ValidateRange(0.0, 1.0)][double]$DdsScale = 0.25,
    [switch]$EnableSecondTransmitter,
    [ValidateRange(-360.0, 360.0)][double]$Tx2RelativePhaseDegrees = 0.0,
    [switch]$LeaveTransmittersSafe,
    [ValidateRange(4096, 262144)][int]$SampleCount = 16384,
    [ValidateRange(1, 10)][int]$Cycles = 3,
    [ValidateRange(1, 20)][int]$CapturesPerState = 3,
    [ValidateSet(1, 2)][int]$PhaseChannel = 1,
    [ValidateRange(0.0, 337.5)][double]$ReferencePhaseDegrees = 0.0,
    [switch]$InternalPower,
    [switch]$FullPhaseSweep,
    [switch]$LnaMappingOnly,
    [switch]$Quiet,
    [ValidateRange(0.0, 31.5)][double]$FrontendAttenuationDb = 0.0
)

$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
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

$referenceSteps = $ReferencePhaseDegrees / 22.5
if ([Math]::Abs($referenceSteps - [Math]::Round($referenceSteps)) -gt 1.0e-9) {
    throw 'ReferencePhaseDegrees must be a 22.5-degree phase step.'
}
if (-not $EnableSecondTransmitter -and
    [Math]::Abs($Tx2RelativePhaseDegrees) -gt 1.0e-9) {
    throw 'Tx2RelativePhaseDegrees requires -EnableSecondTransmitter.'
}
$effectiveTx2GainDb = if ([double]::IsNaN($Tx2GainDb)) {
    $TxGainDb
} else {
    $Tx2GainDb
}
if ($effectiveTx2GainDb -lt -89.0 -or $effectiveTx2GainDb -gt 0.0) {
    throw 'Tx2GainDb must be between -89 and 0 dB.'
}

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

    if (-not $Quiet) { Write-Host "> $Command" }
    $serial.Write("$Command`n")
    $line = Read-RfLine
    if (-not $Quiet) { Write-Host "< $line" }
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

function Measure-TonePhasors {
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

    $positiveReal /= $count
    $positiveImag /= $count
    $negativeReal /= $count
    $negativeImag /= $count
    $positiveAmplitude = [Math]::Sqrt(
        $positiveReal * $positiveReal + $positiveImag * $positiveImag)
    $negativeAmplitude = [Math]::Sqrt(
        $negativeReal * $negativeReal + $negativeImag * $negativeImag)

    return [pscustomobject]@{
        positive_real = $positiveReal
        positive_imag = $positiveImag
        positive_amplitude = $positiveAmplitude
        negative_real = $negativeReal
        negative_imag = $negativeImag
        negative_amplitude = $negativeAmplitude
        peak_code = $peak
        clipped_samples = $clipCount
    }
}

function Get-RelativePhase {
    param(
        [Parameter(Mandatory)][double]$DutReal,
        [Parameter(Mandatory)][double]$DutImag,
        [Parameter(Mandatory)][double]$ReferenceReal,
        [Parameter(Mandatory)][double]$ReferenceImag
    )

    $real = $DutReal * $ReferenceReal + $DutImag * $ReferenceImag
    $imag = $DutImag * $ReferenceReal - $DutReal * $ReferenceImag
    return [Math]::Atan2($imag, $real) * 180.0 / [Math]::PI
}

function Wrap-Degrees {
    param([Parameter(Mandatory)][double]$Degrees)
    while ($Degrees -ge 180.0) { $Degrees -= 360.0 }
    while ($Degrees -lt -180.0) { $Degrees += 360.0 }
    return $Degrees
}

function Get-CircularStatistics {
    param([Parameter(Mandatory)][double[]]$AnglesDegrees)

    $sumCos = 0.0
    $sumSin = 0.0
    foreach ($angle in $AnglesDegrees) {
        $radians = $angle * [Math]::PI / 180.0
        $sumCos += [Math]::Cos($radians)
        $sumSin += [Math]::Sin($radians)
    }
    $count = $AnglesDegrees.Count
    $mean = [Math]::Atan2($sumSin, $sumCos) * 180.0 / [Math]::PI
    $resultant = [Math]::Sqrt($sumCos * $sumCos + $sumSin * $sumSin) / $count
    $boundedResultant = [Math]::Max(1.0e-12, [Math]::Min(1.0, $resultant))
    $std = [Math]::Sqrt(-2.0 * [Math]::Log($boundedResultant)) *
        180.0 / [Math]::PI
    return [pscustomobject]@{
        mean_deg = $mean
        circular_std_deg = $std
        resultant_length = $resultant
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
    $powerStateIsValid = if ($InternalPower) {
        $offState
    } else {
        $externalSafe -or $offState
    }
    if ($status -notmatch 'FAULT=NONE' -or -not $powerStateIsValid) {
        throw "Expected safe OFF state with no fault: $status"
    }

    $originalTxLo = Get-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency'
    $originalRxLo = Get-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency'
    $originalRx0Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode'
    $originalRx0Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalRx1Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode'
    $originalRx1Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain'
    $originalTx0Gain = Get-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalTx1Gain = Get-IioAttribute Output 'ad9361-phy' 'voltage1' 'hardwaregain'
    $originalDds = [Collections.Generic.List[object]]::new()
    foreach ($channelIndex in 0..7) {
        $channelName = "altvoltage$channelIndex"
        $originalDds.Add([pscustomobject]@{
            channel = $channelName
            frequency = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'frequency'
            scale = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale'
            phase = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'phase'
            raw = Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw'
        })
    }
    $sampleRate = [double](Get-IioAttribute Input 'cf-ad9361-lpc' 'voltage0' 'sampling_frequency')
    $plutoStateSaved = $true

    # Quiesce both transmitters before changing gain, LO, DDS frequency, or phase.
    foreach ($channelIndex in 0..7) {
        $channelName = "altvoltage$channelIndex"
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw' '0'
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale' '0.000000'
    }
    foreach ($txChannel in @('voltage0', 'voltage1')) {
        Set-IioAttribute Output 'ad9361-phy' $txChannel 'hardwaregain' '-89.0'
    }

    $toneFrequencyHz = 1000000.0
    if ($toneFrequencyHz -ge $sampleRate / 2.0) {
        throw "The 1 MHz test tone is outside Nyquist: Fs=$sampleRate"
    }
    $targetRfHz = [Math]::Round($RfFrequencyMHz * 1000000.0)
    $loFrequencyHz = [Math]::Round($targetRfHz - $toneFrequencyHz)

    Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' 'manual'
    Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' 'manual'
    Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' ([string]$RxGainDb)
    Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' ([string]$RxGainDb)
    Set-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain' (
        $TxGainDb.ToString('0.0', $culture))
    if ($EnableSecondTransmitter) {
        Set-IioAttribute Output 'ad9361-phy' 'voltage1' 'hardwaregain' (
            $effectiveTx2GainDb.ToString('0.0', $culture))
    }

    $ddsScaleText = $DdsScale.ToString('0.000000', $culture)
    $activeDdsChannels = @('altvoltage0', 'altvoltage2')
    if ($EnableSecondTransmitter) {
        $activeDdsChannels += @('altvoltage4', 'altvoltage6')
    }
    foreach ($channelName in $activeDdsChannels) {
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'frequency' '1000000'
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'scale' $ddsScaleText
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw' '1'
    }
    $tx2DdsPhaseDegrees = $Tx2RelativePhaseDegrees
    while ($tx2DdsPhaseDegrees -lt 0.0) { $tx2DdsPhaseDegrees += 360.0 }
    while ($tx2DdsPhaseDegrees -ge 360.0) { $tx2DdsPhaseDegrees -= 360.0 }
    $tx2DdsPhaseMilliDegrees = [Math]::Round($tx2DdsPhaseDegrees * 1000.0)
    $tx2DdsIPhaseDegrees = $tx2DdsPhaseDegrees + 90.0
    if ($tx2DdsIPhaseDegrees -ge 360.0) { $tx2DdsIPhaseDegrees -= 360.0 }
    $tx2DdsIPhaseMilliDegrees = [Math]::Round(
        $tx2DdsIPhaseDegrees * 1000.0)
    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'phase' '90000'
    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage2' 'phase' (
        '0')
    if ($EnableSecondTransmitter) {
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage4' 'phase' (
            [string]$tx2DdsIPhaseMilliDegrees)
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage6' 'phase' (
            [string]$tx2DdsPhaseMilliDegrees)
    }
    Set-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency' ([string]$loFrequencyHz)
    Set-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency' ([string]$loFrequencyHz)
    Start-Sleep -Milliseconds 200

    $actualTxLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency')
    $actualRxLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency')
    if ([Math]::Abs($actualTxLo - $loFrequencyHz) -gt 10000.0 -or
        [Math]::Abs($actualRxLo - $loFrequencyHz) -gt 10000.0) {
        throw 'PLUTO LO readback mismatch; another application may be controlling it.'
    }
    foreach ($channelName in $activeDdsChannels) {
        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $channelName 'raw' '1'
    }

    if ($InternalPower) {
        Invoke-RfCommand 'POWER ON' '^OK POWER=ON SOURCE=INTERNAL$' | Out-Null
    } else {
        Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' |
            Out-Null
    }
    $rfActive = $true
    $frontendAtt = $FrontendAttenuationDb.ToString('0.0', $culture)
    Invoke-RfCommand "ATT ALL $frontendAtt" '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null

    if ($LnaMappingOnly) {
        $lnaStates = @(
            [pscustomobject]@{
                name = 'all_off'
                command = 'LNA ALL OFF'
            },
            [pscustomobject]@{
                name = 'ch1_on'
                command = 'LNA 1 ON'
            },
            [pscustomobject]@{
                name = 'ch2_on'
                command = 'LNA 2 ON'
            },
            [pscustomobject]@{
                name = 'all_on'
                command = 'LNA ALL ON'
            }
        )
        $lnaRows = [Collections.Generic.List[object]]::new()
        $lnaCaptureIndex = 0
        foreach ($lnaState in $lnaStates) {
            Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
            Invoke-RfCommand $lnaState.command '^OK$' | Out-Null
            Start-Sleep -Milliseconds 20
            for ($repeat = 1; $repeat -le $CapturesPerState; ++$repeat) {
                ++$lnaCaptureIndex
                Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
                $capturePath = Join-Path $OutputDirectory (
                    'iq_lna_{0:D2}_{1}_r{2:D2}.bin' -f
                    $lnaCaptureIndex, $lnaState.name, $repeat)
                Save-IioCapture $capturePath
                $bytes = [IO.File]::ReadAllBytes($capturePath)
                $ch1 = Measure-TonePhasors $bytes 0 $toneFrequencyHz $sampleRate
                $ch2 = Measure-TonePhasors $bytes 1 $toneFrequencyHz $sampleRate
                $usePositive = (
                    $ch1.positive_amplitude + $ch2.positive_amplitude
                ) -ge (
                    $ch1.negative_amplitude + $ch2.negative_amplitude
                )
                if ($usePositive) {
                    $ch1Amplitude = $ch1.positive_amplitude
                    $ch2Amplitude = $ch2.positive_amplitude
                    $sideband = 'positive'
                }
                else {
                    $ch1Amplitude = $ch1.negative_amplitude
                    $ch2Amplitude = $ch2.negative_amplitude
                    $sideband = 'negative'
                }
                $ch1Dbfs = 20.0 * [Math]::Log10(
                    [Math]::Max(1.0e-12, $ch1Amplitude / 2048.0))
                $ch2Dbfs = 20.0 * [Math]::Log10(
                    [Math]::Max(1.0e-12, $ch2Amplitude / 2048.0))
                $lnaRows.Add([pscustomobject]@{
                    condition = $lnaState.name
                    repeat = $repeat
                    ch1_tone_dbfs = [Math]::Round($ch1Dbfs, 3)
                    ch2_tone_dbfs = [Math]::Round($ch2Dbfs, 3)
                    sideband = $sideband
                    ch1_peak_code = $ch1.peak_code
                    ch2_peak_code = $ch2.peak_code
                    ch1_clipped_samples = $ch1.clipped_samples
                    ch2_clipped_samples = $ch2.clipped_samples
                    capture_file = Split-Path -Leaf $capturePath
                })
                if (-not $Quiet) {
                    Write-Host (
                        ('[{0}/{1}] {2} repeat={3}: CH1={4:F2} dBFS CH2={5:F2} dBFS') -f
                        $lnaCaptureIndex,
                        ($lnaStates.Count * $CapturesPerState),
                        $lnaState.name, $repeat, $ch1Dbfs, $ch2Dbfs)
                }
            }
        }

        $lnaCsvPath = Join-Path $OutputDirectory 'lna_channel_mapping_measurements.csv'
        $lnaRows | Export-Csv -LiteralPath $lnaCsvPath -NoTypeInformation
        $lnaSummary = foreach ($lnaState in $lnaStates) {
            $matching = @(
                $lnaRows | Where-Object { $_.condition -eq $lnaState.name }
            )
            [pscustomobject]@{
                condition = $lnaState.name
                ch1_mean_dbfs = [Math]::Round(
                    ($matching | Measure-Object ch1_tone_dbfs -Average).Average, 3)
                ch2_mean_dbfs = [Math]::Round(
                    ($matching | Measure-Object ch2_tone_dbfs -Average).Average, 3)
                sample_count = $matching.Count
                clipped_samples = (
                    ($matching | Measure-Object ch1_clipped_samples -Sum).Sum +
                    ($matching | Measure-Object ch2_clipped_samples -Sum).Sum
                )
            }
        }
        $offSummary = $lnaSummary | Where-Object { $_.condition -eq 'all_off' }
        $lnaSummaryWithDelta = foreach ($row in $lnaSummary) {
            [pscustomobject]@{
                condition = $row.condition
                ch1_mean_dbfs = $row.ch1_mean_dbfs
                ch2_mean_dbfs = $row.ch2_mean_dbfs
                ch1_delta_from_all_off_db = [Math]::Round(
                    $row.ch1_mean_dbfs - $offSummary.ch1_mean_dbfs, 3)
                ch2_delta_from_all_off_db = [Math]::Round(
                    $row.ch2_mean_dbfs - $offSummary.ch2_mean_dbfs, 3)
                sample_count = $row.sample_count
                clipped_samples = $row.clipped_samples
            }
        }
        $lnaSummaryPath = Join-Path $OutputDirectory 'lna_channel_mapping_summary.csv'
        $lnaSummaryWithDelta |
            Export-Csv -LiteralPath $lnaSummaryPath -NoTypeInformation
        $lnaSummaryWithDelta | Format-Table -AutoSize | Out-String | Write-Host

        Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
        Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
        Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
        if ($InternalPower) {
            Invoke-RfCommand 'SAFE' '^OK SAFE$' | Out-Null
        } else {
            Invoke-RfCommand 'POWER OFF' `
                '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
        }
        $rfActive = $false
        Write-Host "LNA channel mapping completed: $lnaSummaryPath"
        return
    }

    Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null
    $referenceChannel = if ($PhaseChannel -eq 1) { 2 } else { 1 }
    $zeroZeroBaselineMeasurements = [Collections.Generic.List[object]]::new()
    if ($ReferencePhaseDegrees -ne 0.0) {
        Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
        Start-Sleep -Milliseconds 20
        for ($repeat = 1; $repeat -le $CapturesPerState; ++$repeat) {
            Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
            $capturePath = Join-Path $OutputDirectory (
                'iq_cal_both_0deg_r{0:D2}.bin' -f $repeat)
            Save-IioCapture $capturePath
            $bytes = [IO.File]::ReadAllBytes($capturePath)
            $ch1 = Measure-TonePhasors $bytes 0 $toneFrequencyHz $sampleRate
            $ch2 = Measure-TonePhasors $bytes 1 $toneFrequencyHz $sampleRate
            $usePositive = (
                $ch1.positive_amplitude + $ch2.positive_amplitude
            ) -ge (
                $ch1.negative_amplitude + $ch2.negative_amplitude
            )
            if ($usePositive) {
                $ch1Real = $ch1.positive_real
                $ch1Imag = $ch1.positive_imag
                $ch1Amplitude = $ch1.positive_amplitude
                $ch2Real = $ch2.positive_real
                $ch2Imag = $ch2.positive_imag
                $ch2Amplitude = $ch2.positive_amplitude
                $sideband = 'positive'
            }
            else {
                $ch1Real = $ch1.negative_real
                $ch1Imag = $ch1.negative_imag
                $ch1Amplitude = $ch1.negative_amplitude
                $ch2Real = $ch2.negative_real
                $ch2Imag = $ch2.negative_imag
                $ch2Amplitude = $ch2.negative_amplitude
                $sideband = 'negative'
            }
            $relativePhase = if ($PhaseChannel -eq 1) {
                Get-RelativePhase $ch1Real $ch1Imag $ch2Real $ch2Imag
            }
            else {
                Get-RelativePhase $ch2Real $ch2Imag $ch1Real $ch1Imag
            }
            $ch1Dbfs = 20.0 * [Math]::Log10(
                [Math]::Max(1.0e-12, $ch1Amplitude / 2048.0))
            $ch2Dbfs = 20.0 * [Math]::Log10(
                [Math]::Max(1.0e-12, $ch2Amplitude / 2048.0))
            $zeroZeroBaselineMeasurements.Add([pscustomobject]@{
                repeat = $repeat
                relative_phase_deg = $relativePhase
                sideband = $sideband
                ch1_tone_dbfs = $ch1Dbfs
                ch2_tone_dbfs = $ch2Dbfs
                ch1_peak_code = $ch1.peak_code
                ch2_peak_code = $ch2.peak_code
                ch1_clipped_samples = $ch1.clipped_samples
                ch2_clipped_samples = $ch2.clipped_samples
                capture_file = Split-Path -Leaf $capturePath
            })
            if (-not $Quiet) {
                Write-Host (
                    ('[calibration] both=0.0 repeat={0}: relative={1:F2} deg ' +
                    'CH1={2:F2} dBFS CH2={3:F2} dBFS') -f
                    $repeat, $relativePhase, $ch1Dbfs, $ch2Dbfs)
            }
        }
        $zeroZeroBaselineMeasurements |
            Export-Csv -LiteralPath (
                Join-Path $OutputDirectory 'zero_zero_baseline_measurements.csv'
            ) -NoTypeInformation
        Invoke-RfCommand (
            "PHASE $referenceChannel " +
            $ReferencePhaseDegrees.ToString('0.0', $culture)
        ) '^OK$' | Out-Null
        Start-Sleep -Milliseconds 20
    }

    $phaseSequence = if ($FullPhaseSweep) {
        @((0..15 | ForEach-Object { [double]$_ * 22.5 }) + 0.0)
    } else {
        @(0.0, 90.0, 180.0, 270.0, 0.0)
    }
    $measurements = [Collections.Generic.List[object]]::new()
    $measurementIndex = 0
    for ($cycle = 1; $cycle -le $Cycles; ++$cycle) {
        for ($step = 0; $step -lt $phaseSequence.Count; ++$step) {
            $commandedPhase = $phaseSequence[$step]
            Invoke-RfCommand (
                "PHASE $PhaseChannel " +
                $commandedPhase.ToString('0.0', $culture)
            ) '^OK$' | Out-Null
            Start-Sleep -Milliseconds 20

            for ($repeat = 1; $repeat -le $CapturesPerState; ++$repeat) {
                ++$measurementIndex
                Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
                $capturePath = Join-Path $OutputDirectory (
                    'iq_{0:D3}_c{1:D2}_s{2:D2}_r{3:D2}_{4:F1}deg.bin' -f
                    $measurementIndex, $cycle, ($step + 1), $repeat,
                    $commandedPhase)
                Save-IioCapture $capturePath
                $bytes = [IO.File]::ReadAllBytes($capturePath)
                $ch1 = Measure-TonePhasors $bytes 0 $toneFrequencyHz $sampleRate
                $ch2 = Measure-TonePhasors $bytes 1 $toneFrequencyHz $sampleRate
                $usePositive = (
                    $ch1.positive_amplitude + $ch2.positive_amplitude
                ) -ge (
                    $ch1.negative_amplitude + $ch2.negative_amplitude
                )
                if ($usePositive) {
                    $ch1Real = $ch1.positive_real
                    $ch1Imag = $ch1.positive_imag
                    $ch1Amplitude = $ch1.positive_amplitude
                    $ch2Real = $ch2.positive_real
                    $ch2Imag = $ch2.positive_imag
                    $ch2Amplitude = $ch2.positive_amplitude
                    $sideband = 'positive'
                }
                else {
                    $ch1Real = $ch1.negative_real
                    $ch1Imag = $ch1.negative_imag
                    $ch1Amplitude = $ch1.negative_amplitude
                    $ch2Real = $ch2.negative_real
                    $ch2Imag = $ch2.negative_imag
                    $ch2Amplitude = $ch2.negative_amplitude
                    $sideband = 'negative'
                }

                $relativePhase = if ($PhaseChannel -eq 1) {
                    Get-RelativePhase $ch1Real $ch1Imag $ch2Real $ch2Imag
                }
                else {
                    Get-RelativePhase $ch2Real $ch2Imag $ch1Real $ch1Imag
                }
                $ch1Dbfs = 20.0 * [Math]::Log10(
                    [Math]::Max(1.0e-12, $ch1Amplitude / 2048.0))
                $ch2Dbfs = 20.0 * [Math]::Log10(
                    [Math]::Max(1.0e-12, $ch2Amplitude / 2048.0))
                $measurements.Add([pscustomobject]@{
                    measurement_index = $measurementIndex
                    cycle = $cycle
                    sequence_step = $step + 1
                    repeat = $repeat
                    commanded_phase_deg = $commandedPhase
                    reference_channel = $referenceChannel
                    reference_phase_deg = $ReferencePhaseDegrees
                    relative_phase_deg = $relativePhase
                    sideband = $sideband
                    ch1_tone_dbfs = $ch1Dbfs
                    ch2_tone_dbfs = $ch2Dbfs
                    ch1_peak_code = $ch1.peak_code
                    ch2_peak_code = $ch2.peak_code
                    ch1_clipped_samples = $ch1.clipped_samples
                    ch2_clipped_samples = $ch2.clipped_samples
                    capture_file = Split-Path -Leaf $capturePath
                })
                $progressMessage = (
                    ('[{0}/{1}] cycle={2} phase={3:F1} repeat={4}: ' +
                    'relative={5:F2} deg CH1={6:F2} dBFS CH2={7:F2} dBFS') -f
                    $measurementIndex,
                    ($Cycles * $phaseSequence.Count * $CapturesPerState),
                    $cycle, $commandedPhase, $repeat, $relativePhase,
                    $ch1Dbfs, $ch2Dbfs)
                if (-not $Quiet) { Write-Host $progressMessage }
            }
        }
    }

    $baselineAngles = if ($ReferencePhaseDegrees -ne 0.0) {
        [double[]]@(
            $zeroZeroBaselineMeasurements |
                ForEach-Object { $_.relative_phase_deg }
        )
    } else {
        [double[]]@(
            $measurements |
                Where-Object { $_.cycle -eq 1 -and $_.sequence_step -eq 1 } |
                ForEach-Object { $_.relative_phase_deg }
        )
    }
    $baseline = Get-CircularStatistics $baselineAngles
    $finalRows = foreach ($row in $measurements) {
        $measuredDelta = Wrap-Degrees (
            $row.relative_phase_deg - $baseline.mean_deg)
        $expectedDelta = Wrap-Degrees (
            $ReferencePhaseDegrees - $row.commanded_phase_deg)
        $signedPhaseError = Wrap-Degrees ($measuredDelta - $expectedDelta)
        [pscustomobject]@{
            measurement_index = $row.measurement_index
            cycle = $row.cycle
            sequence_step = $row.sequence_step
            repeat = $row.repeat
            commanded_phase_deg = $row.commanded_phase_deg
            reference_channel = $row.reference_channel
            reference_phase_deg = $row.reference_phase_deg
            expected_delta_from_both_zero_deg = [Math]::Round(
                $expectedDelta, 4)
            relative_phase_deg = [Math]::Round($row.relative_phase_deg, 4)
            delta_from_initial_deg = [Math]::Round(
                $measuredDelta, 4)
            signed_phase_error_deg = [Math]::Round($signedPhaseError, 4)
            sideband = $row.sideband
            ch1_tone_dbfs = [Math]::Round($row.ch1_tone_dbfs, 3)
            ch2_tone_dbfs = [Math]::Round($row.ch2_tone_dbfs, 3)
            ch1_peak_code = $row.ch1_peak_code
            ch2_peak_code = $row.ch2_peak_code
            ch1_clipped_samples = $row.ch1_clipped_samples
            ch2_clipped_samples = $row.ch2_clipped_samples
            capture_file = $row.capture_file
        }
    }

    $rawCsvPath = Join-Path $OutputDirectory 'phase_presence_measurements.csv'
    $finalRows | Export-Csv -LiteralPath $rawCsvPath -NoTypeInformation

    $summaryPhases = @(
        $phaseSequence | Sort-Object -Unique
    )
    $summaryRows = foreach ($commandedPhase in $summaryPhases) {
        $matching = @(
            $finalRows | Where-Object {
                [double]$_.commanded_phase_deg -eq $commandedPhase
            }
        )
        $angles = [double[]]@(
            $matching | ForEach-Object { [double]$_.delta_from_initial_deg }
        )
        $statistics = Get-CircularStatistics $angles
        $errorAngles = [double[]]@(
            $matching | ForEach-Object { [double]$_.signed_phase_error_deg }
        )
        $errorStatistics = Get-CircularStatistics $errorAngles
        $expectedDelta = Wrap-Degrees (
            $ReferencePhaseDegrees - $commandedPhase)
        [pscustomobject]@{
            commanded_phase_deg = $commandedPhase
            reference_phase_deg = $ReferencePhaseDegrees
            expected_delta_from_both_zero_deg = [Math]::Round(
                $expectedDelta, 3)
            measured_delta_mean_deg = [Math]::Round($statistics.mean_deg, 3)
            signed_phase_error_mean_deg = [Math]::Round(
                $errorStatistics.mean_deg, 3)
            circular_std_deg = [Math]::Round($statistics.circular_std_deg, 3)
            phase_error_circular_std_deg = [Math]::Round(
                $errorStatistics.circular_std_deg, 3)
            resultant_length = [Math]::Round($statistics.resultant_length, 6)
            sample_count = $matching.Count
            ch1_tone_mean_dbfs = [Math]::Round(
                ($matching | Measure-Object ch1_tone_dbfs -Average).Average, 3)
            ch2_tone_mean_dbfs = [Math]::Round(
                ($matching | Measure-Object ch2_tone_dbfs -Average).Average, 3)
        }
    }
    $summaryCsvPath = Join-Path $OutputDirectory 'phase_presence_summary.csv'
    $summaryRows | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation

    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        pluto_uri = $PlutoUri
        rf_frequency_mhz = $RfFrequencyMHz
        sample_rate_sps = $sampleRate
        tone_frequency_hz = $toneFrequencyHz
        tx_gain_db = $TxGainDb
        tx1_gain_db = $TxGainDb
        tx2_gain_db = if ($EnableSecondTransmitter) {
            $effectiveTx2GainDb
        } else {
            $null
        }
        rx_gain_db = $RxGainDb
        dds_scale = $DdsScale
        second_transmitter_enabled = [bool]$EnableSecondTransmitter
        tx2_relative_phase_command_deg = $Tx2RelativePhaseDegrees
        tx2_dds_phase_programmed_deg = $tx2DdsPhaseDegrees
        frontend_attenuation_db = $FrontendAttenuationDb
        frontend_power_source = if ($InternalPower) { "INTERNAL" } else { "EXTERNAL" }
        phase_dut = "CH$PhaseChannel"
        phase_reference = if ($PhaseChannel -eq 1) {
            "CH2 at $($ReferencePhaseDegrees.ToString('0.0', $culture)) degrees"
        } else {
            "CH1 at $($ReferencePhaseDegrees.ToString('0.0', $culture)) degrees"
        }
        zero_zero_baseline_captures = $zeroZeroBaselineMeasurements.Count
        full_phase_sweep = [bool]$FullPhaseSweep
        cycles = $Cycles
        captures_per_state = $CapturesPerState
        baseline_relative_phase_deg = [Math]::Round($baseline.mean_deg, 4)
        calibrated = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (
        Join-Path $OutputDirectory 'measurement_setup.json')

    $summaryRows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "Phase-presence test completed: $summaryCsvPath"

    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    if ($InternalPower) {
        Invoke-RfCommand 'SAFE' '^OK SAFE$' | Out-Null
    } else {
        Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
            Out-Null
    }
    $rfActive = $false
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            if ($InternalPower) {
                Write-Warning 'SAFE sent during cleanup; internal RF power was disabled.'
            } else {
                Write-Warning 'SAFE sent during cleanup; external rails remain applied.'
            }
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
            foreach ($ddsState in $originalDds) {
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'raw' '0'
                Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'scale' '0.000000'
            }
            if ($LeaveTransmittersSafe) {
                Set-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain' '-89.0'
                Set-IioAttribute Output 'ad9361-phy' 'voltage1' 'hardwaregain' '-89.0'
            } else {
                $tx0GainNumber = [regex]::Match(
                    $originalTx0Gain, '-?\d+(\.\d+)?').Value
                $tx1GainNumber = [regex]::Match(
                    $originalTx1Gain, '-?\d+(\.\d+)?').Value
                Set-IioAttribute Output 'ad9361-phy' 'voltage0' 'hardwaregain' $tx0GainNumber
                Set-IioAttribute Output 'ad9361-phy' 'voltage1' 'hardwaregain' $tx1GainNumber
                foreach ($ddsState in $originalDds) {
                    $savedFrequency = [double]$ddsState.frequency
                    if ($savedFrequency -ge 0.0 -and
                        $savedFrequency -le $sampleRate / 2.0) {
                        Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'frequency' $ddsState.frequency
                    }
                    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'phase' $ddsState.phase
                    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'scale' $ddsState.scale
                    Set-IioAttribute Output 'cf-ad9361-dds-core-lpc' $ddsState.channel 'raw' $ddsState.raw
                }
            }
            Set-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency' $originalTxLo
            Set-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency' $originalRxLo
            if ($LeaveTransmittersSafe) {
                Write-Host 'Restored Pluto RX/LO settings; left both transmitters at -89 dB with DDS disabled.'
            } else {
                Write-Host 'Restored original Pluto LO, gain, and DDS settings.'
            }
        }
        catch {
            Write-Warning "Could not fully restore Pluto settings: $($_.Exception.Message)"
        }
    }
}
