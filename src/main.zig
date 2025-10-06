const std = @import("std");

const INT_MAX: i32 = @bitCast(@as(i32, std.math.maxInt(i32)));
const TARGET_FPS: f64 = 60.0;
const TIME_PER_FRAME: f64 = 1.0 / TARGET_FPS;

// TODO: interface.
// Wayland protocol constants
const display_id = 1;
const WL_DISPLAY_GET_REGISTRY = 1;
const WL_DISPLAY_SYNC = 0;
const WL_DISPLAY_ERROR = 0;
const WL_DISPLAY_DELETE_ID = 1;

const WL_CALLBACK_EVENT_DONE = 0;

const WL_REGISTRY_EVENT_GLOBAL = 0;
const WL_REGISTRY_REQUEST_BIND = 0;

const WL_COMPOSITOR_VERSION = 5;
const WL_COMPOSITOR_REQUEST_CREATE_SURFACE = 0;

const WL_SEAT_VERSION = 9;
const WL_SEAT_EVENT_CAPABILITIES = 0;
const WL_SEAT_CAPABILITY_POINTER = 1;
const WL_SEAT_CAPABILITY_KEYBOARD = 2;
const WL_SEAT_CAPABILITY_TOUCH = 4;

const WL_SEAT_REQUEST_GET_POINTER = 0;
const WL_SEAT_REQUEST_GET_KEYBOARD = 1;

const wl_pointer_enter = 0;
const wl_pointer_leave = 1;
const wl_pointer_motion = 2;
const wl_pointer_button = 3;

const wl_keyboard_enter = 1;
const wl_keyboard_leave = 2;
const wl_keyboard_key = 3;
const wl_keyboard_modifiers = 4;
const wl_keyboard_repeat = 5;

const WL_SURFACE_REQUEST_ATTACH = 1;
const WL_SURFACE_REQUEST_DAMAGE = 2;
const WL_SURFACE_REQUEST_FRAMES = 3;
const WL_SURFACE_REQUEST_COMMIT = 6;

const xdg_configure = 0;
const XDG_WM_BASE_VERSION = 2;
const xdg_toplevel_configure = 0;
const xdg_close = 1;
const xdg_toplevel_configure_bounds = 2;
const xdg_toplevel_wm_capabilities = 3;
const XDG_SURFACE_REQUEST_GET_TOPLEVEL = 1;
const XDG_WM_BASE_REQUEST_GET_XDG_SURFACE = 2;
const XDG_SURFACE_REQUEST_ACK_CONFIGURE = 4;

const WL_SHM_VERSION = 1;
const WL_SHM_EVENT_FORMAT = 0;
const WL_SHM_REQUEST_CREATE_POOL = 0;
const WL_SHM_POOL_ENUM_FORMAT_ARGB8888 = 0;
const WL_SHM_POOL_REQUEST_CREATE_BUFFER = 0;

const Vec2 = @Vector(2, f32);
const Vec3 = @Vector(3, f32);

const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn lerp(self: @This(), other: Color, t: f32) Color {
        const t_clamped = @max(0.0, @min(1.0, t));
        return Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * (1.0 - t_clamped) + @as(f32, @floatFromInt(other.r)) * t_clamped),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * (1.0 - t_clamped) + @as(f32, @floatFromInt(other.g)) * t_clamped),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * (1.0 - t_clamped) + @as(f32, @floatFromInt(other.b)) * t_clamped),
        };
    }
};

const Scene = struct {
    static: Circle,
    movable: Circle,
};

const Circle = struct {
    radius: f32,
    center: Vec2,
    color: Color,

    pub fn isInside(self: @This(), point: Vec2) bool {
        const d2 = std.math.pow(f32, (point[0] - self.center[0]), 2) + std.math.pow(f32, (point[1] - self.center[1]), 2);
        const r2 = std.math.pow(f32, self.radius, 2);
        return d2 <= r2;
    }

    pub fn move(self: *@This(), point: Vec2) void {
        self.center = point;
    }

    pub fn update(self: *@This(), c: Color) void {
        self.color = c;
    }
};

fn createSocket(allocator: std.mem.Allocator) !std.net.Stream {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    const s_dir = try std.fs.path.joinZ(allocator, &.{
        xdg_runtime_dir,
        wayland_display,
    });
    defer allocator.free(s_dir);

    const socket = std.net.connectUnixSocket(s_dir);
    return socket;
}

pub fn writeRequest(socket: std.net.Stream, id: u32, op: u16, message: []const u32) !void {
    const msg_bytes = std.mem.sliceAsBytes(message);
    const header = Header{
        .id = id,
        .op = op,
        .size = @sizeOf(Header) + @as(u16, @intCast(msg_bytes.len)),
    };

    // std.log.debug("Writing request: id={any}, op={any}, size={any}\nmsg={any}\n", .{ header.id, header.op, header.size, message });
    socket.writeAll(std.mem.asBytes(&header)) catch |err| {
        switch (err) {
            error.BrokenPipe => {
                std.log.debug("Compositor closed connection (BrokenPipe) - likely protocol error\n", .{});
                return err;
            },
            else => return err,
        }
    };

    socket.writeAll(msg_bytes) catch |err| {
        switch (err) {
            error.BrokenPipe => {
                std.log.debug("Compositor closed connection (BrokenPipe) during message body\n", .{});
                return err;
            },
            else => return err,
        }
    };
}

const Header = extern struct {
    id: u32,
    op: u16,
    size: u16,

    pub fn read(socket: std.net.Stream) !Header {
        var header: Header = undefined;
        const read_bytes = try readAll(socket, std.mem.asBytes(&header));
        if (read_bytes < @sizeOf(Header)) return error.HeaderTooSmall;
        return header;
    }
};

const Event = struct {
    header: Header,
    data: []const u8,

    pub fn read(socket: std.net.Stream, buf: []u8) !Event {
        const header = try Header.read(socket);
        const msg_len = header.size - @sizeOf(Header);
        if (msg_len > buf.len) {
            std.log.debug("message len {any}, buffer len {any}, msg too large.", .{ msg_len, buf.len });
            return error.MessageTooLarge;
        }

        const msg_data = buf[0..msg_len];
        const read_bytes = try readAll(socket, msg_data);
        if (read_bytes < msg_len) return error.UnexpectedEOF;
        return Event{
            .header = header,
            .data = msg_data,
        };
    }
};

fn readAll(socket: std.net.Stream, buf: []u8) !usize {
    var read_bytes: usize = 0;
    while (read_bytes < buf.len) {
        const cur = try socket.read(buf[read_bytes..]);
        if (cur == 0) break;
        read_bytes += cur;
    }
    return read_bytes;
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    const socket = try createSocket(gpa);
    defer socket.close();

    var next: u32 = 2;
    const registry_id: u32 = next;
    next += 1;

    try writeRequest(
        socket,
        display_id,
        WL_DISPLAY_GET_REGISTRY,
        &[_]u32{registry_id},
    );

    const registry_callback_id: u32 = next;
    next += 1;
    try writeRequest(
        socket,
        display_id,
        WL_DISPLAY_SYNC,
        &[_]u32{registry_callback_id},
    );

    var message: [4096]u8 align(8) = [_]u8{0} ** 4096;
    // var message = std.ArrayList(u8).init(gpa);
    // defer message.deinit();

    // we need to bind these ->
    var wl_shm: ?struct { name: u32, id: u32, version: u32 } = null;
    var wl_seat: ?struct { name: u32, id: u32, version: u32 } = null;
    var wl_compositor: ?struct { name: u32, id: u32, version: u32 } = null;
    var xdg_wm_base: ?struct { name: u32, id: u32, version: u32 } = null;

    while (true) {
        const event = try Event.read(socket, &message);
        // std.log.debug("Event:\tid:{any}\top:{any}\n", .{ event.header.id, event.header.op });

        if (event.header.id == registry_callback_id) {
            break;
        }

        if (event.header.id == registry_id and event.header.op == WL_REGISTRY_EVENT_GLOBAL) {
            // TODO: its per interface, need to abstract from XML later.
            // why not use std.mem.readInt here? is the performance that critical?
            const name: u32 = @bitCast(event.data[0..4].*);
            const interface_len: u32 = @bitCast(event.data[4..8].*);
            // this is raw bytes from c, includes a sentinel|terminator
            const interface: [:0]const u8 = event.data[8..][0 .. interface_len - 1 :0];
            const interface_padding = (interface_len + 3) & ~@as(u32, 3);
            const version: u32 = @bitCast(event.data[8 + interface_padding ..][0..4].*);

            std.log.debug("Name: {s}\tId: {any} | V: {any}\n", .{ interface, name, version });

            if (std.mem.eql(u8, interface, "wl_shm")) {
                if (version < WL_SHM_VERSION) {
                    debugPrintVarName("Older version detected, needs update.\n", .{ version, WL_SHM_VERSION });
                    break;
                }
                wl_shm = .{
                    .id = 0,
                    .name = name,
                    .version = @min(version, WL_SHM_VERSION),
                };
            } else if (std.mem.eql(u8, interface, "wl_compositor")) {
                if (version < WL_COMPOSITOR_VERSION) {
                    debugPrintVarName("Older version detected, needs update.\n", .{WL_COMPOSITOR_VERSION});
                    break;
                }
                wl_compositor = .{
                    .id = 0,
                    .name = name,
                    .version = @min(version, WL_COMPOSITOR_VERSION),
                };
            } else if (std.mem.eql(u8, interface, "wl_seat")) {
                if (version < WL_SEAT_VERSION) {
                    debugPrintVarName("Older version detected, needs update.\n", .{WL_SEAT_VERSION});
                    break;
                }
                wl_seat = .{
                    .id = 0,
                    .name = name,
                    .version = @min(version, WL_SEAT_VERSION),
                };
            } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
                if (version < XDG_WM_BASE_VERSION) {
                    debugPrintVarName("Older version detected, needs update.\n", .{XDG_WM_BASE_VERSION});
                    break;
                }
                xdg_wm_base = .{
                    .id = 0,
                    .name = name,
                    .version = @min(version, XDG_WM_BASE_VERSION),
                };
            }
            continue;
        }
    }

    if (wl_compositor) |it| {
        wl_compositor.?.id = next;
        std.log.debug("wl_compositor: id - {any} | v - {any}\n", .{ wl_compositor.?.id, wl_compositor.?.version });
        try bindInterface(
            gpa,
            socket,
            registry_id,
            it.name,
            "wl_compositor",
            it.version,
            next,
        );
        next += 1;
    }
    if (wl_seat) |it| {
        wl_seat.?.id = next;
        std.log.debug("wl_seat: id - {any} | v - {any}\n", .{ wl_seat.?.id, wl_seat.?.version });
        try bindInterface(
            gpa,
            socket,
            registry_id,
            it.name,
            "wl_seat",
            it.version,
            next,
        );
        next += 1;
    }
    if (wl_shm) |it| {
        wl_shm.?.id = next;
        std.log.debug("wl_shm: id - {any} | v - {any}\n", .{ wl_shm.?.id, wl_shm.?.version });
        try bindInterface(
            gpa,
            socket,
            registry_id,
            it.name,
            "wl_shm",
            it.version,
            next,
        );
        next += 1;
    }
    if (xdg_wm_base) |it| {
        xdg_wm_base.?.id = next;
        std.log.debug("xdg_wm_base: id - {any} | v - {any}\n", .{ xdg_wm_base.?.id, xdg_wm_base.?.version });
        try bindInterface(
            gpa,
            socket,
            registry_id,
            it.name,
            "xdg_wm_base",
            it.version,
            next,
        );
        next += 1;
    }

    // trying new bind for keyboard input
    std.log.debug("wl_seat: {any}\n", .{wl_seat.?.id});
    std.log.debug("wl_shm: {any}\n", .{wl_shm.?.id});
    std.log.debug("wl_compositor: {any}\n", .{wl_compositor.?.id});
    std.log.debug("xdg_wm_base: {any}\n", .{xdg_wm_base.?.id});
    std.log.debug("\n", .{});

    // DONE WITH BINDS

    // create wl_surface (wl_compositor::create_surface).
    // set the surface to xdg_surface (xdg_wm_base::get_xdg_surface).
    // define xdg top level (xdg_surface::get_toplevel)
    // commit the surface using wl_commit
    // wait xdg_surface::configure event, and respond to it.
    // to answer a xdg configure, we do xdg_surface::ack_configure
    // then commit to wl_surface again.

    const surface_id = next;
    next += 1;
    const xdg_surface_id = next;
    next += 1;
    const xdg_toplevel_id = next;
    next += 1;

    try writeRequest(
        socket,
        wl_compositor.?.id,
        WL_COMPOSITOR_REQUEST_CREATE_SURFACE,
        &[_]u32{surface_id},
    );

    try writeRequest(
        socket,
        xdg_wm_base.?.id,
        XDG_WM_BASE_REQUEST_GET_XDG_SURFACE,
        &[_]u32{
            xdg_surface_id,
            surface_id,
        },
    );
    try writeRequest(
        socket,
        xdg_surface_id,
        XDG_SURFACE_REQUEST_GET_TOPLEVEL,
        &[_]u32{xdg_toplevel_id},
    );

    try writeRequest(
        socket,
        surface_id,
        WL_SURFACE_REQUEST_COMMIT,
        &[_]u32{},
    );

    const wl_pointer = next;
    next += 1;
    const wl_keyboard = next;
    next += 1;
    // const wl_touch = next;
    // next += 1;

    while (true) {
        const event = try Event.read(socket, &message);
        if (xdg_surface_id == event.header.id) {
            std.log.debug("Event:\tid:{any}\top:{any}\n", .{ event.header.id, event.header.op });
            switch (event.header.op) {
                xdg_configure => {
                    const serial_id: u32 = @bitCast(event.data[0..4].*);
                    try writeRequest(
                        socket,
                        xdg_surface_id,
                        XDG_SURFACE_REQUEST_ACK_CONFIGURE,
                        &[_]u32{serial_id},
                    );
                    try writeRequest(
                        socket,
                        surface_id,
                        WL_SURFACE_REQUEST_COMMIT,
                        &[_]u32{},
                    );
                    break;
                },
                else => {
                    std.log.debug("NOT TRACKED\nEvent:\tid:{any}\top:{any}\n", .{ event.header.id, event.header.op });
                },
            }
        } else if (wl_seat.?.id == event.header.id) {
            if (event.header.op == WL_SEAT_EVENT_CAPABILITIES) {
                const capabilities: u32 = @bitCast(event.data[0..4].*);
                std.log.debug("Seat capabilities: 0x{x}\n", .{capabilities});
                try writeRequest(
                    socket,
                    wl_seat.?.id,
                    WL_SEAT_REQUEST_GET_POINTER,
                    &[_]u32{wl_pointer},
                );
                try writeRequest(
                    socket,
                    wl_seat.?.id,
                    WL_SEAT_REQUEST_GET_KEYBOARD,
                    &[_]u32{wl_keyboard},
                );
            }
        }
    }

    std.log.debug("\n\nstart: framebuffer\n", .{});
    // Pixel argb for 256x256 window size.
    const Pixel = [4]u8;

    // create shared memory file.
    // allocate proper space.
    // create shared memory pool
    // allocate proper wl_buffer  (wl_shm_pool::create_buffer)

    const framebuffer_size = [2]usize{ 512, 512 };

    const shm_fd = try std.posix.memfd_create("zigland_framebuffer", 0);
    defer std.posix.close(shm_fd);

    const shm_fd_len = framebuffer_size[0] * framebuffer_size[1] * @sizeOf(Pixel);
    try std.posix.ftruncate(shm_fd, shm_fd_len);

    const wl_shm_pool_id = try writeWlShmRequestCreatePool(
        socket,
        wl_shm.?.id,
        &next,
        shm_fd,
        @intCast(shm_fd_len),
    );

    // wl_shm_pool::create_buffer(
    // id: new_id<wl_buffer>,
    //  offset: int,
    //  width: int,
    //  height: int,
    //  stride: int,
    //  format: uint<wl_shm.format>
    // )

    std.log.debug("shm_pool created\n", .{});

    const framebuffer_id = next;
    next += 1;
    try writeRequest(
        socket,
        wl_shm_pool_id,
        WL_SHM_POOL_REQUEST_CREATE_BUFFER,
        &[_]u32{
            framebuffer_id,
            0, // Byte offset of the framebuffer in the pool, allocated at the start.
            framebuffer_size[0], // width
            framebuffer_size[1], // height
            framebuffer_size[0] * @sizeOf(Pixel), // stride (bytes in a single row)
            WL_SHM_POOL_ENUM_FORMAT_ARGB8888, // framebuffer format
        },
    );

    std.log.debug("creating a slice\n", .{});
    const shm_pool_bytes = try std.posix.mmap(
        null,
        shm_fd_len,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        shm_fd,
        0,
    );
    const framebuffer = @as([*]Pixel, @ptrCast(shm_pool_bytes.ptr))[0 .. shm_pool_bytes.len / @sizeOf(Pixel)];

    var scene = Scene{
        .static = Circle{
            .radius = 260,
            .center = .{ 320, 320 },
            .color = .{ .r = 0xFF, .g = 0x60, .b = 0x7F },
        },

        .movable = Circle{
            .radius = 260,
            .center = .{ 0, 0 },
            .color = .{ .r = 0x00, .g = 0xFF, .b = 0x00 },
        },
    };

    // drawScene(scene, framebuffer, framebuffer_size, 0);

    // Attach Surface -> mark as Damaged Surface -> Commit Surface -> event loop
    // id, x, y => offset for buffer
    std.log.debug("Attach\n", .{});
    try writeRequest(
        socket,
        surface_id,
        WL_SURFACE_REQUEST_ATTACH,
        &[_]u32{
            framebuffer_id,
            0,
            0,
        },
    );

    // x, y, width, height => damaged
    std.log.debug("Damage\n", .{});
    try writeRequest(
        socket,
        surface_id,
        WL_SURFACE_REQUEST_DAMAGE,
        &[_]u32{
            0,
            0,
            INT_MAX,
            INT_MAX,
        },
    );

    // reserve frame?
    var frame_callback_id = next;
    next += 1;
    try writeRequest(socket, surface_id, WL_SURFACE_REQUEST_FRAMES, &[_]u32{frame_callback_id});
    std.log.debug("Commit\n", .{});
    try writeRequest(
        socket,
        surface_id,
        WL_SURFACE_REQUEST_COMMIT,
        &[_]u32{},
    );

    std.log.debug("Event Loop start.\n", .{});
    var window_open: bool = true;

    // trying to time movement
    var timer = try std.time.Timer.start();
    // var last_time: u64 = 0;

    const framerate: u32 = 60;
    const duration_seconds: f32 = 6.283;
    var total_frames: u32 = @intFromFloat(duration_seconds * @as(f32, @floatFromInt(framerate)));

    // const time_step: f32 = 1.0 / @as(f32, @floatFromInt(framerate));

    var stdout_buffer: [framebuffer_size[0] * framebuffer_size[1]]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    while (window_open) {
        // const current_time = timer.read();
        // const delta_nanos = current_time - last_time;
        // last_time = current_time;
        // const delta_time = @as(f64, @floatFromInt(delta_nanos)) / 1_000_000_000.0;
        // _ = delta_time;

        const event = try Event.read(socket, &message);
        if (xdg_surface_id == event.header.id) {
            std.log.debug("Event:\tid:{any}\top:{any}\n", .{ event.header.id, event.header.op });
            switch (event.header.op) {
                xdg_configure => {
                    const serial_id: u32 = @bitCast(event.data[0..4].*);
                    try writeRequest(
                        socket,
                        xdg_surface_id,
                        XDG_SURFACE_REQUEST_ACK_CONFIGURE,
                        &[_]u32{serial_id},
                    );
                    try writeRequest(
                        socket,
                        surface_id,
                        WL_SURFACE_REQUEST_COMMIT,
                        &[_]u32{},
                    );
                },
                else => {
                    std.log.debug("NOT TRACKED\nEvent:\tid:{any}\top:{any}\n", .{ event.header.id, event.header.op });
                },
            }
        } else if (xdg_toplevel_id == event.header.id) {
            switch (event.header.op) {
                xdg_toplevel_configure => {
                    // this should be  "RESIZE"
                    // TODO eventually.
                    const width: u32 = @bitCast(event.data[0..4].*);
                    const height: u32 = @bitCast(event.data[4..8].*);
                    const states_len: u32 = @bitCast(event.data[8..12].*);

                    // this needs specific alignment to work.
                    const states = @as([*]const u32, @ptrCast(@alignCast(event.data[12..].ptr)))[0..states_len];

                    std.log.debug("xdg_toplevel:configure({any}, {any}, {any})", .{ width, height, states });
                },
                xdg_close => {
                    window_open = false;
                    std.log.debug("xdg_toplevel:close()", .{});
                },
                xdg_toplevel_configure_bounds => std.log.debug("xdg_toplevel:configure_bounds()", .{}),
                xdg_toplevel_wm_capabilities => std.log.debug("xdg_toplevel:wm_capabilities()", .{}),
                else => return error.InvalidOpcode,
            }
        } else if (event.header.id == framebuffer_id) {
            switch (event.header.op) {
                // https://wayland.app/protocols/wayland#wl_buffer:event:release
                0 => {
                    // The xdg_toplevel:release event let's us know that it is safe to reuse the buffer now.
                    std.log.debug("wl_buffer:release()", .{});
                },
                else => return error.InvalidOpcode,
            }
        } else if (event.header.id == display_id) {
            switch (event.header.op) {
                // https://wayland.app/protocols/wayland#wl_display:event:error
                0 => {
                    const id: u32 = @bitCast(event.data[0..4].*);
                    const error_code: u32 = @bitCast(event.data[4..8].*);
                    const error_message_len: u32 = @bitCast(event.data[8..12].*);
                    const error_message = event.data[12 .. error_message_len - 1 :0];
                    std.log.warn("wl_display:error({any}, {any}, \"{any}\")", .{ id, error_code, std.zig.fmtString(error_message) });
                },
                // https://wayland.app/protocols/wayland#wl_display:event:delete_id
                1 => {
                    // wl_display:delete_id tells us that we can reuse an id. In this article we log it, but
                    // otherwise ignore it.
                    const name: u32 = @bitCast(event.data[0..4].*);
                    std.log.debug("wl_display:delete_id({any})", .{name});
                    next = name;
                },
                else => return error.InvalidOpcode,
            }
        } else if (event.header.id == wl_pointer) {
            switch (event.header.op) {
                wl_pointer_enter => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const surface: u32 = @bitCast(event.data[4..8].*);
                    const x: f32 = @bitCast(event.data[8..12].*);
                    const y: f32 = @bitCast(event.data[12..16].*);
                    std.log.debug("Mouse Enter: .serial = {any} .surface = {any} .x = {any} .y = {any}\n", .{ serial, surface, x, y });
                },
                wl_pointer_leave => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const surface: u32 = @bitCast(event.data[4..8].*);
                    std.log.debug("Mouse Leave: .serial {any} .surface = {any}\n", .{ serial, surface });
                },
                wl_pointer_motion => {
                    const time: u32 = @bitCast(event.data[0..4].*);
                    const x: u32 = @bitCast(event.data[4..8].*);
                    const y: u32 = @bitCast(event.data[8..12].*);
                    std.log.debug("Mouse Move: .time = {any} .x = {any} .y = {any}\n", .{ time, x >> 8, y >> 8 });

                    const point = Vec2{ @floatFromInt(x >> 8), @floatFromInt(y >> 8) };
                    scene.movable.move(point);

                    // if (scene.static.isInside(point)) {
                    //     scene.static.update(Color{ .b = 0x00, .g = 0xFF, .r = 0xFF });
                    // } else {
                    //     scene.static.update(Color{ .b = 0xFF, .g = 0x00, .r = 0x00 });
                    // }
                },
                wl_pointer_button => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const time: u32 = @bitCast(event.data[4..8].*);
                    const button: u32 = @bitCast(event.data[8..12].*);
                    const state: u32 = @bitCast(event.data[12..16].*);
                    std.log.debug("Mouse Enter: .serial = {any} .time = {any} .button = {any} .state = {any}\n", .{ serial, time, button, state });
                },
                else => {
                    std.log.debug("Mouse event not tracked {{ .id = {any}, .op = {x}, .message = \"{any}\" }}", .{ event.header.id, event.header.op, std.zig.fmtString(std.mem.sliceAsBytes(event.data)) });
                },
            }
        } else if (event.header.id == wl_keyboard) {
            switch (event.header.op) {
                wl_keyboard_enter => {
                    // const key_array:
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const surface: u32 = @bitCast(event.data[4..8].*);
                    std.log.debug("Keyboard Enter: .serial {any} .surface {any}\n", .{ serial, surface });
                },
                wl_keyboard_leave => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const surface: u32 = @bitCast(event.data[4..8].*);
                    std.log.debug("Keyboard Leave: .serial {any} .surface {any}\n", .{ serial, surface });
                },
                wl_keyboard_key => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const time: u32 = @bitCast(event.data[4..8].*);
                    const key: u32 = @bitCast(event.data[8..12].*);
                    const state: u32 = @bitCast(event.data[12..16].*);

                    _ = serial;
                    _ = time;
                    std.log.debug("Key key{any} state{any}\n", .{ key, state });
                },
                wl_keyboard_modifiers => {
                    const serial: u32 = @bitCast(event.data[0..4].*);
                    const mods_depressed: u32 = @bitCast(event.data[4..8].*);
                    const mods_latched: u32 = @bitCast(event.data[8..12].*);
                    const mods_locked: u32 = @bitCast(event.data[12..16].*);
                    const groups: u32 = @bitCast(event.data[16..20].*);

                    _ = serial;
                    std.log.debug("Modifier: {any} {any} {any} {any}\n", .{ mods_depressed, mods_latched, mods_locked, groups });
                    // TODO: get user inputs
                },
                else => {
                    std.log.warn("Keyboard event not tracked {{ .id = {any}, .op = {x}, .message = \"{any}\" }}", .{ event.header.id, event.header.op, std.zig.fmtString(std.mem.sliceAsBytes(event.data)) });
                },
            }
        } else if (frame_callback_id == event.header.id and event.header.op == WL_CALLBACK_EVENT_DONE) {
            if (total_frames > 0) {
                // TODO: abstract away platform layers?
                const elapsed_seconds = @as(f32, @floatFromInt(timer.read())) / 1_000_000_000.0;
                drawScene(
                    scene,
                    framebuffer,
                    framebuffer_size,
                    elapsed_seconds,
                );
                try stdout.writeAll(std.mem.sliceAsBytes(framebuffer));
                total_frames -= 1;
            } else {
                window_open = false;
            }
            // Attach
            try writeRequest(
                socket,
                surface_id,
                WL_SURFACE_REQUEST_ATTACH,
                &[_]u32{ framebuffer_id, 0, 0 },
            );
            // Damage
            try writeRequest(
                socket,
                surface_id,
                WL_SURFACE_REQUEST_DAMAGE,
                &[_]u32{ 0, 0, INT_MAX, INT_MAX },
            );
            // Frame Callback
            frame_callback_id = next;
            next += 1;
            try writeRequest(
                socket,
                surface_id,
                WL_SURFACE_REQUEST_FRAMES,
                &[_]u32{frame_callback_id},
            );

            // Commit
            try writeRequest(
                socket,
                surface_id,
                WL_SURFACE_REQUEST_COMMIT,
                &[_]u32{},
            );
        } else {
            std.log.warn("unknown event {{ .id = {any}, .op = {x}, .message = \"{any}\" }}", .{ event.header.id, event.header.op, std.zig.fmtString(std.mem.sliceAsBytes(event.data)) });
        }
    }
    try stdout.flush();
}

fn length(v: Vec2) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

pub fn palette(t: f32) Vec3 {
    const a: Vec3 = .{ 0.5, 0.5, 0.5 };
    const b: Vec3 = .{ 0.5, 0.5, 0.5 };
    const c: Vec3 = .{ 1.0, 1.0, 1.0 };
    const d: Vec3 = .{ 0.263, 0.416, 0.557 };

    const t_vec: Vec3 = .{ t, t, t };
    const phase: Vec3 = c * t_vec + d;
    const cos_val: Vec3 = .{
        @cos(6.28318 * phase[0]),
        @cos(6.28318 * phase[1]),
        @cos(6.28318 * phase[2]),
    };

    return a + b * cos_val;
}

fn fract(v: Vec2) Vec2 {
    return .{
        v[0] - @floor(v[0]),
        v[1] - @floor(v[1]),
    };
}

// Video URL: https://youtu.be/f4s1h2YETNY
pub fn drawScene(scene: Scene, framebuffer: [][4]u8, framebuffer_size: [2]usize, time: f32) void {
    _ = scene;

    const iTime = time;

    const width_f: f32 = @floatFromInt(framebuffer_size[0]);
    const height_f: f32 = @floatFromInt(framebuffer_size[1]);
    const resolution: Vec2 = .{ width_f, height_f };

    for (0..framebuffer_size[1]) |y| {
        const row = framebuffer[y * framebuffer_size[0] .. (y + 1) * framebuffer_size[0]];
        for (row, 0..framebuffer_size[0]) |*pixel, x| {
            const x_f: f32 = @floatFromInt(x);
            const y_f: f32 = @floatFromInt(y);
            const fragCoord: Vec2 = .{ x_f, y_f };

            var uv = (fragCoord * @as(Vec2, .{ 2.0, 2.0 }) - resolution) / @as(Vec2, .{ height_f, height_f });
            const uv0 = uv;
            var finalColor: Vec3 = .{ 0.0, 0.0, 0.0 };

            var i: f32 = 0.0;
            while (i < 4.0) : (i += 1.0) {
                uv = fract(uv * @as(Vec2, .{ 1.5, 1.5 })) - @as(Vec2, .{ 0.5, 0.5 });

                const d = length(uv) * @exp(-length(uv0));

                const col = palette(length(uv0) + i * 0.4 + iTime * 0.4);

                const sin_val = @sin(d * 8.0 + iTime) / 8.0;
                const d_modified = @abs(sin_val);

                const brightness = std.math.pow(f32, 0.01 / d_modified, 1.2);

                finalColor += col * @as(Vec3, .{ brightness, brightness, brightness });
            }

            const r_clamped = @min(1.0, @max(0.0, finalColor[0]));
            const g_clamped = @min(1.0, @max(0.0, finalColor[1]));
            const b_clamped = @min(1.0, @max(0.0, finalColor[2]));

            const r: u8 = @intFromFloat(r_clamped * 255.0);
            const g: u8 = @intFromFloat(g_clamped * 255.0);
            const b: u8 = @intFromFloat(b_clamped * 255.0);

            pixel.* = .{ b, g, r, 0xFF };
        }
    }
}

// pub fn drawScene(scene: Scene, framebuffer: [][4]u8, framebuffer_size: [2]usize) void {
//     const threshold = 1.0;
//     const r1 = scene.static.radius;
//     const r2 = scene.movable.radius;
//     const r1_squared = r1 * r1;
//     const r2_squared = r2 * r2;

//     for (0..framebuffer_size[1]) |y| {
//         const row = framebuffer[y * framebuffer_size[0] .. (y + 1) * framebuffer_size[0]];
//         for (row, 0..framebuffer_size[0]) |*pixel, x| {
//             const point: Vec2 = .{ @floatFromInt(x), @floatFromInt(y) };

//             const dx1 = point[0] - scene.static.center[0];
//             const dy1 = point[1] - scene.static.center[1];
//             const d_squared1 = (dx1 * dx1) + (dy1 * dy1);

//             const dx2 = point[0] - scene.movable.center[0];
//             const dy2 = point[1] - scene.movable.center[1];
//             const d_squared2 = (dx2 * dx2) + (dy2 * dy2);

//             const val1 = r1_squared / (d_squared1 + 0.0001);
//             const val2 = r2_squared / (d_squared2 + 0.0001);
//             const total_value = val1 + val2;

//             if (total_value > threshold) {
//                 const t = val2 / total_value;
//                 const blended_color = scene.static.color.lerp(scene.movable.color, t);

//                 pixel.* = .{
//                     blended_color.b,
//                     blended_color.g,
//                     blended_color.r,
//                     0xFF,
//                 };
//             } else {
//                 pixel.* = .{ 0x00, 0x00, 0x00, 0xFF };
//             }
//         }
//     }
// }

pub fn writeWlShmRequestCreatePool(
    socket: std.net.Stream,
    wl_shm_id: u32,
    next: *u32,
    fd: std.posix.fd_t,
    fd_len: i32,
) !u32 {
    const wl_shm_pool_id = next.*;

    const msg = [_]u32{ wl_shm_pool_id, @intCast(fd_len) };
    const msg_bytes = std.mem.sliceAsBytes(&msg);

    const header = Header{
        .id = wl_shm_id,
        .op = WL_SHM_REQUEST_CREATE_POOL,
        .size = @sizeOf(Header) + @as(u16, @intCast(msg_bytes.len)),
    };
    const header_bytes = std.mem.asBytes(&header);

    const msg_iov = [_]std.posix.iovec_const{
        .{
            .base = header_bytes.ptr,
            .len = header_bytes.len,
        },
        .{
            .base = msg_bytes.ptr,
            .len = msg_bytes.len,
        },
    };

    const control_msg = cmsg(std.posix.fd_t){
        .level = std.posix.SOL.SOCKET,
        .type = 0x01, // SCM_RIGHTS (std.c.solaris.SCM_RIGHTS)
        .data = fd,
    };
    const control_msg_bytes = std.mem.asBytes(&control_msg);

    const socket_msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &msg_iov,
        .iovlen = msg_iov.len,
        .control = control_msg_bytes.ptr,
        .controllen = control_msg_bytes.len,
        .flags = 0,
    };

    const sent_bytes = try std.posix.sendmsg(socket.handle, &socket_msg, 0);
    if (sent_bytes < header_bytes.len + msg_bytes.len) {
        return error.ConnectionClosed;
    }

    next.* += 1;
    return wl_shm_pool_id;
}

fn cmsg(comptime T: type) type {
    const padding_size = (@sizeOf(T) + @sizeOf(c_long) - 1) & ~(@as(usize, @sizeOf(c_long) - 1));
    return extern struct {
        len: c_ulong = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
}

fn debugPrintVarName(
    comptime message: []const u8,
    items: anytype,
) void {
    const T = @TypeOf(items);
    const info = @typeInfo(T).@"struct";

    std.log.debug(message ++ "\n", .{});
    inline for (info.fields, 0..) |field, i| {
        const name = field.name;
        const val = @field(items, name);
        std.log.debug("{s}: {any}", .{ name, val });
        if (i < info.fields.len - 1) {
            std.log.debug(", ", .{});
        }
    }
}

fn bindInterface(
    allocator: std.mem.Allocator,
    socket: std.net.Stream,
    registry_id: u32,
    name: u32,
    interface_str: []const u8,
    version: u32,
    new_id: u32,
) !void {
    const padded_string = (interface_str.len + 1 + 3) & ~@as(u32, 3);
    var interface_string = try allocator.alloc(u8, padded_string);
    defer allocator.free(interface_string);
    @memset(interface_string, 0);
    // var interface_string: [padded_string]u8 = std.mem.zeroes([padded_string]u8);
    @memcpy(interface_string[0..interface_str.len], interface_str);

    // do wl_registry:bind
    var request: std.ArrayList(u32) = .empty;
    defer request.deinit(allocator);

    try request.append(allocator, name);
    try request.append(allocator, @intCast(interface_str.len + 1));

    var i: usize = 0;
    while (i < interface_string.len) : (i += 4) {
        const chunk: [4]u8 = interface_string[i .. i + 4][0..4].*;
        const word: u32 = @bitCast(chunk);
        try request.append(allocator, word);
    }

    try request.append(allocator, version);
    try request.append(allocator, new_id);

    std.log.debug("Binding interface: {s} (name={any}, version={any}, new_id={any})\n", .{
        interface_str,
        name,
        version,
        new_id,
    });
    std.log.debug("Sending bind request with {any} words\n", .{request.items.len});
    std.log.debug("Interface string bytes: ", .{});
    for (interface_string) |byte| {
        std.log.debug("{x:0>2} ", .{byte});
    }
    std.log.debug("\n", .{});
    std.log.debug("Request words: ", .{});
    for (request.items) |word| {
        std.log.debug("{x:0>8} ", .{word});
    }
    std.log.debug("\n", .{});

    try writeRequest(socket, registry_id, WL_REGISTRY_REQUEST_BIND, request.items);
}
