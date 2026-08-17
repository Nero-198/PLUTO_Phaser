#ifndef MAPS010144_H
#define MAPS010144_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_io.h"
#include "rf_types.h"

typedef struct {
    rf_io_t io;
    uint8_t ser_pin;
    uint8_t clk_pin;
    uint8_t le_pin;
    uint64_t last_le_us;
    bool has_updated;
} maps010144_t;

rf_status_t maps010144_init(maps010144_t *device, const rf_io_t *io,
                            uint8_t ser_pin, uint8_t clk_pin, uint8_t le_pin);
rf_status_t maps010144_encode_chain(uint8_t channel_1_steps,
                                    uint8_t channel_2_steps,
                                    uint8_t words[2]);
rf_status_t maps010144_write(maps010144_t *device, uint8_t channel_1_steps,
                             uint8_t channel_2_steps);
void maps010144_quiet(maps010144_t *device);

#endif
