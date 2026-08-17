#include "rf_frontend.h"

#include <stddef.h>

#include "board_pins.h"
#include "power_timing.h"

static bool channel_mask_is_valid(uint8_t channel_mask)
{
    return channel_mask != 0u &&
           (channel_mask & (uint8_t)RF_CHANNEL_MASK_ALL) == channel_mask;
}

static void set_safe_logical_state(rf_frontend_t *frontend)
{
    frontend->state.attenuation_steps[0] = RF_ATTENUATION_MAX_STEPS;
    frontend->state.attenuation_steps[1] = RF_ATTENUATION_MAX_STEPS;
    frontend->state.phase_steps[0] = 0u;
    frontend->state.phase_steps[1] = 0u;
    frontend->state.lna_enabled[0] = false;
    frontend->state.lna_enabled[1] = false;
}

static void quiet_all_buses(rf_frontend_t *frontend)
{
    pe4302_quiet(&frontend->attenuators);
    maps010144_quiet(&frontend->phase_shifters);
}

static rf_status_t ready_status(const rf_frontend_t *frontend)
{
    if (frontend->state.fault != RF_FAULT_NONE ||
        frontend->state.power_state == RF_POWER_FAULT) {
        return RF_STATUS_FAULT_LATCHED;
    }
    if (frontend->state.power_state == RF_POWER_OFF) {
        return RF_STATUS_POWER_OFF;
    }
    if (frontend->state.power_state != RF_POWER_READY) {
        return RF_STATUS_NOT_READY;
    }
    return RF_STATUS_OK;
}

rf_status_t rf_frontend_init(rf_frontend_t *frontend, const rf_io_t *io)
{
    rf_status_t status;

    if (frontend == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    frontend->io = *io;
    frontend->state.power_state = RF_POWER_OFF;
    frontend->state.power_source = RF_POWER_SOURCE_NONE;
    frontend->state.fault = RF_FAULT_NONE;
    set_safe_logical_state(frontend);

    status = sn74hc595_chain_init(
        &frontend->shift_registers, io, BOARD_PIN_ATT_SER,
        BOARD_PIN_ATT_SRCLK, BOARD_PIN_ATT_RCLK, BOARD_PIN_ATT_SRCLR);
    if (status != RF_STATUS_OK) {
        return status;
    }
    status = pe4302_init(&frontend->attenuators, &frontend->shift_registers,
                         BOARD_PIN_ATT_LE);
    if (status != RF_STATUS_OK) {
        return status;
    }
    status = maps010144_init(&frontend->phase_shifters, io,
                             BOARD_PIN_PHASE_SER, BOARD_PIN_PHASE_CLK,
                             BOARD_PIN_PHASE_LE);
    if (status != RF_STATUS_OK) {
        return status;
    }
    status = bgb741_init(&frontend->lnas, io, BOARD_PIN_LNA_CH1,
                         BOARD_PIN_LNA_CH2);
    if (status != RF_STATUS_OK) {
        return status;
    }
    status = tps7a2033_init(&frontend->power_supply, io,
                            BOARD_PIN_LDO_ENABLE);
    if (status != RF_STATUS_OK) {
        return status;
    }
    bgb741_all_off(&frontend->lnas);
    quiet_all_buses(frontend);
    tps7a2033_set_enabled(&frontend->power_supply, false);
    return RF_STATUS_OK;
}

static rf_status_t power_on_with_source(rf_frontend_t *frontend,
                                        rf_power_source_t source)
{
    rf_status_t status;

    if (frontend == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (frontend->state.fault != RF_FAULT_NONE) {
        return RF_STATUS_FAULT_LATCHED;
    }
    if (source != RF_POWER_SOURCE_INTERNAL &&
        source != RF_POWER_SOURCE_EXTERNAL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (frontend->state.power_state == RF_POWER_READY) {
        return frontend->state.power_source == source
                   ? RF_STATUS_OK
                   : RF_STATUS_NOT_READY;
    }
    if (source == RF_POWER_SOURCE_INTERNAL &&
        (frontend->state.power_state != RF_POWER_OFF ||
         frontend->state.power_source != RF_POWER_SOURCE_NONE)) {
        return RF_STATUS_NOT_READY;
    }
    if (source == RF_POWER_SOURCE_EXTERNAL &&
        !((frontend->state.power_state == RF_POWER_OFF &&
           frontend->state.power_source == RF_POWER_SOURCE_NONE) ||
          (frontend->state.power_state == RF_POWER_EXTERNAL_SAFE &&
           frontend->state.power_source == RF_POWER_SOURCE_EXTERNAL))) {
        return RF_STATUS_NOT_READY;
    }

    bgb741_all_off(&frontend->lnas);
    quiet_all_buses(frontend);
    frontend->state.power_state = RF_POWER_STARTING;
    frontend->state.power_source = source;
    tps7a2033_set_enabled(
        &frontend->power_supply, source == RF_POWER_SOURCE_INTERNAL);
    frontend->io.delay_us(frontend->io.context,
                          RF_POWER_SETTLE_TIME_MS * 1000u);

    sn74hc595_chain_set_clear(&frontend->shift_registers, false);
    status = pe4302_write(&frontend->attenuators, RF_ATTENUATION_MAX_STEPS,
                          RF_ATTENUATION_MAX_STEPS);
    if (status == RF_STATUS_OK) {
        status = maps010144_write(&frontend->phase_shifters, 0u, 0u);
    }
    if (status != RF_STATUS_OK) {
        rf_frontend_safe_shutdown(frontend, RF_FAULT_INIT_FAILURE);
        return RF_STATUS_IO_ERROR;
    }
    set_safe_logical_state(frontend);
    frontend->state.power_state = RF_POWER_READY;
    return RF_STATUS_OK;
}

rf_status_t rf_frontend_power_on(rf_frontend_t *frontend)
{
    return power_on_with_source(frontend, RF_POWER_SOURCE_INTERNAL);
}

rf_status_t rf_frontend_power_on_external(rf_frontend_t *frontend)
{
    return power_on_with_source(frontend, RF_POWER_SOURCE_EXTERNAL);
}

rf_status_t rf_frontend_power_off(rf_frontend_t *frontend)
{
    if (frontend == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (frontend->state.power_state == RF_POWER_FAULT) {
        return RF_STATUS_FAULT_LATCHED;
    }
    if (frontend->state.power_state == RF_POWER_OFF ||
        frontend->state.power_state == RF_POWER_EXTERNAL_SAFE) {
        bgb741_all_off(&frontend->lnas);
        quiet_all_buses(frontend);
        tps7a2033_set_enabled(&frontend->power_supply, false);
        set_safe_logical_state(frontend);
        return RF_STATUS_OK;
    }
    if (frontend->state.power_state != RF_POWER_READY) {
        return RF_STATUS_NOT_READY;
    }
    rf_frontend_safe_shutdown(frontend, RF_FAULT_NONE);
    return RF_STATUS_OK;
}

rf_status_t rf_frontend_external_power_removed(rf_frontend_t *frontend)
{
    if (frontend == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (frontend->state.power_source != RF_POWER_SOURCE_EXTERNAL ||
        (frontend->state.power_state != RF_POWER_EXTERNAL_SAFE &&
         frontend->state.power_state != RF_POWER_FAULT)) {
        return RF_STATUS_NOT_READY;
    }

    bgb741_all_off(&frontend->lnas);
    quiet_all_buses(frontend);
    tps7a2033_set_enabled(&frontend->power_supply, false);
    set_safe_logical_state(frontend);
    frontend->state.power_source = RF_POWER_SOURCE_NONE;
    if (frontend->state.fault == RF_FAULT_NONE) {
        frontend->state.power_state = RF_POWER_OFF;
    }
    return RF_STATUS_OK;
}

rf_status_t rf_frontend_set_attenuation_mask(rf_frontend_t *frontend,
                                              uint8_t channel_mask,
                                              uint8_t steps)
{
    uint8_t channel_1_steps;
    uint8_t channel_2_steps;
    rf_status_t status;

    if (frontend == NULL || !channel_mask_is_valid(channel_mask)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (steps > RF_ATTENUATION_MAX_STEPS) {
        return RF_STATUS_OUT_OF_RANGE;
    }
    status = ready_status(frontend);
    if (status != RF_STATUS_OK) {
        return status;
    }
    channel_1_steps = (channel_mask & RF_CHANNEL_MASK_1) != 0u
                          ? steps
                          : frontend->state.attenuation_steps[0];
    channel_2_steps = (channel_mask & RF_CHANNEL_MASK_2) != 0u
                          ? steps
                          : frontend->state.attenuation_steps[1];
    status = pe4302_write(&frontend->attenuators, channel_1_steps,
                          channel_2_steps);
    if (status == RF_STATUS_OK) {
        frontend->state.attenuation_steps[0] = channel_1_steps;
        frontend->state.attenuation_steps[1] = channel_2_steps;
    }
    return status;
}

rf_status_t rf_frontend_set_attenuation(rf_frontend_t *frontend,
                                         rf_channel_t channel, uint8_t steps)
{
    if (channel != RF_CHANNEL_1 && channel != RF_CHANNEL_2) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    return rf_frontend_set_attenuation_mask(
        frontend, channel == RF_CHANNEL_1 ? RF_CHANNEL_MASK_1
                                         : RF_CHANNEL_MASK_2,
        steps);
}

rf_status_t rf_frontend_set_phase_mask(rf_frontend_t *frontend,
                                       uint8_t channel_mask, uint8_t steps)
{
    uint8_t channel_1_steps;
    uint8_t channel_2_steps;
    rf_status_t status;

    if (frontend == NULL || !channel_mask_is_valid(channel_mask)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (steps > RF_PHASE_MAX_STEPS) {
        return RF_STATUS_OUT_OF_RANGE;
    }
    status = ready_status(frontend);
    if (status != RF_STATUS_OK) {
        return status;
    }
    channel_1_steps = (channel_mask & RF_CHANNEL_MASK_1) != 0u
                          ? steps
                          : frontend->state.phase_steps[0];
    channel_2_steps = (channel_mask & RF_CHANNEL_MASK_2) != 0u
                          ? steps
                          : frontend->state.phase_steps[1];
    status = maps010144_write(&frontend->phase_shifters, channel_1_steps,
                              channel_2_steps);
    if (status == RF_STATUS_OK) {
        frontend->state.phase_steps[0] = channel_1_steps;
        frontend->state.phase_steps[1] = channel_2_steps;
    }
    return status;
}

rf_status_t rf_frontend_set_phase(rf_frontend_t *frontend,
                                  rf_channel_t channel, uint8_t steps)
{
    if (channel != RF_CHANNEL_1 && channel != RF_CHANNEL_2) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    return rf_frontend_set_phase_mask(
        frontend, channel == RF_CHANNEL_1 ? RF_CHANNEL_MASK_1
                                         : RF_CHANNEL_MASK_2,
        steps);
}

rf_status_t rf_frontend_set_lna_mask(rf_frontend_t *frontend,
                                     uint8_t channel_mask, bool enabled)
{
    rf_status_t status;

    if (frontend == NULL || !channel_mask_is_valid(channel_mask)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (!enabled) {
        if ((channel_mask & RF_CHANNEL_MASK_1) != 0u) {
            (void)bgb741_set(&frontend->lnas, RF_CHANNEL_1, false);
            frontend->state.lna_enabled[0] = false;
        }
        if ((channel_mask & RF_CHANNEL_MASK_2) != 0u) {
            (void)bgb741_set(&frontend->lnas, RF_CHANNEL_2, false);
            frontend->state.lna_enabled[1] = false;
        }
        return RF_STATUS_OK;
    }
    status = ready_status(frontend);
    if (status != RF_STATUS_OK) {
        return status;
    }
    if ((channel_mask & RF_CHANNEL_MASK_1) != 0u) {
        (void)bgb741_set(&frontend->lnas, RF_CHANNEL_1, true);
        frontend->state.lna_enabled[0] = true;
    }
    if ((channel_mask & RF_CHANNEL_MASK_2) != 0u) {
        (void)bgb741_set(&frontend->lnas, RF_CHANNEL_2, true);
        frontend->state.lna_enabled[1] = true;
    }
    return RF_STATUS_OK;
}

rf_status_t rf_frontend_set_lna(rf_frontend_t *frontend,
                                rf_channel_t channel, bool enabled)
{
    if (channel != RF_CHANNEL_1 && channel != RF_CHANNEL_2) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    return rf_frontend_set_lna_mask(
        frontend, channel == RF_CHANNEL_1 ? RF_CHANNEL_MASK_1
                                         : RF_CHANNEL_MASK_2,
        enabled);
}

void rf_frontend_safe_shutdown(rf_frontend_t *frontend, rf_fault_t fault)
{
    bool controls_powered;
    rf_power_source_t source;
    rf_power_state_t previous_state;

    if (frontend == NULL) {
        return;
    }
    source = frontend->state.power_source;
    previous_state = frontend->state.power_state;
    controls_powered = source != RF_POWER_SOURCE_NONE &&
                       (previous_state == RF_POWER_READY ||
                        previous_state == RF_POWER_STARTING);
    frontend->state.power_state = RF_POWER_STOPPING;
    bgb741_all_off(&frontend->lnas);
    frontend->state.lna_enabled[0] = false;
    frontend->state.lna_enabled[1] = false;

    if (controls_powered) {
        (void)pe4302_write(&frontend->attenuators,
                           RF_ATTENUATION_MAX_STEPS,
                           RF_ATTENUATION_MAX_STEPS);
        (void)maps010144_write(&frontend->phase_shifters, 0u, 0u);
    }
    tps7a2033_set_enabled(&frontend->power_supply, false);
    quiet_all_buses(frontend);
    if (source == RF_POWER_SOURCE_INTERNAL) {
        frontend->io.delay_us(frontend->io.context,
                              RF_POWER_DISCHARGE_TIME_MS * 1000u);
        frontend->state.power_source = RF_POWER_SOURCE_NONE;
    }
    set_safe_logical_state(frontend);
    frontend->state.fault = fault;
    if (fault != RF_FAULT_NONE) {
        frontend->state.power_state = RF_POWER_FAULT;
    } else if (source == RF_POWER_SOURCE_EXTERNAL) {
        frontend->state.power_state = RF_POWER_EXTERNAL_SAFE;
    } else {
        frontend->state.power_state = RF_POWER_OFF;
    }
}

rf_status_t rf_frontend_clear_fault(rf_frontend_t *frontend)
{
    if (frontend == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (frontend->state.power_state != RF_POWER_FAULT ||
        frontend->power_supply.enabled ||
        frontend->state.power_source != RF_POWER_SOURCE_NONE) {
        return RF_STATUS_NOT_READY;
    }
    frontend->state.fault = RF_FAULT_NONE;
    frontend->state.power_state = RF_POWER_OFF;
    return RF_STATUS_OK;
}

const rf_frontend_state_t *rf_frontend_get_state(
    const rf_frontend_t *frontend)
{
    return frontend == NULL ? NULL : &frontend->state;
}

const char *rf_power_state_name(rf_power_state_t state)
{
    switch (state) {
    case RF_POWER_OFF:
        return "OFF";
    case RF_POWER_STARTING:
        return "STARTING";
    case RF_POWER_READY:
        return "READY";
    case RF_POWER_STOPPING:
        return "STOPPING";
    case RF_POWER_EXTERNAL_SAFE:
        return "EXTERNAL_SAFE";
    case RF_POWER_FAULT:
        return "FAULT";
    default:
        return "UNKNOWN";
    }
}

const char *rf_power_source_name(rf_power_source_t source)
{
    switch (source) {
    case RF_POWER_SOURCE_NONE:
        return "NONE";
    case RF_POWER_SOURCE_INTERNAL:
        return "INTERNAL";
    case RF_POWER_SOURCE_EXTERNAL:
        return "EXTERNAL";
    default:
        return "UNKNOWN";
    }
}

const char *rf_fault_name(rf_fault_t fault)
{
    switch (fault) {
    case RF_FAULT_NONE:
        return "NONE";
    case RF_FAULT_COMM_TIMEOUT:
        return "COMM_TIMEOUT";
    case RF_FAULT_USB_DISCONNECTED:
        return "USB_DISCONNECTED";
    case RF_FAULT_INIT_FAILURE:
        return "INIT_FAILURE";
    default:
        return "UNKNOWN";
    }
}
