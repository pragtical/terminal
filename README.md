# pragtical-terminal

`pragtical-terminal` is a (mostly) fully-featured terminal emulator designed to
slot into pragtical as a plugin for windows (Windows 10+ only), mac and linux.

![image](https://github.com/adamharrison/lite-xl-terminal/assets/1034518/6b8003da-d4c1-4227-8fc9-3d2b1ae89bf2)

## Description

A simple, and straightforward integrated terminal that presents itself as
`xterm-256color`. Supports:

1. A configurable-length scrollback buffer.
2. Alternate buffer support for things like `vim` and `htop`.
3. Configurable color support.
4. Signal characters.
5. Configurable shell.
6. Selecting from terminal.
7. Copying from terminal.
8. UTF-8 support.
9. Terminal resizing.
10. Locked scrollback regions.
11. Copying from terminal.
12. And more!

By default, will use `$SHELL` as your shell if present. If not, we will use
`sh` on linux and mac (though this is configurable), and
`%COMSPEC%` or `c:\windows\system32\cmd.exe` on windows.

### Usage

You can activate the terminal as a docked view at the bottom of your editor by
either pressing `alt+t`, or running the `Terminal: Toggle Drawer` command.

You can also put a `TerminalView` into your main viewing pane by using ``ctrl+shift+` ``
or by running the `Terminal: Open Tab` command. It can be closed with `ctrl+shift+w`.

Most commands that would normally be bound to `ctrl+<key>` in the editor
can be accessed by `ctrl+shift+<key>` when the terminal has focus.

### Supported Shells

The following shells are tested on each release to ensure that they actually
function:

* bash (Linux/Mac/Windows 10+)
* dash (Linux/Mac)
* zsh (Linux/Mac)
* cmd.exe (Windows 10+)

More shells should work, but are not tested outright.

## Installation

The easiest way to install `pragtical-terminal` is to use
[`ppm`](https://github.com/pragtical/plugin-manager), and then run the
following command:

```
ppm install terminal
```

If you want to simply try it out, you can use `ppm`'s `run` command:

```
ppm run terminal
```

If you want to grab it directly, and build it from the repo, on Linux, Mac
or MSYS on Windows you can do:

```
git clone --depth=1 https://github.com/pragtical/terminal.git \
  --recurse-submodules --shallow-submodules && cd terminal && \
  ./build.sh && cp -R plugins/terminal ~/.config/pragtical/plugins && \
  cp libterminal.so ~/.config/pragtical/plugins/terminal
```

If you want to install on Windows, but don't have MSYS, you can download
the files directly from our [release](https://github.com/pragtical/terminal/releases/tag/latest)
page, download `libterminal.x86_64-windows.dll`, as well as the Source Code,
and place both the dll, and the `plugins/terminal/init.lua` from the source
code archive into your pragtical plugins directory as `plugins/terminal/init.lua`
and `plugins/terminal/libterminal.x86_64-windows.dll`.

### Stanalone

If you want to use terminal as a standalone terminal, here's a handy script you can use:

```
PRAGTICAL_SCALE=1 ppm run terminal --config 'config.plugins.treeview=false config.plugins.workspace=false config.always_show_tabs=false local _,_,x,y = system.get_window_size() system.set_window_size(800, 500, x, y) local TerminalView = require "plugins.terminal".class local old_close = TerminalView.close function TerminalView:close() old_close(self) os.exit(0) end core.add_thread(function() command.perform("terminal:open-tab") local node = core.root_view.root_node:get_node_for_view(core.status_view) node:close_view(core.root_view.root_node, core.status_view) end)'
```

## Status

1.0 has been released. It should be functional on Windows 10+, Linux, and
MacOS.

## Building

As this is a native plugin, it requires building. Currently it has no
dependencies other than the native OS libraries for each OS.

### Linux, Mac, and Windows MSYS

```
./build.sh -g
```

### Linux -> Windows

```
CC=x86_64-w64-mingw32-gcc BIN=libterminal.dll ./build.sh -g
```
