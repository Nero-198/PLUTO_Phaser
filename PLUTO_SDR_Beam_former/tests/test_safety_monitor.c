#include <assert.h>
#include <stdio.h>

#include "power_timing.h"
#include "rf_frontend.h"
#include "safety_monitor.h"
#include "test_support.h"

static void test_timeout_and_disconnect(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    safety_monitor_t monitor;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(safety_monitor_init(&monitor, &io) == RF_STATUS_OK);
    assert(rf_frontend_power_on(&frontend) == RF_STATUS_OK);
    safety_monitor_note_valid_command(&monitor);
    assert(safety_monitor_remaining_ms(&monitor, &frontend) ==
           RF_COMMUNICATION_LEASE_MS);
    state.now_us += (uint64_t)RF_COMMUNICATION_LEASE_MS * 1000u - 1u;
    safety_monitor_poll(&monitor, &frontend, true);
    assert(frontend.state.power_state == RF_POWER_READY);
    assert(safety_monitor_remaining_ms(&monitor, &frontend) == 1u);
    state.now_us += 1u;
    safety_monitor_poll(&monitor, &frontend, true);
    assert(frontend.state.power_state == RF_POWER_FAULT);
    assert(frontend.state.fault == RF_FAULT_COMM_TIMEOUT);
    assert(!frontend.power_supply.enabled);

    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_OK);
    assert(rf_frontend_power_on(&frontend) == RF_STATUS_OK);
    safety_monitor_note_valid_command(&monitor);
    safety_monitor_poll(&monitor, &frontend, false);
    assert(frontend.state.power_state == RF_POWER_FAULT);
    assert(frontend.state.fault == RF_FAULT_USB_DISCONNECTED);
    assert(!frontend.power_supply.enabled);
}

static void test_external_disconnect_requires_power_removal(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    safety_monitor_t monitor;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(safety_monitor_init(&monitor, &io) == RF_STATUS_OK);
    assert(rf_frontend_power_on_external(&frontend) == RF_STATUS_OK);
    safety_monitor_note_valid_command(&monitor);
    safety_monitor_poll(&monitor, &frontend, false);
    assert(frontend.state.power_state == RF_POWER_FAULT);
    assert(frontend.state.power_source == RF_POWER_SOURCE_EXTERNAL);
    assert(frontend.state.fault == RF_FAULT_USB_DISCONNECTED);
    assert(!frontend.power_supply.enabled);
    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_NOT_READY);
    assert(rf_frontend_external_power_removed(&frontend) == RF_STATUS_OK);
    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_OK);
}

int main(void)
{
    test_timeout_and_disconnect();
    test_external_disconnect_requires_power_removal();
    puts("test_safety_monitor: passed");
    return 0;
}
