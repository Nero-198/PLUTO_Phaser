#ifndef COMMAND_PROTOCOL_H
#define COMMAND_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rf_frontend.h"

typedef struct {
    size_t response_length;
    bool valid_command;
} command_protocol_result_t;

command_protocol_result_t command_protocol_execute(
    rf_frontend_t *frontend, const char *line, char *response,
    size_t response_size, uint32_t lease_remaining_ms);

#endif
