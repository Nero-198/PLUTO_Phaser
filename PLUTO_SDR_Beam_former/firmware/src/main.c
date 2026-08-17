#include <stdbool.h>
#include <stddef.h>

#include "hardware/watchdog.h"
#include "pico/stdlib.h"

#include "command_protocol.h"
#include "pico_io.h"
#include "power_timing.h"
#include "rf_frontend.h"
#include "safety_monitor.h"
#include "usb_cdc_transport.h"

#define RESPONSE_BUFFER_SIZE 192u

int main(void)
{
    rf_io_t io;
    rf_frontend_t frontend;
    safety_monitor_t safety_monitor;
    usb_cdc_transport_t transport;
    char response[RESPONSE_BUFFER_SIZE];
    rf_status_t init_status;

    /* Establish the safe GPIO state before initializing USB or waiting for a
     * host. GPIO0/1 remain pull-free inputs reserved for future UART use. */
    rf_pico_io_init(&io);
    init_status = rf_frontend_init(&frontend, &io);
    if (init_status != RF_STATUS_OK) {
        /* rf_pico_io_init already established the physical safe state. Do not
         * touch partially initialized drivers; remain safe until reset. */
        for (;;) {
            tight_loop_contents();
        }
    }
    (void)safety_monitor_init(&safety_monitor, &io);

    stdio_init_all();
    usb_cdc_transport_init(&transport);
    watchdog_enable(RF_WATCHDOG_TIMEOUT_MS, true);

    for (;;) {
        usb_cdc_event_t event;

        watchdog_update();
        event = usb_cdc_transport_poll(&transport);
        if (usb_cdc_transport_take_connection_event(&transport)) {
            (void)usb_cdc_transport_send_line(
                &transport, "READY RF_FRONTEND 1.0 SAFE");
        }
        if (event == USB_CDC_EVENT_LINE_OVERFLOW) {
            (void)usb_cdc_transport_send_line(&transport,
                                              "ERR LINE_TOO_LONG");
        } else if (event == USB_CDC_EVENT_LINE) {
            command_protocol_result_t result = command_protocol_execute(
                &frontend, usb_cdc_transport_line(&transport), response,
                sizeof(response), safety_monitor_remaining_ms(
                                      &safety_monitor, &frontend));
            if (result.valid_command) {
                safety_monitor_note_valid_command(&safety_monitor);
            }
            if (result.response_length != 0u) {
                (void)usb_cdc_transport_send_line(&transport, response);
            }
        }
        safety_monitor_poll(&safety_monitor, &frontend,
                            usb_cdc_transport_is_connected(&transport));
        sleep_us(100u);
    }
}
