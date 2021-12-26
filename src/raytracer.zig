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

pub const f32_2 = std.meta.Vector(2, f32);
pub const f32_3 = std.meta.Vector(3, f32);
pub const f32_4 = std.meta.Vector(4, f32);

// FIXME Zig doesn't seem to have a suitable matrix construct yet
pub const f32_3x3 = [3]f32_3;
pub const f32_4x3 = [4]f32_3;
pub const f32_4x4 = [4]f32_4;

const FrameBufferPixelFormat = f32_4;
const FramebufferExtentMin = u32_2{ 16, 16 };
const FramebufferExtentMax = u32_2{ 2048, 2048 };
const RenderTileSize = u32_2{ 16, 16 };
const MaxWorkItemCount: u32 = 2048;
const diffuse_sample_count: u32 = 16;

const WorkItem = struct {
    position_start: u32_2,
    position_end: u32_2,
};

const RayQuery = struct {
    direction_ws: f32_3,
    accum: FrameBufferPixelFormat = .{},
};

pub const RaytracerState = struct {
    frame_extent: u32_2,
    framebuffer: [][]FrameBufferPixelFormat,
    work_queue: []WorkItem, // Work item should be taken from the end
    work_queue_size: u32 = 0,
    ray_queries: []RayQuery, // FIXME Put in worker context
    ray_query_count: u32 = 0,
    rng: std.rand.Xoroshiro128, // Hardcode PRNG type for forward compatibility
};

pub fn create_raytracer_state(allocator: std.mem.Allocator, extent: u32_2, seed: u64) !RaytracerState {
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

    // Allocate work item queue
    const work_queue = try allocator.alloc(WorkItem, MaxWorkItemCount);
    errdefer allocator.free(work_queue);

    const ray_queries = try allocator.alloc(RayQuery, RenderTileSize[0] * RenderTileSize[1] * 1024);
    errdefer allocator.free(ray_queries);

    return RaytracerState{
        .frame_extent = extent,
        .framebuffer = framebuffer,
        .work_queue = work_queue,
        .ray_queries = ray_queries,
        .rng = std.rand.Xoroshiro128.init(seed),
    };
}

pub fn destroy_raytracer_state(allocator: std.mem.Allocator, rt: *RaytracerState) void {
    allocator.free(rt.ray_queries);

    allocator.free(rt.work_queue);

    for (rt.framebuffer) |column| {
        allocator.free(column);
    }

    allocator.free(rt.framebuffer);
}

// Cut the screen into tiles and create a workload item for each
pub fn add_fullscreen_workload(rt: *RaytracerState) void {
    const tile_count = (rt.frame_extent + RenderTileSize - u32_2{ 1, 1 }) / RenderTileSize;

    var tile_index: u32_2 = .{ 0, undefined };
    while (tile_index[0] < tile_count[0]) : (tile_index[0] += 1) {
        tile_index[1] = 0;
        while (tile_index[1] < tile_count[1]) : (tile_index[1] += 1) {
            const tile_min = tile_index * RenderTileSize;
            const tile_max = (tile_index + @splat(2, @as(u32, 1))) * RenderTileSize;
            const tile_max_clamped = u32_2{
                std.math.min(tile_max[0], rt.frame_extent[0]),
                std.math.min(tile_max[1], rt.frame_extent[1]),
            };

            rt.work_queue[rt.work_queue_size] = WorkItem{
                .position_start = tile_min,
                .position_end = tile_max_clamped,
            };
            rt.work_queue_size += 1;
        }
    }
}

// Renders some of the internal workload items and returns if everything is finished
pub fn render_workload(rt: *RaytracerState, item_count: u32) bool {
    const count = std.math.min(item_count, rt.work_queue_size);
    const end = rt.work_queue_size;
    const start = end - count;

    for (rt.work_queue[start..end]) |work_item| {
        render_work_item(rt, work_item);
    }

    rt.work_queue_size = start;

    return rt.work_queue_size == 0;
}

const Material = struct {
    albedo: f32_3,
    metalness: f32,
    fake_texture: bool,
};

const Pi: f32 = 3.14159265;
const DegToRad: f32 = Pi / 180.0;
const RayHitThreshold: f32 = 0.001;

const Ray = struct {
    origin: f32_3,
    direction: f32_3, // Not normalized
};

const Sphere = struct {
    origin: f32_3,
    radius: f32,
    material: *const Material,
};

const Scene = struct {
    spheres: [8]*const Sphere,
};

// TODO annoying
fn u32_2_to_f32_2(v: u32_2) f32_2 {
    return .{
        @intToFloat(f32, v[0]),
        @intToFloat(f32, v[1]),
    };
}

fn dot(a: f32_3, b: f32_3) f32 {
    return @reduce(.Add, a * b);
}

fn cross(v1: f32_3, v2: f32_3) f32_3 {
    return .{
        v1[1] * v2[2] - v1[2] * v2[1],
        v1[2] * v2[0] - v1[0] * v2[2],
        v1[0] * v2[1] - v1[1] * v2[0],
    };
}

// normal should be normalized
fn reflect(v: f32_3, normal: f32_3) f32_3 {
    return v - normal * @splat(3, 2.0 * dot(v, normal));
}

fn mul(m: f32_3x3, v: f32_3) f32_3 {
    return f32_3{
        dot(.{ m[0][0], m[1][0], m[2][0] }, v),
        dot(.{ m[0][1], m[1][1], m[2][1] }, v),
        dot(.{ m[0][2], m[1][2], m[2][2] }, v),
    };
}

fn normalize(v: f32_3) f32_3 {
    const length = std.math.sqrt(dot(v, v));
    const lengthInv = 1.0 / length;

    return v * @splat(3, lengthInv);
}

fn sign(value: f32) f32 {
    return if (value >= 0.0) 1.0 else -1.0;
}

fn lookAt(viewPosition: f32_3, targetPosition: f32_3, upDirection: f32_3) f32_3x3 {
    const viewForward = -normalize(targetPosition - viewPosition);
    const viewRight = normalize(cross(upDirection, viewForward));
    const viewUp = cross(viewForward, viewRight);

    return .{
        viewRight,
        viewUp,
        viewForward,
    };
}

fn sampleDistribution(normal: f32_3, sample: f32_3) f32_3 {
    const sampleOriented = sample * @splat(3, sign(dot(normal, sample)));
    return sampleOriented;
}

fn render_work_item(rt: *RaytracerState, work_item: WorkItem) void {
    const fovDegrees: f32 = 100.0;
    const maxSteps: u32 = 2;

    const mat1Mirror = Material{ .albedo = .{ 0.2, 0.2, 0.2 }, .metalness = 1.0, .fake_texture = false };
    const mat2 = Material{ .albedo = .{ 0.2, 0.2, 0.2 }, .metalness = 0.2, .fake_texture = true };
    const mat3Diffuse = Material{ .albedo = .{ 0.2, 0.2, 0.2 }, .metalness = 0.4, .fake_texture = false };
    const mat4 = Material{ .albedo = .{ 10.0, 10.0, 4.0 }, .metalness = 0.0, .fake_texture = false };
    const mat5 = Material{ .albedo = .{ 10.0, 1.0, 1.0 }, .metalness = 0.0, .fake_texture = false };
    const mat6EmissiveGreen = Material{ .albedo = .{ 1.0, 14.0, 1.0 }, .metalness = 0.0, .fake_texture = false };

    const s1 = Sphere{ .origin = .{ 0.0, 0.0, 0.0 }, .radius = 1.0, .material = &mat1Mirror };
    const s2 = Sphere{ .origin = .{ 0.0, -301.0, 0.0 }, .radius = 300.0, .material = &mat2 };
    const s3 = Sphere{ .origin = .{ -2.0, 0.5, -2.0 }, .radius = 1.5, .material = &mat3Diffuse };
    const s4 = Sphere{ .origin = .{ 2.0, -0.1, 1.0 }, .radius = 0.9, .material = &mat3Diffuse };
    const s5 = Sphere{ .origin = .{ -4.0, 0.0, 0.0 }, .radius = 1.0, .material = &mat4 };
    const sphereEmissiveRed = Sphere{ .origin = .{ 4.0, -0.2, 1.0 }, .radius = 0.8, .material = &mat5 };
    const sphereEmissiveGreen = Sphere{ .origin = .{ -1.3, -0.5, 1.5 }, .radius = 0.5, .material = &mat6EmissiveGreen };
    const sphereMirror2 = Sphere{ .origin = .{ -3.0, 1.0, 4.0 }, .radius = 2.0, .material = &mat1Mirror };

    const spheres = [_]*const Sphere{ &s1, &s2, &s3, &s4, &s5, &sphereEmissiveRed, &sphereEmissiveGreen, &sphereMirror2 };
    const scene = Scene{ .spheres = spheres };

    const cameraPositionWS = f32_3{ 3.0, 3.0, 6.0 };
    const cameraTargetWS = f32_3{ 0.0, -1.0, 0.0 };
    const cameraUpVector = f32_3{ 0.0, 1.0, 0.0 };
    const camera_orientation_ws = lookAt(cameraPositionWS, cameraTargetWS, cameraUpVector);

    const aspectRatioInv = @intToFloat(f32, rt.frame_extent[1]) / @intToFloat(f32, rt.frame_extent[0]);
    const tanHFov: f32 = std.math.tan((fovDegrees * 0.5) * DegToRad);
    const viewportTransform = f32_2{ tanHFov, -tanHFov * aspectRatioInv };
    const imageSizeFloat = u32_2_to_f32_2(rt.frame_extent);

    // FOR TODO
    var pos_ts: u32_2 = .{ work_item.position_start[0], undefined };
    while (pos_ts[0] < work_item.position_end[0]) : (pos_ts[0] += 1) {
        pos_ts[1] = work_item.position_start[1];

        while (pos_ts[1] < work_item.position_end[1]) : (pos_ts[1] += 1) {
            const rayIndex = u32_2_to_f32_2(pos_ts) + @splat(2, @as(f32, 0.5));
            const ray_dir_vs = ((rayIndex - imageSizeFloat * @splat(2, @as(f32, 0.5))) / imageSizeFloat) * viewportTransform;

            const ray_origin_vs: f32_3 = @splat(3, @as(f32, 0.0));

            const ray_vs = Ray{
                .origin = ray_origin_vs,
                .direction = .{ ray_dir_vs[0], ray_dir_vs[1], -1.0 },
            };

            const ray_ws = Ray{
                .origin = ray_vs.origin + cameraPositionWS,
                .direction = mul(camera_orientation_ws, ray_vs.direction),
            };

            const color = shade(scene, &rt.rng, ray_ws, maxSteps);

            rt.framebuffer[pos_ts[0]][pos_ts[1]] += f32_4{ color[0], color[1], color[2], 1 };
        }
    }
}

const RayHit = struct {
    t: f32,
    mat: *const Material,
    position_ws: f32_3,
    normal_ws: f32_3,
};

fn shade(scene: Scene, rng: *std.rand.Xoroshiro128, ray: Ray, steps: u32) f32_3 {
    var hitResult: RayHit = undefined;

    if (traverse_scene(scene, ray, &hitResult)) {
        const mat = hitResult.mat;

        if (steps > 0) {
            if (mat.metalness == 1.0) {
                const reflectedRay = Ray{ .origin = hitResult.position_ws, .direction = reflect(ray.direction, hitResult.normal_ws) };
                return shade(scene, rng, reflectedRay, steps - 1);
            } else {
                var albedo = mat.albedo;
                if (mat.fake_texture) {
                    // Checkerboard formula
                    const size: f32 = 1.0;
                    const modx1: f32 = (std.math.mod(f32, std.math.absFloat(hitResult.position_ws[0]) + size * 0.5, size * 2.0) catch 0.0) - size;
                    const mody1: f32 = (std.math.mod(f32, std.math.absFloat(hitResult.position_ws[2]) + size * 0.5, size * 2.0) catch 0.0) - size;

                    if (modx1 * mody1 > 0.0)
                        albedo = f32_3{ 0.1, 0.1, 0.15 };
                }

                var i: u32 = 0;
                var accum: f32_3 = .{};
                while (i < diffuse_sample_count) : (i += 1) {
                    const random_f32_3 = f32_3{
                        rng.random().float(f32) * 2.0 - 1.0,
                        rng.random().float(f32) * 2.0 - 1.0,
                        rng.random().float(f32) * 2.0 - 1.0,
                    };
                    var randomSample = normalize(random_f32_3);
                    randomSample = sampleDistribution(hitResult.normal_ws, randomSample);
                    const reflectedRay = Ray{ .origin = hitResult.position_ws, .direction = randomSample };

                    accum += shade(scene, rng, reflectedRay, steps - 1);
                }

                // Shade result
                return albedo * accum / @splat(3, @intToFloat(f32, diffuse_sample_count));
            }
        } else return mat.albedo;
    }

    // No hit -> fake skybox
    const normalizedDirection = normalize(ray.direction);
    const t: f32 = 0.5 * (normalizedDirection[1] + 1.0);
    return f32_3{ 1.0, 1.0, 1.0 } * @splat(3, 1.0 - t) + f32_3{ 0.5, 0.7, 1.0 } * @splat(3, t);
}

fn traverse_scene(s: Scene, ray: Ray, hit: *RayHit) bool {
    var bestHit: f32 = 0.0;

    for (s.spheres) |sphere_ws| {
        const t = hit_sphere(sphere_ws.*, ray);

        if (isBetterHit(t, bestHit)) {
            bestHit = t;
            const ray_hit_ws = ray.origin + ray.direction * @splat(3, t);
            hit.normal_ws = (ray_hit_ws - sphere_ws.origin) / @splat(3, sphere_ws.radius);
            hit.position_ws = ray_hit_ws;
            hit.mat = sphere_ws.material;
        }
    }

    hit.t = bestHit;
    return bestHit > RayHitThreshold;
}

fn hit_sphere(sphere: Sphere, ray: Ray) f32 {
    const originToCenter = ray.origin - sphere.origin;
    const a = dot(ray.direction, ray.direction);
    const b = 2.0 * dot(originToCenter, ray.direction);
    const c = dot(originToCenter, originToCenter) - sphere.radius * sphere.radius;
    const discriminant = b * b - 4.0 * a * c;

    if (discriminant < 0.0) {
        return -1.0;
    } else {
        return ((-b - std.math.sqrt(discriminant)) * 0.5) / a;
    }
}
fn isBetterHit(value: f32, base: f32) bool {
    return value > RayHitThreshold and (!(base > RayHitThreshold) or value < base);
}
