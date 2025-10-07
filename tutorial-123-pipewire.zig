const std = @import("std");
const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("spa/param/audio/format-utils.h");
});

const SAMPLE_RATE = 44100;
const DEFAULT_CHANNELS = 2;
const DEFAULT_VOLUME = 0.7;

fn registryEventGlobal(
    data: ?*anyopaque,
    id: u32,
    permissions: u32,
    type_str: [*c]const u8,
    version: u32,
    props: [*c]const c.struct_spa_dict,
) callconv(.c) void {
    _ = data;
    _ = permissions;
    _ = props;

    std.log.debug("object_id {}, version {},  type_str {s}", .{ id, version, type_str });
}

const RoundTripData = struct {
    pending: i32,
    loop: *c.pw_main_loop,
};

fn onCoreDone(data: ?*anyopaque, id: u32, seq: i32) callconv(.c) void {
    const d: *RoundTripData = @ptrCast(@alignCast(data));
    if (id == c.PW_ID_CORE and seq == d.pending) {
        std.log.debug("All events done", .{});
        _ = c.pw_main_loop_quit(d.loop);
    }
}

fn roundTrip(core: ?*c.struct_pw_core, loop: ?*c.struct_pw_main_loop) callconv(.c) void {
    const core_events = c.pw_core_events{
        .version = c.PW_VERSION_CORE_EVENTS,
        .done = onCoreDone,
    };

    var data = RoundTripData{
        .loop = loop.?,
        .pending = undefined,
    };
    var core_listener: c.spa_hook = undefined;
    defer c.spa_hook_remove(&core_listener);
    data.pending = c.pw_core_sync(core, c.PW_ID_CORE, 0);

    _ = c.pw_core_add_listener(
        core.?,
        &core_listener,
        &core_events,
        &data,
    );

    const err = c.pw_main_loop_run(loop);
    if (err < 0) {
        std.log.err("main_loop_run error: {}\n", .{err});
    }
}

pub fn main() !void {
    std.debug.print("Audio Library\n", .{});
    c.pw_init(null, null);
    const loop = c.pw_main_loop_new(null);
    if (loop == null) return error.MainLoopCreationFail;
    defer c.pw_main_loop_destroy(loop);

    const pw_loop = c.pw_main_loop_get_loop(loop);

    const context = c.pw_context_new(
        pw_loop,
        null,
        0,
    );
    if (context == null) return error.ContextCreationFail;
    defer c.pw_context_destroy(context);

    const core = c.pw_context_connect(
        context,
        null,
        0,
    );
    if (core == null) return error.ConnectionFail;
    defer _ = c.pw_core_disconnect(core);

    const registry = c.pw_core_get_registry(
        core,
        c.PW_VERSION_REGISTRY,
        0,
    );
    if (registry == null) return error.RegistryFailed;
    defer c.pw_proxy_destroy(@ptrCast(registry));

    var registry_events = c.struct_pw_registry_events{
        .global = registryEventGlobal,
        .global_remove = null,
        .version = c.PW_VERSION_REGISTRY_EVENTS,
    };

    // this needs to be initialized to 0
    // but we can't use the default spa_zero(&listener), because zig cImport
    // cast discards const qualifier
    // cant do ->
    // var registry_listener: pw.struct_spa_hook = undefined;
    // pw.spa_zero(&registry_listener);
    var registry_listener = std.mem.zeroes(c.struct_spa_hook);
    _ = c.pw_registry_add_listener(
        registry,
        &registry_listener,
        &registry_events,
        null,
    );

    std.debug.print("Listening for PipeWire objects...\n\n", .{});

    // tutorial 2
    // _ = pw.pw_main_loop_run(loop);

    // tutorial 3
    roundTrip(core, loop);
}
