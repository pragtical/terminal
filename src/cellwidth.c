#include <stddef.h>
#include "cellwidth.h"
#include "../lib/pragtical/src/unidata.h"

static int contains(const range_table* ranges, size_t count, uint32_t cp) {
  size_t lo = 0;
  while (lo < count) {
    size_t mid = lo + (count - lo) / 2;
    const range_table* range = &ranges[mid];
    if (cp < range->first) count = mid;
    else if (cp > range->last) lo = mid + 1;
    else return (cp - range->first) % range->step == 0;
  }
  return 0;
}

#define IN_TABLE(table, cp) contains(table, sizeof(table) / sizeof(*table), cp)

int terminal_char_width(uint32_t cp) {
  if (cp < 0x300) return 1;
  if (cp == 0x200d || (cp >= 0x1f3fb && cp <= 0x1f3ff) ||
      IN_TABLE(compose_table, cp) || IN_TABLE(spacing_mark_table, cp) ||
      (cp >= 0xe0020 && cp <= 0xe007f)) return 0;
  return IN_TABLE(doublewidth_table, cp) ? 2 : 1;
}

int terminal_is_pictograph(uint32_t cp) {
  return IN_TABLE(pictographic_table, cp);
}
