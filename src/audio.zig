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
    sample_data: SampleData,
    position: usize,
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

    const samples_needed = n_frames * DEFAULT_CHANNELS;
    // TODO: abstract this to use the proper sampling
    const samples_available = data.sample_data.pcm16.len - data.position;
    const samples_to_copy = @min(samples_needed, samples_available);

    @memcpy(dst[0..samples_to_copy], data.sample_data.pcm16[data.position..][0..samples_to_copy]);
    data.position += samples_to_copy;

    std.debug.print("needed = {} | available =  {} | to_copy = {}", .{ samples_needed, samples_available, samples_to_copy });
    if (samples_to_copy < samples_needed) {
        // fill with 0 or quit loop?
        @memset(dst[samples_to_copy..samples_needed], 0);
        std.log.debug("\n>Wav ended<\n", .{});
        _ = c.pw_main_loop_quit(data.loop);
    }

    // sine wave , maybe try to adapt this to variate using kb/mouse inputs?
    // var idx: usize = 0;
    // for (0..n_frames) |_| {
    //     // data.accumulator += M_PI_M2 * 440 / SAMPLE_RATE;
    //     data.accumulator += M_PI_M2 * 440.0 / @as(f64, @floatFromInt(SAMPLE_RATE));
    //     if (data.accumulator >= M_PI_M2)
    //         data.accumulator -= M_PI_M2;

    //     const val = std.math.sin(data.accumulator) * DEFAULT_VOLUME * 32767.0;
    //     const val_i16: i16 = @intFromFloat(val);
    //     for (0..DEFAULT_CHANNELS) |_| {
    //         dst[idx] = val_i16;
    //         idx += 1;
    //     }
    // }

    spa_buffer.?.datas[0].chunk.*.offset = 0;
    spa_buffer.?.datas[0].chunk.*.stride = @intCast(stride);
    spa_buffer.?.datas[0].chunk.*.size = @intCast(n_frames * stride);
    _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);
}

const stream_events = c.pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .process = onProcess,
};

const WavHeader = extern struct {
    id: [4]u8, //     Always written "Riff"
    size: u32, //     Total file size
    ftype: [4]u8, //  "Wave"
    chunk: [4]u8, // maybe make a tagged so we avoid storing this?
    chunk_len: u32,
};

const ChunkHeader = extern struct {
    id: [4]u8,
    size: u32,
};

const FormatChunk = extern struct {
    fmt: u16, // PCM x Byte Integer
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32, // (Sample Rate * BitsPerSample * Channels) / 8
    block_align: u16, //(BitsPerSample * Channels) / 8.1 - 8 bit mono2 - 8 bit stereo/16 bit mono4 - 16 bit stereo
    bit_per_sample: u16,
    data_id: [4]u8,
    data_size: u32,
};

const WavFormat = enum(u16) {
    pcm = 1,
    ieee = 3, // maybe check if worth implement?
    alaw = 6, // maybe check if worth implement?
    mulaw = 7, // maybe check if worth implement?
    extensible = 0xFFFE,
};

const SampleData = union(enum) {
    pcm8: []u8,
    pcm16: []i16,
    pcm24: []i24,
    pcm32: []i32,
    float32: []f32,
    float64: []f64,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |data| allocator.free(data),
        }
    }
};

const Wav = struct {
    fmt: FormatChunk,
    data: SampleData,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        // allocator.free(self.data);
        self.data.deinit(allocator);
    }
};

// Allocates new memory, must free if you call
fn loadWave(allocator: std.mem.Allocator, file: []const u8) !Wav {
    const wav = std.fs.cwd().openFile(
        file,
        .{ .mode = .read_only },
    ) catch {
        return error.FileNotFound;
    };
    defer wav.close();

    var header_buffer = [_]u8{0} ** (@sizeOf(WavHeader) + @sizeOf(FormatChunk));
    var reader = std.fs.File.reader(wav, &header_buffer);

    var bytes_read = reader.read(&header_buffer) catch {
        return error.ReadFileError;
    };
    if (bytes_read < header_buffer.len) {
        return error.UnexpectedEOF;
    }

    const wav_header: WavHeader = std.mem.bytesToValue(
        WavHeader,
        header_buffer[0..@sizeOf(WavHeader)],
    );
    if (!std.mem.eql(u8, &wav_header.id, "RIFF") or !std.mem.eql(u8, &wav_header.ftype, "WAVE")) {
        printStruct(wav_header);
        return error.NotWavFormat;
    }
    if (!std.mem.eql(u8, &wav_header.chunk, "fmt ")) {
        return error.ChunkFormatNotTracked;
    }

    var chunk_header: FormatChunk = std.mem.bytesToValue(
        FormatChunk,
        header_buffer[@sizeOf(WavHeader)..],
    );
    printStruct(chunk_header);

    // allocator.alignedAlloc(comptime T: type, comptime alignment: ?Alignment, n: usize)
    const raw_buffer = try allocator.alloc(u8, chunk_header.data_size);
    errdefer allocator.free(raw_buffer);

    bytes_read = reader.read(raw_buffer) catch {
        return error.ReadFileError;
    };
    if (bytes_read != raw_buffer.len) {
        return error.UnexpectedEOF;
    }

    const a = @sizeOf(FormatChunk);
    const b = @sizeOf(WavHeader) - @sizeOf(ChunkHeader);
    const wav_size = (wav.stat() catch {
        return error.FailedFileStat;
    }).size;

    std.debug.assert(raw_buffer.len + header_buffer.len == wav_size);
    chunk_header.data_size = wav_header.size - a - b;

    const sample_data = switch (chunk_header.fmt) {
        1 => blk: { // PCM
            switch (chunk_header.bit_per_sample) {
                8 => break :blk SampleData{ .pcm8 = raw_buffer },
                16 => break :blk SampleData{ .pcm16 = @alignCast(std.mem.bytesAsSlice(i16, raw_buffer)) },
                24 => break :blk SampleData{ .pcm24 = @alignCast(std.mem.bytesAsSlice(i24, raw_buffer)) },
                32 => break :blk SampleData{ .pcm32 = @alignCast(std.mem.bytesAsSlice(i32, raw_buffer)) },
                else => return error.UnsopportedBitsPerSample,
            }
        },
        3 => blk: { // IEEE Float
            switch (chunk_header.bit_per_sample) {
                32 => break :blk SampleData{ .float32 = @alignCast(std.mem.bytesAsSlice(f32, raw_buffer)) },
                64 => break :blk SampleData{ .float64 = @alignCast(std.mem.bytesAsSlice(f64, raw_buffer)) },
                else => return error.UnsopportedBitsPerSample,
            }
        },
        else => return error.UnsupportedFormat,
    };

    return .{ .fmt = chunk_header, .data = sample_data };
}

fn printStruct(data: anytype) void {
    inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "chunk")) {
            std.debug.print("{s}: [", .{field.name});
            defer std.debug.print("] | 0x{X}\n", .{
                @field(data, field.name),
            });
            inline for (@field(data, field.name), 0..) |char, i| {
                if (char > 33 and char < 127) {
                    std.debug.print("{c}", .{char});
                } else {
                    std.debug.print(" {d}", .{char});
                }
                if (i < 3) {
                    std.debug.print(",", .{});
                }
            }
        } else if (field.type == [4]u8) {
            std.debug.print("{s}: {s} | 0x{X}\n", .{
                field.name,
                @field(data, field.name),
                @field(data, field.name),
                // field.type,
            });
        } else {
            std.debug.print("{s}: {any} | 0x{X}\n", .{
                field.name,
                @field(data, field.name),
                @field(data, field.name),
            });
        }
    }
}

pub fn main() !void {
    std.debug.print("Pipewire Tutorial\n", .{});

    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    // const wave = try loadWave(gpa, "./assets/Ahavoh_Rabboh_Mode.wav");
    const wave = try loadWave(gpa, "./assets/d_flat.wav");
    defer wave.deinit(gpa);

    var data: Data = .{
        .loop = undefined,
        .stream = undefined,
        .accumulator = 0,
        .sample_data = wave.data,
        .position = 0,
    };

    std.log.debug("sz = {}\n", .{wave.data.pcm16.len});

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
        .channels = wave.fmt.num_channels,
        .rate = wave.fmt.sample_rate,
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
