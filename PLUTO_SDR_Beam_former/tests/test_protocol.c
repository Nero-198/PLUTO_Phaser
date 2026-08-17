#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"
#include "command_protocol.h"
#include "line_reader.h"
#include "rf_frontend.h"
#include "test_support.h"

static command_protocol_result_t expect_response(rf_frontend_t *frontend,
                                                  const char *command,
                                                  const char *expected)
{
    char response[192];
    command_protocol_result_t result = command_protocol_execute(
        frontend, command, response, sizeof(response), 1234u);
    assert(result.response_length == strlen(expected));
    assert(strcmp(response, expected) == 0);
    return result;
}

static void test_protocol_commands(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    char response[192];
    char long_line[97];
    command_protocol_result_t result;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(expect_response(&frontend, "ping", "OK PONG").valid_command);
    assert(expect_response(&frontend, "KEEPALIVE", "OK KEEPALIVE")
               .valid_command);
    assert(expect_response(&frontend, "ATT 1 0", "ERR POWER_OFF")
               .valid_command);
    assert(expect_response(&frontend, "power on",
                           "OK POWER=ON SOURCE=INTERNAL")
               .valid_command);
    assert(expect_response(&frontend, "ATT 1 12.5", "OK").valid_command);
    assert(frontend.state.attenuation_steps[0] == 25u);
    assert(!expect_response(&frontend, "ATT 2 12.3", "ERR RANGE")
                .valid_command);
    assert(expect_response(&frontend, "PHASE 2 337.5", "OK").valid_command);
    assert(frontend.state.phase_steps[1] == 15u);
    assert(!expect_response(&frontend, "PHASE ALL 360", "ERR RANGE")
                .valid_command);
    assert(expect_response(&frontend, "LNA ALL ON", "OK").valid_command);
    assert(!expect_response(&frontend, "LNA 3 ON", "ERR SYNTAX")
                .valid_command);

    result = command_protocol_execute(&frontend, "STATUS", response,
                                      sizeof(response), 1234u);
    assert(result.valid_command);
    assert(strstr(response, "STATE=READY") != NULL);
    assert(strstr(response, "POWER=ON") != NULL);
    assert(strstr(response, "SOURCE=INTERNAL") != NULL);
    assert(strstr(response, "FAULT=NONE") != NULL);
    assert(strstr(response, "LEASE_MS=1234") != NULL);
    assert(strstr(response, "CH1_ATT=12.5") != NULL);
    assert(strstr(response, "CH2_PHASE=337.5") != NULL);

    assert(expect_response(&frontend, "SAFE", "OK SAFE").valid_command);
    assert(frontend.state.power_state == RF_POWER_OFF);

    rf_frontend_safe_shutdown(&frontend, RF_FAULT_USB_DISCONNECTED);
    assert(expect_response(&frontend, "POWER ON",
                           "ERR FAULT USB_DISCONNECTED")
               .valid_command);
    assert(expect_response(&frontend, "FAULT CLEAR", "OK FAULT=NONE")
               .valid_command);

    memset(long_line, 'A', sizeof(long_line) - 1u);
    long_line[sizeof(long_line) - 1u] = '\0';
    assert(!expect_response(&frontend, long_line, "ERR LINE_TOO_LONG")
                .valid_command);
}

static void test_external_power_commands(void)
{
    test_io_state_t state;
    rf_io_t io = test_make_io(&state);
    rf_frontend_t frontend;
    char response[192];
    command_protocol_result_t result;

    assert(rf_frontend_init(&frontend, &io) == RF_STATUS_OK);
    assert(expect_response(&frontend, "POWER EXTERNAL ON",
                           "OK POWER=ON SOURCE=EXTERNAL")
               .valid_command);
    assert(!state.levels[BOARD_PIN_LDO_ENABLE]);
    result = command_protocol_execute(&frontend, "STATUS", response,
                                      sizeof(response), 1234u);
    assert(result.valid_command);
    assert(strstr(response, "STATE=READY") != NULL);
    assert(strstr(response, "SOURCE=EXTERNAL") != NULL);

    assert(expect_response(&frontend, "POWER OFF",
                           "OK POWER=EXTERNAL_SAFE REMOVE_RAILS")
               .valid_command);
    assert(frontend.state.power_state == RF_POWER_EXTERNAL_SAFE);
    assert(expect_response(&frontend, "POWER EXTERNAL OFF",
                           "OK POWER=OFF SOURCE=NONE")
               .valid_command);
    assert(frontend.state.power_state == RF_POWER_OFF);

    assert(expect_response(&frontend, "POWER EXTERNAL ON",
                           "OK POWER=ON SOURCE=EXTERNAL")
               .valid_command);
    assert(expect_response(&frontend, "SAFE",
                           "OK SAFE EXTERNAL_RAILS_ON")
               .valid_command);
    assert(expect_response(&frontend, "POWER EXTERNAL ON",
                           "OK POWER=ON SOURCE=EXTERNAL")
               .valid_command);
    rf_frontend_safe_shutdown(&frontend, RF_FAULT_USB_DISCONNECTED);
    assert(expect_response(&frontend, "FAULT CLEAR", "ERR NOT_READY")
               .valid_command);
    assert(expect_response(&frontend, "POWER EXTERNAL OFF",
                           "OK POWER=OFF SOURCE=NONE")
               .valid_command);
    assert(expect_response(&frontend, "FAULT CLEAR", "OK FAULT=NONE")
               .valid_command);
}

static void test_fragmented_lines_and_overflow(void)
{
    line_reader_t reader;
    const char *fragment_1 = "ATT 1 ";
    const char *fragment_2 = "12.5\r\n";
    size_t index;
    line_reader_event_t event = LINE_READER_EVENT_NONE;

    line_reader_init(&reader);
    for (index = 0u; fragment_1[index] != '\0'; ++index) {
        assert(line_reader_feed(&reader, fragment_1[index]) ==
               LINE_READER_EVENT_NONE);
    }
    for (index = 0u; fragment_2[index] != '\0'; ++index) {
        event = line_reader_feed(&reader, fragment_2[index]);
    }
    assert(event == LINE_READER_EVENT_LINE);
    assert(strcmp(line_reader_line(&reader), "ATT 1 12.5") == 0);

    line_reader_init(&reader);
    for (index = 0u; index < LINE_READER_BUFFER_SIZE; ++index) {
        assert(line_reader_feed(&reader, 'X') == LINE_READER_EVENT_NONE);
    }
    assert(line_reader_feed(&reader, '\n') == LINE_READER_EVENT_OVERFLOW);
}

int main(void)
{
    test_protocol_commands();
    test_external_power_commands();
    test_fragmented_lines_and_overflow();
    puts("test_protocol: passed");
    return 0;
}
