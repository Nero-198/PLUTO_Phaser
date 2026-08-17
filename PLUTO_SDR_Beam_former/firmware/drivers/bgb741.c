#include "bgb741.h"

#include <stddef.h>

rf_status_t bgb741_init(bgb741_t *device, const rf_io_t *io,
                        uint8_t channel_1_pin, uint8_t channel_2_pin)
{
    if (device == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    device->io = *io;
    device->pins[0] = channel_1_pin;
    device->pins[1] = channel_2_pin;
    bgb741_all_off(device);
    return RF_STATUS_OK;
}

rf_status_t bgb741_set(bgb741_t *device, rf_channel_t channel, bool enabled)
{
    if (device == NULL || (channel != RF_CHANNEL_1 && channel != RF_CHANNEL_2)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    device->io.gpio_write(device->io.context, device->pins[(unsigned)channel],
                          enabled);
    return RF_STATUS_OK;
}

void bgb741_all_off(bgb741_t *device)
{
    if (device != NULL) {
        device->io.gpio_write(device->io.context, device->pins[0], false);
        device->io.gpio_write(device->io.context, device->pins[1], false);
    }
}
