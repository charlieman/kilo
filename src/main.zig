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

var orig_termios: linux.termios = undefined;
var stdout: std.fs.File.Writer = undefined;

const Flow = enum {
    keep_going,
    exit,
};

//*** terminal ***/

fn enableRawMode() !void {
    orig_termios = try os.tcgetattr(linux.STDIN_FILENO);

    var raw = orig_termios;
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
    if (linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &orig_termios) == -1) {
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
fn editorRefreshScreen() !void {
    // \x1b: Escape character (27)
    // [: part of the escape sequence
    // J: Erase In Display (https://vt100.net/docs/vt100-ug/chapter3.html#ED)
    // 2: Argument to ED (Erase all of the display)
    _ = try stdout.write("\x1b[2J");

    // H: Cursor position (https://vt100.net/docs/vt100-ug/chapter3.html#CUP)
    _ = try stdout.write("\x1b[H");
}

//*** input ***/

//*** init ***/

pub fn main() anyerror!void {
    try enableRawMode();
    defer disableRawMode() catch {};

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
