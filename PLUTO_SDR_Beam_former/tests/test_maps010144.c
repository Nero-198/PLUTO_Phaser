#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "board_pins.h"
#include "maps010144.h"
#include "test_support.h"

static void test_all_codes_and_known_chain(void)
{
    uint8_t code;
    uint8_t words[2];

    for (code = 0u; code <= RF_PHASE_MAX_STEPS; ++code) {
        assert(maps010144_encode_chain(code, code, words) == RF_STATUS_OK);
        assert(words[0] == (uint8_t)(code << 2u));
        assert(words[1] == (uint8_t)(code << 2u));
    }
    assert(maps010144_encode_chain(1u, 15u, words) == RF_STATUS_OK);
    assert(words[0] == 0x3cu);
    assert(words[1] == 0x04u);
    assert(maps010144_encode_chain(16u, 0u, words) == RF_STATUS_OUT_OF_RANGE);
}

static void test_waveform(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    maps010144_t phase;
    size_t index;
    bool serial_level = false;
    uint16_t shifted = 0u;
    unsigned sampled_bits = 0u;
    uint64_t first_le_time;
    uint64_t second_le_time;

    assert(maps010144_init(&phase, &io, BOARD_PIN_PHASE_SER,
                           BOARD_PIN_PHASE_CLK,
                           BOARD_PIN_PHASE_LE) == RF_STATUS_OK);
    test_clear_events(&state);
    assert(maps010144_write(&phase, 1u, 15u) == RF_STATUS_OK);
    assert(test_count_rising_edges(&state, BOARD_PIN_PHASE_CLK) == 12u);
    assert(test_count_rising_edges(&state, BOARD_PIN_PHASE_LE) == 1u);
    for (index = 0u; index < state.event_count; ++index) {
        if (state.events[index].pin == BOARD_PIN_PHASE_SER) {
            serial_level = state.events[index].level;
        } else if (state.events[index].pin == BOARD_PIN_PHASE_CLK &&
                   state.events[index].level) {
            shifted = (uint16_t)((shifted << 1u) | (serial_level ? 1u : 0u));
            ++sampled_bits;
        }
    }
    assert(sampled_bits == 12u);
    assert(shifted == 0x0f04u);
    index = test_find_event(&state, BOARD_PIN_PHASE_LE, true, 0u);
    assert(index < state.event_count);
    first_le_time = state.events[index].time_us;

    test_clear_events(&state);
    assert(maps010144_write(&phase, 0u, 0u) == RF_STATUS_OK);
    index = test_find_event(&state, BOARD_PIN_PHASE_LE, true, 0u);
    assert(index < state.event_count);
    second_le_time = state.events[index].time_us;
    assert(second_le_time - first_le_time >= 1u);
}

int main(void)
{
    test_all_codes_and_known_chain();
    test_waveform();
    puts("test_maps010144: passed");
    return 0;
}
