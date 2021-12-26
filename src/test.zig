const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const raytracer = @import("raytracer.zig");

const test_seed: u64 = 0xC0FFEE42DEADBEEF;

test "Critical path" {
    const extent = raytracer.u32_2{ 128, 128 };

    const allocator: std.mem.Allocator = std.heap.page_allocator;

    var rt = try raytracer.create_raytracer_state(allocator, extent, test_seed);
    defer raytracer.destroy_raytracer_state(allocator, &rt);

    raytracer.add_fullscreen_workload(&rt);

    _ = raytracer.render_workload(&rt, rt.work_queue_size);
}
