#ifndef LINE_READER_H
#define LINE_READER_H

#include <stdbool.h>
#include <stddef.h>

#define LINE_READER_BUFFER_SIZE 96u

typedef enum {
    LINE_READER_EVENT_NONE = 0,
    LINE_READER_EVENT_LINE,
    LINE_READER_EVENT_OVERFLOW
} line_reader_event_t;

typedef struct {
    char buffer[LINE_READER_BUFFER_SIZE];
    size_t length;
    bool overflow;
} line_reader_t;

void line_reader_init(line_reader_t *reader);
line_reader_event_t line_reader_feed(line_reader_t *reader, char character);
const char *line_reader_line(const line_reader_t *reader);

#endif
