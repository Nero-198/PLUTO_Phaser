#include <assert.h>
#include <stdio.h>

#include "board_pins.h"
#include "power_timing.h"
#include "rf_frontend.h"
#include "test_support.h"

static void test_power_sequences_and_guards(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    size_t ldo_on;
    size_t att_clock;
    size_t phase_clock;
    size_t lna_off;
    size_t att_latch;
    size_t phase_latch;
    size_t ldo_off;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_OFF);
    assert(frontend.state.power_source == RF_POWER_SOURCE_NONE);
    assert(frontend.state.attenuation_steps[0] == RF_ATTENUATION_MAX_STEPS);
    assert(!state.levels[BOARD_PIN_LDO_ENABLE]);
    assert(!state.levels[BOARD_PIN_LNA_CH1]);
    assert(!state.levels[BOARD_PIN_LNA_CH2]);

    frontend.state.power_state = RF_POWER_STARTING;
    assert(rf_frontend_set_attenuation(&frontend, RF_CHANNEL_1, 0u) ==
           RF_STATUS_NOT_READY);
    assert(rf_frontend_set_phase(&frontend, RF_CHANNEL_1, 0u) ==
           RF_STATUS_NOT_READY);
    assert(rf_frontend_set_lna(&frontend, RF_CHANNEL_1, true) ==
           RF_STATUS_NOT_READY);
    frontend.state.power_state = RF_POWER_OFF;

    test_clear_events(&state);
    assert(rf_frontend_power_on(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_READY);
    assert(frontend.state.power_source == RF_POWER_SOURCE_INTERNAL);
    assert(!frontend.state.lna_enabled[0] && !frontend.state.lna_enabled[1]);
    ldo_on = test_find_event(&state, BOARD_PIN_LDO_ENABLE, true, 0u);
    att_clock = test_find_event(&state, BOARD_PIN_ATT_SRCLK, true, 0u);
    phase_clock = test_find_event(&state, BOARD_PIN_PHASE_CLK, true, 0u);
    assert(ldo_on < state.event_count);
    assert(att_clock < state.event_count);
    assert(phase_clock < state.event_count);
    assert(state.events[att_clock].time_us - state.events[ldo_on].time_us >=
           RF_POWER_SETTLE_TIME_MS * 1000u);
    assert(state.events[phase_clock].time_us - state.events[ldo_on].time_us >=
           RF_POWER_SETTLE_TIME_MS * 1000u);

    assert(rf_frontend_set_attenuation_mask(
               &frontend, RF_CHANNEL_MASK_ALL, 20u) == RF_STATUS_OK);
    assert(rf_frontend_set_phase(&frontend, RF_CHANNEL_2, 15u) == RF_STATUS_OK);
    assert(rf_frontend_set_lna_mask(&frontend, RF_CHANNEL_MASK_ALL, true) ==
           RF_STATUS_OK);
    assert(state.levels[BOARD_PIN_LNA_CH1] &&
           state.levels[BOARD_PIN_LNA_CH2]);

    test_clear_events(&state);
    assert(rf_frontend_power_off(&frontend) == RF_STATUS_OK);
    lna_off = test_find_event(&state, BOARD_PIN_LNA_CH1, false, 0u);
    att_latch = test_find_event(&state, BOARD_PIN_ATT_LE, true, 0u);
    phase_latch = test_find_event(&state, BOARD_PIN_PHASE_LE, true, 0u);
    ldo_off = test_find_event(&state, BOARD_PIN_LDO_ENABLE, false, 0u);
    assert(lna_off < att_latch);
    assert(att_latch < phase_latch);
    assert(phase_latch < ldo_off);
    assert(state.now_us - state.events[ldo_off].time_us >=
           RF_POWER_DISCHARGE_TIME_MS * 1000u);
    assert(frontend.state.power_state == RF_POWER_OFF);
    assert(frontend.state.power_source == RF_POWER_SOURCE_NONE);
    assert(frontend.state.attenuation_steps[0] == RF_ATTENUATION_MAX_STEPS);
    assert(frontend.state.phase_steps[0] == 0u);
    assert(!state.levels[BOARD_PIN_LDO_ENABLE]);
    assert(!state.levels[BOARD_PIN_ATT_SRCLR]);
    assert(!state.levels[BOARD_PIN_PHASE_CLK]);
    assert(rf_frontend_set_attenuation(&frontend, RF_CHANNEL_1, 1u) ==
           RF_STATUS_POWER_OFF);
}

static void test_external_power_mode(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    uint64_t start_us;
    size_t att_clock;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    test_clear_events(&state);
    start_us = state.now_us;
    assert(rf_frontend_power_on_external(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_READY);
    assert(frontend.state.power_source == RF_POWER_SOURCE_EXTERNAL);
    assert(!frontend.power_supply.enabled);
    assert(!state.levels[BOARD_PIN_LDO_ENABLE]);
    assert(test_find_event(&state, BOARD_PIN_LDO_ENABLE, true, 0u) ==
           state.event_count);
    att_clock = test_find_event(&state, BOARD_PIN_ATT_SRCLK, true, 0u);
    assert(att_clock < state.event_count);
    assert(state.events[att_clock].time_us - start_us >=
           RF_POWER_SETTLE_TIME_MS * 1000u);

    assert(rf_frontend_set_lna(&frontend, RF_CHANNEL_1, true) ==
           RF_STATUS_OK);
    assert(rf_frontend_power_off(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_EXTERNAL_SAFE);
    assert(frontend.state.power_source == RF_POWER_SOURCE_EXTERNAL);
    assert(!state.levels[BOARD_PIN_LDO_ENABLE]);
    assert(!state.levels[BOARD_PIN_LNA_CH1]);
    assert(rf_frontend_set_attenuation(&frontend, RF_CHANNEL_1, 1u) ==
           RF_STATUS_NOT_READY);

    assert(rf_frontend_external_power_removed(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_OFF);
    assert(frontend.state.power_source == RF_POWER_SOURCE_NONE);

    assert(rf_frontend_power_on_external(&frontend) == RF_STATUS_OK);
    assert(rf_frontend_power_off(&frontend) == RF_STATUS_OK);
    assert(rf_frontend_power_on_external(&frontend) == RF_STATUS_OK);
    rf_frontend_safe_shutdown(&frontend, RF_FAULT_COMM_TIMEOUT);
    assert(frontend.state.power_state == RF_POWER_FAULT);
    assert(frontend.state.power_source == RF_POWER_SOURCE_EXTERNAL);
    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_NOT_READY);
    assert(rf_frontend_external_power_removed(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_source == RF_POWER_SOURCE_NONE);
    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_OK);
}

static void test_fault_latch(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(rf_frontend_power_on(&frontend) == RF_STATUS_OK);
    rf_frontend_safe_shutdown(&frontend, RF_FAULT_COMM_TIMEOUT);
    assert(frontend.state.power_state == RF_POWER_FAULT);
    assert(frontend.state.fault == RF_FAULT_COMM_TIMEOUT);
    assert(!frontend.power_supply.enabled);
    assert(rf_frontend_power_on(&frontend) == RF_STATUS_FAULT_LATCHED);
    assert(rf_frontend_clear_fault(&frontend) == RF_STATUS_OK);
    assert(frontend.state.power_state == RF_POWER_OFF);
    assert(frontend.state.fault == RF_FAULT_NONE);
}

int main(void)
{
    test_power_sequences_and_guards();
    test_external_power_mode();
    test_fault_latch();
    puts("test_rf_frontend: passed");
    return 0;
}
