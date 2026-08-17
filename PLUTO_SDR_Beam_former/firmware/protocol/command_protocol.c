#include "command_protocol.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "rf_types.h"

#define COMMAND_BUFFER_SIZE 96u
#define MAX_TOKENS 4u

static char ascii_upper(char value)
{
    if (value >= 'a' && value <= 'z') {
        return (char)(value - ('a' - 'A'));
    }
    return value;
}

static bool token_equals(const char *left, const char *right)
{
    while (*left != '\0' && *right != '\0') {
        if (ascii_upper(*left) != ascii_upper(*right)) {
            return false;
        }
        ++left;
        ++right;
    }
    return *left == '\0' && *right == '\0';
}

static size_t write_response(char *response, size_t response_size,
                             const char *text)
{
    int count;

    if (response == NULL || response_size == 0u) {
        return 0u;
    }
    count = snprintf(response, response_size, "%s", text);
    if (count < 0) {
        response[0] = '\0';
        return 0u;
    }
    return (size_t)count < response_size ? (size_t)count : response_size - 1u;
}

static command_protocol_result_t result_with_text(char *response,
                                                   size_t response_size,
                                                   const char *text,
                                                   bool valid)
{
    command_protocol_result_t result;
    result.response_length = write_response(response, response_size, text);
    result.valid_command = valid;
    return result;
}

static size_t tokenize(char *buffer, char *tokens[MAX_TOKENS])
{
    size_t count = 0u;
    char *cursor = buffer;

    while (*cursor != '\0') {
        while (*cursor == ' ' || *cursor == '\t') {
            ++cursor;
        }
        if (*cursor == '\0') {
            break;
        }
        if (count == MAX_TOKENS) {
            return MAX_TOKENS + 1u;
        }
        tokens[count++] = cursor;
        while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t') {
            ++cursor;
        }
        if (*cursor != '\0') {
            *cursor++ = '\0';
        }
    }
    return count;
}

/* Parses a non-negative decimal with no fraction or a .0/.5 fraction and
 * returns the value multiplied by two. */
static bool parse_times_two(const char *text, uint16_t *value)
{
    uint32_t integer = 0u;
    uint32_t result;
    bool has_digit = false;

    while (*text >= '0' && *text <= '9') {
        has_digit = true;
        integer = integer * 10u + (uint32_t)(*text - '0');
        if (integer > 32767u) {
            return false;
        }
        ++text;
    }
    if (!has_digit) {
        return false;
    }
    result = integer * 2u;
    if (*text == '.') {
        ++text;
        if (*text == '5') {
            ++result;
            ++text;
        } else if (*text == '0') {
            ++text;
        } else {
            return false;
        }
    }
    if (*text != '\0' || result > UINT16_MAX) {
        return false;
    }
    *value = (uint16_t)result;
    return true;
}

static bool parse_channel_mask(const char *text, uint8_t *channel_mask)
{
    if (token_equals(text, "1")) {
        *channel_mask = RF_CHANNEL_MASK_1;
        return true;
    }
    if (token_equals(text, "2")) {
        *channel_mask = RF_CHANNEL_MASK_2;
        return true;
    }
    if (token_equals(text, "ALL")) {
        *channel_mask = RF_CHANNEL_MASK_ALL;
        return true;
    }
    return false;
}

static bool parse_on_off(const char *text, bool *enabled)
{
    if (token_equals(text, "ON")) {
        *enabled = true;
        return true;
    }
    if (token_equals(text, "OFF")) {
        *enabled = false;
        return true;
    }
    return false;
}

static command_protocol_result_t status_result(
    const rf_frontend_t *frontend, char *response, size_t response_size,
    uint32_t lease_remaining_ms)
{
    const rf_frontend_state_t *state = rf_frontend_get_state(frontend);
    unsigned att1_tenths = (unsigned)state->attenuation_steps[0] * 5u;
    unsigned att2_tenths = (unsigned)state->attenuation_steps[1] * 5u;
    unsigned phase1_tenths = (unsigned)state->phase_steps[0] * 225u;
    unsigned phase2_tenths = (unsigned)state->phase_steps[1] * 225u;
    int count;
    command_protocol_result_t result;

    count = snprintf(
        response, response_size,
        "OK STATE=%s POWER=%s SOURCE=%s FAULT=%s LEASE_MS=%lu "
        "CH1_ATT=%u.%u CH1_PHASE=%u.%u CH1_LNA=%s "
        "CH2_ATT=%u.%u CH2_PHASE=%u.%u CH2_LNA=%s",
        rf_power_state_name(state->power_state),
        state->power_state == RF_POWER_READY ? "ON" : "OFF",
        rf_power_source_name(state->power_source),
        rf_fault_name(state->fault), (unsigned long)lease_remaining_ms,
        att1_tenths / 10u, att1_tenths % 10u, phase1_tenths / 10u,
        phase1_tenths % 10u, state->lna_enabled[0] ? "ON" : "OFF",
        att2_tenths / 10u, att2_tenths % 10u, phase2_tenths / 10u,
        phase2_tenths % 10u, state->lna_enabled[1] ? "ON" : "OFF");
    result.response_length =
        count < 0 || response_size == 0u
            ? 0u
            : ((size_t)count < response_size ? (size_t)count
                                             : response_size - 1u);
    result.valid_command = true;
    return result;
}

static command_protocol_result_t status_code_result(
    rf_status_t status, char *response, size_t response_size,
    const char *success_text, const rf_frontend_t *frontend)
{
    char fault_text[64];

    switch (status) {
    case RF_STATUS_OK:
        return result_with_text(response, response_size, success_text, true);
    case RF_STATUS_OUT_OF_RANGE:
        return result_with_text(response, response_size, "ERR RANGE", true);
    case RF_STATUS_POWER_OFF:
        return result_with_text(response, response_size, "ERR POWER_OFF", true);
    case RF_STATUS_NOT_READY:
        return result_with_text(response, response_size, "ERR NOT_READY", true);
    case RF_STATUS_FAULT_LATCHED:
        (void)snprintf(fault_text, sizeof(fault_text), "ERR FAULT %s",
                       rf_fault_name(frontend->state.fault));
        return result_with_text(response, response_size, fault_text, true);
    case RF_STATUS_IO_ERROR:
        return result_with_text(response, response_size, "ERR IO", true);
    case RF_STATUS_INVALID_ARGUMENT:
    default:
        return result_with_text(response, response_size, "ERR SYNTAX", false);
    }
}

command_protocol_result_t command_protocol_execute(
    rf_frontend_t *frontend, const char *line, char *response,
    size_t response_size, uint32_t lease_remaining_ms)
{
    char buffer[COMMAND_BUFFER_SIZE];
    char *tokens[MAX_TOKENS];
    size_t line_length;
    size_t token_count;
    uint8_t channel_mask;
    uint16_t numeric;
    bool enabled;
    rf_status_t status;

    if (frontend == NULL || line == NULL || response == NULL ||
        response_size == 0u) {
        return (command_protocol_result_t){0u, false};
    }
    line_length = strlen(line);
    if (line_length >= sizeof(buffer)) {
        return result_with_text(response, response_size, "ERR LINE_TOO_LONG",
                                false);
    }
    memcpy(buffer, line, line_length + 1u);
    token_count = tokenize(buffer, tokens);
    if (token_count == 0u) {
        response[0] = '\0';
        return (command_protocol_result_t){0u, false};
    }
    if (token_count > MAX_TOKENS) {
        return result_with_text(response, response_size, "ERR SYNTAX", false);
    }

    if (token_equals(tokens[0], "PING") && token_count == 1u) {
        return result_with_text(response, response_size, "OK PONG", true);
    }
    if (token_equals(tokens[0], "KEEPALIVE") && token_count == 1u) {
        return result_with_text(response, response_size, "OK KEEPALIVE", true);
    }
    if (token_equals(tokens[0], "HELP") && token_count == 1u) {
        return result_with_text(
            response, response_size,
            "OK COMMANDS=PING,KEEPALIVE,HELP,STATUS,POWER,SAFE,FAULT,ATT,PHASE,LNA",
            true);
    }
    if (token_equals(tokens[0], "STATUS") && token_count == 1u) {
        return status_result(frontend, response, response_size,
                             lease_remaining_ms);
    }
    if (token_equals(tokens[0], "SAFE") && token_count == 1u) {
        if (frontend->state.fault != RF_FAULT_NONE) {
            return status_code_result(RF_STATUS_FAULT_LATCHED, response,
                                      response_size, "OK SAFE", frontend);
        }
        rf_frontend_safe_shutdown(frontend, RF_FAULT_NONE);
        return result_with_text(
            response, response_size,
            frontend->state.power_source == RF_POWER_SOURCE_EXTERNAL
                ? "OK SAFE EXTERNAL_RAILS_ON"
                : "OK SAFE",
            true);
    }
    if (token_equals(tokens[0], "FAULT") && token_count == 2u &&
        token_equals(tokens[1], "CLEAR")) {
        status = rf_frontend_clear_fault(frontend);
        return status_code_result(status, response, response_size,
                                  "OK FAULT=NONE", frontend);
    }
    if (token_equals(tokens[0], "POWER") && token_count == 2u &&
        parse_on_off(tokens[1], &enabled)) {
        status = enabled ? rf_frontend_power_on(frontend)
                         : rf_frontend_power_off(frontend);
        return status_code_result(
            status, response, response_size,
            enabled ? "OK POWER=ON SOURCE=INTERNAL"
                    : (frontend->state.power_source ==
                               RF_POWER_SOURCE_EXTERNAL
                           ? "OK POWER=EXTERNAL_SAFE REMOVE_RAILS"
                           : "OK POWER=OFF"),
            frontend);
    }
    if (token_equals(tokens[0], "POWER") && token_count == 3u &&
        token_equals(tokens[1], "EXTERNAL") &&
        parse_on_off(tokens[2], &enabled)) {
        status = enabled
                     ? rf_frontend_power_on_external(frontend)
                     : rf_frontend_external_power_removed(frontend);
        return status_code_result(
            status, response, response_size,
            enabled ? "OK POWER=ON SOURCE=EXTERNAL"
                    : "OK POWER=OFF SOURCE=NONE",
            frontend);
    }
    if (token_equals(tokens[0], "ATT") && token_count == 3u) {
        if (!parse_channel_mask(tokens[1], &channel_mask)) {
            return result_with_text(response, response_size, "ERR SYNTAX",
                                    false);
        }
        if (!parse_times_two(tokens[2], &numeric) ||
            numeric > RF_ATTENUATION_MAX_STEPS) {
            return result_with_text(response, response_size, "ERR RANGE",
                                    false);
        }
        status = rf_frontend_set_attenuation_mask(frontend, channel_mask,
                                                  (uint8_t)numeric);
        return status_code_result(status, response, response_size, "OK",
                                  frontend);
    }
    if (token_equals(tokens[0], "PHASE") && token_count == 3u) {
        if (!parse_channel_mask(tokens[1], &channel_mask)) {
            return result_with_text(response, response_size, "ERR SYNTAX",
                                    false);
        }
        if (!parse_times_two(tokens[2], &numeric) || numeric > 675u ||
            (numeric % 45u) != 0u) {
            return result_with_text(response, response_size, "ERR RANGE",
                                    false);
        }
        status = rf_frontend_set_phase_mask(frontend, channel_mask,
                                            (uint8_t)(numeric / 45u));
        return status_code_result(status, response, response_size, "OK",
                                  frontend);
    }
    if (token_equals(tokens[0], "LNA") && token_count == 3u) {
        if (!parse_channel_mask(tokens[1], &channel_mask) ||
            !parse_on_off(tokens[2], &enabled)) {
            return result_with_text(response, response_size, "ERR SYNTAX",
                                    false);
        }
        status = rf_frontend_set_lna_mask(frontend, channel_mask, enabled);
        return status_code_result(status, response, response_size, "OK",
                                  frontend);
    }
    return result_with_text(response, response_size, "ERR SYNTAX", false);
}
