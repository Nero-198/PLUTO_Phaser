#ifndef TEST_SUPPORT_H
#define TEST_SUPPORT_H

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "rf_io.h"

#define TEST_MAX_GPIO_PINS 30u
#define TEST_MAX_EVENTS 4096u

typedef struct {
    uint8_t pin;
    bool level;
    uint64_t time_us;
} test_gpio_event_t;

typedef struct {
    uint64_t now_us;
    bool levels[TEST_MAX_GPIO_PINS];
    test_gpio_event_t events[TEST_MAX_EVENTS];
    size_t event_count;
} test_io_state_t;

static inline void test_gpio_write(void *context, uint8_t pin, bool level)
{
    test_io_state_t *state = context;
    assert(pin < TEST_MAX_GPIO_PINS);
    assert(state->event_count < TEST_MAX_EVENTS);
    state->levels[pin] = level;
    state->events[state->event_count++] =
        (test_gpio_event_t){pin, level, state->now_us};
}

static inline void test_delay_us(void *context, uint32_t duration_us)
{
    test_io_state_t *state = context;
    state->now_us += duration_us;
}

static inline uint64_t test_time_us(void *context)
{
    test_io_state_t *state = context;
    return state->now_us;
}

static inline rf_io_t test_make_io(test_io_state_t *state)
{
    rf_io_t io;
    memset(state, 0, sizeof(*state));
    io.context = state;
    io.gpio_write = test_gpio_write;
    io.delay_us = test_delay_us;
    io.time_us = test_time_us;
    return io;
}

static inline void test_clear_events(test_io_state_t *state)
{
    state->event_count = 0u;
}

static inline size_t test_count_rising_edges(const test_io_state_t *state,
                                             uint8_t pin)
{
    size_t count = 0u;
    size_t index;
    bool previous = false;

    for (index = 0u; index < state->event_count; ++index) {
        if (state->events[index].pin == pin) {
            if (!previous && state->events[index].level) {
                ++count;
            }
            previous = state->events[index].level;
        }
    }
    return count;
}

static inline size_t test_find_event(const test_io_state_t *state, uint8_t pin,
                                     bool level, size_t start)
{
    size_t index;
    for (index = start; index < state->event_count; ++index) {
        if (state->events[index].pin == pin &&
            state->events[index].level == level) {
            return index;
        }
    }
    return state->event_count;
}

#endif
