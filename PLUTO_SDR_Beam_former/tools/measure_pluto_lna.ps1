[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$PlutoUri = 'ip:192.168.2.1',
    [string]$LibiioDirectory = 'tmp/libiio-v0.26/Windows-VS-2022-x64',
    [string]$OutputDirectory = 'captures/pluto_lna_validation_20260716',
    [ValidateRange(-3, 71)][int]$RxGainDb = 20,
    [ValidateRange(4096, 262144)][int]$SampleCount = 8192
)

$ErrorActionPreference = 'Stop'

$iioAttr = (Resolve-Path (Join-Path $LibiioDirectory 'iio_attr.exe')).Path
$iioReadDev = (Resolve-Path (Join-Path $LibiioDirectory 'iio_readdev.exe')).Path
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$serial.NewLine = "`n"
$rfActive = $false
$rxStateSaved = $false

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

function Get-IioChannelAttribute {
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

function Set-IioChannelAttribute {
    param(
        [ValidateSet('Input', 'Output')][string]$Direction,
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Attribute,
        [Parameter(Mandatory)][string]$Value
    )

    $directionFlag = if ($Direction -eq 'Input') { '-i' } else { '-o' }
    & $iioAttr -u $PlutoUri $directionFlag -c $Device $Channel $Attribute $Value | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "iio_attr write failed: $Device/$Channel/$Attribute=$Value"
    }
}

function Save-IioCapture {
    param([Parameter(Mandatory)][string]$Path)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $iioReadDev
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-u', $PlutoUri,
        '-T', '5000',
        '-b', '8192',
        '-s', [string]$SampleCount,
        'cf-ad9361-lpc',
        'voltage0', 'voltage1', 'voltage2', 'voltage3'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Could not start iio_readdev.'
    }
    $file = [System.IO.File]::Create($Path)
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
    Write-Host "Saved $Path ($actualBytes bytes)"
}

function Measure-ToneAtFrequency {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateSet(0, 1)][int]$Channel,
        [Parameter(Mandatory)][double]$FrequencyHz,
        [Parameter(Mandatory)][double]$SampleRateHz
    )

    $count = [int]($Bytes.Length / 8)
    $offset = if ($Channel -eq 0) { 0 } else { 4 }
    $omega = 2.0 * [Math]::PI * $FrequencyHz / $SampleRateHz
    $stepCos = [Math]::Cos(-$omega)
    $stepSin = [Math]::Sin(-$omega)
    $rotCos = 1.0
    $rotSin = 0.0
    $sumI = 0.0
    $sumQ = 0.0
    $sumSquares = 0.0
    $toneRealPositive = 0.0
    $toneImagPositive = 0.0
    $toneRealNegative = 0.0
    $toneImagNegative = 0.0
    $clipCount = 0
    $peak = 0

    for ($sample = 0; $sample -lt $count; $sample++) {
        $base = $sample * 8 + $offset
        $i = [int][BitConverter]::ToInt16($Bytes, $base)
        $q = [int][BitConverter]::ToInt16($Bytes, $base + 2)
        $sumI += $i
        $sumQ += $q
        $sumSquares += [double]$i * $i + [double]$q * $q
        $toneRealPositive += $i * $rotCos - $q * $rotSin
        $toneImagPositive += $i * $rotSin + $q * $rotCos
        $toneRealNegative += $i * $rotCos + $q * $rotSin
        $toneImagNegative += -$i * $rotSin + $q * $rotCos
        $absI = [Math]::Abs($i)
        $absQ = [Math]::Abs($q)
        $peak = [Math]::Max($peak, [Math]::Max($absI, $absQ))
        if ($absI -ge 2040 -or $absQ -ge 2040) {
            $clipCount++
        }

        $nextCos = $rotCos * $stepCos - $rotSin * $stepSin
        $rotSin = $rotSin * $stepCos + $rotCos * $stepSin
        $rotCos = $nextCos
    }

    $dcPower = ($sumI * $sumI + $sumQ * $sumQ) / $count
    $rms = [Math]::Sqrt([Math]::Max(0.0, ($sumSquares - $dcPower) / $count))
    $toneAmplitudePositive = [Math]::Sqrt(
        $toneRealPositive * $toneRealPositive + $toneImagPositive * $toneImagPositive
    ) / $count
    $toneAmplitudeNegative = [Math]::Sqrt(
        $toneRealNegative * $toneRealNegative + $toneImagNegative * $toneImagNegative
    ) / $count
    if ($toneAmplitudePositive -ge $toneAmplitudeNegative) {
        $toneAmplitude = $toneAmplitudePositive
        $detectedFrequency = $FrequencyHz
    }
    else {
        $toneAmplitude = $toneAmplitudeNegative
        $detectedFrequency = -$FrequencyHz
    }
    $rmsDbfs = if ($rms -gt 0) { 20.0 * [Math]::Log10($rms / 2048.0) } else { -999.0 }
    $toneDbfs = if ($toneAmplitude -gt 0) { 20.0 * [Math]::Log10($toneAmplitude / 2048.0) } else { -999.0 }

    return [pscustomobject]@{
        tone_dbfs = [Math]::Round($toneDbfs, 3)
        detected_frequency_hz = $detectedFrequency
        rms_dbfs = [Math]::Round($rmsDbfs, 3)
        peak_code = $peak
        clipped_samples = $clipCount
    }
}

function Capture-Condition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][double]$ToneFrequencyHz,
        [Parameter(Mandatory)][double]$SampleRateHz
    )

    Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    Start-Sleep -Milliseconds 100
    $path = Join-Path $OutputDirectory "$Name.bin"
    Save-IioCapture $path
    Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ch1 = Measure-ToneAtFrequency $bytes 0 $ToneFrequencyHz $SampleRateHz
    Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    $ch2 = Measure-ToneAtFrequency $bytes 1 $ToneFrequencyHz $SampleRateHz
    Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    Write-Host ("{0}: CH1 tone={1} dBFS rms={2} peak={3}; CH2 tone={4} dBFS rms={5} peak={6}" -f `
        $Name, $ch1.tone_dbfs, $ch1.rms_dbfs, $ch1.peak_code,
        $ch2.tone_dbfs, $ch2.rms_dbfs, $ch2.peak_code)
    return @(
        [pscustomobject]@{ condition=$Name; channel=1; tone_dbfs=$ch1.tone_dbfs; detected_frequency_hz=$ch1.detected_frequency_hz; rms_dbfs=$ch1.rms_dbfs; peak_code=$ch1.peak_code; clipped_samples=$ch1.clipped_samples },
        [pscustomobject]@{ condition=$Name; channel=2; tone_dbfs=$ch2.tone_dbfs; detected_frequency_hz=$ch2.detected_frequency_hz; rms_dbfs=$ch2.rms_dbfs; peak_code=$ch2.peak_code; clipped_samples=$ch2.clipped_samples }
    )
}

try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path $OutputDirectory).Path

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $knownExternalState = $status -match 'STATE=EXTERNAL_SAFE' -and $status -match 'SOURCE=EXTERNAL'
    $newExternalState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    if ($status -notmatch 'FAULT=NONE' -or (-not $knownExternalState -and -not $newExternalState)) {
        throw "Expected a safe OFF state with no fault before RF measurement: $status"
    }

    $originalRx0Mode = Get-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode'
    $originalRx0Gain = Get-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalRx1Mode = Get-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode'
    $originalRx1Gain = Get-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain'
    $rxStateSaved = $true

    $rxLo = [double](Get-IioChannelAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency')
    $txLo = [double](Get-IioChannelAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency')
    $ddsFrequency = [double](Get-IioChannelAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'frequency')
    $ddsScale = [double](Get-IioChannelAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'scale')
    $sampleRate = [double](Get-IioChannelAttribute Input 'cf-ad9361-lpc' 'voltage0' 'sampling_frequency')
    $toneFrequency = $txLo + $ddsFrequency - $rxLo
    if ([Math]::Abs($toneFrequency) -ge $sampleRate / 2) {
        throw "Expected tone $toneFrequency Hz lies outside Nyquist range at $sampleRate S/s."
    }
    Write-Host "Pluto: TX_LO=$txLo RX_LO=$rxLo DDS=$ddsFrequency scale=$ddsScale Fs=$sampleRate expected_IF=$toneFrequency Hz"

    Set-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' 'manual'
    Set-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' 'manual'
    Set-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' ([string]$RxGainDb)
    Set-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' ([string]$RxGainDb)

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
    $rfActive = $true
    Invoke-RfCommand 'ATT ALL 20' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($row in (Capture-Condition 'lna_all_off' $toneFrequency $sampleRate)) { $results.Add($row) }

    Invoke-RfCommand 'LNA 1 ON' '^OK$' | Out-Null
    foreach ($row in (Capture-Condition 'lna_ch1_on' $toneFrequency $sampleRate)) { $results.Add($row) }
    Invoke-RfCommand 'LNA 1 OFF' '^OK$' | Out-Null

    Invoke-RfCommand 'LNA 2 ON' '^OK$' | Out-Null
    foreach ($row in (Capture-Condition 'lna_ch2_on' $toneFrequency $sampleRate)) { $results.Add($row) }
    Invoke-RfCommand 'LNA 2 OFF' '^OK$' | Out-Null

    Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null
    foreach ($row in (Capture-Condition 'lna_all_on' $toneFrequency $sampleRate)) { $results.Add($row) }
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null

    $csvPath = Join-Path $OutputDirectory 'lna_measurements.csv'
    $results | Export-Csv -LiteralPath $csvPath -NoTypeInformation

    $offCh1 = ($results | Where-Object { $_.condition -eq 'lna_all_off' -and $_.channel -eq 1 }).tone_dbfs
    $offCh2 = ($results | Where-Object { $_.condition -eq 'lna_all_off' -and $_.channel -eq 2 }).tone_dbfs
    $onCh1 = ($results | Where-Object { $_.condition -eq 'lna_ch1_on' -and $_.channel -eq 1 }).tone_dbfs
    $onCh2 = ($results | Where-Object { $_.condition -eq 'lna_ch2_on' -and $_.channel -eq 2 }).tone_dbfs
    $gainCh1 = [Math]::Round($onCh1 - $offCh1, 3)
    $gainCh2 = [Math]::Round($onCh2 - $offCh2, 3)
    $summary = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        pluto_uri = $PlutoUri
        tx_lo_hz = $txLo
        rx_lo_hz = $rxLo
        dds_frequency_hz = $ddsFrequency
        expected_if_hz = $toneFrequency
        sample_rate_sps = $sampleRate
        rx_gain_db = $RxGainDb
        frontend_attenuation_db = 20.0
        frontend_phase_deg = 0.0
        ch1_lna_delta_db = $gainCh1
        ch2_lna_delta_db = $gainCh2
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json')
    Write-Host "Measured LNA delta: CH1=$gainCh1 dB, CH2=$gainCh2 dB"

    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
    $rfActive = $false
    $status = Invoke-RfCommand 'STATUS' '^OK '
    if ($status -notmatch 'STATE=EXTERNAL_SAFE' -or
        $status -notmatch 'FAULT=NONE' -or
        $status -notmatch 'CH1_LNA=OFF' -or
        $status -notmatch 'CH2_LNA=OFF') {
        throw "Unexpected final frontend state: $status"
    }
    Write-Host "RF LNA validation completed. Results: $csvPath"
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-Warning 'SAFE was sent during cleanup; external rails remain physically applied.'
        }
        catch {
            Write-Warning "Could not send SAFE during cleanup: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()

    if ($rxStateSaved) {
        try {
            $rx0GainNumber = [regex]::Match($originalRx0Gain, '-?\d+(\.\d+)?').Value
            $rx1GainNumber = [regex]::Match($originalRx1Gain, '-?\d+(\.\d+)?').Value
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' 'manual'
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' 'manual'
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' $rx0GainNumber
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' $rx1GainNumber
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' $originalRx0Mode
            Set-IioChannelAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' $originalRx1Mode
            Write-Host 'Restored the original Pluto RX gain settings.'
        }
        catch {
            Write-Warning "Could not fully restore Pluto RX settings: $($_.Exception.Message)"
        }
    }
}
