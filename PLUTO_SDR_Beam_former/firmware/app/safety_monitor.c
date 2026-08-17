#include "safety_monitor.h"

#include <stddef.h>

#include "power_timing.h"

#define MICROSECONDS_PER_MILLISECOND 1000u

rf_status_t safety_monitor_init(safety_monitor_t *monitor, const rf_io_t *io)
{
    if (monitor == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    monitor->io = *io;
    monitor->last_valid_command_us = io->time_us(io->context);
    return RF_STATUS_OK;
}

void safety_monitor_note_valid_command(safety_monitor_t *monitor)
{
    if (monitor != NULL) {
        monitor->last_valid_command_us =
            monitor->io.time_us(monitor->io.context);
    }
}

void safety_monitor_poll(safety_monitor_t *monitor, rf_frontend_t *frontend,
                         bool usb_connected)
{
    uint64_t elapsed_us;

    if (monitor == NULL || frontend == NULL ||
        frontend->state.power_state != RF_POWER_READY) {
        return;
    }
    if (!usb_connected) {
        rf_frontend_safe_shutdown(frontend, RF_FAULT_USB_DISCONNECTED);
        return;
    }
    elapsed_us = monitor->io.time_us(monitor->io.context) -
                 monitor->last_valid_command_us;
    if (elapsed_us >=
        (uint64_t)RF_COMMUNICATION_LEASE_MS * MICROSECONDS_PER_MILLISECOND) {
        rf_frontend_safe_shutdown(frontend, RF_FAULT_COMM_TIMEOUT);
    }
}

uint32_t safety_monitor_remaining_ms(const safety_monitor_t *monitor,
                                     const rf_frontend_t *frontend)
{
    uint64_t timeout_us;
    uint64_t elapsed_us;
    uint64_t remaining_us;

    if (monitor == NULL || frontend == NULL ||
        frontend->state.power_state != RF_POWER_READY) {
        return 0u;
    }
    timeout_us =
        (uint64_t)RF_COMMUNICATION_LEASE_MS * MICROSECONDS_PER_MILLISECOND;
    elapsed_us = monitor->io.time_us(monitor->io.context) -
                 monitor->last_valid_command_us;
    if (elapsed_us >= timeout_us) {
        return 0u;
    }
    remaining_us = timeout_us - elapsed_us;
    return (uint32_t)((remaining_us + MICROSECONDS_PER_MILLISECOND - 1u) /
                      MICROSECONDS_PER_MILLISECOND);
}
