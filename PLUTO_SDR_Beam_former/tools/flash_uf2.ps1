[CmdletBinding()]
param(
    [string]$Uf2Path = (Join-Path $PSScriptRoot '..\build\pico-arduino-sdk\rf_frontend_firmware.uf2'),
    [ValidateRange(1, 60)]
    [int]$ReenumerationTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

$resolvedUf2 = (Resolve-Path -LiteralPath $Uf2Path).Path
$bootVolumes = @(
    Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.VolumeName -eq 'RPI-RP2' }
)

if ($bootVolumes.Count -eq 0) {
    throw 'RPI-RP2 was not found. Hold BOOTSEL while connecting RP2040-Zero, then retry.'
}
if ($bootVolumes.Count -ne 1) {
    throw "Expected one RPI-RP2 volume, found $($bootVolumes.Count)."
}

$driveRoot = "$($bootVolumes[0].DeviceID)\"
$destination = Join-Path $driveRoot (Split-Path -Leaf $resolvedUf2)
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedUf2).Hash

Write-Host "UF2: $resolvedUf2"
Write-Host "SHA-256: $hash"
Write-Host "Writing to $destination"
Copy-Item -LiteralPath $resolvedUf2 -Destination $destination -Force

$deadline = [DateTime]::UtcNow.AddSeconds($ReenumerationTimeoutSeconds)
while ((Test-Path -LiteralPath $driveRoot) -and
       [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
if (Test-Path -LiteralPath $driveRoot) {
    throw 'UF2 was copied, but RPI-RP2 did not disconnect before the timeout.'
}

Write-Host 'UF2 copied and BOOTSEL volume disconnected. Waiting for USB CDC enumeration...'
$cdcDevice = $null
$deadline = [DateTime]::UtcNow.AddSeconds($ReenumerationTimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline -and $null -eq $cdcDevice) {
    $cdcDevice = Get-PnpDevice -PresentOnly |
        Where-Object {
            $_.InstanceId -match 'VID_2E8A' -and
            ($_.Class -eq 'Ports' -or $_.FriendlyName -match 'Serial|CDC')
        } |
        Select-Object -First 1
    if ($null -eq $cdcDevice) {
        Start-Sleep -Milliseconds 200
    }
}

if ($null -eq $cdcDevice) {
    Write-Warning 'Firmware was written, but a matching USB CDC device was not found before the timeout.'
    exit 2
}

Write-Host "CDC enumerated: $($cdcDevice.FriendlyName)"
