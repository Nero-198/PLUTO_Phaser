#ifndef BGB741_H
#define BGB741_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_io.h"
#include "rf_types.h"

typedef struct {
    rf_io_t io;
    uint8_t pins[2];
} bgb741_t;

rf_status_t bgb741_init(bgb741_t *device, const rf_io_t *io,
                        uint8_t channel_1_pin, uint8_t channel_2_pin);
rf_status_t bgb741_set(bgb741_t *device, rf_channel_t channel, bool enabled);
void bgb741_all_off(bgb741_t *device);

#endif
