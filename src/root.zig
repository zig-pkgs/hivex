const std = @import("std");
const c = @cImport(@cInclude("hivex.h"));
const testing = std.testing;

test "just header" {
    const h = c.hivex_open("upstream/images/minimal", 0);
    try testing.expect(h != null);
    defer _ = c.hivex_close(h);
}
