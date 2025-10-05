const std = @import("std");

const pw = @cImport({
    @cInclude("pipewire/pipewire.h");
});

fn registryEventGlobal(
    data: ?*anyopaque,
    id: u32,
    permissions: u32,
    type_str: [*c]const u8,
    version: u32,
    props: [*c]const pw.struct_spa_dict,
) callconv(.c) void {
    _ = data;
    _ = permissions;
    _ = props;

    std.debug.print("object_id {}, version {},  type_str {s}\n", .{ id, version, type_str });
}

pub fn main() !void {
    std.debug.print("Audio Library\n", .{});
    pw.pw_init(null, null);
    const loop = pw.pw_main_loop_new(null);
    if (loop == null) return error.MainLoopCreationFail;
    defer pw.pw_main_loop_destroy(loop);

    const pw_loop = pw.pw_main_loop_get_loop(loop);

    const context = pw.pw_context_new(
        pw_loop,
        null,
        0,
    );
    if (context == null) return error.ContextCreationFail;
    defer pw.pw_context_destroy(context);

    const core = pw.pw_context_connect(
        context,
        null,
        0,
    );
    if (core == null) return error.ConnectionFail;
    defer _ = pw.pw_core_disconnect(core);

    const registry = pw.pw_core_get_registry(
        core,
        pw.PW_VERSION_REGISTRY,
        0,
    );
    if (registry == null) return error.RegistryFailed;
    defer pw.pw_proxy_destroy(@ptrCast(registry));

    var registry_events = pw.struct_pw_registry_events{
        .global = registryEventGlobal,
        .global_remove = null,
        .version = pw.PW_VERSION_REGISTRY_EVENTS,
    };

    // this needs to be initialized to 0
    // but we can't use the default spa_zero(&listener), because zig cImport
    // cast discards const qualifier
    // cant do ->
    // var registry_listener: pw.struct_spa_hook = undefined;
    // pw.spa_zero(&registry_listener);
    var registry_listener = std.mem.zeroes(pw.struct_spa_hook);
    _ = pw.pw_registry_add_listener(
        registry,
        &registry_listener,
        &registry_events,
        null,
    );

    std.debug.print("Listening for PipeWire objects...\n\n", .{});

    _ = pw.pw_main_loop_run(loop);
}
