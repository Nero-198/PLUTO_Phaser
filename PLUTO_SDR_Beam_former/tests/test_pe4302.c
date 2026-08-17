#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "board_pins.h"
#include "pe4302.h"
#include "power_timing.h"
#include "sn74hc595_chain.h"
#include "test_support.h"

static void test_all_codes_and_known_chain(void)
{
    uint8_t code;
    uint8_t bytes[2];

    for (code = 0u; code <= RF_ATTENUATION_MAX_STEPS; ++code) {
        assert(pe4302_encode_chain(code, code, bytes) == RF_STATUS_OK);
        assert(bytes[0] == (uint8_t)(code << 2u));
        assert(bytes[1] == (uint8_t)(code << 2u));
    }
    assert(pe4302_encode_chain(1u, 63u, bytes) == RF_STATUS_OK);
    assert(bytes[0] == 0xfcu);
    assert(bytes[1] == 0x04u);
    assert(pe4302_encode_chain(64u, 0u, bytes) == RF_STATUS_OUT_OF_RANGE);
}

static void test_waveform_and_update_interval(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    sn74hc595_chain_t chain;
    pe4302_t attenuator;
    size_t index;
    bool serial_level = false;
    uint16_t shifted = 0u;
    uint64_t first_latch_time;
    uint64_t second_latch_time;
    size_t clear_low_index;
    size_t clear_high_index;
    size_t first_clock_index;
    size_t last_clock_fall_index = 0u;
    size_t rclk_high_index;
    size_t rclk_low_index;
    size_t le_high_index;
    size_t le_low_index;

    assert(sn74hc595_chain_init(&chain, &io, BOARD_PIN_ATT_SER,
                                BOARD_PIN_ATT_SRCLK, BOARD_PIN_ATT_RCLK,
                                BOARD_PIN_ATT_SRCLR) == RF_STATUS_OK);
    assert(pe4302_init(&attenuator, &chain, BOARD_PIN_ATT_LE) == RF_STATUS_OK);
    test_clear_events(&state);
    assert(pe4302_write(&attenuator, 1u, 63u) == RF_STATUS_OK);
    assert(test_count_rising_edges(&state, BOARD_PIN_ATT_SRCLK) == 16u);
    assert(test_count_rising_edges(&state, BOARD_PIN_ATT_RCLK) == 1u);
    assert(test_count_rising_edges(&state, BOARD_PIN_ATT_LE) == 1u);

    clear_low_index =
        test_find_event(&state, BOARD_PIN_ATT_SRCLR, false, 0u);
    clear_high_index =
        test_find_event(&state, BOARD_PIN_ATT_SRCLR, true,
                        clear_low_index + 1u);
    first_clock_index =
        test_find_event(&state, BOARD_PIN_ATT_SRCLK, true, 0u);
    assert(clear_low_index < clear_high_index);
    assert(clear_high_index < first_clock_index);
    assert(state.events[clear_high_index].time_us -
               state.events[clear_low_index].time_us >=
           RF_SN74HC595_EDGE_DELAY_US);
    assert(state.events[first_clock_index].time_us -
               state.events[clear_high_index].time_us >=
           RF_SN74HC595_EDGE_DELAY_US);

    for (index = 0u; index < state.event_count; ++index) {
        if (state.events[index].pin == BOARD_PIN_ATT_SER) {
            serial_level = state.events[index].level;
        } else if (state.events[index].pin == BOARD_PIN_ATT_SRCLK &&
                   state.events[index].level) {
            size_t clock_fall_index =
                test_find_event(&state, BOARD_PIN_ATT_SRCLK, false,
                                index + 1u);
            assert(clock_fall_index < state.event_count);
            assert(state.events[clock_fall_index].time_us -
                       state.events[index].time_us >=
                   RF_SN74HC595_EDGE_DELAY_US);
            last_clock_fall_index = clock_fall_index;
            shifted = (uint16_t)((shifted << 1u) | (serial_level ? 1u : 0u));
        }
    }
    assert(shifted == 0xfc04u);
    rclk_high_index =
        test_find_event(&state, BOARD_PIN_ATT_RCLK, true, 0u);
    rclk_low_index =
        test_find_event(&state, BOARD_PIN_ATT_RCLK, false,
                        rclk_high_index + 1u);
    le_high_index = test_find_event(&state, BOARD_PIN_ATT_LE, true, 0u);
    le_low_index =
        test_find_event(&state, BOARD_PIN_ATT_LE, false,
                        le_high_index + 1u);
    assert(last_clock_fall_index < rclk_high_index);
    assert(rclk_high_index < rclk_low_index);
    assert(rclk_low_index < le_high_index);
    assert(le_high_index < le_low_index);
    assert(state.events[rclk_high_index].time_us -
               state.events[last_clock_fall_index].time_us >=
           RF_SN74HC595_EDGE_DELAY_US);
    assert(state.events[rclk_low_index].time_us -
               state.events[rclk_high_index].time_us >=
           RF_SN74HC595_EDGE_DELAY_US);
    assert(state.events[le_high_index].time_us -
               state.events[rclk_low_index].time_us >=
           RF_PE4302_LE_DELAY_US);
    assert(state.events[le_low_index].time_us -
               state.events[le_high_index].time_us >=
           RF_PE4302_LE_DELAY_US);
    first_latch_time = state.events[le_high_index].time_us;

    test_clear_events(&state);
    assert(pe4302_write(&attenuator, 2u, 3u) == RF_STATUS_OK);
    index = test_find_event(&state, BOARD_PIN_ATT_LE, true, 0u);
    assert(index < state.event_count);
    second_latch_time = state.events[index].time_us;
    assert(second_latch_time - first_latch_time >= 40u);
}

int main(void)
{
    test_all_codes_and_known_chain();
    test_waveform_and_update_interval();
    puts("test_pe4302: passed");
    return 0;
}
