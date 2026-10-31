//! The GPU device and the window's swapchain, through SDL_GPU. Each frame runs in this order:
//! `beginFrame`, uploads, render passes (renderer/renderer.zig), then `endFrame`.

const std = @import("std");
const embedded = @import("embedded_shaders");
const c = @import("sdl.zig").c;
const profile = @import("../../profiling/profile.zig");
const types = @import("../types.zig");
const window_backend = @import("window.zig");

/// A frame in progress: the command buffer and the swapchain texture it draws to.
pub const Frame = struct {
    cmd: *c.SDL_GPUCommandBuffer,
    swapchain: *c.SDL_GPUTexture,
    /// Swapchain size in pixels. This can differ from the window size on high-DPI displays.
    width: u32,
    height: u32,
};

/// Owns the GPU device and the window's swapchain. Each frame runs in this order:
/// beginFrame, uploads, beginPass, draws, endPass, then endFrame.
pub const Gpu = struct {
    /// The SDL window this device is claimed for. It stays inside the backend.
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,

    /// Creates the GPU device and claims the window for it.
    /// `window` must outlive the returned Gpu.
    pub fn init(window: *types.Window, gpu_debug: bool) Gpu {
        const sdl_window = window_backend.toSdl(window);
        // Request Vulkan 1.2 so the device accepts SPIR-V 1.5, which Slang emits by default.
        // Version 1.2.0 is (1 << 22) | (2 << 12); Zig can't translate VK_MAKE_API_VERSION.
        var vk_opts = std.mem.zeroes(c.SDL_GPUVulkanOptions);
        vk_opts.vulkan_api_version = (1 << 22) | (2 << 12);

        const props = c.SDL_CreateProperties();
        if (props == 0) {
            std.debug.panic("SDL_CreateProperties failed: {s}", .{c.SDL_GetError()});
        }
        defer c.SDL_DestroyProperties(props);

        _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
        // Ask for DXIL only when this build embeds it (-Ddxil=true). Without it the device would
        // accept a format the game has no code for.
        if (embedded.default_vert_dxil.len != 0) {
            _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXIL_BOOLEAN, true);
        }
        // Ask for MSL only when this build embeds it (-Dmetal=true), so SDL won't select a format
        // the executable cannot provide.
        if (embedded.default_vert_msl.len != 0) {
            _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true);
        }
        _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, gpu_debug);
        _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_VULKAN_OPTIONS_POINTER, &vk_opts);

        const device = c.SDL_CreateGPUDeviceWithProperties(props) orelse {
            std.debug.panic("SDL_CreateGPUDeviceWithProperties failed: {s}", .{c.SDL_GetError()});
        };

        if (!c.SDL_ClaimWindowForGPUDevice(device, sdl_window)) {
            std.debug.panic("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        }

        return .{ .window = sdl_window, .device = device };
    }

    /// The format the window's swapchain uses. Textures and pipelines that draw
    /// to the window or are copied into it must use this format.
    pub fn swapchainFormat(self: *const Gpu) c.SDL_GPUTextureFormat {
        return c.SDL_GetGPUSwapchainTextureFormat(self.device, self.window);
    }

    /// Sets vsync. On is the default, so it changes nothing. Off presents frames as soon as they are
    /// ready, which can tear. Returns false when the window can't present without vsync, and vsync stays on.
    pub fn setVsync(self: *Gpu, vsync: bool) bool {
        if (vsync) return true;
        if (!c.SDL_WindowSupportsGPUPresentMode(self.device, self.window, c.SDL_GPU_PRESENTMODE_IMMEDIATE)) return false;
        return c.SDL_SetGPUSwapchainParameters(self.device, self.window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_IMMEDIATE);
    }

    /// Acquires a command buffer and the swapchain texture.
    /// Returns null when the frame should be skipped, such as while the window is minimized.
    pub fn beginFrame(self: *Gpu) ?Frame {
        const zone = profile.zoneNamed(@src(), "acquire frame");
        defer zone.End();
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return null;

        var swapchain: ?*c.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        const acquired = c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain, &w, &h);
        if (!acquired or swapchain == null) {
            // Submit the empty command buffer so SDL can release it.
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return null;
        }
        return .{ .cmd = cmd, .swapchain = swapchain.?, .width = w, .height = h };
    }

    /// Submits the frame's commands to the GPU.
    pub fn endFrame(frame: Frame) void {
        const zone = profile.zoneNamed(@src(), "submit frame");
        defer zone.End();
        _ = c.SDL_SubmitGPUCommandBuffer(frame.cmd);
    }

    /// Releases the device. Destroy anything created from it first.
    pub fn deinit(self: *Gpu) void {
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }
};
