const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

usingnamespace @import("raytracer.zig");

const test_seed: u64 = 0xC0FFEE42DEADBEEF;

test "Critical path" {
    const extent = u32_2{ 128, 128 };

    const allocator: *std.mem.Allocator = std.heap.page_allocator;

    var game_state = try create_raytracer_state(allocator, extent, test_seed);
    defer destroy_raytracer_state(allocator, &game_state);
}
