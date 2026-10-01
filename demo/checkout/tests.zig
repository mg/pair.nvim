const std = @import("std");
const cart = @import("src/cart.zig");

test "checkout applies a discount" {
    const items = [_]cart.Item{.{ .price = 20, .quantity = 2 }};
    try std.testing.expectApproxEqAbs(
        @as(f64, 30),
        cart.total(&items, 0.25),
        0.0001,
    );
}
