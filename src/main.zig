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

var orig_termios: linux.termios = undefined;

fn enableRawMode() void {
    _ = linux.tcgetattr(linux.STDIN_FILENO, &orig_termios);
    var raw = orig_termios;
    raw.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    raw.oflag &= ~(linux.OPOST);
    raw.cflag |= linux.CS8;
    raw.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    raw.cc[VMIN] = 0;
    raw.cc[VTIME] = 1;

    _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &raw);
}

fn disableRawMode() void {
    _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &orig_termios);
}

fn iscntrl(char: u8) bool {
    return c.iscntrl(char) != 0;
}

pub fn main() anyerror!void {
    enableRawMode();
    defer disableRawMode();

    while (true) {
        var char: [1]u8 = .{0};
        _ = try os.read(linux.STDIN_FILENO, char[0..1]);
        if (iscntrl(char[0])) {
            std.debug.print("{d}\r\n", .{char[0]});
        } else {
            std.debug.print("{d} ('{c}')\r\n", .{ char[0], char[0] });
        }
        if (char[0] == 'q') break;
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
