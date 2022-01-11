const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

var orig_termios: linux.termios = undefined;

fn enableRawMode() void {
    _ = linux.tcgetattr(linux.STDIN_FILENO, &orig_termios);
    var raw = orig_termios;
    raw.lflag &= ~linux.ECHO;
    _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &raw);
}

fn disableRawMode() void {
    _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &orig_termios);
}

pub fn main() anyerror!void {
    enableRawMode();
    defer disableRawMode();

    var c: [1]u8 = undefined;
    var slice = c[0..c.len];
    while ((try os.read(linux.STDIN_FILENO, slice)) == 1 and slice[0] != 'q') {}
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
