#include "maps010144.h"

#include <stddef.h>

#include "power_timing.h"

static void shift_word(maps010144_t *device, uint8_t word)
{
    int bit;

    for (bit = 5; bit >= 0; --bit) {
        device->io.gpio_write(device->io.context, device->ser_pin,
                              ((word >> (unsigned int)bit) & 1u) != 0u);
        device->io.delay_us(device->io.context, RF_SERIAL_HALF_PERIOD_US);
        device->io.gpio_write(device->io.context, device->clk_pin, true);
        device->io.delay_us(device->io.context, RF_SERIAL_HALF_PERIOD_US);
        device->io.gpio_write(device->io.context, device->clk_pin, false);
        device->io.delay_us(device->io.context, RF_SERIAL_HALF_PERIOD_US);
    }
}

rf_status_t maps010144_init(maps010144_t *device, const rf_io_t *io,
                            uint8_t ser_pin, uint8_t clk_pin, uint8_t le_pin)
{
    if (device == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    device->io = *io;
    device->ser_pin = ser_pin;
    device->clk_pin = clk_pin;
    device->le_pin = le_pin;
    device->last_le_us = 0u;
    device->has_updated = false;
    maps010144_quiet(device);
    return RF_STATUS_OK;
}

rf_status_t maps010144_encode_chain(uint8_t channel_1_steps,
                                    uint8_t channel_2_steps,
                                    uint8_t words[2])
{
    if (words == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (channel_1_steps > RF_PHASE_MAX_STEPS ||
        channel_2_steps > RF_PHASE_MAX_STEPS) {
        return RF_STATUS_OUT_OF_RANGE;
    }
    words[0] = (uint8_t)(channel_2_steps << 2u);
    words[1] = (uint8_t)(channel_1_steps << 2u);
    return RF_STATUS_OK;
}

rf_status_t maps010144_write(maps010144_t *device, uint8_t channel_1_steps,
                             uint8_t channel_2_steps)
{
    uint8_t words[2];
    uint64_t now;
    uint64_t elapsed;
    rf_status_t status;

    if (device == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    status = maps010144_encode_chain(channel_1_steps, channel_2_steps, words);
    if (status != RF_STATUS_OK) {
        return status;
    }
    now = device->io.time_us(device->io.context);
    if (device->has_updated) {
        elapsed = now - device->last_le_us;
        if (elapsed < RF_MAPS_MIN_LE_INTERVAL_US) {
            device->io.delay_us(
                device->io.context,
                (uint32_t)(RF_MAPS_MIN_LE_INTERVAL_US - elapsed));
        }
    }
    device->io.gpio_write(device->io.context, device->le_pin, false);
    device->io.gpio_write(device->io.context, device->clk_pin, false);
    shift_word(device, words[0]);
    shift_word(device, words[1]);
    device->io.delay_us(device->io.context, RF_SERIAL_HALF_PERIOD_US);
    device->io.gpio_write(device->io.context, device->le_pin, true);
    device->last_le_us = device->io.time_us(device->io.context);
    device->has_updated = true;
    device->io.delay_us(device->io.context, RF_SERIAL_HALF_PERIOD_US);
    device->io.gpio_write(device->io.context, device->le_pin, false);
    device->io.gpio_write(device->io.context, device->ser_pin, false);
    return RF_STATUS_OK;
}

void maps010144_quiet(maps010144_t *device)
{
    if (device != NULL) {
        device->io.gpio_write(device->io.context, device->ser_pin, false);
        device->io.gpio_write(device->io.context, device->clk_pin, false);
        device->io.gpio_write(device->io.context, device->le_pin, false);
    }
}
