#ifndef BOARD_PINS_H
#define BOARD_PINS_H

#include <stdbool.h>
#include <stdint.h>

enum {
    BOARD_PIN_UART_TX = 0u,
    BOARD_PIN_UART_RX = 1u,
    BOARD_PIN_ATT_SER = 2u,
    BOARD_PIN_ATT_SRCLK = 3u,
    BOARD_PIN_ATT_RCLK = 4u,
    BOARD_PIN_ATT_LE = 5u,
    BOARD_PIN_ATT_SRCLR = 8u,
    BOARD_PIN_PHASE_LE = 9u,
    BOARD_PIN_PHASE_CLK = 10u,
    BOARD_PIN_PHASE_SER = 11u,
    BOARD_PIN_LNA_CH1 = 14u,
    BOARD_PIN_LNA_CH2 = 15u,
    BOARD_PIN_LDO_ENABLE = 26u
};

#define BOARD_RF_SAFE_LEVEL false

#endif
