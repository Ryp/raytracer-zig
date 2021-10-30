const std = @import("std");
const assert = std.debug.assert;

// I borrowed this name from HLSL
fn all(vector: anytype) bool {
    const type_info = @typeInfo(@TypeOf(vector));
    assert(type_info.Vector.child == bool);
    assert(type_info.Vector.len > 1);

    return @reduce(.And, vector);
}

fn any(vector: anytype) bool {
    const type_info = @typeInfo(@TypeOf(vector));
    assert(type_info.Vector.child == bool);
    assert(type_info.Vector.len > 1);

    return @reduce(.Or, vector);
}

pub const u32_2 = std.meta.Vector(2, u32);

pub const f32_3 = std.meta.Vector(3, f32);
pub const f32_4 = std.meta.Vector(4, f32);

pub const f32_3x3 = std.meta.Vector(3, f32_3);
pub const f32_4x3 = std.meta.Vector(4, f32_3);
pub const f32_4x4 = std.meta.Vector(4, f32_4);

const FrameBufferPixelFormat = f32_4;
const FramebufferExtentMin = u32_2{ 16, 16 };
const FramebufferExtentMax = u32_2{ 2048, 2048 };

pub const RaytracerState = struct {
    frame_extent: u32_2,
    framebuffer: [][]FrameBufferPixelFormat,
    rng: std.rand.Xoroshiro128, // Hardcode PRNG type for forward compatibility
};

pub fn create_raytracer_state(allocator: *std.mem.Allocator, extent: u32_2, seed: u64) !RaytracerState {
    assert(all(extent >= FramebufferExtentMin));
    assert(all(extent <= FramebufferExtentMax));

    // Allocate framebuffer
    const framebuffer = try allocator.alloc([]FrameBufferPixelFormat, extent[0]);
    errdefer allocator.free(framebuffer);

    for (framebuffer) |*column| {
        column.* = try allocator.alloc(FrameBufferPixelFormat, extent[1]);
        errdefer allocator.free(column);

        for (column.*) |*cell| {
            cell.* = .{ 0.0, 0.0, 0.0, 0.0 };
        }
    }

    return RaytracerState{
        .frame_extent = extent,
        .framebuffer = framebuffer,
        .rng = std.rand.Xoroshiro128.init(seed),
    };
}

pub fn destroy_raytracer_state(allocator: *std.mem.Allocator, rt: *RaytracerState) void {
    for (rt.framebuffer) |column| {
        allocator.free(column);
    }

    allocator.free(rt.framebuffer);
}
