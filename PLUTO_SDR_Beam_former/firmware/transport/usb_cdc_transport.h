#ifndef USB_CDC_TRANSPORT_H
#define USB_CDC_TRANSPORT_H

#include <stdbool.h>
#include <stddef.h>

#include "line_reader.h"

#define USB_CDC_TX_BUFFER_SIZE 256u

typedef enum {
    USB_CDC_EVENT_NONE = 0,
    USB_CDC_EVENT_LINE,
    USB_CDC_EVENT_LINE_OVERFLOW
} usb_cdc_event_t;

typedef struct {
    line_reader_t line_reader;
    char tx_buffer[USB_CDC_TX_BUFFER_SIZE];
    size_t tx_length;
    size_t tx_offset;
    bool was_connected;
    bool connection_event;
} usb_cdc_transport_t;

void usb_cdc_transport_init(usb_cdc_transport_t *transport);
usb_cdc_event_t usb_cdc_transport_poll(usb_cdc_transport_t *transport);
bool usb_cdc_transport_is_connected(const usb_cdc_transport_t *transport);
bool usb_cdc_transport_take_connection_event(usb_cdc_transport_t *transport);
const char *usb_cdc_transport_line(const usb_cdc_transport_t *transport);
bool usb_cdc_transport_send_line(usb_cdc_transport_t *transport,
                                 const char *text);

#endif
