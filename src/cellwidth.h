#ifndef TERMINAL_CELLWIDTH_H
#define TERMINAL_CELLWIDTH_H

#include <stdint.h>

int terminal_char_width(uint32_t cp);
int terminal_is_pictograph(uint32_t cp);

#endif
