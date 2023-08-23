# pragtical-terminal

`pragtical-terminal` is a (mostly) fully-featured terminal emulator designed to slot into pragtical as a plugin for windows (Windows 10+ only), mac and linux.

![image](https://github.com/adamharrison/lite-xl-terminal/assets/1034518/6b8003da-d4c1-4227-8fc9-3d2b1ae89bf2)


## Installation

The easiest way to install `pragtical-terminal` is to use [`ppm`](https://github.com/pragtical/plugin-manager), and
then run the following command:

```
ppm add https://github.com/pragtical/terminal.git && ppm install terminal
```

If you want to simply try it out, you can use `ppm`'s `run` command:

```
ppm run https://github.com/pragtical/terminal.git terminal
```

If you want to grab it directly, and build it from the repo, you can do:

```
git clone --depth=1 https://github.com/pragtical/terminal.git --recurse-submodules --shallow-submodules
  cd terminal && ./build.sh && cp -R plugins/terminal ~/.config/pragtical/plugins && cp libterminal.so ~/.config/pragtical/plugins/terminal
```

Until we're released.

## Usage

You can activate the terminal by either pressing `ctrl+t`, or running the `Terminal: Toggle` command.

## Status

Currently pre-release; but mostly complete. Some small issues remain. Please feel free to post
issues if you find something; but should work in most cases.

### Supported Shells

The following shells are tested on each release to ensure that they actually function:

* bash (Linux/Mac)
* dash (Linux/Mac)
* zsh (Linux/Mac)
* cmd.exe (Windows 10+)

### Building

As this is a native plugin, it requires building. Currently it has no dependencies other than
the native OS libraries for each OS.

#### Linux, Mac, and Windows MSYS

```
./build.sh
```

#### Linux -> Windows

```
CC=x86_64-w64-mingw32-gcc BIN=libterminal.dll ./build.sh
```

## Description

A simple, and straightforward terminal that presents itself as `xterm-256color`. Supports:

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

By default, will use `$SHELL`, if present. If not, we will use `sh` on linux and mac
(though this is configurable), and `c:\windows\system32\cmd.exe` on windows.

## Limitations

Currently doesn't support the following (non-exhaustive list; mainly contains
things that may be supported in future):

2. Setting explicitly tab stops.
3. `DECBKM`.
