#include "pico_io.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pico/stdlib.h"

#include "board_pins.h"

static const uint8_t rf_output_pins[] = {
    BOARD_PIN_ATT_SER,      BOARD_PIN_ATT_SRCLK, BOARD_PIN_ATT_RCLK,
    BOARD_PIN_ATT_LE,       BOARD_PIN_ATT_SRCLR, BOARD_PIN_PHASE_LE,
    BOARD_PIN_PHASE_CLK,    BOARD_PIN_PHASE_SER, BOARD_PIN_LNA_CH1,
    BOARD_PIN_LNA_CH2,      BOARD_PIN_LDO_ENABLE};

static const uint8_t rf_serial_pins[] = {
    BOARD_PIN_ATT_SER,   BOARD_PIN_ATT_SRCLK, BOARD_PIN_ATT_RCLK,
    BOARD_PIN_ATT_LE,    BOARD_PIN_ATT_SRCLR, BOARD_PIN_PHASE_LE,
    BOARD_PIN_PHASE_CLK, BOARD_PIN_PHASE_SER};

static void pico_gpio_write(void *context, uint8_t pin, bool level)
{
    (void)context;
    gpio_put(pin, level);
}

static void pico_delay_us(void *context, uint32_t duration_us)
{
    (void)context;
    sleep_us(duration_us);
}

static uint64_t pico_time_us(void *context)
{
    (void)context;
    return time_us_64();
}

void rf_pico_io_init(rf_io_t *io)
{
    size_t index;

    if (io == NULL) {
        return;
    }
    for (index = 0u;
         index < sizeof(rf_output_pins) / sizeof(rf_output_pins[0]); ++index) {
        uint8_t pin = rf_output_pins[index];
        gpio_init(pin);
        gpio_put(pin, BOARD_RF_SAFE_LEVEL);
        gpio_set_dir(pin, GPIO_OUT);
    }
    for (index = 0u;
         index < sizeof(rf_serial_pins) / sizeof(rf_serial_pins[0]); ++index) {
        uint8_t pin = rf_serial_pins[index];
        gpio_set_drive_strength(pin, GPIO_DRIVE_STRENGTH_8MA);
        gpio_set_slew_rate(pin, GPIO_SLEW_RATE_SLOW);
    }
    gpio_init(BOARD_PIN_UART_TX);
    gpio_set_dir(BOARD_PIN_UART_TX, GPIO_IN);
    gpio_disable_pulls(BOARD_PIN_UART_TX);
    gpio_init(BOARD_PIN_UART_RX);
    gpio_set_dir(BOARD_PIN_UART_RX, GPIO_IN);
    gpio_disable_pulls(BOARD_PIN_UART_RX);

    io->context = NULL;
    io->gpio_write = pico_gpio_write;
    io->delay_us = pico_delay_us;
    io->time_us = pico_time_us;
}
