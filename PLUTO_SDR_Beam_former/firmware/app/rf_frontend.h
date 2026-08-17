#ifndef RF_FRONTEND_H
#define RF_FRONTEND_H

#include <stdbool.h>
#include <stdint.h>

#include "bgb741.h"
#include "maps010144.h"
#include "pe4302.h"
#include "rf_io.h"
#include "rf_types.h"
#include "sn74hc595_chain.h"
#include "tps7a2033.h"

typedef struct {
    rf_power_state_t power_state;
    rf_power_source_t power_source;
    rf_fault_t fault;
    uint8_t attenuation_steps[2];
    uint8_t phase_steps[2];
    bool lna_enabled[2];
} rf_frontend_state_t;

typedef struct {
    rf_io_t io;
    sn74hc595_chain_t shift_registers;
    pe4302_t attenuators;
    maps010144_t phase_shifters;
    bgb741_t lnas;
    tps7a2033_t power_supply;
    rf_frontend_state_t state;
} rf_frontend_t;

rf_status_t rf_frontend_init(rf_frontend_t *frontend, const rf_io_t *io);
rf_status_t rf_frontend_power_on(rf_frontend_t *frontend);
rf_status_t rf_frontend_power_on_external(rf_frontend_t *frontend);
rf_status_t rf_frontend_power_off(rf_frontend_t *frontend);
rf_status_t rf_frontend_external_power_removed(rf_frontend_t *frontend);
rf_status_t rf_frontend_set_attenuation(rf_frontend_t *frontend,
                                         rf_channel_t channel, uint8_t steps);
rf_status_t rf_frontend_set_attenuation_mask(rf_frontend_t *frontend,
                                              uint8_t channel_mask,
                                              uint8_t steps);
rf_status_t rf_frontend_set_phase(rf_frontend_t *frontend,
                                  rf_channel_t channel, uint8_t steps);
rf_status_t rf_frontend_set_phase_mask(rf_frontend_t *frontend,
                                       uint8_t channel_mask, uint8_t steps);
rf_status_t rf_frontend_set_lna(rf_frontend_t *frontend,
                                rf_channel_t channel, bool enabled);
rf_status_t rf_frontend_set_lna_mask(rf_frontend_t *frontend,
                                     uint8_t channel_mask, bool enabled);
void rf_frontend_safe_shutdown(rf_frontend_t *frontend, rf_fault_t fault);
rf_status_t rf_frontend_clear_fault(rf_frontend_t *frontend);
const rf_frontend_state_t *rf_frontend_get_state(
    const rf_frontend_t *frontend);

const char *rf_power_state_name(rf_power_state_t state);
const char *rf_power_source_name(rf_power_source_t source);
const char *rf_fault_name(rf_fault_t fault);

#endif
