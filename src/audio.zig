const std = @import("std");
const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("spa/param/audio/format-utils.h");
});

// the C macro :
// error: integer and float literals passed to variadic function must be casted to a fixed-size number type
// therefore we create a function that will bypass that
// source: https://github.com/hexops/mach/blob/main/src/sysaudio/pipewire.zig
extern fn sysaudio_spa_format_audio_raw_build(
    builder: [*c]c.spa_pod_builder,
    id: u32,
    info: [*c]c.spa_audio_info_raw,
) callconv(.c) [*c]c.spa_pod;

const SAMPLE_RATE = 44_100;
const DEFAULT_CHANNELS = 2;
const DEFAULT_VOLUME = 0.7;

const M_PI_M2 = std.math.pi + std.math.pi;

const Data = struct {
    loop: ?*c.pw_main_loop,
    stream: ?*c.pw_stream,
    accumulator: f64,
};

fn onProcess(user_data: ?*anyopaque) callconv(.c) void {
    var data: *Data = @ptrCast(@alignCast(user_data.?));
    const pw_buffer: ?*c.pw_buffer = c.pw_stream_dequeue_buffer(data.stream);
    if (pw_buffer == null) {
        std.log.err("out of buffer", .{});
    }
    const spa_buffer: ?*c.spa_buffer = pw_buffer.?.buffer;

    var dst: [*]i16 = @ptrCast(@alignCast(spa_buffer.?.datas[0].data));

    const stride = @sizeOf(i16) * DEFAULT_CHANNELS;
    var n_frames = spa_buffer.?.datas[0].maxsize / stride;
    if (pw_buffer.?.requested > 0) {
        n_frames = @min(pw_buffer.?.requested, n_frames);
    }

    var idx: usize = 0;
    for (0..n_frames) |_| {
        // data.accumulator += M_PI_M2 * 440 / SAMPLE_RATE;
        data.accumulator += M_PI_M2 * 440.0 / @as(f64, @floatFromInt(SAMPLE_RATE));
        if (data.accumulator >= M_PI_M2)
            data.accumulator -= M_PI_M2;

        const val = std.math.sin(data.accumulator) * DEFAULT_VOLUME * 32767.0;
        const val_i16: i16 = @intFromFloat(val);
        for (0..DEFAULT_CHANNELS) |_| {
            dst[idx] = val_i16;
            idx += 1;
        }
    }

    spa_buffer.?.datas[0].chunk.*.offset = 0;
    spa_buffer.?.datas[0].chunk.*.stride = @intCast(stride);
    spa_buffer.?.datas[0].chunk.*.size = @intCast(n_frames * stride);
    _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);
}

const stream_events = c.pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .process = onProcess,
};

// .Wav File
// <WAVE-form> → RIFF('WAVE'
//                    <fmt-ck>            // Format of the file
//                    [<fact-ck>]         // Fact chunk
//                    [<cue-ck>]          // Cue points
//                    [<playlist-ck>]     // Playlist
//                    [<assoc-data-list>] // Associated data list
//                    <wave-data> )       // Wave data
// bin data

const RiffHeader = extern struct {
    id: [4]u8, // Always written "Riff"
    size: u32,
    fmt: [4]u8, // "Wave"
};

const ChunkHeader = extern struct {
    id: [4]u8,
    size: u32,
};

const FormatChunk = extern struct {
    fmt: u16,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block: u16,
    bit_rate: u16,
};

const Wave = struct {
    fmt: FormatChunk,
    data: []u8,
};

fn loadWave(allocator: std.mem.Allocator, file: []const u8) !void {
    const wav = std.fs.cwd().openFile(
        file,
        .{ .mode = .read_only },
    ) catch {
        return error.FileNotFound;
    };
    defer wav.close();
    _ = allocator;

    const wav_size = (wav.stat() catch {
        return error.FailedFileStat;
    }).size;

    std.debug.print("{}\n", .{wav_size});
    var buffer = [_]u8{0} ** @sizeOf(RiffHeader);
    var reader = std.fs.File.reader(wav, &buffer);
    const bytes_read = reader.read(&buffer) catch {
        return error.ReadFileError;
    };
    if (bytes_read < buffer.len) {
        return error.UnexpectedEOF;
    }

    const riff: RiffHeader = @bitCast(buffer);
    std.debug.print("{s}, {s}, {}\n", .{ riff.id, riff.fmt, riff.size });

    // var buffer: [4096]u8 = undefined;
    // var reader = std.fs.File.reader(wav, buffer);
    // var interface = &reader.interface;
}

pub fn main() !void {
    std.debug.print("Pipewire Tutorial\n", .{});

    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    try loadWave(gpa, "./assets/d_flat.wav");

    var data: Data = .{
        .loop = undefined,
        .stream = undefined,
        .accumulator = 0,
    };

    var buffer: [1024]u8 = undefined;
    var builder: c.spa_pod_builder = c.spa_pod_builder{
        .data = &buffer,
        .size = buffer.len,
        ._padding = 0,
        .state = .{
            .offset = 0,
            .flags = 0,
            .frame = null,
        },
        .callbacks = .{
            .data = null,
            .funcs = null,
        },
    };

    var audio_info = c.spa_audio_info_raw{
        .format = c.SPA_AUDIO_FORMAT_S16,
        .channels = @as(u32, DEFAULT_CHANNELS),
        .rate = @as(u32, SAMPLE_RATE),
    };

    var params = [1][*c]c.spa_pod{
        sysaudio_spa_format_audio_raw_build(
            &builder,
            c.SPA_PARAM_EnumFormat,
            &audio_info,
        ),
    };

    c.pw_init(null, null);
    defer c.pw_deinit();

    data.loop = c.pw_main_loop_new(null);
    defer c.pw_main_loop_destroy(data.loop);

    data.stream = c.pw_stream_new_simple(
        c.pw_main_loop_get_loop(data.loop),
        "audio-src",
        c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE,
            "Audio",
            c.PW_KEY_MEDIA_CATEGORY,
            "Playback",
            c.PW_KEY_MEDIA_ROLE,
            "Music",
            @as(?*anyopaque, null),
        ),
        &stream_events,
        &data,
    );
    defer c.pw_stream_destroy(data.stream);

    _ = c.pw_stream_connect(
        data.stream,
        c.PW_DIRECTION_OUTPUT,
        c.PW_ID_ANY,
        c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS | c.PW_STREAM_FLAG_RT_PROCESS,
        @ptrCast(&params),
        params.len,
    );

    _ = c.pw_main_loop_run(data.loop);
}
