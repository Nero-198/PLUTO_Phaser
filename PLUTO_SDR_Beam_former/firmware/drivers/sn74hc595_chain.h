#ifndef SN74HC595_CHAIN_H
#define SN74HC595_CHAIN_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_io.h"
#include "rf_types.h"

typedef struct {
    rf_io_t io;
    uint8_t ser_pin;
    uint8_t srclk_pin;
    uint8_t rclk_pin;
    uint8_t srclr_pin;
} sn74hc595_chain_t;

rf_status_t sn74hc595_chain_init(sn74hc595_chain_t *chain, const rf_io_t *io,
                                 uint8_t ser_pin, uint8_t srclk_pin,
                                 uint8_t rclk_pin, uint8_t srclr_pin);
void sn74hc595_chain_set_clear(sn74hc595_chain_t *chain, bool asserted);
void sn74hc595_chain_quiet(sn74hc595_chain_t *chain);
rf_status_t sn74hc595_chain_write(sn74hc595_chain_t *chain,
                                  const uint8_t *bytes, uint8_t count);

#endif
