[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$PortName,
    [switch]$EnableRfPower,
    [switch]$ExternalPower,
    [switch]$ConfirmExternalPowerRemoved,
    [ValidateSet('None', 'Timeout', 'Disconnect')]
    [string]$FaultTest = 'None',
    [ValidateRange(100, 5000)]
    [int]$ReadTimeoutMs = 1500
)

$ErrorActionPreference = 'Stop'
if ($FaultTest -ne 'None' -and -not $EnableRfPower) {
    throw '-FaultTest requires -EnableRfPower.'
}
if ($ExternalPower -and -not $EnableRfPower) {
    throw '-ExternalPower requires -EnableRfPower.'
}
if ($ExternalPower -and $FaultTest -ne 'None') {
    throw 'External-power fault tests require manual rail removal and are not automated by this script.'
}
if ($ConfirmExternalPowerRemoved -and
    ($EnableRfPower -or $ExternalPower -or $FaultTest -ne 'None')) {
    throw '-ConfirmExternalPowerRemoved cannot be combined with power or fault-test options.'
}
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = $ReadTimeoutMs
$serial.WriteTimeout = $ReadTimeoutMs
$serial.NewLine = "`n"
$rfPowerAttempted = $false

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$ExpectedPattern
    )

    Write-Host "> $Command"
    $serial.Write("$Command`n")
    return Read-RfResponse -CommandLabel $Command -ExpectedPattern $ExpectedPattern
}

function Read-RfResponse {
    param(
        [Parameter(Mandatory)][string]$CommandLabel,
        [Parameter(Mandatory)][string]$ExpectedPattern
    )

    while ($true) {
        $line = $serial.ReadLine().Trim()
        Write-Host "< $line"
        if ($line -like 'READY RF_FRONTEND*') {
            continue
        }
        if ($line -notmatch $ExpectedPattern) {
            throw "Unexpected response to '$CommandLabel': $line"
        }
        return $line
    }
}

function Invoke-RfFragmentedCommand {
    param(
        [Parameter(Mandatory)][string[]]$Fragments,
        [Parameter(Mandatory)][string]$ExpectedPattern
    )

    $label = $Fragments -join ''
    Write-Host "> $label [fragmented]"
    foreach ($fragment in $Fragments) {
        $serial.Write($fragment)
        Start-Sleep -Milliseconds 10
    }
    $serial.Write("`n")
    return Read-RfResponse -CommandLabel $label -ExpectedPattern $ExpectedPattern
}

try {
    $serial.Open()
    Start-Sleep -Milliseconds 100
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    if ($ConfirmExternalPowerRemoved) {
        Write-Warning 'This option confirms that both external RF rails have already been physically removed.'
        $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
        if ($status -notmatch 'SOURCE=EXTERNAL') {
            throw "Firmware is not waiting for external-power removal: $status"
        }
        Invoke-RfCommand -Command 'POWER EXTERNAL OFF' `
            -ExpectedPattern '^OK POWER=OFF SOURCE=NONE$' | Out-Null
        $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
        if ($status -match 'FAULT=(?!NONE)([A-Z_]+)') {
            Invoke-RfCommand -Command 'FAULT CLEAR' `
                -ExpectedPattern '^OK FAULT=NONE$' | Out-Null
        }
        $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
        if ($status -notmatch 'STATE=OFF' -or
            $status -notmatch 'SOURCE=NONE' -or
            $status -notmatch 'FAULT=NONE') {
            throw "Expected OFF/SOURCE=NONE after external-rail removal: $status"
        }
        Write-Host 'External-power removal acknowledged; firmware is in the OFF state.'
        return
    }

    Invoke-RfCommand -Command 'PING' -ExpectedPattern '^OK PONG$' | Out-Null
    Invoke-RfFragmentedCommand -Fragments @('P', 'IN', 'G') `
        -ExpectedPattern '^OK PONG$' | Out-Null
    $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
    if ($status -match 'FAULT=(?!NONE)([A-Z_]+)') {
        Invoke-RfCommand -Command 'FAULT CLEAR' -ExpectedPattern '^OK FAULT=NONE$' | Out-Null
        $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
    }
    if ($status -match 'SOURCE=EXTERNAL') {
        throw 'Firmware still records external rails. Physically remove both rails, then run this script with -ConfirmExternalPowerRemoved.'
    }
    if ($status -notmatch 'POWER=OFF' -or $status -notmatch 'SOURCE=NONE') {
        throw "Expected the startup safe state, got: $status"
    }

    Invoke-RfCommand -Command 'ATT 1 0' -ExpectedPattern '^ERR POWER_OFF$' | Out-Null
    Invoke-RfCommand -Command 'PHASE 1 22.5' -ExpectedPattern '^ERR POWER_OFF$' | Out-Null
    Invoke-RfCommand -Command 'LNA 1 ON' -ExpectedPattern '^ERR POWER_OFF$' | Out-Null
    Invoke-RfCommand -Command 'LNA ALL OFF' -ExpectedPattern '^OK$' | Out-Null
    Invoke-RfCommand -Command 'ATT 1 12.3' -ExpectedPattern '^ERR RANGE$' | Out-Null
    Invoke-RfCommand -Command ('X' * 96) -ExpectedPattern '^ERR LINE_TOO_LONG$' | Out-Null
    $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
    if ($status -notmatch 'POWER=OFF' -or
        $status -notmatch 'CH1_ATT=31\.5' -or
        $status -notmatch 'CH2_ATT=31\.5' -or
        $status -notmatch 'CH1_PHASE=0\.0' -or
        $status -notmatch 'CH2_PHASE=0\.0' -or
        $status -notmatch 'CH1_LNA=OFF' -or
        $status -notmatch 'CH2_LNA=OFF') {
        throw "Safe state changed after rejected commands: $status"
    }

    if ($EnableRfPower) {
        if ($ExternalPower) {
            Write-Warning 'POWER EXTERNAL ON asserts that stable +3.3 V and -3.3 V are already applied with a common ground. GPIO26 will remain Low.'
        }
        else {
            Write-Warning 'RF rails will be enabled. Use current limiting and disconnect RF input for the first test.'
        }
        $rfPowerAttempted = $true
        if ($ExternalPower) {
            Invoke-RfCommand -Command 'POWER EXTERNAL ON' `
                -ExpectedPattern '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
        }
        else {
            Invoke-RfCommand -Command 'POWER ON' `
                -ExpectedPattern '^OK POWER=ON SOURCE=INTERNAL$' | Out-Null
        }
        Invoke-RfCommand -Command 'ATT ALL 31.5' -ExpectedPattern '^OK$' | Out-Null
        Invoke-RfCommand -Command 'PHASE ALL 0' -ExpectedPattern '^OK$' | Out-Null
        Invoke-RfCommand -Command 'LNA ALL OFF' -ExpectedPattern '^OK$' | Out-Null
        switch ($FaultTest) {
            'Timeout' {
                Write-Host 'Waiting 2500 ms without a valid command...'
                Start-Sleep -Milliseconds 2500
                Invoke-RfCommand -Command 'STATUS' `
                    -ExpectedPattern '^OK STATE=FAULT POWER=OFF SOURCE=NONE FAULT=COMM_TIMEOUT ' | Out-Null
                $rfPowerAttempted = $false
                Invoke-RfCommand -Command 'FAULT CLEAR' `
                    -ExpectedPattern '^OK FAULT=NONE$' | Out-Null
            }
            'Disconnect' {
                Write-Host 'Closing CDC port to trigger USB disconnect safety shutdown...'
                $serial.Close()
                Start-Sleep -Milliseconds 500
                $serial.Open()
                Start-Sleep -Milliseconds 100
                Invoke-RfCommand -Command 'STATUS' `
                    -ExpectedPattern '^OK STATE=FAULT POWER=OFF SOURCE=NONE FAULT=USB_DISCONNECTED ' | Out-Null
                $rfPowerAttempted = $false
                Invoke-RfCommand -Command 'FAULT CLEAR' `
                    -ExpectedPattern '^OK FAULT=NONE$' | Out-Null
            }
            default {
                Invoke-RfCommand -Command 'KEEPALIVE' `
                    -ExpectedPattern '^OK KEEPALIVE$' | Out-Null
                Invoke-RfCommand -Command 'POWER OFF' `
                    -ExpectedPattern $(if ($ExternalPower) {
                        '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$'
                    } else {
                        '^OK POWER=OFF$'
                    }) | Out-Null
                $rfPowerAttempted = $false
            }
        }
        $status = Invoke-RfCommand -Command 'STATUS' -ExpectedPattern '^OK '
        if ($ExternalPower) {
            if ($status -notmatch 'STATE=EXTERNAL_SAFE' -or
                $status -notmatch 'POWER=OFF' -or
                $status -notmatch 'SOURCE=EXTERNAL' -or
                $status -notmatch 'FAULT=NONE') {
                throw "Expected EXTERNAL_SAFE after RF power test, got: $status"
            }
            Write-Warning 'Control lines are safe. Now physically remove both external rails, then rerun with -ConfirmExternalPowerRemoved.'
        }
        elseif ($status -notmatch 'STATE=OFF' -or
                $status -notmatch 'POWER=OFF' -or
                $status -notmatch 'SOURCE=NONE' -or
                $status -notmatch 'FAULT=NONE') {
            throw "Expected a cleared safe state after RF power test, got: $status"
        }
    }

    Write-Host 'CDC smoke test passed.'
}
finally {
    if ($rfPowerAttempted -and -not $serial.IsOpen) {
        try {
            $serial.Open()
            Start-Sleep -Milliseconds 100
        }
        catch {
            Write-Warning "Could not reopen CDC for SAFE cleanup: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) {
        if ($rfPowerAttempted) {
            try {
                $serial.Write("SAFE`n")
                Start-Sleep -Milliseconds 100
                if ($ExternalPower) {
                    Write-Warning 'SAFE only disabled RF controls. Physically remove both external rails before acknowledging removal.'
                }
            }
            catch {
                Write-Warning "Could not send SAFE during cleanup: $($_.Exception.Message)"
            }
        }
        $serial.Close()
    }
    $serial.Dispose()
}
