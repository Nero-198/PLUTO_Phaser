[CmdletBinding()]
param(
    [string]$BeforeDirectory = "captures/internal_rf_phase_att_matrix_20260729",
    [string]$AfterDirectory = "captures/internal_rf_phase_att_matrix_rx_swapped_20260729"
)

$ErrorActionPreference = "Stop"
$beforeRoot = (Resolve-Path -LiteralPath $BeforeDirectory).Path
$afterRoot = (Resolve-Path -LiteralPath $AfterDirectory).Path
$beforeRows = Import-Csv -LiteralPath (Join-Path $beforeRoot "attenuation_summary.csv")
$afterRows = Import-Csv -LiteralPath (Join-Path $afterRoot "attenuation_summary.csv")
$comparison = [Collections.Generic.List[object]]::new()

foreach ($before in $beforeRows) {
    $attenuation = [double]$before.commanded_attenuation_db
    $after = $afterRows |
        Where-Object { [double]$_.commanded_attenuation_db -eq $attenuation } |
        Select-Object -First 1
    if ($null -eq $after) {
        throw "Missing post-swap ATT row: $attenuation dB"
    }

    $beforeRx1 = [double]$before.rx1_measured_change_db
    $beforeRx2 = [double]$before.rx2_measured_change_db
    $afterRx1 = [double]$after.rx1_measured_change_db
    $afterRx2 = [double]$after.rx2_measured_change_db

    # Before swap: board CH1 -> Rx2 and board CH2 -> Rx1.
    # After swap:  board CH1 -> Rx1 and board CH2 -> Rx2.
    $comparison.Add([pscustomobject]@{
        commanded_attenuation_db = $attenuation
        before_rx1_change_db     = $beforeRx1
        after_rx1_change_db      = $afterRx1
        rx1_repeat_difference_db = [math]::Round($afterRx1 - $beforeRx1, 3)
        before_rx2_change_db     = $beforeRx2
        after_rx2_change_db      = $afterRx2
        rx2_repeat_difference_db = [math]::Round($afterRx2 - $beforeRx2, 3)
        before_board_ch1_db      = $beforeRx2
        after_board_ch1_db       = $afterRx1
        board_ch1_difference_db  = [math]::Round($afterRx1 - $beforeRx2, 3)
        before_board_ch2_db      = $beforeRx1
        after_board_ch2_db       = $afterRx2
        board_ch2_difference_db  = [math]::Round($afterRx2 - $beforeRx1, 3)
    })
}

$csvPath = Join-Path $afterRoot "rx_swap_attenuation_comparison.csv"
$comparison | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$report = [Collections.Generic.List[string]]::new()
$report.Add("# Rx swap attenuation comparison")
$report.Add("")
$report.Add("Before the swap, board CH1 was observed by Rx2 and board CH2 by Rx1.")
$report.Add("After the swap, board CH1 is observed by Rx1 and board CH2 by Rx2.")
$report.Add("")
$report.Add("## Results grouped by Pluto receiver")
$report.Add("")
$report.Add("| ATT | Rx1 before | Rx1 after | Difference | Rx2 before | Rx2 after | Difference |")
$report.Add("|---:|---:|---:|---:|---:|---:|---:|")
foreach ($row in $comparison) {
    $report.Add(
        ("| {0:N1} | {1:N3} | {2:N3} | {3:N3} | {4:N3} | {5:N3} | {6:N3} |" -f
            $row.commanded_attenuation_db,
            $row.before_rx1_change_db,
            $row.after_rx1_change_db,
            $row.rx1_repeat_difference_db,
            $row.before_rx2_change_db,
            $row.after_rx2_change_db,
            $row.rx2_repeat_difference_db)
    )
}
$report.Add("")
$report.Add("## Results grouped by RF board channel")
$report.Add("")
$report.Add("| ATT | Board CH1 before | Board CH1 after | Difference | Board CH2 before | Board CH2 after | Difference |")
$report.Add("|---:|---:|---:|---:|---:|---:|---:|")
foreach ($row in $comparison) {
    $report.Add(
        ("| {0:N1} | {1:N3} | {2:N3} | {3:N3} | {4:N3} | {5:N3} | {6:N3} |" -f
            $row.commanded_attenuation_db,
            $row.before_board_ch1_db,
            $row.after_board_ch1_db,
            $row.board_ch1_difference_db,
            $row.before_board_ch2_db,
            $row.after_board_ch2_db,
            $row.board_ch2_difference_db)
    )
}
$report.Add("")
$report.Add("## Interpretation")
$report.Add("")
$report.Add("- At 10 and 20 dB, both board channels are close to the command and agree across the swap within about 1.1 dB.")
$report.Add("- Rx1 reproduces almost exactly the same attenuation after the board paths were exchanged.")
$report.Add("- The Rx1 shortfall at 31.5 dB therefore follows the Pluto Rx1 measurement path, not a particular PE4302 board channel.")
$report.Add("- The 31.5 dB points are close to the noise floor and should not be used alone to assign a board fault.")

$reportPath = Join-Path $afterRoot "RX_SWAP_COMPARISON.md"
$report | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host "Wrote:"
Write-Host "  $csvPath"
Write-Host "  $reportPath"
