#include "sn74hc595_chain.h"

#include <stddef.h>

#include "power_timing.h"

static void shift_byte(sn74hc595_chain_t *chain, uint8_t value)
{
    int bit;

    for (bit = 7; bit >= 0; --bit) {
        chain->io.gpio_write(chain->io.context, chain->ser_pin,
                             ((value >> (unsigned int)bit) & 1u) != 0u);
        chain->io.delay_us(chain->io.context,
                           RF_SN74HC595_EDGE_DELAY_US);
        chain->io.gpio_write(chain->io.context, chain->srclk_pin, true);
        chain->io.delay_us(chain->io.context,
                           RF_SN74HC595_EDGE_DELAY_US);
        chain->io.gpio_write(chain->io.context, chain->srclk_pin, false);
        chain->io.delay_us(chain->io.context,
                           RF_SN74HC595_EDGE_DELAY_US);
    }
}

rf_status_t sn74hc595_chain_init(sn74hc595_chain_t *chain, const rf_io_t *io,
                                 uint8_t ser_pin, uint8_t srclk_pin,
                                 uint8_t rclk_pin, uint8_t srclr_pin)
{
    if (chain == NULL || !rf_io_is_valid(io)) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    chain->io = *io;
    chain->ser_pin = ser_pin;
    chain->srclk_pin = srclk_pin;
    chain->rclk_pin = rclk_pin;
    chain->srclr_pin = srclr_pin;
    sn74hc595_chain_quiet(chain);
    return RF_STATUS_OK;
}

void sn74hc595_chain_set_clear(sn74hc595_chain_t *chain, bool asserted)
{
    if (chain != NULL) {
        chain->io.gpio_write(chain->io.context, chain->srclr_pin, !asserted);
    }
}

void sn74hc595_chain_quiet(sn74hc595_chain_t *chain)
{
    if (chain != NULL) {
        chain->io.gpio_write(chain->io.context, chain->ser_pin, false);
        chain->io.gpio_write(chain->io.context, chain->srclk_pin, false);
        chain->io.gpio_write(chain->io.context, chain->rclk_pin, false);
        sn74hc595_chain_set_clear(chain, true);
    }
}

rf_status_t sn74hc595_chain_write(sn74hc595_chain_t *chain,
                                  const uint8_t *bytes, uint8_t count)
{
    uint8_t index;

    if (chain == NULL || bytes == NULL || count == 0u) {
        return RF_STATUS_INVALID_ARGUMENT;
    }
    chain->io.gpio_write(chain->io.context, chain->srclk_pin, false);
    chain->io.gpio_write(chain->io.context, chain->rclk_pin, false);
    chain->io.gpio_write(chain->io.context, chain->ser_pin, false);
    /* SRCLR only clears the shift stages. The parallel outputs retain their
     * previous value until the deliberate RCLK rising edge below. */
    sn74hc595_chain_set_clear(chain, true);
    chain->io.delay_us(chain->io.context, RF_SN74HC595_EDGE_DELAY_US);
    sn74hc595_chain_set_clear(chain, false);
    chain->io.delay_us(chain->io.context, RF_SN74HC595_EDGE_DELAY_US);
    for (index = 0u; index < count; ++index) {
        shift_byte(chain, bytes[index]);
    }
    chain->io.delay_us(chain->io.context, RF_SN74HC595_EDGE_DELAY_US);
    chain->io.gpio_write(chain->io.context, chain->rclk_pin, true);
    chain->io.delay_us(chain->io.context, RF_SN74HC595_EDGE_DELAY_US);
    chain->io.gpio_write(chain->io.context, chain->rclk_pin, false);
    chain->io.delay_us(chain->io.context, RF_SN74HC595_EDGE_DELAY_US);
    chain->io.gpio_write(chain->io.context, chain->ser_pin, false);
    return RF_STATUS_OK;
}
