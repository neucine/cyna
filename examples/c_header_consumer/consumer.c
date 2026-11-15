#include "c_header_consumer.h"

#include <stddef.h>

_Static_assert(sizeof(Header) >= sizeof(int) + sizeof(unsigned char),
    "Header should expose a concrete C layout");

int use_header(Header *header) {
    return header_len(*header) + (int)header_tag(header);
}
