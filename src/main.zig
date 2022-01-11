const std = @import("std");
const os = std.os;
const mem = std.mem;

pub fn main() anyerror!void {
    var c: [1]u8 = undefined;
    var slice = c[0..c.len];
    while ((try os.read(os.system.STDIN_FILENO, slice)) == 1 and slice[0] != 'q') {}
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
