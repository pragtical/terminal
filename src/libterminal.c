#if _WIN32
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  // https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
  #if __MINGW32__ || __MINGW64__ // https://stackoverflow.com/questions/66419746/is-there-support-for-winpty-in-mingw-w64
    #define NTDDI_VERSION 0x0A000006 //NTDDI_WIN10_RS5
    #undef _WIN32_WINNT
    #define _WIN32_WINNT 0x0A00 // _WIN32_WINNT_WIN10
  #endif
  #include <windows.h>
  #include <wincon.h>
#else
  #include <unistd.h>
  #include <fcntl.h>
  #include <sys/ioctl.h>
  #include <sys/types.h>
  #include <sys/wait.h>
  #include <signal.h>
  #if __APPLE__
    #include <util.h>
  #else
    #include <pty.h>
  #endif
#endif
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <inttypes.h>
#include "cellwidth.h"

#ifdef LIBTERMINAL_STANDALONE
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>
#else
  #define PRAGTICAL_PLUGIN_ENTRYPOINT
  #include <pragtical_plugin_api.h>
#endif

#ifndef min
  static int min(int a, int b) { return a < b ? a : b; }
  static int max(int a, int b) { return a > b ? a : b; }
#endif

#define LIBTERMINAL_BACKBUFFER_PAGE_LINES 200
#define LIBTERMINAL_CHUNK_SIZE 4096
#define LIBTERMINAL_MAX_CHUNKS_PROCESSED 10
#define LIBTERMINAL_MAX_LINE_WIDTH 1024
#define LIBTERMINAL_NAME_MAX 256
#define LIBTERMINAL_DEFAULT_TAB_SIZE 8

typedef enum attributes_e {
  // Colors
  ATTRIBUTE_UNSET_COLOR = 0,
  ATTRIBUTE_INVERSE_COLOR = 1,
  ATTRIBUTE_INDEX_COLOR = 2,
  ATTRIBUTE_RGB_COLOR = 3,
  // Background attribute bits carry the remaining text decorations.
  ATTRIBUTE_CONCEAL = 8,
  ATTRIBUTE_STRIKE = 16,
  // Attributes
  ATTRIBUTE_BOLD = 8,
  ATTRIBUTE_ITALIC = 16,
  ATTRIBUTE_UNDERLINE = 32,
  ATTRIBUTE_FAINT = 64,
  ATTRIBUTE_INVERSE = 128,
  ATTRIBUTE_STYLING_MASK = (ATTRIBUTE_BOLD | ATTRIBUTE_ITALIC | ATTRIBUTE_UNDERLINE | ATTRIBUTE_FAINT | ATTRIBUTE_INVERSE)
} attributes_e;

typedef struct color_t {
  union {
    struct {
      uint8_t attributes;
      union {
        struct {
          uint8_t r;
          uint8_t g;
          uint8_t b;
        };
        uint8_t index;
      };
    };
    uint32_t value;
  };
} color_t;
static color_t indexed_color(uint8_t index) { return (color_t) { .attributes = ATTRIBUTE_INDEX_COLOR, .index = index }; }
static color_t rgb_color(uint8_t r, uint8_t g, uint8_t b) { return (color_t) { .attributes = ATTRIBUTE_RGB_COLOR, .r = r, .g = g, .b = b }; }
static color_t UNSET_COLOR = { .attributes = ATTRIBUTE_UNSET_COLOR, .index = 0 };
static color_t INVERSE_COLOR = { .attributes = ATTRIBUTE_INVERSE_COLOR, .index = 0 };

#define LIBTERMINAL_NO_STYLING (buffer_styling_t) { .value = 0 }

typedef struct buffer_styling_t {
  union {
    struct {
      color_t foreground;
      color_t background;
    };
    uint64_t value;
  };
} buffer_styling_t;

// Only multi-codepoint glyphs allocate extra storage. A cell copied to
// scrollback can share its immutable suffix with the original screen.
typedef struct glyph_suffix_t {
  unsigned references, length, capacity;
  uint32_t last;
  char text[];
} glyph_suffix_t;

#define WIDE_TAIL 0x110000u

typedef struct buffer_char_t {
  buffer_styling_t styling;
  uint32_t codepoint;
  glyph_suffix_t* suffix;
} buffer_char_t;

typedef struct backbuffer_page_t {
  struct backbuffer_page_t* prev;
  struct backbuffer_page_t* next;
  int columns, lines, line, first;
  buffer_char_t buffer[];
} backbuffer_page_t;

typedef enum view_e {
  VIEW_NORMAL_BUFFER = 0,
  VIEW_ALTERNATE_BUFFER = 1,
  VIEW_MAX = 2
} view_e;

typedef enum cursor_mode_e {
  CURSOR_SOLID         = 0,
  CURSOR_HIDDEN        = 1,
  CURSOR_BLINKING      = 2,
} cursor_mode_e;

typedef enum paste_mode_e {
  PASTE_NORMAL,
  PASTE_BRACKETED
} paste_mode_e;

typedef enum keys_mode_e {
  KEYS_MODE_NORMAL,
  KEYS_MODE_APPLICATION
} keys_mode_e;

typedef enum mouse_tracking_mode_e {
  MOUSE_TRACKING_NONE,
  MOUSE_TRACKING_X10,
  MOUSE_TRACKING_NORMAL,
  MOUSE_TRACKING_BUTTON,
  MOUSE_TRACKING_ANY
} mouse_tracking_mode_e;

typedef enum mouse_encoding_e {
  MOUSE_ENCODING_DEFAULT,
  MOUSE_ENCODING_SGR
} mouse_encoding_e;

typedef enum charset_e {
  CHARSET_US,
  CHARSET_DEC,
  CHARSET_OTHER
} charset_e;

typedef struct view_t {
  buffer_char_t* buffer;
  int* overflows; // I don't like this, but as a result of how this is architected, this is necessary to ensure proper line outputs.
  int cursor_x, cursor_y;
  int wrap_pending, autowrap, origin_mode;
  buffer_styling_t cursor_styling; // What characters are currently being emitted as.
  int saved_cursor_x, saved_cursor_y;
  int saved_wrap_pending, saved_origin_mode, saved_autowrap;
  buffer_styling_t saved_cursor_styling;
  charset_e saved_charset;
  cursor_mode_e cursor_mode;
  int cursor_hidden, cursor_shape;
  keys_mode_e cursor_keys_mode;
  keys_mode_e keypad_keys_mode;
  color_t palette[256];                // Custom palette as per the ^][4;#;rgb:24/04/3C command. The fuck?
  charset_e charset;
  int last_graphical_character; // for CSI b
  int tab_size;
  // The index of where the scrolling region starts/ends.
  // If enabled, disables shuffling of text to the scrollback
  // buffer. When applied, shifts cursor to the top, and allows you to write
  // text wherever. However, if you hit newline, at the bottom of the scroll region
  // shifts only that region up.
  int scrolling_region_start, scrolling_region_end;
} view_t;

typedef enum mode_e {
  // Acts as a normal terminal, with a pty, and a shell.
  MODE_PTY,
  // Acts as a dummy; text is pumped in manually from lua.
  MODE_DUMMY
} mode_e;

typedef struct {
  int debug;                                         // If true, dumps output to working directory in a file called `terminal.log`.
  backbuffer_page_t* scrollback_buffer_end;          // End of the linked list.
  backbuffer_page_t* scrollback_buffer_start;        // Beginning of linked list.
  backbuffer_page_t* scrollback_target;              // Target based on scrollback_position.
  int scrollback_target_top_offset;                  // The offset that the top of the scrollback_target page is from the start of the buffer.
  int scrollback_total_lines;                        // Cached total amount of lines we can scroll bcak.
  int scrollback_position;                           // Canonical amount of lines we've scrolled back.
  int scrollback_limit;                              // The amount of lines we'll hold in memory maximum.
  int columns, lines;
  view_e current_view;
  view_t views[VIEW_MAX];                            // Normally just two buffers, normal, and alternate.
  paste_mode_e paste_mode;
  mouse_tracking_mode_e mouse_tracking_mode;
  mouse_encoding_e mouse_encoding;
  mode_e mode;                                       // The mode the terminal is in.
  int reporting_focus;                               // Enables/disbles reporting focus.
  char name[LIBTERMINAL_NAME_MAX];                   // Window name, set with OS command.
  int child_exited, exit_code, exit_signal, output_eof;
  char buffered_sequence[LIBTERMINAL_CHUNK_SIZE];
  int sequence_length, sequence_discard, string_escape;
  unsigned utf8_value, utf8_min;
  int utf8_remaining;
  color_t foreground, background;
  unsigned screen_version;
  int synchronized;
  #if _WIN32
    PROCESS_INFORMATION process_information;
    HPCON hpcon;
    HANDLE topty;
    HANDLE frompty;
    char nonblocking_buffer[LIBTERMINAL_CHUNK_SIZE];   // Oh my god, I hate windows so much.
    int nonblocking_buffer_length;
    HANDLE nonblocking_buffer_mutex;
    HANDLE nonblocking_thread;
    volatile LONG closing;
    HANDLE closing_console, job;
  #else
    int master;                                        // FD for pty.
    pid_t pid;                                         // pid for shell.
  #endif
} terminal_t;


// Retain an unfinished character across PTY reads. On a broken continuation,
// emit a replacement and leave the next byte (possibly ESC) for the parser.
static int read_codepoint(terminal_t* terminal, const char* str, int* offset, unsigned* value) {
  unsigned char byte = str[*offset];
  if (terminal->utf8_remaining) {
    if ((byte & 0xc0) != 0x80) {
      terminal->utf8_remaining = 0;
      *value = 0xfffd;
      return 1;
    }
    ++*offset;
    terminal->utf8_value = (terminal->utf8_value << 6) | (byte & 0x3f);
    if (--terminal->utf8_remaining) return 0;
    unsigned c = terminal->utf8_value;
    *value = c >= terminal->utf8_min && c <= 0x10ffff && !(c >= 0xd800 && c <= 0xdfff) ? c : 0xfffd;
    return 1;
  }
  ++*offset;
  if (byte < 0x80 || byte < 0xc2 || byte > 0xf4) {
    *value = byte < 0x80 ? byte : 0xfffd;
    return 1;
  }
  terminal->utf8_remaining = byte < 0xe0 ? 1 : byte < 0xf0 ? 2 : 3;
  terminal->utf8_value = byte & (0x7f >> (terminal->utf8_remaining + 1));
  terminal->utf8_min = byte < 0xe0 ? 0x80 : byte < 0xf0 ? 0x800 : 0x10000;
  return 0;
}

static int codepoint_to_utf8(unsigned int codepoint, char* target) {
  if (codepoint < 128) {
    *(target++) = codepoint;
    return 1;
  } else if (codepoint < 2048) {
    *(target++) = 0xC0 | (codepoint >> 6);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 2;
  } else if (codepoint < 65536) {
    *(target++) = 0xE0 | (codepoint >> 12);
    *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
    *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
    return 3;
  }
  *(target++) = 0xF0 | (codepoint >> 18);
  *(target++) = 0x80 | ((codepoint >> 12) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 6) & 0x3F);
  *(target++) = 0x80 | ((codepoint >> 0) & 0x3F);
  return 4;
}

static void release_cells(buffer_char_t* cells, size_t count) {
  for (size_t i = 0; i < count; i++) {
    glyph_suffix_t* suffix = cells[i].suffix;
    if (suffix && --suffix->references == 0) free(suffix);
  }
}

// Acquire the source first so overlapping screen moves are safe.
static void copy_cells(buffer_char_t* dest, const buffer_char_t* source, size_t count) {
  for (size_t i = 0; i < count; ++i)
    if (source[i].suffix) ++source[i].suffix->references;
  release_cells(dest, count);
  memmove(dest, source, count * sizeof(*dest));
}

// Moving rows transfers ownership. Only the displaced edge needs releasing.
static void move_cells(buffer_char_t* dest, buffer_char_t* source, size_t count) {
  if (!count || source == dest) return;
  size_t distance = dest < source ? source - dest : dest - source;
  size_t edge = distance < count ? distance : count;
  release_cells(dest < source ? dest : dest + count - edge, edge);
  memmove(dest, source, count * sizeof(*dest));
  memset(dest < source ? source + count - edge : source, 0, edge * sizeof(*source));
}

static void append_suffix(buffer_char_t* cell, uint32_t cp) {
  char bytes[4];
  unsigned length = codepoint_to_utf8(cp, bytes);
  glyph_suffix_t* old = cell->suffix;
  unsigned used = old ? old->length : 0;
  // Bound a single terminal cell independently of the scrollback limit.
  if (used + length > 4096) return;
  if (!old || old->references > 1 || old->capacity < used + length) {
    unsigned capacity = max(16, (used + length) * 2);
    glyph_suffix_t* copy = malloc(sizeof(*copy) + capacity);
    if (!copy) return;
    copy->references = 1;
    copy->capacity = capacity;
    if (old) memcpy(copy->text, old->text, used);
    release_cells(cell, 1);
    cell->suffix = copy;
  }
  memcpy(cell->suffix->text + used, bytes, length);
  cell->suffix->length = used + length;
  cell->suffix->last = cp;
}

// Starts searching for the desired scrollback page based on offset, given the starting page of start; should pass NULL if you don't care.
// Target should contain the desired offset, top_offset should match the top offset of start, if start is not null.
static backbuffer_page_t* terminal_find_scrollback_page(terminal_t* terminal, backbuffer_page_t* start, int* offset, int* top_offset) {
  if (!terminal->scrollback_buffer_start || *offset <= 0) {
    *offset = 0;
    *top_offset = 0;
    return NULL;
  }
  while (*offset > *top_offset) {
    if (!start) {
      start = terminal->scrollback_buffer_start;
      *top_offset = start->line;
    } else {
      if (!start->prev) {
        *offset = *top_offset;
        return start;
      }
      start = start->prev;
      *top_offset += start->line;
    }
  }
  while (*offset < (*top_offset - start->line)) {
    if (!start->next) {
      *offset = 0;
      *top_offset = 0;
      return NULL;
    }
    *top_offset -= start->line;
    start = start->next;
  }
  return start;
}

static int terminal_scrollback(terminal_t* terminal, int target) {
  if (target != terminal->scrollback_position) ++terminal->screen_version;
  target = max(0, min(target, terminal->scrollback_total_lines));
  terminal->scrollback_target = terminal_find_scrollback_page(terminal, terminal->scrollback_target, &target, &terminal->scrollback_target_top_offset);
  terminal->scrollback_position = target;
  return terminal->scrollback_position;
}

static int terminal_output(terminal_t* terminal, const char* str, int len);
static void terminal_input(terminal_t* terminal, const char* str, int len) {
  if (terminal->mode == MODE_PTY) {
    if (terminal->child_exited) return;
    #ifdef _WIN32
      WriteFile(terminal->topty, str, len, NULL, NULL);
    #else
      write(terminal->master, str, len);
    #endif
  } else
    terminal_output(terminal, str, len);
}

static void terminal_clear_scrollback_buffer(terminal_t* terminal) {
  backbuffer_page_t* scrollback_buffer = terminal->scrollback_buffer_start;
  while (scrollback_buffer) {
      backbuffer_page_t* prev = scrollback_buffer->prev;
      release_cells(scrollback_buffer->buffer + scrollback_buffer->first * scrollback_buffer->columns,
                    (size_t)scrollback_buffer->columns * (scrollback_buffer->line - scrollback_buffer->first));
      free(scrollback_buffer);
      scrollback_buffer = prev;
  }
  terminal->scrollback_buffer_start = NULL;
  terminal->scrollback_buffer_end = NULL;
  terminal->scrollback_target = NULL;
  terminal->scrollback_target_top_offset = 0;
  terminal->scrollback_total_lines = 0;
  terminal->scrollback_position = 0;
}

static void clear_screen(terminal_t* terminal, view_t* view) {
  size_t cells = (size_t)terminal->columns * terminal->lines;
  if (view->buffer) {
    release_cells(view->buffer, cells);
    memset(view->buffer, 0, cells * sizeof(*view->buffer));
    memset(view->overflows, 0, terminal->lines * sizeof(*view->overflows));
  }
  view->wrap_pending = view->cursor_x = view->cursor_y = 0;
}

// Restore power-on emulator state while retaining the PTY, dimensions and theme.
static void terminal_reset(terminal_t* terminal) {
  terminal_clear_scrollback_buffer(terminal);
  for (int i = 0; i < VIEW_MAX; ++i) {
    view_t* view = &terminal->views[i];
    clear_screen(terminal, view);
    *view = (view_t){
      .buffer = view->buffer, .overflows = view->overflows,
      .scrolling_region_start = -1, .scrolling_region_end = -1,
      .autowrap = 1, .saved_autowrap = 1, .tab_size = LIBTERMINAL_DEFAULT_TAB_SIZE
    };
    for (int j = 0; j < 256; ++j) view->palette[j] = indexed_color(j);
  }
  terminal->current_view = VIEW_NORMAL_BUFFER;
  terminal->mouse_tracking_mode = MOUSE_TRACKING_NONE;
  terminal->mouse_encoding = MOUSE_ENCODING_DEFAULT;
  terminal->paste_mode = PASTE_NORMAL;
  terminal->reporting_focus = terminal->synchronized = 0;
  terminal->sequence_length = terminal->sequence_discard = terminal->string_escape = 0;
  terminal->utf8_remaining = 0;
  terminal->name[0] = 0;
  ++terminal->screen_version;
}

static void terminal_push_scrollback_line(terminal_t* terminal, const buffer_char_t* line, int overflow) {
  if (terminal->scrollback_limit <= 0) return;
  if (terminal->scrollback_total_lines >= terminal->scrollback_limit) {
    backbuffer_page_t* page = terminal->scrollback_buffer_end;
    release_cells(page->buffer + page->first * page->columns, page->columns);
    ++page->first;
    --terminal->scrollback_total_lines;
    if (page->first == page->line) {
      terminal->scrollback_buffer_end = page->next;
      if (page->next) page->next->prev = NULL;
      else terminal->scrollback_buffer_start = NULL;
      if (terminal->scrollback_target == page) {
        terminal->scrollback_target = NULL;
        terminal->scrollback_target_top_offset = 0;
      }
      free(page);
    }
  }
  ++terminal->scrollback_total_lines;
  if (terminal->scrollback_target) ++terminal->scrollback_target_top_offset;
  if (terminal->scrollback_position)
    terminal->scrollback_position = min(terminal->scrollback_position + 1, terminal->scrollback_total_lines);
  if (!terminal->scrollback_buffer_start || terminal->scrollback_buffer_start->columns != terminal->columns || terminal->scrollback_buffer_start->line >= terminal->scrollback_buffer_start->lines) {
    backbuffer_page_t* page = calloc(sizeof(backbuffer_page_t) + LIBTERMINAL_BACKBUFFER_PAGE_LINES*terminal->columns*sizeof(buffer_char_t) + sizeof(int)*LIBTERMINAL_BACKBUFFER_PAGE_LINES, 1);
    if (!terminal->scrollback_buffer_start)
      terminal->scrollback_buffer_end = page;
    backbuffer_page_t* prev = terminal->scrollback_buffer_start;
    page->prev = prev;
    if (prev)
      prev->next = page;
    terminal->scrollback_buffer_start = page;
    page->lines = LIBTERMINAL_BACKBUFFER_PAGE_LINES;
    page->columns = terminal->columns;
    page->line = 0;
  }
  copy_cells(&terminal->scrollback_buffer_start->buffer[terminal->scrollback_buffer_start->line * terminal->columns], line, terminal->columns);
  int* backbuffer_overflows = (int*)&terminal->scrollback_buffer_start->buffer[LIBTERMINAL_BACKBUFFER_PAGE_LINES*terminal->scrollback_buffer_start->columns];
  backbuffer_overflows[terminal->scrollback_buffer_start->line] = overflow;
  terminal->scrollback_buffer_start->line++;
}

static int terminal_line_is_empty(terminal_t* terminal, const buffer_char_t* line, int overflow) {
  if (overflow)
    return 0;
  for (int i = 0; i < terminal->columns; ++i) {
    if (line[i].codepoint && line[i].codepoint != ' ')
      return 0;
  }
  return 1;
}

static void terminal_save_cursor(view_t* view) {
  view->saved_wrap_pending = view->wrap_pending;
  view->saved_origin_mode = view->origin_mode;
  view->saved_autowrap = view->autowrap;
  view->saved_cursor_x = view->cursor_x;
  view->saved_cursor_y = view->cursor_y;
  view->saved_cursor_styling = view->cursor_styling;
  view->saved_charset = view->charset;
}

static void terminal_restore_cursor(terminal_t* terminal, view_t* view) {
  view->cursor_x = min(max(view->saved_cursor_x, 0), terminal->columns - 1);
  view->cursor_y = min(max(view->saved_cursor_y, 0), terminal->lines - 1);
  view->wrap_pending = view->saved_wrap_pending && view->cursor_x == terminal->columns - 1;
  view->origin_mode = view->saved_origin_mode;
  view->autowrap = view->saved_autowrap;
  view->cursor_styling = view->saved_cursor_styling;
  view->charset = view->saved_charset;
}

static void terminal_blank_cells(buffer_char_t* cells, int count, buffer_styling_t styling) {
  release_cells(cells, count);
  for (int i = 0; i < count; ++i)
    cells[i] = (buffer_char_t){ styling, ' ' };
}

static void terminal_scroll_region_up(terminal_t* terminal, int start, int end, int count, int push_scrollback) {
  view_t* view = &terminal->views[terminal->current_view];
  start = min(max(start, 0), terminal->lines - 1);
  end = min(max(end, start + 1), terminal->lines);
  count = min(max(count, 1), end - start);

  if (push_scrollback && terminal->current_view == VIEW_NORMAL_BUFFER) {
    for (int y = start; y < start + count; ++y) {
      if (!terminal_line_is_empty(terminal, &view->buffer[terminal->columns * y], view->overflows[y]))
        terminal_push_scrollback_line(terminal, &view->buffer[terminal->columns * y], view->overflows[y]);
    }
  }

  if (end > start + count) {
    move_cells(&view->buffer[terminal->columns * start], &view->buffer[terminal->columns * (start + count)], terminal->columns * (end - start - count));
    memmove(&view->overflows[start], &view->overflows[start + count], sizeof(int) * (end - start - count));
  }
  for (int y = end - count; y < end; ++y) {
    terminal_blank_cells(&view->buffer[terminal->columns * y], terminal->columns, view->cursor_styling);
    view->overflows[y] = 0;
  }
}

static void terminal_scroll_region_down(terminal_t* terminal, int start, int end, int count) {
  view_t* view = &terminal->views[terminal->current_view];
  start = min(max(start, 0), terminal->lines - 1);
  end = min(max(end, start + 1), terminal->lines);
  count = min(max(count, 1), end - start);

  if (end > start + count) {
    move_cells(&view->buffer[terminal->columns * (start + count)], &view->buffer[terminal->columns * start], terminal->columns * (end - start - count));
    memmove(&view->overflows[start + count], &view->overflows[start], sizeof(int) * (end - start - count));
  }
  for (int y = start; y < start + count; ++y) {
    terminal_blank_cells(&view->buffer[terminal->columns * y], terminal->columns, view->cursor_styling);
    view->overflows[y] = 0;
  }
}

static void terminal_shift_buffer(terminal_t* terminal) {
  view_t* view = &terminal->views[terminal->current_view];

  if (view->scrolling_region_start != -1 && view->scrolling_region_end != -1) {
    // We perform this song and dance in case of Guldoman levels of resizing.
    terminal_scroll_region_up(terminal, view->scrolling_region_start, view->scrolling_region_end, 1, 1);
    return;
  }
  if (terminal->current_view == VIEW_NORMAL_BUFFER)
    terminal_push_scrollback_line(terminal, &view->buffer[0], view->overflows[0]);
  move_cells(&view->buffer[0], &view->buffer[terminal->columns], terminal->columns * (terminal->lines - 1));
  memmove(&view->overflows[0], &view->overflows[1], sizeof(int) * (terminal->lines - 1));
  terminal_blank_cells(&view->buffer[terminal->columns * (terminal->lines - 1)], terminal->columns, view->cursor_styling);
  view->overflows[terminal->lines - 1] = 0;
}

static int terminal_index(terminal_t* terminal, view_t* view) {
  int bottom = view->scrolling_region_end == -1 ? terminal->lines : view->scrolling_region_end;
  if (view->cursor_y == bottom - 1) {
    terminal_shift_buffer(terminal);
    return 1;
  }
  view->cursor_y = min(view->cursor_y + 1, terminal->lines - 1);
  return 0;
}

// Remove both halves when an edit cuts a wide glyph at either boundary.
static void clear_wide_edges(buffer_char_t* row, int start, int end, int columns, buffer_styling_t style) {
  if (start > 0 && start < columns && row[start].codepoint == WIDE_TAIL)
    terminal_blank_cells(row + start - 1, 2, style);
  if (end > 0 && end < columns && row[end].codepoint == WIDE_TAIL)
    terminal_blank_cells(row + end - 1, 2, style);
}

static int regional_indicator(unsigned cp) { return cp >= 0x1f1e6 && cp <= 0x1f1ff; }

static int terminal_put_char(terminal_t* terminal, view_t* view, unsigned codepoint) {
  int shifts = 0, width = terminal_char_width(codepoint);
  buffer_char_t* row = view->buffer + view->cursor_y * terminal->columns;
  int prev = view->wrap_pending ? view->cursor_x : view->cursor_x - 1;
  if (prev > 0 && row[prev].codepoint == WIDE_TAIL) --prev;
  if (prev >= 0 && codepoint >= 0x300) {
    buffer_char_t* cell = row + prev;
    int flag = regional_indicator(cell->codepoint) && !cell->suffix && regional_indicator(codepoint);
    int joined = cell->suffix && cell->suffix->last == 0x200d && terminal_is_pictograph(codepoint);
    if (width == 0 || flag || joined) {
      if (!cell->codepoint) cell->codepoint = ' ';
      if ((flag || (codepoint == 0xfe0f && terminal_is_pictograph(cell->codepoint))) &&
          prev + 1 < terminal->columns && row[prev + 1].codepoint != WIDE_TAIL) {
        clear_wide_edges(row, prev + 1, prev + 2, terminal->columns, cell->styling);
        terminal_blank_cells(row + prev + 1, 1, cell->styling);
        row[prev + 1].codepoint = WIDE_TAIL;
        view->cursor_x = min(prev + 2, terminal->columns - 1);
        view->wrap_pending = view->autowrap && prev + 2 == terminal->columns;
      }
      append_suffix(cell, codepoint);
      return 0;
    }
  }
  if (!width) return 0;
  width = min(width, terminal->columns);
  if (view->wrap_pending || (width == 2 && view->cursor_x + width > terminal->columns && view->autowrap)) {
    view->overflows[view->cursor_y] = 1;
    view->cursor_x = 0;
    shifts = terminal_index(terminal, view);
    row = view->buffer + view->cursor_y * terminal->columns;
  }
  if (width > terminal->columns - view->cursor_x) return shifts;
  int x = view->cursor_x;
  clear_wide_edges(row, x, x + width, terminal->columns, view->cursor_styling);
  release_cells(row + x, width);
  row[x] = (buffer_char_t){ view->cursor_styling, codepoint };
  if (width == 2) row[x+1] = (buffer_char_t){ view->cursor_styling, WIDE_TAIL };
  view->last_graphical_character = codepoint;
  view->wrap_pending = view->autowrap && x + width == terminal->columns;
  view->cursor_x = min(x + width, terminal->columns - 1);
  return shifts;
}

static void terminal_switch_buffer(terminal_t* terminal, view_e view) {
  if (terminal->current_view == view) return;
  terminal->current_view = view;
  if (view == VIEW_ALTERNATE_BUFFER) {
    clear_screen(terminal, &terminal->views[VIEW_ALTERNATE_BUFFER]);
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_wrap_pending = 0;
    terminal->views[VIEW_ALTERNATE_BUFFER].autowrap = 1;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_autowrap = 1;
    terminal->views[VIEW_ALTERNATE_BUFFER].origin_mode = 0;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_origin_mode = 0;
    terminal->views[VIEW_ALTERNATE_BUFFER].cursor_styling = LIBTERMINAL_NO_STYLING;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_cursor_x = 0;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_cursor_y = 0;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_cursor_styling = LIBTERMINAL_NO_STYLING;
    terminal->views[VIEW_ALTERNATE_BUFFER].saved_charset = CHARSET_US;
    terminal->views[VIEW_ALTERNATE_BUFFER].scrolling_region_end = -1;
    terminal->views[VIEW_ALTERNATE_BUFFER].scrolling_region_start = -1;
    for (int i = 0; i < 256; ++i)
      terminal->views[VIEW_ALTERNATE_BUFFER].palette[i] = indexed_color(i);
  }
}

static int parse_number(const char* seq, int def) {
  if (*seq < '0' || *seq > '9') return def;
  int n = 0;
  while (*seq >= '0' && *seq <= '9') {
    n = min(65535, n * 10 + (*seq - '0'));
    ++seq;
  }
  return n;
}

typedef enum terminal_escape_type_e {
  ESCAPE_TYPE_NONE,
  ESCAPE_TYPE_OPEN,
  ESCAPE_TYPE_CSI,
  ESCAPE_TYPE_OS,
  ESCAPE_TYPE_STRING,
  ESCAPE_TYPE_FIXED_WIDTH,
  ESCAPE_TYPE_UNKNOWN
} terminal_escape_type_e;


// Parse a field up to its separator or the final byte. Empty fields have
// their caller's default value (including the optional RGB color-space ID).
static int sgr_field(const char** p, int def) {
  int n = parse_number(*p, def);
  while (**p >= '0' && **p <= '9') ++*p;
  return n;
}

static int read_sgr_color(const char** p, view_t* view, color_t* color) {
  char separator = **p;
  if (separator != ':' && separator != ';') return 0;
  ++*p;
  int mode = sgr_field(p, -1);
  if (mode != 2 && mode != 5) return 0;
  int fields[4], count = 0;
  int max_fields = mode == 5 ? 1 : separator == ':' ? 4 : 3;
  while (count < max_fields && **p == separator) {
    ++*p;
    fields[count++] = sgr_field(p, -1);
  }
  if (mode == 5 && count == 1 && fields[0] >= 0 && fields[0] < 256) {
    *color = view->palette[fields[0]];
    return 1;
  }
  if (mode == 2 && count >= 3) {
    int* rgb = &fields[count - 3];
    for (int i = 0; i < 3; ++i) if (rgb[i] < 0 || rgb[i] > 255) return 0;
    *color = rgb_color(rgb[0], rgb[1], rgb[2]);
    return 1;
  }
  return 0;
}

static void set_graphics(view_t* view, const char* p) {
  color_t* fg = &view->cursor_styling.foreground;
  color_t* bg = &view->cursor_styling.background;
  for (;;) {
    int mode = sgr_field(&p, 0);
    color_t color = UNSET_COLOR;
    color_t* target = NULL;
    switch (mode) {
      case 0: view->cursor_styling = LIBTERMINAL_NO_STYLING; break;
      case 1: fg->attributes |= ATTRIBUTE_BOLD; break;
      case 2: fg->attributes |= ATTRIBUTE_FAINT; break;
      case 3: fg->attributes |= ATTRIBUTE_ITALIC; break;
      case 4:
        if (*p == ':' && parse_number(p + 1, 1) == 0) fg->attributes &= ~ATTRIBUTE_UNDERLINE;
        else fg->attributes |= ATTRIBUTE_UNDERLINE;
        break;
      case 7: fg->attributes |= ATTRIBUTE_INVERSE; break;
      case 8: bg->attributes |= ATTRIBUTE_CONCEAL; break;
      case 9: bg->attributes |= ATTRIBUTE_STRIKE; break;
      case 22: fg->attributes &= ~(ATTRIBUTE_BOLD | ATTRIBUTE_FAINT); break;
      case 23: fg->attributes &= ~ATTRIBUTE_ITALIC; break;
      case 24: fg->attributes &= ~ATTRIBUTE_UNDERLINE; break;
      case 27: fg->attributes &= ~ATTRIBUTE_INVERSE; break;
      case 28: bg->attributes &= ~ATTRIBUTE_CONCEAL; break;
      case 29: bg->attributes &= ~ATTRIBUTE_STRIKE; break;
      case 39: target = fg; break;
      case 49: target = bg; break;
      case 38: case 48: case 58:
        if (read_sgr_color(&p, view, &color) && mode != 58)
          target = mode == 38 ? fg : bg;
        break;
      default:
        if (mode >= 30 && mode <= 37) { target = fg; color = view->palette[mode-30]; }
        else if (mode >= 40 && mode <= 47) { target = bg; color = view->palette[mode-40]; }
        else if (mode >= 90 && mode <= 97) { target = fg; color = view->palette[mode-90+8]; }
        else if (mode >= 100 && mode <= 107) { target = bg; color = view->palette[mode-100+8]; }
    }
    if (target) {
      color.attributes |= target->attributes & ATTRIBUTE_STYLING_MASK;
      *target = color;
    }
    // Ignore unused subparameters of this attribute.
    while (*p == ':') { ++p; sgr_field(&p, 0); }
    if (*p != ';') return;
    ++p;
  }
}

static int terminal_escape_sequence(terminal_t* terminal, terminal_escape_type_e type, const char* seq) {
  #ifdef LIBTERMINAL_DEBUG_ESCAPE
  fprintf(stderr, "ESC");
  for (int i = 1; i < strlen(seq); ++i) {
    fprintf(stderr, "%c", seq[i]);
  }
  fprintf(stderr, "\n");
  #endif
  view_t* view = &terminal->views[terminal->current_view];
  int unhandled = 0;
  int end = (view->scrolling_region_end == -1 ? terminal->lines : view->scrolling_region_end);
  if (type == ESCAPE_TYPE_CSI) {
    int seq_end = strlen(seq) - 1;
    if (seq[2] == '?' && seq[seq_end] == 'p' && seq[seq_end-1] == '$') {
      int mode = parse_number(seq + 3, 0), status = 0;
      switch (mode) {
        case 1: status = view->cursor_keys_mode == KEYS_MODE_APPLICATION ? 1 : 2; break;
        case 6: status = view->origin_mode ? 1 : 2; break;
        case 7: status = view->autowrap ? 1 : 2; break;
        case 25: status = view->cursor_hidden ? 2 : 1; break;
        case 1004: status = terminal->reporting_focus ? 1 : 2; break;
        case 1006: status = terminal->mouse_encoding == MOUSE_ENCODING_SGR ? 1 : 2; break;
        case 1049: status = terminal->current_view == VIEW_ALTERNATE_BUFFER ? 1 : 2; break;
        case 2004: status = terminal->paste_mode == PASTE_BRACKETED ? 1 : 2; break;
        case 2026: status = terminal->synchronized ? 1 : 2; break;
      }
      if (terminal->mode == MODE_PTY) {
        char reply[40];
        int n = snprintf(reply, sizeof(reply), "\033[?%d;%d$y", mode, status);
        terminal_input(terminal, reply, n);
      }
      return 0;
    }
    // Private protocols reuse standard final bytes (e.g. Kitty CSI > ... u).
    if (seq[2] >= '<' && seq[2] <= '?' &&
        !(seq[2] == '?' && (seq[seq_end] == 'h' || seq[seq_end] == 'l')))
      return 0;
    int top = max(view->scrolling_region_start, 0);
    if (strchr("ABCDEFGHJKLMPSTX@dfr", seq[seq_end])) view->wrap_pending = 0;
    switch (seq[seq_end]) {
      case '@': {
        int x = view->cursor_x, cols = terminal->columns;
        int length = min(max(parse_number(seq + 2, 1), 1), cols - x);
        buffer_char_t* row = view->buffer + cols * view->cursor_y;
        clear_wide_edges(row, x, cols - length, cols, view->cursor_styling);
        move_cells(row + x + length, row + x, cols - x - length);
        terminal_blank_cells(row + x, length, view->cursor_styling);
      } break;
      case 'A': view->cursor_y = max(view->cursor_y - max(parse_number(&seq[2], 1), 1), view->cursor_y >= top ? top : 0);     break;
      case 'B': view->cursor_y = min(view->cursor_y + max(parse_number(&seq[2], 1), 1), view->cursor_y < end ? end - 1 : terminal->lines - 1); break;
      case 'C': view->cursor_x = min(view->cursor_x + max(parse_number(&seq[2], 1), 1), terminal->columns - 1); break;
      case 'D': view->cursor_x = max(view->cursor_x - max(parse_number(&seq[2], 1), 1), 0); break;
      case 'E': view->cursor_y = min(view->cursor_y + max(parse_number(&seq[2], 1), 1), view->cursor_y < end ? end - 1 : terminal->lines - 1); view->cursor_x = 0; break;
      case 'F': view->cursor_y = max(view->cursor_y - max(parse_number(&seq[2], 1), 1), view->cursor_y >= top ? top : 0); view->cursor_x = 0; break;
      case 'G': view->cursor_x = min(max(max(parse_number(&seq[2], 1), 1) - 1, 0), terminal->columns - 1); break;
      case 'f':
      case 'H': {
        const char* sep = strchr(seq + 2, ';');
        int first = view->origin_mode ? top : 0;
        int last = view->origin_mode ? end : terminal->lines;
        view->cursor_y = min(first + max(parse_number(seq + 2, 1), 1) - 1, last - 1);
        view->cursor_x = sep ? min(max(parse_number(sep + 1, 1), 1) - 1, terminal->columns - 1) : 0;
      } break;
      case 'J': {
        switch (seq[2]) {
          case '1':
            for (int y = 0; y <= view->cursor_y; ++y) {
              int w = y == view->cursor_y ? (view->cursor_x+1) : terminal->columns;
              clear_wide_edges(view->buffer + terminal->columns * y, 0, w, terminal->columns, view->cursor_styling);
              terminal_blank_cells(&view->buffer[terminal->columns * y], w, view->cursor_styling);
              if (w == terminal->columns)
                view->overflows[y] = 0;
            }
          break;
          case '3':
            terminal_clear_scrollback_buffer(terminal);
            break;
          case '2':
            for (int y = 0; y < terminal->lines; ++y)
              terminal_blank_cells(&view->buffer[terminal->columns * y], terminal->columns, view->cursor_styling);
            memset(view->overflows, 0, sizeof(int) * terminal->lines);
          break;
          default:
            for (int y = view->cursor_y; y < terminal->lines; ++y) {
              int x = y == view->cursor_y ? view->cursor_x : 0;
              clear_wide_edges(view->buffer + terminal->columns * y, x, terminal->columns, terminal->columns, view->cursor_styling);
              terminal_blank_cells(&view->buffer[terminal->columns * y + x], terminal->columns - x, view->cursor_styling);
              if (x == 0)
                view->overflows[y] = 0;
            }
          break;
        }
      } break;
      case 'K': {
        int s, e;
        switch (seq[2]) {
          case '1': s = 0; e = view->cursor_x + 1; break;
          case '2': s = 0; e = terminal->columns; break;
          default: s = view->cursor_x; e = terminal->columns; break;
        }
        buffer_char_t* row = view->buffer + view->cursor_y * terminal->columns;
        clear_wide_edges(row, s, e, terminal->columns, view->cursor_styling);
        terminal_blank_cells(row + s, e - s, view->cursor_styling);
      } break;
      case 'L': {
        int length = parse_number(&seq[2], 1);
        int start = view->scrolling_region_start == -1 ? 0 : view->scrolling_region_start;
        if (view->cursor_y >= start && view->cursor_y < end)
          terminal_scroll_region_down(terminal, view->cursor_y, end, length);
      } break;
      case 'M': {
        int length = parse_number(&seq[2], 1);
        int start = view->scrolling_region_start == -1 ? 0 : view->scrolling_region_start;
        if (view->cursor_y >= start && view->cursor_y < end)
          terminal_scroll_region_up(terminal, view->cursor_y, end, length, 0);
      } break;
      case 'P':
      case 'X': {
        int x = view->cursor_x, cols = terminal->columns;
        int length = min(max(parse_number(seq + 2, 1), 1), cols - x);
        buffer_char_t* row = view->buffer + cols * view->cursor_y;
        clear_wide_edges(row, x, x + length, cols, view->cursor_styling);
        if (seq[seq_end] == 'P') {
          move_cells(row + x, row + x + length, cols - x - length);
          x = cols - length;
        }
        terminal_blank_cells(row + x, length, view->cursor_styling);
      } break;
      case 'S': {
        terminal_scroll_region_up(terminal, view->scrolling_region_start == -1 ? 0 : view->scrolling_region_start, end, parse_number(&seq[2], 1), 0);
      } break;
      case 'T': {
        terminal_scroll_region_down(terminal, view->scrolling_region_start == -1 ? 0 : view->scrolling_region_start, end, parse_number(&seq[2], 1));
      } break;
      case 's': {
        terminal_save_cursor(view);
      } break;
      case 'u': {
        terminal_restore_cursor(terminal, view);
      } break;
      case 'b': {
        if (view->last_graphical_character) {
          int count = max(1, parse_number(seq + 2, 1));
          for (int i = 0; i < count; ++i)
            terminal_put_char(terminal, view, view->last_graphical_character);
        }
      } break;
      case 'c': {
        if (terminal->mode == MODE_PTY) terminal_input(terminal, "\e[?1;2c", 7);
      } break;
      case 'd': view->cursor_y = min((view->origin_mode ? top : 0) + max(parse_number(seq + 2, 1), 1) - 1,
                                   (view->origin_mode ? end : terminal->lines) - 1); break;
      case 'h': {
        if (seq[2] == '?') {
          const char* next = &seq[3];
          while (next) {
            view = &terminal->views[terminal->current_view];
            switch (parse_number(next, 0)) {
              case 1: view->cursor_keys_mode = KEYS_MODE_APPLICATION; break;
              case 6:
                view->origin_mode = 1;
                view->cursor_x = view->wrap_pending = 0;
                view->cursor_y = max(view->scrolling_region_start, 0);
                break;
              case 7: view->autowrap = 1; view->wrap_pending = 0; break;
              case 9: terminal->mouse_tracking_mode = MOUSE_TRACKING_X10; break;
              case 12: view->cursor_mode = CURSOR_BLINKING; break;
              case 25: view->cursor_hidden = 0; break;
              case 1000: terminal->mouse_tracking_mode = MOUSE_TRACKING_NORMAL; break;
              case 1002: terminal->mouse_tracking_mode = MOUSE_TRACKING_BUTTON; break;
              case 1003: terminal->mouse_tracking_mode = MOUSE_TRACKING_ANY; break;
              case 1006: terminal->mouse_encoding = MOUSE_ENCODING_SGR; break;
              case 1004: terminal->reporting_focus = 1; break;
              case 1047: terminal_switch_buffer(terminal, VIEW_ALTERNATE_BUFFER); break;
              case 1048: terminal_save_cursor(view); break;
              case 1049:
                if (terminal->current_view == VIEW_NORMAL_BUFFER) {
                  terminal_save_cursor(view);
                  terminal_switch_buffer(terminal, VIEW_ALTERNATE_BUFFER);
                }
                break;
              case 2026: terminal->synchronized = 1; break;
              case 2004: terminal->paste_mode = PASTE_BRACKETED; break;
              default: unhandled = 1; break;
            }
            if ((next = strstr(next, ";")))
              next++;
          }
        }
      } break;
      case 'l': {
        if (seq[2] == '?') {
          const char* next = &seq[3];
          while (next) {
            view = &terminal->views[terminal->current_view];
            switch (parse_number(next, 0)) {
              case 1: view->cursor_keys_mode = KEYS_MODE_NORMAL; break;
              case 6:
                view->origin_mode = 0;
                view->cursor_x = view->wrap_pending = 0;
                view->cursor_y = 0;
                break;
              case 7: view->autowrap = 0; view->wrap_pending = 0; break;
              case 9:
              case 1000:
              case 1002:
              case 1003:
                terminal->mouse_tracking_mode = MOUSE_TRACKING_NONE;
              break;
              case 12: view->cursor_mode = CURSOR_SOLID; break;
              case 25: view->cursor_hidden = 1; break;
              case 1006: terminal->mouse_encoding = MOUSE_ENCODING_DEFAULT; break;
              case 1004: terminal->reporting_focus = 0; break;
              case 1047: terminal_switch_buffer(terminal, VIEW_NORMAL_BUFFER); break;
              case 1048: terminal_restore_cursor(terminal, view); break;
              case 1049:
                if (terminal->current_view == VIEW_ALTERNATE_BUFFER) {
                  terminal_switch_buffer(terminal, VIEW_NORMAL_BUFFER);
                  terminal_restore_cursor(terminal, &terminal->views[VIEW_NORMAL_BUFFER]);
                }
                break;
              case 2026: terminal->synchronized = 0; break;
              case 2004: terminal->paste_mode = PASTE_NORMAL; break;
              default: unhandled = 1; break;
            }
            if ((next = strchr(next, ';')))
              next++;
          }
        }
      } break;
      case 'm': set_graphics(view, seq + 2); break;
      case 'n': {
        if (parse_number(&seq[2], 0) == 6) {
          // CPR responses are one-based and must end with R; fish waits for the complete sequence.
          char buffer[32];
          int length = snprintf(buffer, sizeof(buffer), "\x1B[%d;%dR", view->cursor_y + 1 - (view->origin_mode ? top : 0), view->cursor_x + 1);
          if (terminal->mode == MODE_PTY) terminal_input(terminal, buffer, length);
        } else if (parse_number(seq + 2, 0) == 5 && terminal->mode == MODE_PTY) {
          terminal_input(terminal, "\033[0n", 4);
        } else
          unhandled = 1;
      } break;
      case 'q': {
        if (seq[seq_end - 1] == ' ') {
          int style = parse_number(seq + 2, 0);
          if (style <= 6) {
            view->cursor_shape = style < 3 ? 0 : (style < 5 ? 1 : 2);
            view->cursor_mode = !style || style % 2 ? CURSOR_BLINKING : CURSOR_SOLID;
          }
        }
      } break;
      case 'r': {
        const char* sep = strchr(seq + 2, ';');
        int first = max(parse_number(seq + 2, 1), 1);
        int last = sep ? parse_number(sep + 1, terminal->lines) : terminal->lines;
        if (!last) last = terminal->lines;
        if (first < last && last <= terminal->lines) {
          int full = first == 1 && last == terminal->lines;
          view->scrolling_region_start = full ? -1 : first - 1;
          view->scrolling_region_end = full ? -1 : last;
          view->cursor_x = 0;
          view->cursor_y = view->origin_mode ? first - 1 : 0;
        }
      } break;
      default: unhandled = 1; break;
    }
  } else if (type == ESCAPE_TYPE_OS) {
    switch (seq[2]) {
      case '0':
      case '2':
        if (seq[3] == ';')
          snprintf(terminal->name, sizeof(terminal->name), "%s", seq + 4);
      break;
      case '1': {
        if (terminal->mode == MODE_PTY && (!strcmp(seq + 2, "10;?") || !strcmp(seq + 2, "11;?"))) {
          color_t color = seq[3] == '0' ? terminal->foreground : terminal->background;
          char response[40];
          int n = snprintf(response, sizeof(response), "\033]1%c;rgb:%04x/%04x/%04x\033\\",
            seq[3], color.r * 257, color.g * 257, color.b * 257);
          terminal_input(terminal, response, n);
        }
      } break;
      case '4': {
        int idx, r,g,b;
        if (sscanf(&seq[3], ";%d;rgb:%x/%x/%x", &idx, &r, &g, &b) == 4 && idx >= 0 && idx < 256) {
          view->palette[idx] = rgb_color(r, g, b);
        } else
          unhandled = 1;
      } break;
      default: unhandled = 1; break;
    }
  } else if (type == ESCAPE_TYPE_FIXED_WIDTH) {
    switch (seq[1]) {
      case '#': { // Put in, to satisfy vttest.
        switch (seq[2]) {
          case '8':
            release_cells(view->buffer, (size_t)terminal->lines * terminal->columns);
            for (int y = 0; y < terminal->lines; ++y) {
              for (int x = 0; x < terminal->columns; ++x)
                view->buffer[y * terminal->columns + x] = (buffer_char_t){ view->cursor_styling, 'E' };
            }
          break;
          default: unhandled = 1; break;
        }
      } break;
      case 'D':
      case 'E': {
        view->wrap_pending = 0;
        terminal_index(terminal, view);
        if (seq[1] == 'E')
          view->cursor_x = 0;
      } break;
      case '(':
        switch (seq[2]) {
          case '0': view->charset = CHARSET_DEC; break;
          case 'B': view->charset = CHARSET_US; break;
          default: view->charset = CHARSET_OTHER; break;
        }
      break;
      case '=': view->keypad_keys_mode = KEYS_MODE_APPLICATION; break;
      case '>': view->keypad_keys_mode = KEYS_MODE_NORMAL; break;
      case '7': terminal_save_cursor(view); break;
      case '8': terminal_restore_cursor(terminal, view); break;
      case 'c': terminal_reset(terminal); break;
      case 'M':
        view->wrap_pending = 0;
        if (view->cursor_y == max(0, view->scrolling_region_start))
          terminal_scroll_region_down(terminal, view->cursor_y, end, 1);
        else
          view->cursor_y = max(0, view->cursor_y - 1);
        break;
      default: unhandled = 1; break;
    }
  }

  if (unhandled) {
    #ifdef LIBTERMINAL_DEBUG_ESCAPE
      fprintf(stderr, "UNKNOWN ESCAPE SEQUENCE\n");
    #endif
    return -1;
  }
  return 0;
}


static terminal_escape_type_e get_terminal_escape_type(char a, int* fixed_width) {
  switch (a) {
    case '[': return ESCAPE_TYPE_CSI;
    case ']': return ESCAPE_TYPE_OS;
    case 'P': case 'X': case '^': case '_': return ESCAPE_TYPE_STRING;
    case 'D':
    case 'E':
    case 'H':
    case 'M':
    case 'Z':
    case 'F':
    case '>':
    case '=':
    case '7':
    case '8':
    case 'c':
    case 'l':
    case 'm':
    case 'n':
    case 'o':
    case '|':
    case '}':
    case '~':
      *fixed_width = 2;
      return ESCAPE_TYPE_FIXED_WIDTH;
    case ' ':
    case '#':
    case '%':
    case '(':
    case ')':
    case '*':
    case '+':
      *fixed_width = 3;
      return ESCAPE_TYPE_FIXED_WIDTH;
  }
  return ESCAPE_TYPE_UNKNOWN;
}

static terminal_escape_type_e parse_partial_sequence(const char* seq, int len, int* fixed_width) {
  if (len == 0)
    return ESCAPE_TYPE_NONE;
  if (len == 1)
    return ESCAPE_TYPE_OPEN;
  return get_terminal_escape_type(seq[1], fixed_width);
}

static int translate_charset(charset_e charset, int codepoint) {
  if (charset == CHARSET_DEC) {
    switch (codepoint) {
      case 0x5F: codepoint = ' '; break;
      case 0x60: codepoint = 0x25C6; break;
      case 0x61: codepoint = 0x2592; break;
      case 0x62: codepoint = '\t'; break;
      case 0x63: codepoint = '\f'; break;
      case 0x64: codepoint = '\r'; break;
      case 0x65: codepoint = '\n'; break;
      case 0x66: codepoint = 0xB0; break;
      case 0x67: codepoint = 0xB1; break;
      case 0x68: codepoint = '\n'; break;
      case 0x69: codepoint = '\v'; break;
      case 0x6A: codepoint = 0x2518; break;
      case 0x6B: codepoint = 0x2510; break;
      case 0x6C: codepoint = 0x250C; break;
      case 0x6D: codepoint = 0x2514; break;
      case 0x6E: codepoint = 0x253C; break;
      case 0x70: codepoint = 0x23BB; break;
      case 0x71: codepoint = 0x2500; break;
      case 0x72: codepoint = 0x23BC; break;
      case 0x73: codepoint = 0x23BD; break;
      case 0x74: codepoint = 0x251C; break;
      case 0x75: codepoint = 0x2524; break;
      case 0x76: codepoint = 0x2534; break;
      case 0x77: codepoint = 0x252C; break;
      case 0x78: codepoint = 0x2502; break;
      case 0x79: codepoint = 0x2264; break;
      case 0x7A: codepoint = 0x2265; break;
      case 0x7B: codepoint = 0x03C0; break;
      case 0x7C: codepoint = 0x2260; break;
      case 0x7D: codepoint = 0x00A3; break;
      case 0x7E: codepoint = 0x00B7; break;
    }
  }
  return codepoint;
}

static int terminal_output(terminal_t* terminal, const char* str, int len) {
  ++terminal->screen_version;
  if (terminal->debug)  {
    FILE* file = fopen("terminal.log", "ab");
    if (file) {
      fwrite(str, sizeof(char), len, file);
      fclose(file);
    }
  }
  unsigned int codepoint;
  int total_shifts = 0;
  int offset = 0;
  view_t* view = &terminal->views[terminal->current_view];
  int fixed_width = 0;
  char* seq = terminal->buffered_sequence;
  terminal_escape_type_e type = parse_partial_sequence(seq, terminal->sequence_length, &fixed_width);
  while (offset < len) {
    if (type != ESCAPE_TYPE_NONE) {
      unsigned char byte = str[offset++];
      int string = type == ESCAPE_TYPE_OS || type == ESCAPE_TYPE_STRING;
      int st = string && terminal->string_escape && byte == '\\';
      int complete = st || (type == ESCAPE_TYPE_OS && byte == '\a');
      if (byte == 0x18 || byte == 0x1a) {
        terminal->sequence_discard = complete = 1;
      } else if (byte == 0x1b && !string) {
        terminal->sequence_length = 1;
        seq[0] = byte;
        terminal->sequence_discard = 0;
        type = ESCAPE_TYPE_OPEN;
        continue;
      } else if (!complete) {
        if (!byte) continue;
        if (terminal->sequence_length < (int)sizeof(terminal->buffered_sequence) - 1)
          seq[terminal->sequence_length++] = byte;
        else
          terminal->sequence_discard = 1;
        if (type == ESCAPE_TYPE_OPEN)
          type = get_terminal_escape_type(byte, &fixed_width);
        complete = type == ESCAPE_TYPE_UNKNOWN ||
          (type == ESCAPE_TYPE_FIXED_WIDTH && terminal->sequence_length >= fixed_width) ||
          (type == ESCAPE_TYPE_CSI && terminal->sequence_length > 2 && byte >= 0x40 && byte <= 0x7e);
      }
      terminal->string_escape = byte == 0x1b;
      if (complete) {
        if (st && !terminal->sequence_discard) --terminal->sequence_length;
        seq[terminal->sequence_length] = 0;
        if (!terminal->sequence_discard && type != ESCAPE_TYPE_STRING)
          terminal_escape_sequence(terminal, type, seq);
        view = &terminal->views[terminal->current_view];
        terminal->sequence_length = terminal->sequence_discard = terminal->string_escape = 0;
        type = ESCAPE_TYPE_NONE;
      }
    } else {
      if (!read_codepoint(terminal, str, &offset, &codepoint)) continue;
      if (codepoint != '\e')
        view->last_graphical_character = 0;
      switch (codepoint) {
        case 0x00:
        case 0x01:
        case 0x02:
        case 0x03:
        case 0x04:
        case 0x05:
        case 0x06:
        case 0x07:
        break;
        case '\b': {
          view->wrap_pending = 0;
          if (view->cursor_x)
            --view->cursor_x;
        } break;
        case '\t':
          view->wrap_pending = 0;
          view->cursor_x = min((view->cursor_x / view->tab_size + 1) * view->tab_size, terminal->columns - 1);
          break;
        case '\n':
        case 0x0b:
        case 0x0c:
          view->wrap_pending = 0;
          total_shifts += terminal_index(terminal, view);
          break;
        case '\r': {
          view->wrap_pending = view->cursor_x = 0;
        } break;
        case 0x0E:
        case 0x0F:
        case 0x11:
        case 0x12:
        case 0x13:
        case 0x14:
        case 0x15:
        case 0x16:
        case 0x17:
        case 0x18:
        case 0x19:
        case 0x1A:
          break;
        case 0x1B: { // escape
          terminal->buffered_sequence[0] = 0x1B;
          type = ESCAPE_TYPE_OPEN;
          terminal->sequence_length = 1;
        } break;
        case 0x1C:
        case 0x1D:
        case 0x1E:
        case 0x1F:
          break;
        case 0x7f: break;
        default:
          total_shifts += terminal_put_char(terminal, view, translate_charset(view->charset, codepoint));
        break;
      }
    }
  }
  return total_shifts;
}

#ifdef _WIN32
  static DWORD WINAPI close_console_worker(void* console) {
    ClosePseudoConsole((HPCON)console);
    return 0;
  }

  static DWORD WINAPI windows_nonblocking_thread_callback(void* data) {
    terminal_t* terminal = (terminal_t*)data;
    char chunk_buffer[LIBTERMINAL_CHUNK_SIZE];
    while (1) {
      DWORD bytes_read;
      WaitForSingleObject(terminal->nonblocking_buffer_mutex, INFINITE);
      DWORD capacity = sizeof(chunk_buffer) - terminal->nonblocking_buffer_length;
      ReleaseMutex(terminal->nonblocking_buffer_mutex);
      if (capacity || terminal->closing) {
        if (terminal->closing) {
          while (1) {
            if (!ReadFile(terminal->frompty, chunk_buffer, sizeof(chunk_buffer), &bytes_read, NULL) || bytes_read == 0)
              break;
          }
          return 0;
        }
        if (!ReadFile(terminal->frompty, chunk_buffer, capacity, &bytes_read, NULL))
          break;
        if (bytes_read > 0) {
          WaitForSingleObject(terminal->nonblocking_buffer_mutex, INFINITE);
          memcpy(&terminal->nonblocking_buffer[terminal->nonblocking_buffer_length], chunk_buffer, bytes_read);
          terminal->nonblocking_buffer_length += bytes_read;
          ReleaseMutex(terminal->nonblocking_buffer_mutex);
        }
      }
      Sleep(1);
    }
    return 0;
  }
#endif

static int terminal_update(terminal_t* terminal, void (*callback)(char*, int, void*), void* data, int* total_shifts) {
  if (terminal->mode == MODE_DUMMY)
    return 0;
  char chunk[LIBTERMINAL_CHUNK_SIZE];
  int len, at_least_one = 0;
  #ifdef _WIN32
    WaitForSingleObject(terminal->nonblocking_buffer_mutex, INFINITE);
    len = terminal->nonblocking_buffer_length;
    memcpy(chunk, terminal->nonblocking_buffer, len);
    terminal->nonblocking_buffer_length = 0;
    ReleaseMutex(terminal->nonblocking_buffer_mutex);
    if (len) {
      *total_shifts += terminal_output(terminal, chunk, len);
      if (callback) callback(chunk, len, data);
    }
    return len > 0;
  #else
    int chunks_processed = 0;
    do {
      len = read(terminal->master, chunk, sizeof(chunk));
      if (len == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
        return at_least_one;
      if (len <= 0) {
        if (len < 0 && errno == EINTR) continue;
        terminal->output_eof = 1;
        return at_least_one ? at_least_one : -1;
      }
      *total_shifts += terminal_output(terminal, chunk, len);
      if (callback)
        callback(chunk, len, data);
      at_least_one = 1;
    } while (len > 0 && chunks_processed++ < LIBTERMINAL_MAX_CHUNKS_PROCESSED);
  #endif
  return -1;
}

#ifndef _WIN32
static void kill_process_group(terminal_t* terminal) {
  if (terminal->pid > 0 && (!terminal->child_exited || !terminal->output_eof)) {
    if (kill(-terminal->pid, SIGKILL) < 0 && errno == ESRCH && !terminal->child_exited)
      kill(terminal->pid, SIGKILL);
  }
}
#endif

static int terminal_close(terminal_t* terminal) {
  terminal_clear_scrollback_buffer(terminal);
  for (int i = 0; i < VIEW_MAX; ++i) {
    if (terminal->views[i].buffer) {
      release_cells(terminal->views[i].buffer, (size_t)terminal->columns * terminal->lines);
      free(terminal->views[i].buffer);
      free(terminal->views[i].overflows);
    }
    terminal->views[i].buffer = NULL;
    terminal->views[i].overflows = NULL;
  }
  if (terminal->mode == MODE_PTY) {
    #if _WIN32
      // This has to be first, because if we don't drain the buffer in our nonblocking_thread,
      // this call can hang. (SIGH).
      InterlockedExchange(&terminal->closing, 1);
      if (terminal->process_information.hProcess && !terminal->child_exited)
        TerminateProcess(terminal->process_information.hProcess, 1);
      if (terminal->job) {
        CloseHandle(terminal->job);
        terminal->job = NULL;
      }
      if (terminal->hpcon) {
        ClosePseudoConsole(terminal->hpcon);
        terminal->hpcon = NULL;
      }
      if (terminal->nonblocking_thread) {
        WaitForSingleObject(terminal->nonblocking_thread, INFINITE);
        CloseHandle(terminal->nonblocking_thread);
        terminal->nonblocking_thread = NULL;
      }
      if (terminal->closing_console) {
        WaitForSingleObject(terminal->closing_console, INFINITE);
        CloseHandle(terminal->closing_console);
        terminal->closing_console = NULL;
      }
      if (terminal->topty) {
        CloseHandle(terminal->topty);
        terminal->topty = NULL;
      }
      if (terminal->frompty) {
        CloseHandle(terminal->frompty);
        terminal->frompty = NULL;
      }
      if (terminal->nonblocking_buffer_mutex) {
        CloseHandle(terminal->nonblocking_buffer_mutex);
        terminal->nonblocking_buffer_mutex = NULL;
      }
      if (terminal->process_information.hProcess) {
        CloseHandle(terminal->process_information.hProcess);
        CloseHandle(terminal->process_information.hThread);
        terminal->process_information.hProcess = NULL;
      }
    #else
      kill_process_group(terminal);
      if (terminal->master >= 0) {
        close(terminal->master);
        terminal->master = -1;
      }
      if (terminal->pid > 0 && !terminal->child_exited) {
        while (waitpid(terminal->pid, NULL, 0) < 0 && errno == EINTR) {}
      }
      terminal->pid = 0;
    #endif
  }
  return 0;
}

static void terminal_free(terminal_t* terminal) {
  terminal_close(terminal);
  free(terminal);
}

static void terminal_resize(terminal_t* terminal, int columns, int lines) {
  if (terminal->columns == columns && terminal->lines == lines)
    return;
  ++terminal->screen_version;
  if (terminal->mode == MODE_PTY) {
    #ifdef _WIN32
      COORD size = { columns, lines };
      if (terminal->hpcon) ResizePseudoConsole(terminal->hpcon, size);
    #else
      struct winsize size = { .ws_row = lines, .ws_col = columns, .ws_xpixel = 0, .ws_ypixel = 0 };
      ioctl(terminal->master, TIOCSWINSZ, &size);
    #endif
  }
  for (int i = 0; i < VIEW_MAX; ++i) {
    buffer_char_t* buffer = malloc(sizeof(buffer_char_t) * columns * lines);
    int* overflows = calloc(lines * sizeof(int), 1);
    memset(buffer, 0, sizeof(buffer_char_t) * columns * lines);
    if (terminal->views[i].buffer) {
      view_t* view = &terminal->views[i];
      int first = i == VIEW_NORMAL_BUFFER ? max(0, view->cursor_y + 1 - lines) : 0;
      for (int y = 0; y < first; ++y)
        terminal_push_scrollback_line(terminal, view->buffer + y * terminal->columns, view->overflows[y]);
      int max_lines = min(terminal->lines - first, lines);
      for (int y = 0; y < max_lines; ++y) {
        const buffer_char_t* row = view->buffer + (first + y) * terminal->columns;
        copy_cells(buffer + y * columns, row, min(terminal->columns, columns));
        if (columns < terminal->columns && row[columns].codepoint == WIDE_TAIL)
          terminal_blank_cells(buffer + y*columns + columns - 1, 1, LIBTERMINAL_NO_STYLING);
      }
      memcpy(overflows, view->overflows + first, max_lines * sizeof(int));
      view->cursor_y -= first;
      view->saved_cursor_y = max(0, view->saved_cursor_y - first);
      release_cells(terminal->views[i].buffer, (size_t)terminal->columns * terminal->lines);
      free(terminal->views[i].buffer);
      free(terminal->views[i].overflows);
    }
    terminal->views[i].buffer = buffer;
    terminal->views[i].cursor_x = min(terminal->views[i].cursor_x, columns - 1);
    terminal->views[i].cursor_y = min(terminal->views[i].cursor_y, lines - 1);
    if (terminal->views[i].cursor_x != columns - 1) terminal->views[i].wrap_pending = 0;
    terminal->views[i].saved_cursor_x = min(terminal->views[i].saved_cursor_x, columns - 1);
    terminal->views[i].saved_cursor_y = min(terminal->views[i].saved_cursor_y, lines - 1);
    if (terminal->views[i].scrolling_region_end != -1) {
      terminal->views[i].scrolling_region_start = min(terminal->views[i].scrolling_region_start, lines - 1);
      terminal->views[i].scrolling_region_end = min(terminal->views[i].scrolling_region_end, lines);
    }
    terminal->views[i].overflows = overflows;
  }
  terminal->columns = columns;
  terminal->lines = lines;
}

static char error_step[64];
static int set_error_step(const char* step) { strncpy(error_step, step, sizeof(error_step)); return 1; }
#if _WIN32
  long long last_error_code;
  static const char* terminal_get_last_error() {
    static char error_buffer[2048];
    strcpy(error_buffer, error_step);
    int len = strlen(error_buffer);
    error_buffer[len++] = ':';
    error_buffer[len++] = ' ';
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, last_error_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&error_buffer[len], sizeof(error_buffer) - (len + 1), NULL);
    return error_buffer;
  }
#else
  // TODO, non-windows error handling, but less important because windows will be failing lots more, 'cause it's shit.
  static const char* terminal_get_last_error() { return error_step; }
#endif

#ifdef _WIN32
// Encode the CRT argv convention, including empty arguments and trailing slashes.
// cmd /s /c receives its final command as shell text inside one outer quote.
static wchar_t* windows_command_line(const char** argv) {
  size_t size = 1;
  for (int i = 0; argv[i]; ++i) size += 2 * strlen(argv[i]) + 3;
  char* utf8 = malloc(size);
  if (!utf8) return NULL;
  char* out = utf8;
  const char* base = argv[0];
  for (const char* c = base; *c; ++c) if (*c == '\\' || *c == '/') base = c + 1;
  int cmd = !_stricmp(base, "cmd.exe") || !_stricmp(base, "cmd");
  for (int i = 0; argv[i]; ++i) {
    if (i) *out++ = ' ';
    const char* arg = argv[i];
    int script = cmd && i && !argv[i+1] && (!_stricmp(argv[i-1], "/c") || !_stricmp(argv[i-1], "/k"));
    int quote = script || !*arg || strpbrk(arg, " \t\"") != NULL;
    if (quote) *out++ = '"';
    if (script) {
      memcpy(out, arg, strlen(arg));
      out += strlen(arg);
    } else {
      while (*arg) {
        size_t slashes = strspn(arg, "\\");
        arg += slashes;
        if (quote && (*arg == '"' || !*arg)) slashes *= 2;
        while (slashes--) *out++ = '\\';
        if (*arg == '"') *out++ = '\\';
        if (*arg) *out++ = *arg++;
      }
    }
    if (quote) *out++ = '"';
  }
  *out = 0;
  wchar_t* result = calloc(size, sizeof(wchar_t));
  if (result && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, result, size)) {
    free(result);
    result = NULL;
  }
  free(utf8);
  return result;
}
#endif

static terminal_t* terminal_new(int columns, int lines, int scrollback_limit, const char* term_env, const char* pathname, const char** argv, const char** environment, const char* cwd) {
  terminal_t* terminal = calloc(sizeof(terminal_t), 1);
  terminal_reset(terminal);
  terminal->foreground = rgb_color(255, 255, 255);
  terminal->background = rgb_color(0, 0, 0);
  terminal->scrollback_limit = scrollback_limit;
  terminal->mode = pathname && strcmp(pathname, "DUMMY") != 0 ? MODE_PTY : MODE_DUMMY;
  if (terminal->mode == MODE_PTY) {
    #ifdef _WIN32
      last_error_code = 0;
      HRESULT result = S_OK;
      HANDLE console_out = NULL, console_in = NULL;
      wchar_t* commandline = NULL;
      wchar_t* directory = NULL;
      STARTUPINFOEXW startup = {0};
      int attributes_ready = 0;
      SIZE_T bytes = 0;
      COORD size = { columns, lines };
      if (!CreatePipe(&console_in, &terminal->topty, NULL, 0) ||
          !CreatePipe(&terminal->frompty, &console_out, NULL, 0)) goto error;
      result = CreatePseudoConsole(size, console_in, console_out, 0, &terminal->hpcon);
      CloseHandle(console_in); console_in = NULL;
      CloseHandle(console_out); console_out = NULL;
      if (FAILED(result)) goto error;
      terminal->nonblocking_buffer_mutex = CreateMutex(NULL, FALSE, NULL);
      if (!terminal->nonblocking_buffer_mutex) goto error;
      startup.StartupInfo.cb = sizeof(startup);
      startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
      InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
      startup.lpAttributeList = malloc(bytes);
      if (!startup.lpAttributeList || !InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes)) goto error;
      attributes_ready = 1;
      if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
          terminal->hpcon, sizeof(HPCON), NULL, NULL)) goto error;
      commandline = windows_command_line(argv);
      if (cwd) {
        size_t capacity = strlen(cwd) + 1;
        directory = calloc(capacity, sizeof(wchar_t));
        if (!directory || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, cwd, -1, directory, capacity)) goto error;
      }
      if (!commandline || !CreateProcessW(NULL, commandline, NULL, NULL, FALSE,
          EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
          (void*)environment[0], directory, &startup.StartupInfo, &terminal->process_information)) goto error;
      terminal->job = CreateJobObjectW(NULL, NULL);
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
      limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      if (!terminal->job || !SetInformationJobObject(terminal->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
          !AssignProcessToJobObject(terminal->job, terminal->process_information.hProcess) ||
          ResumeThread(terminal->process_information.hThread) == (DWORD)-1) goto error;
      terminal->nonblocking_thread = CreateThread(NULL, 0, windows_nonblocking_thread_callback, terminal, 0, NULL);
      if (!terminal->nonblocking_thread && set_error_step("create thread"))
        goto error;
      error:
      last_error_code = FAILED(result) ? HRESULT_CODE(result) : GetLastError();
      if (attributes_ready) DeleteProcThreadAttributeList(startup.lpAttributeList);
      free(startup.lpAttributeList);
      free(commandline);
      free(directory);
      if (console_in) CloseHandle(console_in);
      if (console_out) CloseHandle(console_out);
      if (!terminal->nonblocking_thread) {
        set_error_step("start terminal");
        terminal_close(terminal);
        free(terminal);
        return NULL;
      }
    #else
      struct termios term = {0};
      term.c_cc[VINTR] = 3;
      term.c_cc[VSTART] = '\x13';
      term.c_cc[VSTOP] = '\x11';
      term.c_cc[VSUSP] = 26;
      term.c_cc[VERASE] = '\x7F';
      term.c_cc[VEOL] = 0;
      term.c_cc[VEOF] = 4;
      term.c_lflag |= ISIG | ECHO | ICANON | IEXTEN | ECHOE | ECHOK | ECHOCTL | ECHOKE;
      term.c_cflag |= CS8 | CREAD;
      term.c_iflag |= IUTF8 | ICRNL | IXON;
      term.c_oflag |= OPOST | ONLCR | NL0 | CR0 | TAB0 | BS0 | VT0 | FF0;
      struct winsize size = { .ws_row = lines, .ws_col = columns, .ws_xpixel = 0, .ws_ypixel = 0 };
      terminal->pid = forkpty(&terminal->master, NULL, &term, &size);
      if (terminal->pid == -1 && set_error_step("forkpty")) {
        free(terminal);
        return NULL;
      }
      if (!terminal->pid) {
        if (cwd && chdir(cwd) < 0) { perror(cwd); _exit(126); }
        setenv("TERM", term_env, 1);
        for (int i = 0; environment[i]; i += 2)
          setenv(environment[i], environment[i+1], 1);
        execvp(pathname,  (char** const)argv);
        perror(pathname);
        _exit(127);
      }
      int flags = fcntl(terminal->master, F_GETFL, 0);
      fcntl(terminal->master, F_SETFL, flags | O_NONBLOCK);
    #endif
  }
  terminal_resize(terminal, columns, lines);
  return terminal;
}


static void push_style(lua_State* L, buffer_styling_t style, int* group) {
  if (style.foreground.attributes & ATTRIBUTE_INVERSE) {
    uint8_t attributes = style.foreground.attributes & (ATTRIBUTE_STYLING_MASK & ~ATTRIBUTE_INVERSE);
    style.foreground.attributes &= ~ATTRIBUTE_STYLING_MASK;
    uint8_t decorations = style.background.attributes & ATTRIBUTE_STYLING_MASK;
    style.background.attributes &= ~ATTRIBUTE_STYLING_MASK;
    color_t foreground = style.foreground;
    style.foreground = style.background.value == UNSET_COLOR.value ? INVERSE_COLOR : style.background;
    style.background = foreground.value == UNSET_COLOR.value ? INVERSE_COLOR : foreground;
    style.foreground.attributes |= attributes;
    style.background.attributes |= decorations;
  }
  uint64_t packed = (
    ((uint64_t)style.foreground.attributes << 56) |
    ((uint64_t)style.foreground.r << 48) |
    ((uint64_t)style.foreground.g << 40) |
    ((uint64_t)style.foreground.b << 32) |
    ((uint64_t)style.background.attributes << 24) |
    ((uint64_t)style.background.r << 16) |
    ((uint64_t)style.background.g << 8) |
    ((uint64_t)style.background.b << 0)
  );
  char hex_string[24];
  sprintf(hex_string, "%" PRIu64, packed);
  lua_pushstring(L, hex_string);
  lua_rawseti(L, -2, ++(*group));
}

static void output_line(lua_State* L, buffer_char_t* start, buffer_char_t* end, int overflows) {
  lua_newtable(L);
  int group = 0;
  buffer_char_t* limit = end;
  while (limit > start && !(limit - 1)->codepoint) --limit;
  size_t size = (size_t)(limit - start) * 4 + 1;
  for (buffer_char_t* cell = start; cell < limit; ++cell)
    if (cell->suffix) size += cell->suffix->length;
  char* text = malloc(size);
  if (!text) luaL_error(L, "failed to allocate terminal line buffer");
  int widths = 0;
  do {
    buffer_styling_t style = start->styling;
    size_t length = 0;
    int cells = 0;
    while (start < limit && start->styling.value == style.value) {
      int wide = start + 1 < limit && start[1].codepoint == WIDE_TAIL;
      int cluster = wide || start->suffix;
      if (cluster && length) break;
      length += codepoint_to_utf8(start->codepoint ? start->codepoint : ' ', text + length);
      if (start->suffix) {
        memcpy(text + length, start->suffix->text, start->suffix->length);
        length += start->suffix->length;
      }
      start += wide ? 2 : 1;
      if (cluster) { cells = wide ? 2 : 1; break; }
    }
    if (start == limit && !overflows) text[length++] = '\n';
    push_style(L, style, &group);
    lua_pushlstring(L, text, length);
    lua_rawseti(L, -2, ++group);
    if (cells) {
      if (!widths) {
        lua_newtable(L);
        lua_setfield(L, -2, "widths");
        widths = 1;
      }
      lua_getfield(L, -1, "widths");
      lua_pushinteger(L, cells);
      lua_rawseti(L, -2, group);
      lua_pop(L, 1);
    }
  } while (start < limit);
  free(text);
}


static terminal_t* lua_toterminal(lua_State* L, int index) {
  lua_getfield(L, index, "__terminal");
  terminal_t* terminal = (terminal_t*)lua_touserdata(L, -1);
  lua_pop(L, 1);
  return terminal;
}

static int f_terminal_lines(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  int history = terminal->current_view == VIEW_NORMAL_BUFFER ? terminal->scrollback_total_lines : 0;
  int start = luaL_optinteger(L, 2, history ? -terminal->scrollback_position : 0);
  start = max(-history, min(start, terminal->lines));
  int last = luaL_optinteger(L, 3, start + terminal->lines - 1);
  int end = min(last, terminal->lines - 1) + 1;
  lua_newtable(L);
  if (start >= end) return 1;
  int total_lines = 0;
  int remaining_lines = end - start;
  view_t* view = &terminal->views[terminal->current_view];
  if (terminal->current_view == VIEW_NORMAL_BUFFER && start < 0) {
    int top_offset = terminal->scrollback_target_top_offset;
    int offset = -start;
    backbuffer_page_t* current_backbuffer = terminal_find_scrollback_page(terminal, terminal->scrollback_target, &offset, &top_offset);
    int lines_into_buffer = top_offset - offset;
    while (current_backbuffer && remaining_lines > 0) {
      int* backbuffer_overflows = (int*)&current_backbuffer->buffer[LIBTERMINAL_BACKBUFFER_PAGE_LINES*current_backbuffer->columns];
      for (int y = lines_into_buffer; y < current_backbuffer->line; ++y) {
        output_line(L, &current_backbuffer->buffer[y * current_backbuffer->columns], &current_backbuffer->buffer[(y+1) * current_backbuffer->columns], backbuffer_overflows[y]);
        lua_rawseti(L, -2, ++total_lines);
        if (--remaining_lines == 0)
          break;
      }
      current_backbuffer = current_backbuffer->next;
      lines_into_buffer = 0;
    }
    start = 0;
  }
  if (remaining_lines > 0) {
    remaining_lines = min(remaining_lines, terminal->lines - start);
    for (int y = 0; y < remaining_lines; ++y) {
      output_line(L, &view->buffer[(y + start) * terminal->columns], &view->buffer[(y + start + 1) * terminal->columns], view->overflows[y + start]);
      lua_rawseti(L, -2, ++total_lines);
    }
  }
  return 1;
}


#if _WIN32
static const char* lua_toutf8(lua_State* L, LPCWSTR str) {
  int len = WideCharToMultiByte(CP_UTF8, 0, str, -1, NULL, 0, NULL, NULL);
  if (len > 0) {
    char* output = (char *) malloc(sizeof(char) * len);
    if (output) {
      len = WideCharToMultiByte(CP_UTF8, 0, str, -1, output, len, NULL, NULL);
      if (len) {
        lua_pushlstring(L, output, len - 1);
        free(output);
        return lua_tostring(L, -1);
      }
      free(output);
    }
  }
  return NULL;
}
#endif

static int f_terminal_new(lua_State* L) {
  int x = luaL_checkinteger(L, 1);
  int y = luaL_checkinteger(L, 2);
  int scrollback_limit = luaL_checkinteger(L, 3);
  const char* term_env = luaL_checkstring(L, 4);
  const char* path = luaL_checkstring(L, 5);
  const char* cwd = luaL_optstring(L, 9, NULL);
  size_t nargs = 0, envcount = 0;
  if (lua_istable(L, 6)) {
    for (;;) {
      lua_rawgeti(L, 6, nargs + 1);
      if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
      luaL_checktype(L, -1, LUA_TSTRING);
      lua_pop(L, 1);
      ++nargs;
    }
  }
  #if _WIN32
    size_t envlen;
    const char* block = luaL_checklstring(L, 7, &envlen);
    envcount = 1;
  #else
    luaL_checktype(L, 7, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 7)) {
      luaL_checktype(L, -2, LUA_TSTRING);
      luaL_checktype(L, -1, LUA_TSTRING);
      envcount += 2;
      lua_pop(L, 1);
    }
  #endif
  const char** arguments = calloc(nargs + 2 + envcount + 1, sizeof(*arguments));
  if (!arguments) return luaL_error(L, "out of memory");
  const char** environment = arguments + nargs + 2;
  arguments[0] = path;
  for (size_t i = 0; i < nargs; ++i) {
    lua_rawgeti(L, 6, i + 1);
    arguments[i + 1] = lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  #if _WIN32
    wchar_t* env16 = calloc(envlen + 2, sizeof(wchar_t));
    if (!env16 || (envlen && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, block, envlen, env16, envlen))) {
      free(arguments); free(env16);
      return luaL_error(L, "invalid environment block");
    }
    environment[0] = (const char*)env16;
  #else
    size_t i = 0;
    lua_pushnil(L);
    while (lua_next(L, 7)) {
      environment[i++] = lua_tostring(L, -2);
      environment[i++] = lua_tostring(L, -1);
      lua_pop(L, 1);
    }
  #endif
  int debug = lua_toboolean(L, 8);
  terminal_t* terminal = terminal_new(x, y, scrollback_limit, term_env, path, arguments, environment, cwd);
  #if _WIN32
    free(env16);
  #endif
  free(arguments);
  if (!terminal)
    return luaL_error(L, "error creating terminal: %s", terminal_get_last_error());
  terminal->debug = debug;
  lua_newtable(L);
  lua_pushlightuserdata(L, terminal);
  lua_setfield(L, -2, "__terminal");
  luaL_setmetatable(L, "libterminal");
  return 1;
}

#if _WIN32
static int f_terminal_getenv(lua_State* L) {
  LPWCH system_env = GetEnvironmentStringsW(), envp = system_env;
  lua_newtable(L);
  int table = lua_gettop(L);
  while (wcslen(envp) > 0) {
    const char* str = lua_toutf8(L, envp);
    if (str) {
      const char* equal = strchr(str + (*str == '='), '=');
      lua_pushlstring(L, str, equal - str);
      lua_pushstring(L, equal + 1);
      lua_rawset(L, table);
      lua_pop(L, 1);
    }
    envp += wcslen(envp) + 1;
  }
  FreeEnvironmentStringsW(system_env);
  return 1;
}
#endif


static int f_terminal_gc(lua_State* L) {
  terminal_free(lua_toterminal(L, 1));
  return 0;
}

static int f_terminal_close(lua_State* L) {
  lua_pushinteger(L, terminal_close(lua_toterminal(L, 1)));
  return 1;
}

static void chunk_update(char* buf, int len, void* L) {
  lua_pushvalue(L, 2);
  lua_pushlstring(L, buf, len);
  lua_call(L, 1, 0);
}
static void push_chunk(char* buf, int len, void* state) {
  lua_pushlstring((lua_State*)state, buf, len);
}

static int f_terminal_update(lua_State* L){
  int status, total_shifts = 0;
  if (lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 2)) {
    int top = lua_gettop(L);
    luaL_checkstack(L, LIBTERMINAL_MAX_CHUNKS_PROCESSED + 3, "read terminal output");
    terminal_update(lua_toterminal(L, 1), push_chunk, L, &total_shifts);
    int chunks = lua_gettop(L) - top;
    if (chunks) lua_concat(L, chunks); else lua_pushnil(L);
    if (chunks) lua_pushinteger(L, total_shifts); else lua_pushboolean(L, 0);
    lua_pushvalue(L, -2);
    return 2;
  }
  if (lua_type(L, 2) == LUA_TFUNCTION)
    status = terminal_update(lua_toterminal(L, 1), chunk_update, L, &total_shifts);
  else
    status = terminal_update(lua_toterminal(L, 1), NULL, NULL, &total_shifts);
  if (status != 0)
    lua_pushinteger(L, total_shifts);
  else
    lua_pushboolean(L, 0);
  return 1;
}

static int f_terminal_input(lua_State* L) {
  size_t len;
  const char* str = luaL_checklstring(L, 2, &len);
  terminal_input(lua_toterminal(L, 1), str, (int)len);
  return 0;
}

// Foreground and background used to answer OSC 10/11 color queries.
static int f_terminal_colors(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  int fg = luaL_checkinteger(L, 2), bg = luaL_checkinteger(L, 3);
  terminal->foreground = rgb_color(fg >> 16, fg >> 8, fg);
  terminal->background = rgb_color(bg >> 16, bg >> 8, bg);
  return 0;
}

// A revision identifies the rows and cursor displayed by the Lua view.
static int f_terminal_screen_state(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (lua_gettop(L) > 1 && !lua_toboolean(L, 2)) terminal->synchronized = 0;
  lua_pushinteger(L, terminal->screen_version);
  lua_pushboolean(L, terminal->synchronized);
  return 2;
}

static int f_terminal_size(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (lua_gettop(L) > 1) {
    int x = luaL_checkinteger(L, 2), y = luaL_checkinteger(L, 3);
    terminal_resize(terminal, x, y);
  }
  lua_pushinteger(L, terminal->columns);
  lua_pushinteger(L, terminal->lines);
  return 2;
}


static int f_terminal_exited(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->mode == MODE_DUMMY) { lua_pushboolean(L, 0); return 1; }
  if (!terminal->child_exited) {
    #if _WIN32
      DWORD code;
      if (WaitForSingleObject(terminal->process_information.hProcess, 0) == WAIT_OBJECT_0 &&
          GetExitCodeProcess(terminal->process_information.hProcess, &code)) {
        terminal->closing_console = CreateThread(NULL, 0, close_console_worker, terminal->hpcon, 0, NULL);
        if (terminal->closing_console) {
          terminal->hpcon = NULL;
          terminal->child_exited = 1;
          terminal->exit_code = (int)code;
        }
      }
    #else
      int status;
      if (waitpid(terminal->pid, &status, WNOHANG) == terminal->pid) {
        terminal->child_exited = 1;
        terminal->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        terminal->exit_signal = WIFSIGNALED(status) ? WTERMSIG(status) : -1;
      }
    #endif
  }
  #if _WIN32
    terminal->output_eof = WaitForSingleObject(terminal->nonblocking_thread, 0) == WAIT_OBJECT_0
      && terminal->nonblocking_buffer_length == 0;
  #endif
  if (terminal->child_exited && (!lua_toboolean(L, 2) || terminal->output_eof)) {
    lua_pushinteger(L, terminal->exit_code);
    lua_pushinteger(L, terminal->exit_signal);
    return 2;
  }
  lua_pushboolean(L, 0);
  return 1;
}

// Keep the normal screen and scrollback when starting another PTY in a task view.
static int f_terminal_inherit_screen(lua_State* L) {
  terminal_t* next = lua_toterminal(L, 1);
  terminal_t* old = lua_toterminal(L, 2);
  if (next == old) return 0;
  ++next->screen_version;
  ++old->screen_version;
  terminal_resize(old, next->columns, next->lines);
  view_t fresh = next->views[VIEW_NORMAL_BUFFER];
  next->views[VIEW_NORMAL_BUFFER] = old->views[VIEW_NORMAL_BUFFER];
  old->views[VIEW_NORMAL_BUFFER] = fresh;
  terminal_clear_scrollback_buffer(next);
  next->scrollback_buffer_start = old->scrollback_buffer_start;
  next->scrollback_buffer_end = old->scrollback_buffer_end;
  next->scrollback_total_lines = old->scrollback_total_lines;
  old->scrollback_buffer_start = old->scrollback_buffer_end = old->scrollback_target = NULL;
  old->scrollback_total_lines = old->scrollback_position = old->scrollback_target_top_offset = 0;
  return 0;
}

static int f_terminal_kill(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->mode == MODE_PTY) {
    #if _WIN32
      if (terminal->job) TerminateJobObject(terminal->job, 1);
    #else
      kill_process_group(terminal);
    #endif
  }
  return 0;
}

static int f_terminal_cursor(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushinteger(L, terminal->views[terminal->current_view].cursor_x);
  lua_pushinteger(L, terminal->views[terminal->current_view].cursor_y);
  view_t* view = &terminal->views[terminal->current_view];
  switch (view->cursor_hidden ? CURSOR_HIDDEN : view->cursor_mode) {
    case CURSOR_SOLID: lua_pushliteral(L, "solid"); break;
    case CURSOR_HIDDEN: lua_pushliteral(L, "hidden"); break;
    case CURSOR_BLINKING: lua_pushliteral(L, "blinking"); break;
  }
  lua_pushstring(L, view->cursor_shape == 1 ? "underline" : (view->cursor_shape == 2 ? "bar" : "block"));
  return 4;
}

static int f_terminal_cursor_keys_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  switch (terminal->views[terminal->current_view].cursor_keys_mode) {
    case KEYS_MODE_NORMAL: lua_pushliteral(L, "normal"); break;
    case KEYS_MODE_APPLICATION: lua_pushliteral(L, "application"); break;
  }
  return 1;
}

static int f_terminal_keypad_keys_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  switch (terminal->views[terminal->current_view].keypad_keys_mode) {
    case KEYS_MODE_NORMAL: lua_pushliteral(L, "normal"); break;
    case KEYS_MODE_APPLICATION: lua_pushliteral(L, "application"); break;
  }
  return 1;
}

static int f_terminal_scrollback(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->current_view == VIEW_NORMAL_BUFFER) {
    if (lua_gettop(L) >= 2)
      terminal_scrollback(terminal, luaL_checkinteger(L, 2));
    lua_pushinteger(L, terminal->scrollback_position);
    lua_pushinteger(L, terminal->scrollback_total_lines);
  } else {
    lua_pushinteger(L, 0);
    lua_pushinteger(L, 0);
  }
  return 2;
}

static int f_terminal_focused(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->reporting_focus)
    terminal_input(terminal, lua_toboolean(L, 2) ? "\x1B[I" : "\x1B[O", 3);
  return 0;
}

static int f_terminal_paste_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  lua_pushstring(L, terminal->paste_mode == PASTE_BRACKETED ? "bracketed" : "normal");
  return 1;
}

static int f_terminal_name(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  if (terminal->name[0])
    lua_pushstring(L, terminal->name);
  else
    lua_pushnil(L);
  return 1;
}

static int f_terminal_clear(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  ++terminal->screen_version;
  terminal_clear_scrollback_buffer(terminal);
  clear_screen(terminal, &terminal->views[terminal->current_view]);
  return 0;
}

static int f_terminal_reset(lua_State* L) {
  terminal_reset(lua_toterminal(L, 1));
  return 0;
}

static int f_terminal_mouse_tracking_mode(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  switch (terminal->mouse_tracking_mode) {
    case MOUSE_TRACKING_NONE: lua_pushnil(L); break;
    case MOUSE_TRACKING_X10: lua_pushliteral(L, "x10"); break;
    case MOUSE_TRACKING_NORMAL: lua_pushliteral(L, "normal"); break;
    case MOUSE_TRACKING_BUTTON: lua_pushliteral(L, "button"); break;
    case MOUSE_TRACKING_ANY: lua_pushliteral(L, "any"); break;
  }
  return 1;
}

static int f_terminal_mouse_encoding(lua_State* L) {
  terminal_t* terminal = lua_toterminal(L, 1);
  switch (terminal->mouse_encoding) {
    case MOUSE_ENCODING_DEFAULT: lua_pushliteral(L, "default"); break;
    case MOUSE_ENCODING_SGR: lua_pushliteral(L, "sgr"); break;
  }
  return 1;
}

static const luaL_Reg terminal_api[] = {
  { "__gc",                f_terminal_gc                     },
  { "new",                 f_terminal_new                    },
  { "close",               f_terminal_close                  },
  { "input",               f_terminal_input                  },
  { "clear",               f_terminal_clear                  },
  { "reset",               f_terminal_reset                  },
  { "lines",               f_terminal_lines                  },
  { "screen_state",        f_terminal_screen_state             },
  { "colors",              f_terminal_colors                   },
  { "size",                f_terminal_size                   },
  { "update",              f_terminal_update                 },
  { "inherit_screen",      f_terminal_inherit_screen          },
  { "kill",                f_terminal_kill                   },
  { "exited",              f_terminal_exited                 },
  #if _WIN32
  { "getenv",              f_terminal_getenv                 },
  #endif
  { "cursor",              f_terminal_cursor                 },
  { "focused",             f_terminal_focused                },
  { "mouse_tracking_mode", f_terminal_mouse_tracking_mode    },
  { "mouse_encoding",      f_terminal_mouse_encoding         },
  { "cursor_keys_mode",    f_terminal_cursor_keys_mode       },
  { "keypad_keys_mode",    f_terminal_keypad_keys_mode       },
  { "paste_mode",          f_terminal_paste_mode             },
  { "scrollback",          f_terminal_scrollback             },
  { "name",                f_terminal_name                   },
  { NULL,                  NULL                              }
};


#ifndef LIBTERMINAL_VERSION
  #define LIBTERMINAL_VERSION "unknown"
#endif

#ifndef LIBTERMINAL_STANDALONE
int luaopen_pragtical_libterminal(lua_State* L, void* XL) {
  pragtical_plugin_init(XL);
#else
int luaopen_libterminal(lua_State* L) {
#endif
  luaL_newmetatable(L, "libterminal");
  luaL_setfuncs(L, terminal_api, 0);
  lua_pushliteral(L, LIBTERMINAL_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
