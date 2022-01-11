const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

fn enableRawMode() void {
    var raw: linux.termios = undefined;
    _ = linux.tcgetattr(linux.STDIN_FILENO, &raw);
    raw.lflag &= ~linux.ECHO;
    _ = linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &raw);
}

pub fn main() anyerror!void {
    enableRawMode();

    var c: [1]u8 = undefined;
    var slice = c[0..c.len];
    while ((try os.read(linux.STDIN_FILENO, slice)) == 1 and slice[0] != 'q') {}
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
