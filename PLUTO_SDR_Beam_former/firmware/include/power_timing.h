#ifndef POWER_TIMING_H
#define POWER_TIMING_H

#define RF_POWER_SETTLE_TIME_MS 20u
#define RF_POWER_DISCHARGE_TIME_MS 25u
#define RF_COMMUNICATION_LEASE_MS 2000u
#define RF_WATCHDOG_TIMEOUT_MS 2000u

#define RF_SERIAL_HALF_PERIOD_US 1u
/* SN74HC595 Rev. J requires at most 125 ns for the relevant setup and
 * pulse-width constraints at 2 V. Use 5 us to tolerate board-level edge
 * degradation and make logic-analyzer validation unambiguous. */
#define RF_SN74HC595_EDGE_DELAY_US 5u
#define RF_PE4302_LE_DELAY_US 5u
#define RF_ATTENUATOR_MIN_UPDATE_INTERVAL_US 40u
#define RF_MAPS_MIN_LE_INTERVAL_US 1u

#endif
