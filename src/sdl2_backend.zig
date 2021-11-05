const std = @import("std");
const assert = std.debug.assert;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const raytracer = @import("raytracer.zig");

const PixelFormatBGRASizeInBytes: u32 = 4;
const ImageCpuBitDepth: u32 = 32;

fn fill_image_buffer(imageOutput: []u8, rt: *raytracer.RaytracerState) void {
    var j: u32 = 0;
    while (j < rt.frame_extent[1]) : (j += 1) {
        var i: u32 = 0;
        while (i < rt.frame_extent[0]) : (i += 1) {
            const pixelIndexFlatDst = j * rt.frame_extent[0] + i;
            const pixelOutputOffsetInBytes = pixelIndexFlatDst * PixelFormatBGRASizeInBytes;
            const scene_pixel = rt.framebuffer[i][j];
            const sample_count = std.math.max(1.0, scene_pixel[3]);
            const swapchain_pixel = raytracer.f32_3{ scene_pixel[0], scene_pixel[1], scene_pixel[2] } / @splat(3, sample_count);

            const primaryColorBGRA = [4]u8{
                @floatToInt(u8, std.math.min(1.0, swapchain_pixel[0]) * 255.0),
                @floatToInt(u8, std.math.min(1.0, swapchain_pixel[1]) * 255.0),
                @floatToInt(u8, std.math.min(1.0, swapchain_pixel[2]) * 255.0),
                255,
            };
            imageOutput[pixelOutputOffsetInBytes + 0] = primaryColorBGRA[0];
            imageOutput[pixelOutputOffsetInBytes + 1] = primaryColorBGRA[1];
            imageOutput[pixelOutputOffsetInBytes + 2] = primaryColorBGRA[2];
            imageOutput[pixelOutputOffsetInBytes + 3] = primaryColorBGRA[3];
        }
    }
}

pub fn execute_main_loop(allocator: *std.mem.Allocator, rt: *raytracer.RaytracerState) !void {
    const width = rt.frame_extent[0];
    const height = rt.frame_extent[1];
    const stride = width * PixelFormatBGRASizeInBytes; // No extra space between lines
    const image_size_bytes = stride * height;

    var image_cpu = try allocator.alloc(u8, image_size_bytes);
    defer allocator.free(image_cpu);

    if (c.SDL_Init(c.SDL_INIT_EVERYTHING) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, @intCast(c_int, width), @intCast(c_int, height), c.SDL_WINDOW_SHOWN) orelse {
        c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    if (c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1") == c.SDL_bool.SDL_FALSE) {
        c.SDL_Log("Unable to set hint: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const is_big_endian = c.SDL_BYTEORDER == c.SDL_BIG_ENDIAN;
    var rmask: u32 = if (is_big_endian) 0xff000000 else 0x000000ff;
    var gmask: u32 = if (is_big_endian) 0x00ff0000 else 0x0000ff00;
    var bmask: u32 = if (is_big_endian) 0x0000ff00 else 0x00ff0000;
    var amask: u32 = if (is_big_endian) 0x000000ff else 0xff000000;
    var pitch: u32 = stride;

    const render_surface = c.SDL_CreateRGBSurfaceFrom(@ptrCast(*c_void, &image_cpu[0]), @intCast(c_int, width), @intCast(c_int, height), @intCast(c_int, ImageCpuBitDepth), @intCast(c_int, pitch), rmask, gmask, bmask, amask) orelse {
        c.SDL_Log("Unable to create surface: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_FreeSurface(render_surface);

    var shouldExit = false;
    var last_frame_time_ms: u32 = c.SDL_GetTicks();

    while (!shouldExit) {
        const current_frame_time_ms: u32 = c.SDL_GetTicks();
        const frame_delta_secs = @intToFloat(f32, current_frame_time_ms - last_frame_time_ms) * 0.001;

        // Poll events
        var sdlEvent: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&sdlEvent) > 0) {
            switch (@intToEnum(c.SDL_EventType, @intCast(c_int, sdlEvent.type))) {
                .SDL_QUIT => {
                    shouldExit = true;
                },
                .SDL_KEYDOWN => {
                    if (sdlEvent.key.keysym.sym == c.SDLK_ESCAPE)
                        shouldExit = true;
                },
                else => {},
            }
        }

        const work_finished = raytracer.render_workload(rt, 4);

        if (work_finished) {
            raytracer.add_fullscreen_workload(rt);
        }

        // Set window title
        const string = try std.fmt.allocPrintZ(allocator, "Raytracer {d}x{d} w:{d}", .{ rt.frame_extent[0], rt.frame_extent[1], rt.work_queue_size });
        defer allocator.free(string);

        c.SDL_SetWindowTitle(window, string.ptr);

        // Render
        fill_image_buffer(image_cpu, rt);

        const render_texture = c.SDL_CreateTextureFromSurface(renderer, render_surface) orelse {
            c.SDL_Log("Unable to create texture from surface: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };
        defer c.SDL_DestroyTexture(render_texture);

        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, render_texture, null, null);

        // Present
        c.SDL_RenderPresent(renderer);

        last_frame_time_ms = current_frame_time_ms;
    }
}
