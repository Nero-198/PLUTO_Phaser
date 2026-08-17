#ifndef RF_IO_H
#define RF_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    void *context;
    void (*gpio_write)(void *context, uint8_t pin, bool level);
    void (*delay_us)(void *context, uint32_t duration_us);
    uint64_t (*time_us)(void *context);
} rf_io_t;

static inline bool rf_io_is_valid(const rf_io_t *io)
{
    return io != NULL && io->gpio_write != NULL && io->delay_us != NULL &&
           io->time_us != NULL;
}

#endif
