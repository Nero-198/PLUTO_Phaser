#include "tps7a2033.h"

#include <stddef.h>

rf_status_t tps7a2033_init(tps7a2033_t *device, const rf_io_t *io,
                           uint8_t enable_pin)
{
    if (device == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    device->io = *io;
    device->enable_pin = enable_pin;
    device->enabled = false;
    tps7a2033_set_enabled(device, false);
    return RF_STATUS_OK;
}

void tps7a2033_set_enabled(tps7a2033_t *device, bool enabled)
{
    if (device != NULL) {
        device->io.gpio_write(device->io.context, device->enable_pin, enabled);
        device->enabled = enabled;
    }
}
