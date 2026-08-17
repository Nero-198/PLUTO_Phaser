#ifndef SAFETY_MONITOR_H
#define SAFETY_MONITOR_H

#include <stdbool.h>
#include <stdint.h>

#include "rf_frontend.h"
#include "rf_io.h"
#include "rf_types.h"

typedef struct {
    rf_io_t io;
    uint64_t last_valid_command_us;
} safety_monitor_t;

rf_status_t safety_monitor_init(safety_monitor_t *monitor, const rf_io_t *io);
void safety_monitor_note_valid_command(safety_monitor_t *monitor);
void safety_monitor_poll(safety_monitor_t *monitor, rf_frontend_t *frontend,
                         bool usb_connected);
uint32_t safety_monitor_remaining_ms(const safety_monitor_t *monitor,
                                     const rf_frontend_t *frontend);

#endif
