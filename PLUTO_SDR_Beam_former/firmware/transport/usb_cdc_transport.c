#include "usb_cdc_transport.h"

#include <stddef.h>
#include <string.h>

#include "pico/stdio.h"
#include "pico/stdio_usb.h"
#include "pico/stdlib.h"
#include "tusb.h"

static bool flush_tx(usb_cdc_transport_t *transport)
{
    size_t remaining;
    uint32_t available;
    uint32_t requested;
    uint32_t written;

    if (transport->tx_offset >= transport->tx_length) {
        transport->tx_offset = 0u;
        transport->tx_length = 0u;
        return true;
    }
    available = tud_cdc_write_available();
    if (available == 0u) {
        tud_cdc_write_flush();
        return false;
    }
    remaining = transport->tx_length - transport->tx_offset;
    requested = remaining < available ? (uint32_t)remaining : available;
    written = tud_cdc_write(transport->tx_buffer + transport->tx_offset,
                            requested);
    transport->tx_offset += written;
    tud_cdc_write_flush();
    if (transport->tx_offset >= transport->tx_length) {
        transport->tx_offset = 0u;
        transport->tx_length = 0u;
        return true;
    }
    return false;
}

void usb_cdc_transport_init(usb_cdc_transport_t *transport)
{
    if (transport != NULL) {
        line_reader_init(&transport->line_reader);
        transport->tx_length = 0u;
        transport->tx_offset = 0u;
        transport->was_connected = false;
        transport->connection_event = false;
    }
}

usb_cdc_event_t usb_cdc_transport_poll(usb_cdc_transport_t *transport)
{
    bool connected;
    int received;

    if (transport == NULL) {
        return USB_CDC_EVENT_NONE;
    }
    connected = stdio_usb_connected();
    if (connected && !transport->was_connected) {
        transport->connection_event = true;
        transport->was_connected = true;
        return USB_CDC_EVENT_NONE;
    }
    if (!connected && transport->was_connected) {
        line_reader_init(&transport->line_reader);
        transport->tx_length = 0u;
        transport->tx_offset = 0u;
    }
    transport->was_connected = connected;
    if (!connected) {
        return USB_CDC_EVENT_NONE;
    }
    if (!flush_tx(transport)) {
        return USB_CDC_EVENT_NONE;
    }

    while ((received = getchar_timeout_us(0u)) != PICO_ERROR_TIMEOUT) {
        line_reader_event_t line_event =
            line_reader_feed(&transport->line_reader, (char)received);
        if (line_event == LINE_READER_EVENT_LINE) {
            return USB_CDC_EVENT_LINE;
        }
        if (line_event == LINE_READER_EVENT_OVERFLOW) {
            return USB_CDC_EVENT_LINE_OVERFLOW;
        }
    }
    return USB_CDC_EVENT_NONE;
}

bool usb_cdc_transport_is_connected(const usb_cdc_transport_t *transport)
{
    return transport != NULL && transport->was_connected;
}

bool usb_cdc_transport_take_connection_event(usb_cdc_transport_t *transport)
{
    bool event;

    if (transport == NULL) {
        return false;
    }
    event = transport->connection_event;
    transport->connection_event = false;
    return event;
}

const char *usb_cdc_transport_line(const usb_cdc_transport_t *transport)
{
    return transport == NULL ? "" : line_reader_line(&transport->line_reader);
}

bool usb_cdc_transport_send_line(usb_cdc_transport_t *transport,
                                 const char *text)
{
    size_t length;

    if (transport == NULL || text == NULL || !transport->was_connected) {
        return false;
    }
    if (transport->tx_length != 0u) {
        return false;
    }
    length = strlen(text);
    if (length + 2u > sizeof(transport->tx_buffer)) {
        return false;
    }
    memcpy(transport->tx_buffer, text, length);
    transport->tx_buffer[length] = '\r';
    transport->tx_buffer[length + 1u] = '\n';
    transport->tx_length = length + 2u;
    transport->tx_offset = 0u;
    return true;
}
