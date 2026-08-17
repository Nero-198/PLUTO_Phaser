#include "line_reader.h"

#include <stddef.h>

void line_reader_init(line_reader_t *reader)
{
    if (reader != NULL) {
        reader->buffer[0] = '\0';
        reader->length = 0u;
        reader->overflow = false;
    }
}

line_reader_event_t line_reader_feed(line_reader_t *reader, char character)
{
    line_reader_event_t event;

    if (reader == NULL || character == '\r') {
        return LINE_READER_EVENT_NONE;
    }
    if (character == '\n') {
        event = reader->overflow ? LINE_READER_EVENT_OVERFLOW
                                 : LINE_READER_EVENT_LINE;
        reader->buffer[reader->length] = '\0';
        reader->length = 0u;
        reader->overflow = false;
        return event;
    }
    if (!reader->overflow) {
        if (reader->length + 1u < sizeof(reader->buffer)) {
            reader->buffer[reader->length++] = character;
        } else {
            reader->overflow = true;
        }
    }
    return LINE_READER_EVENT_NONE;
}

const char *line_reader_line(const line_reader_t *reader)
{
    return reader == NULL ? "" : reader->buffer;
}
