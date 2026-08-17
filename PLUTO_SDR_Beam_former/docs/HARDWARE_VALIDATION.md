# Hardware validation record

## Functional validation status

Date: 2026-07-29

The assembled board has passed the operational functional validation for both
RF channels: internal positive/negative power generation, individual LNA
control, PE4302 attenuation, MAPS phase control, USB CDC operation, and safe
shutdown. The consolidated measurements and interpretation are recorded in:

- [2-channel RF frontend functional validation report](HARDWARE_VALIDATION_REPORT_20260729.md)

Absolute RF specifications and power-sequencing timing qualification remain
separate follow-up items; see the final section of the report.

## Completed bring-up checks

Date: 2026-07-16

- `RPI-RP2` detected as drive `F:`.
- UF2 SHA-256 written:
  `66CEC1CD404A2E3DB5AA0AD25552A7EB1862E422E3F91692CAB66776289DB9E9`.
- Picotool verified all written flash blocks and rebooted the target.
- Firmware enumerated as `USB Serial Device (COM4)`.
- CDC `PING` returned `OK PONG`.
- Startup `STATUS` returned `STATE=OFF`, `POWER=OFF`, `SOURCE=NONE`, `FAULT=NONE`,
  both channels at 31.5 dB and 0.0 degrees, and both LNAs OFF.
- After closing and reopening COM4 while RF power was OFF, `STATUS` still
  returned `FAULT=NONE`; an idle USB disconnect does not create a false fault.
- While RF power was OFF, `ATT 1 0`, `PHASE 1 22.5`, and `LNA 1 ON` each
  returned `ERR POWER_OFF`. A following `STATUS` proved that both channels
  remained at 31.5 dB, 0.0 degrees, and LNA OFF.
- A `PING` split into three USB writes (`P`, `IN`, `G`) returned `OK PONG`.
- `ATT 1 12.3` returned `ERR RANGE`, and a 96-character line returned
  `ERR LINE_TOO_LONG`; the following `STATUS` proved that the safe state was
  unchanged.
- Neither internal nor external RF power mode was enabled during this safe
  smoke test. External +/-3.3 V operation remains pending a current-limited
  bench-supply test.

## Automated bring-up

1. Hold BOOTSEL while connecting RP2040-Zero and verify that `RPI-RP2` appears.
2. Write the verified UF2 and wait for CDC enumeration:

   ```powershell
   .\tools\flash_uf2.ps1
   ```

3. Run the safe CDC-only test, replacing `COMx` with the enumerated port:

   ```powershell
   .\tools\cdc_smoke_test.ps1 -PortName COMx
   ```

4. Only after checking wiring, disconnecting RF input, and applying current
   limiting, enable the RF rails during the smoke test:

   ```powershell
   .\tools\cdc_smoke_test.ps1 -PortName COMx -EnableRfPower
   ```

5. Under the same safe hardware conditions, verify the communication lease and
   USB disconnect shutdown paths independently:

   ```powershell
   .\tools\cdc_smoke_test.ps1 -PortName COMx -EnableRfPower -FaultTest Timeout
   .\tools\cdc_smoke_test.ps1 -PortName COMx -EnableRfPower -FaultTest Disconnect
   ```

The power-enabled tests leave both LNAs OFF and initialize attenuation to
31.5 dB and phase to 0 degrees. The normal test sends `POWER OFF`; fault tests
verify the latched reason and clear it only after shutdown. The `finally`
cleanup reopens CDC if necessary and sends `SAFE` if a command fails after
power-on.

## External +/-3.3 V bring-up (power ICs not fitted)

This mode never drives GPIO26 High and cannot switch the bench supplies. Connect
the current-limited supplies to the intended RF +3.3 V and -3.3 V nets with a
common ground. Do not inject either rail into an RP2040 supply pin, USB 5 V, or
GPIO26.

1. Run the ordinary CDC-only test first and verify `SOURCE=NONE`.
2. Disconnect RF input, set conservative current limits, verify polarity, and
   apply both external rails.
3. Run:

   ```powershell
   .\tools\cdc_smoke_test.ps1 -PortName COMx -EnableRfPower -ExternalPower
   ```

   The script uses `POWER EXTERNAL ON`, checks the safe RF settings, then sends
   `POWER OFF`. It must finish in `STATE=EXTERNAL_SAFE SOURCE=EXTERNAL`.

4. Physically remove both external rails.
5. Only after measuring that both rails are removed, acknowledge removal:

   ```powershell
   .\tools\cdc_smoke_test.ps1 -PortName COMx -ConfirmExternalPowerRemoved
   ```

The acknowledgment command does not control the supplies. If USB disconnect or
the 2 s lease trips while external power is present, the firmware makes LNA,
ATT, phase, and buses safe but retains `SOURCE=EXTERNAL`; remove both rails and
run the acknowledgment command before clearing the fault.

## Oscilloscope record

Record the actual values below before accepting the timing constants.

| Measurement | Condition | Measured worst case | Acceptance |
| --- | --- | --- | --- |
| GPIO26 rise to +3.3 V stable | min/max input voltage and load | pending | less than control-write delay |
| GPIO26 rise to LM2776 EN = 1.2 V | min/max R/C tolerance | pending | recorded for margin calculation |
| GPIO26 rise to -3.3 V stable | min/max input, load, temperature | pending | less than 20 ms |
| GPIO26 fall to +3.3 V safe | worst-case load | pending | less than 25 ms |
| GPIO26 fall to -3.3 V safe | worst-case load | pending | less than 25 ms |
| First MAPS CLK after GPIO26 rise | power-on command | pending | at least 20 ms and after both rails stable |

If any power timing fails, update `firmware/include/power_timing.h`, rerun all
host tests, rebuild the UF2, and repeat the measurement.

## Logic-analyzer record

| Test | Expected | Result |
| --- | --- | --- |
| ATT ch1=0.5 dB, ch2=31.5 dB | data `0xFC, 0x04`; 16 SRCLK rises; RCLK then LE High-Low | pending |
| PHASE ch1=22.5 deg, ch2=337.5 deg | data `111100, 000100`; 12 CLK rises; LE rising edge | pending |
| USB disconnect while powered | LNA Low, max ATT, 0 deg, GPIO26 Low, FAULT latched | pending |
| 2 s communication timeout | same safe shutdown, `COMM_TIMEOUT` latched | pending |

Operational functional validation is complete and the measured waveforms and
RF results are referenced from the consolidated report above. Do not treat this
as absolute RF-performance or power-timing qualification until the remaining
calibrated measurements in that report are complete.
