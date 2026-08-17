#include "pe4302.h"

#include <stddef.h>

#include "power_timing.h"

rf_status_t pe4302_init(pe4302_t *device, sn74hc595_chain_t *chain,
                        uint8_t le_pin)
{
    if (device == NULL || chain == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    device->chain = chain;
    device->le_pin = le_pin;
    device->last_update_us = 0u;
    device->has_updated = false;
    pe4302_quiet(device);
    return RF_STATUS_OK;
}

rf_status_t pe4302_encode_chain(uint8_t channel_1_steps,
                                uint8_t channel_2_steps, uint8_t bytes[2])
{
    if (bytes == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    if (channel_1_steps > RF_ATTENUATION_MAX_STEPS ||
        channel_2_steps > RF_ATTENUATION_MAX_STEPS) {
        return RF_STATUS_OUT_OF_RANGE;
    }
    bytes[0] = (uint8_t)(channel_2_steps << 2u);
    bytes[1] = (uint8_t)(channel_1_steps << 2u);
    return RF_STATUS_OK;
}

rf_status_t pe4302_write(pe4302_t *device, uint8_t channel_1_steps,
                         uint8_t channel_2_steps)
{
    uint8_t bytes[2];
    uint64_t now;
    uint64_t elapsed;
    rf_status_t status;

    if (device == NULL || device->chain == NULL) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    status = pe4302_encode_chain(channel_1_steps, channel_2_steps, bytes);
    if (status != RF_STATUS_OK) {
        return status;
    }
    now = device->chain->io.time_us(device->chain->io.context);
    if (device->has_updated) {
        elapsed = now - device->last_update_us;
        if (elapsed < RF_ATTENUATOR_MIN_UPDATE_INTERVAL_US) {
            device->chain->io.delay_us(
                device->chain->io.context,
                (uint32_t)(RF_ATTENUATOR_MIN_UPDATE_INTERVAL_US - elapsed));
        }
    }
    device->chain->io.gpio_write(device->chain->io.context, device->le_pin,
                                 false);
    status = sn74hc595_chain_write(device->chain, bytes, 2u);
    if (status != RF_STATUS_OK) {
        return status;
    }
    device->chain->io.delay_us(device->chain->io.context,
                               RF_PE4302_LE_DELAY_US);
    device->chain->io.gpio_write(device->chain->io.context, device->le_pin,
                                 true);
    device->chain->io.delay_us(device->chain->io.context,
                               RF_PE4302_LE_DELAY_US);
    device->chain->io.gpio_write(device->chain->io.context, device->le_pin,
                                 false);
    device->chain->io.delay_us(device->chain->io.context,
                               RF_PE4302_LE_DELAY_US);
    device->last_update_us =
        device->chain->io.time_us(device->chain->io.context);
    device->has_updated = true;
    return RF_STATUS_OK;
}

void pe4302_quiet(pe4302_t *device)
{
    if (device != NULL && device->chain != NULL) {
        device->chain->io.gpio_write(device->chain->io.context, device->le_pin,
                                     false);
        sn74hc595_chain_quiet(device->chain);
    }
}
