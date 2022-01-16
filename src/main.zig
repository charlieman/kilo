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

fn iscntrl(char: u8) bool {
    // we could write c < 0x20 || c == 0x7f and avoid
    // including ctype.h and linking to libC
    return c.iscntrl(char) != 0;
}

inline fn ctrlKey(char: u8) u8 {
    return char & 0b1_1111;
}

//*** init ***/

pub fn main() anyerror!void {
    try enableRawMode();
    defer disableRawMode() catch {};

    const stdout = std.io.getStdOut().writer();

    while (true) {
        var char: [1]u8 = .{0};
        _ = try os.read(linux.STDIN_FILENO, char[0..1]);
        if (iscntrl(char[0])) {
            try stdout.print("{d}\r\n", .{char[0]});
        } else {
            try stdout.print("{d} ('{c}')\r\n", .{ char[0], char[0] });
        }
        if (char[0] == ctrlKey('q')) break;
    }
}

//*** tests ***/

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
