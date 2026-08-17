#ifndef PE4302_H
#define PE4302_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_types.h"
#include "sn74hc595_chain.h"

typedef struct {
    sn74hc595_chain_t *chain;
    uint8_t le_pin;
    uint64_t last_update_us;
    bool has_updated;
} pe4302_t;

rf_status_t pe4302_init(pe4302_t *device, sn74hc595_chain_t *chain,
                        uint8_t le_pin);
rf_status_t pe4302_encode_chain(uint8_t channel_1_steps,
                                uint8_t channel_2_steps, uint8_t bytes[2]);
rf_status_t pe4302_write(pe4302_t *device, uint8_t channel_1_steps,
                         uint8_t channel_2_steps);
void pe4302_quiet(pe4302_t *device);

#endif
