const std = @import("std");

pub fn main() anyerror!void {}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
