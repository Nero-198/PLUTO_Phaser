#ifndef TPS7A2033_H
#define TPS7A2033_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_io.h"
#include "rf_types.h"

typedef struct {
    rf_io_t io;
    uint8_t enable_pin;
    bool enabled;
} tps7a2033_t;

rf_status_t tps7a2033_init(tps7a2033_t *device, const rf_io_t *io,
                           uint8_t enable_pin);
void tps7a2033_set_enabled(tps7a2033_t *device, bool enabled);

#endif
