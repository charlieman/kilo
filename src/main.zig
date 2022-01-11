const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

const c = @cImport({
    @cInclude("ctype.h");
});

var orig_termios: linux.termios = undefined;

fn enableRawMode() void {
    _ = linux.tcgetattr(linux.STDIN_FILENO, &orig_termios);
    var raw = orig_termios;
    raw.iflag &= ~(linux.ICRNL | linux.IXON);
    raw.oflag &= ~(linux.OPOST);
    raw.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
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

    var char: [1]u8 = undefined;
    var slice = char[0..char.len];
    while ((try os.read(linux.STDIN_FILENO, slice)) == 1 and slice[0] != 'q') {
        if (iscntrl(slice[0])) {
            std.debug.print("{d}\n", .{slice[0]});
        } else {
            std.debug.print("{d} ('{c}')\n", .{ slice[0], slice[0] });
        }
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
