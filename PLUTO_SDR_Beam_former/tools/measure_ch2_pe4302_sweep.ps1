[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$PlutoUri = 'ip:192.168.2.1',
    [string]$LibiioDirectory = 'tmp/libiio-v0.26/Windows-VS-2022-x64',
    [string]$OutputDirectory = 'captures/ch2_pe4302_sweep_20260726',
    [ValidateRange(-3, 71)][int]$RxGainDb = 40,
    [ValidateRange(4096, 65536)][int]$SampleCount = 8192
)

$ErrorActionPreference = 'Stop'
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
$rxStateSaved = $false

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
        [string]$Device,
        [string]$Channel,
        [string]$Attribute
    )
    $flag = if ($Direction -eq 'Input') { '-i' } else { '-o' }
    $value = & $iioAttr -u $PlutoUri $flag -c $Device $Channel $Attribute
    if ($LASTEXITCODE -ne 0) {
        throw "iio_attr read failed: $Device/$Channel/$Attribute"
    }
    return ($value | Select-Object -Last 1).Trim()
}

function Set-IioAttribute {
    param(
        [ValidateSet('Input', 'Output')][string]$Direction,
        [string]$Device,
        [string]$Channel,
        [string]$Attribute,
        [string]$Value
    )
    $flag = if ($Direction -eq 'Input') { '-i' } else { '-o' }
    & $iioAttr -u $PlutoUri $flag -c $Device $Channel $Attribute $Value | Out-Null
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
        '-u', $PlutoUri, '-T', '5000', '-b', '8192', '-s', [string]$SampleCount,
        'cf-ad9361-lpc', 'voltage0', 'voltage1', 'voltage2', 'voltage3'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start iio_readdev.' }
    $file = [System.IO.File]::Create($Path)
    try { $process.StandardOutput.BaseStream.CopyTo($file) }
    finally { $file.Dispose() }
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

try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path $OutputDirectory).Path

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and $status -match 'SOURCE=EXTERNAL'
    if ($status -notmatch 'FAULT=NONE' -or (-not $offState -and -not $externalSafe)) {
        throw "Expected safe OFF state with no fault: $status"
    }

    $originalRx0Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode'
    $originalRx0Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain'
    $originalRx1Mode = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode'
    $originalRx1Gain = Get-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain'
    $rxStateSaved = $true

    $rxLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage0' 'frequency')
    $txLo = [double](Get-IioAttribute Output 'ad9361-phy' 'altvoltage1' 'frequency')
    $ddsFrequency = [double](Get-IioAttribute Output 'cf-ad9361-dds-core-lpc' 'altvoltage0' 'frequency')
    $sampleRate = [double](Get-IioAttribute Input 'cf-ad9361-lpc' 'voltage0' 'sampling_frequency')
    $expectedIf = $txLo + $ddsFrequency - $rxLo

    foreach ($channel in @('voltage0', 'voltage1')) {
        Set-IioAttribute Input 'ad9361-phy' $channel 'gain_control_mode' 'manual'
        Set-IioAttribute Input 'ad9361-phy' $channel 'hardwaregain' ([string]$RxGainDb)
    }

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
    $rfActive = $true
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA 2 ON' '^OK$' | Out-Null

    $sequence = @(
        [pscustomobject]@{ direction='down'; attenuation_db=31.5 },
        [pscustomobject]@{ direction='down'; attenuation_db=25.0 },
        [pscustomobject]@{ direction='down'; attenuation_db=20.0 },
        [pscustomobject]@{ direction='down'; attenuation_db=15.0 },
        [pscustomobject]@{ direction='down'; attenuation_db=10.0 },
        [pscustomobject]@{ direction='down'; attenuation_db=5.0 },
        [pscustomobject]@{ direction='down'; attenuation_db=0.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=5.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=10.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=15.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=20.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=25.0 },
        [pscustomobject]@{ direction='up'; attenuation_db=31.5 }
    )

    $metadata = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($step in $sequence) {
        $index++
        $attenuation = $step.attenuation_db.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        Invoke-RfCommand "ATT 2 $attenuation" '^OK$' | Out-Null
        Start-Sleep -Milliseconds 150
        $token = $attenuation.Replace('.', 'p')
        $fileName = '{0:D2}_{1}_{2}dB.bin' -f $index, $step.direction, $token
        $path = Join-Path $OutputDirectory $fileName
        Save-IioCapture $path
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
        Write-Host "Captured CH2 ATT=$attenuation dB ($($step.direction)): $fileName"
        $metadata.Add([pscustomobject]@{
            index = $index
            direction = $step.direction
            attenuation_db = [double]$step.attenuation_db
            file = $fileName
        })
    }

    $metadata | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'sweep_metadata.csv') -NoTypeInformation
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        pluto_uri = $PlutoUri
        tx_lo_hz = $txLo
        rx_lo_hz = $rxLo
        dds_frequency_hz = $ddsFrequency
        expected_if_hz = $expectedIf
        sample_rate_sps = $sampleRate
        rx_gain_db = $RxGainDb
        ch1_attenuation_db = 31.5
        ch1_lna = 'OFF'
        ch2_lna = 'ON during sweep'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'measurement_setup.json')

    Invoke-RfCommand 'ATT 2 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA 2 OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
    $rfActive = $false

    $status = Invoke-RfCommand 'STATUS' '^OK '
    if ($status -notmatch 'STATE=EXTERNAL_SAFE' -or
        $status -notmatch 'FAULT=NONE' -or
        $status -notmatch 'CH1_ATT=31\.5' -or
        $status -notmatch 'CH2_ATT=31\.5' -or
        $status -notmatch 'CH1_LNA=OFF' -or
        $status -notmatch 'CH2_LNA=OFF') {
        throw "Unexpected final frontend state: $status"
    }
    Write-Host "CH2 PE4302 sweep completed: $OutputDirectory"
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-Warning 'SAFE sent during cleanup; external rails remain physically applied.'
        }
        catch {
            Write-Warning "Could not send SAFE during cleanup: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()

    if ($rxStateSaved) {
        try {
            $rx0Gain = [regex]::Match($originalRx0Gain, '-?\d+(\.\d+)?').Value
            $rx1Gain = [regex]::Match($originalRx1Gain, '-?\d+(\.\d+)?').Value
            foreach ($channel in @('voltage0', 'voltage1')) {
                Set-IioAttribute Input 'ad9361-phy' $channel 'gain_control_mode' 'manual'
            }
            Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'hardwaregain' $rx0Gain
            Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'hardwaregain' $rx1Gain
            Set-IioAttribute Input 'ad9361-phy' 'voltage0' 'gain_control_mode' $originalRx0Mode
            Set-IioAttribute Input 'ad9361-phy' 'voltage1' 'gain_control_mode' $originalRx1Mode
            Write-Host 'Restored original Pluto RX gain settings.'
        }
        catch {
            Write-Warning "Could not fully restore Pluto RX settings: $($_.Exception.Message)"
        }
    }
}
