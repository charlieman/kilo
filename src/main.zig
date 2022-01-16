const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

const c = @cImport({
    @cInclude("ctype.h");
});

// These variables are not set in zig's std.os
const VTIME: u8 = 5;
const VMIN: u8 = 6;

//*** data ***/

var stdout: std.fs.File.Writer = undefined;

const Flow = enum {
    keep_going,
    exit,
};

const editorConfig = struct {
    termios: linux.termios = undefined,
    screen_rows: u32 = undefined,
    screen_cols: u32 = undefined,
};

var E = editorConfig{};

//*** terminal ***/

fn enableRawMode() !void {
    E.termios = try os.tcgetattr(linux.STDIN_FILENO);

    var raw = E.termios;
    raw.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    raw.oflag &= ~(linux.OPOST);
    raw.cflag |= linux.CS8;
    raw.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    raw.cc[VMIN] = 0;
    raw.cc[VTIME] = 1;

    if (linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &raw) == -1) {
        return error.tcsetattr;
    }
}

fn disableRawMode() !void {
    // can't use this because TCSA is missing from std.c
    //try os.tcsetattr(linux.STDIN_FILENO, .FLUSH, raw);
    if (linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &E.termios) == -1) {
        return error.tcsetattr;
    }
}

fn editorReadKey() !u8 {
    var char: [1]u8 = .{0};
    var nread = try os.read(linux.STDIN_FILENO, char[0..1]);
    while (nread != 1) {
        if (nread == -1) return error.read;
        nread = try os.read(linux.STDIN_FILENO, char[0..1]);
    }
    return char[0];
}

fn getWindowSize(rows: *u32, cols: *u32) !void {
    var ws: linux.winsize = undefined;
    const rc = linux.ioctl(linux.STDIN_FILENO, linux.T.IOCGWINSZ, @ptrToInt(&ws));
    switch (linux.getErrno(rc)) {
        .SUCCESS => {
            if (ws.ws_col == 0) return error.getWindowSize;
            cols.* = ws.ws_col;
            rows.* = ws.ws_row;
            return;
        },
        // TODO: check for .INTR in a loop like std.os.isatty does?
        else => return error.getWindowSize,
    }
}

fn editorProcessKeypress() !Flow {
    var char = try editorReadKey();
    switch (char) {
        ctrlKey('q') => return .exit,
        else => {},
    }
    return .keep_going;
}

fn iscntrl(char: u8) bool {
    // we could write c < 0x20 || c == 0x7f and avoid
    // including ctype.h and linking to libC
    return c.iscntrl(char) != 0;
}

inline fn ctrlKey(char: u8) u8 {
    return char & 0b1_1111;
}

//*** output ***/

fn editorDrawRows() !void {
    var y: u32 = 0;
    while (y < 24) : (y += 1) {
        _ = try stdout.write("~\r\n");
    }
}

fn editorRefreshScreen() !void {
    // \x1b: Escape character (27)
    // [: part of the escape sequence
    // J: Erase In Display (https://vt100.net/docs/vt100-ug/chapter3.html#ED)
    // 2: Argument to ED (Erase all of the display)
    _ = try stdout.write("\x1b[2J");

    // H: Cursor position (https://vt100.net/docs/vt100-ug/chapter3.html#CUP)
    _ = try stdout.write("\x1b[H");

    try editorDrawRows();

    _ = try stdout.write("\x1b[H");
}

//*** input ***/

//*** init ***/

fn initEditor() !void {
    try getWindowSize(&E.screen_rows, &E.screen_cols);
}

pub fn main() anyerror!void {
    try enableRawMode();
    defer disableRawMode() catch {};

    try initEditor();

    stdout = std.io.getStdOut().writer();

    while (true) {
        try editorRefreshScreen();
        if ((try editorProcessKeypress()) == .exit) break;
    }
}

//*** tests ***/

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

test "getWindowSize" {
    if (std.os.isatty(std.os.STDOUT_FILENO)) {
        var rows: u32 = 0;
        var cols: u32 = 0;
        try getWindowSize(&rows, &cols);
        try std.testing.expect(rows > 0);
        try std.testing.expect(cols > 0);
    }
}
