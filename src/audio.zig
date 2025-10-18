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
    loop: ?*c.pw_thread_loop,
    stream: ?*c.pw_stream,
    samples: []f32,
    position: usize,
    channels: u16,
    sample_rate: u32,
    is_playing: bool,
    preferred_format: u16,
};

fn onProcess(user_data: ?*anyopaque) callconv(.c) void {
    var data: *Data = @ptrCast(@alignCast(user_data.?));

    if (!data.is_playing) {
        return;
    }

    const pw_buffer: ?*c.pw_buffer = c.pw_stream_dequeue_buffer(data.stream);
    if (pw_buffer == null) {
        std.log.err("out of buffer", .{});
        return;
    }

    const spa_buffer: ?*c.spa_buffer = pw_buffer.?.buffer;
    var dst: [*]f32 = @ptrCast(@alignCast(spa_buffer.?.datas[0].data));

    // TODO: get preferred format eventually
    const sample_size = @sizeOf(f32);
    const stride = sample_size * data.channels;
    const max_frames = spa_buffer.?.datas[0].maxsize / stride;
    var n_frames = max_frames;

    if (pw_buffer.?.requested > 0) {
        n_frames = @min(pw_buffer.?.requested, n_frames);
    }

    // Calculate how many frames we can actually write
    const frames_remaining = data.samples.len / data.channels - data.position;

    const frames_to_write = @min(n_frames, frames_remaining);

    if (frames_to_write == 0) {
        data.is_playing = false;
        spa_buffer.?.datas[0].chunk.*.size = 0;
        _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);
        return;
    }

    // Get the f32 samples we need to write
    // adjust for position
    const start_sample = data.position * data.channels;
    const samples_to_write = frames_to_write * data.channels;

    const src_samples = data.samples[start_sample .. start_sample + samples_to_write];
    const dst_slice = dst[0..samples_to_write];

    @memcpy(dst_slice, src_samples);

    data.position += frames_to_write;

    if (frames_to_write < n_frames) {
        data.is_playing = false;
    }

    spa_buffer.?.datas[0].chunk.*.offset = 0;
    spa_buffer.?.datas[0].chunk.*.stride = @intCast(stride);
    spa_buffer.?.datas[0].chunk.*.size = @intCast(frames_to_write * stride);

    _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);
}

fn onStateChanged(user_data: ?*anyopaque, old_state: c.pw_stream_state, state: c.pw_stream_state, err: [*c]const u8) callconv(.c) void {
    _ = old_state;
    _ = err;

    const data = @as(*Data, @ptrCast(@alignCast(user_data.?)));

    if (state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_ERROR) {
        c.pw_thread_loop_signal(data.loop, false);
    }
}

const stream_events = c.pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .process = onProcess,
    .state_changed = onStateChanged,
};

const WavHeader = extern struct {
    id: [4]u8, //     Always written "Riff"
    size: u32, //     Total file size
    ftype: [4]u8, //  "Wave"
};

const ChunkHeader = extern struct {
    id: [4]u8,
    size: u32,
};

const FormatChunk = extern struct {
    fmt: WavFormat, // PCM x Byte Integer
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32, // (Sample Rate * BitsPerSample * Channels) / 8
    block_align: u16, //(BitsPerSample * Channels) / 8.1 - 8 bit mono2 - 8 bit stereo/16 bit mono4 - 16 bit stereo
    bits_per_sample: u16,
};

const ExtensibleChunk = struct {
    bits_per_sample: u16,
    channel_mask: u16,
    fmt: [16]u8,
};

const DataChunk = struct {
    header: ChunkHeader,
    data: []u8,
};

const WavFormat = enum(u16) {
    pcm = 1,
    ieee = 3, // maybe check if worth implement?
    alaw = 6, // maybe check if worth implement?
    mulaw = 7, // maybe check if worth implement?
    extensible = 0xFFFE,
};

const Wav = struct {
    fmt: FormatChunk,
    extensible: ?ExtensibleChunk,
    // we're focing f32 internally
    data: []f32,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.data);
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

    var header_buffer = [_]u8{0} ** (@sizeOf(WavHeader) + @sizeOf(ChunkHeader) + @sizeOf(FormatChunk));
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
    const chunk_header: ChunkHeader = std.mem.bytesAsValue(ChunkHeader, header_buffer[@sizeOf(WavHeader) .. @sizeOf(WavHeader) + @sizeOf(ChunkHeader)]).*;
    if (!std.mem.eql(u8, &chunk_header.id, "fmt ")) {
        return error.ChunkFormatNotTracked;
    }

    var format_chunk: FormatChunk = std.mem.bytesToValue(
        FormatChunk,
        header_buffer[@sizeOf(WavHeader) + @sizeOf(ChunkHeader) ..],
    );
    printStruct(wav_header);
    printStruct(chunk_header);
    printStruct(format_chunk);

    var pos: usize = 0;
    var ext_chunk: ?ExtensibleChunk = null;

    if (format_chunk.fmt == .extensible) {
        var ext_buffer = [_]u8{0} ** @sizeOf(ExtensibleChunk);

        _ = try reader.read(&ext_buffer);
        ext_chunk = std.mem.bytesAsValue(ExtensibleChunk, ext_buffer[0..]).*;

        const ext_format: u16 = std.mem.readInt(u16, ext_chunk.?.fmt[0..2], .little);

        std.log.debug("ext_fmt: {}", .{ext_format});
        std.log.debug("ext_bits_per_sample: {}", .{ext_chunk.?.bits_per_sample});
        std.log.debug("ext_channel_mask: {}", .{ext_chunk.?.channel_mask});
        format_chunk.fmt = switch (ext_format) {
            0x0, 0x1 => .pcm,
            0x3 => .ieee,
            else => return error.UnsupportedFormatEX,
        };

        pos = (@sizeOf(WavHeader) + @sizeOf(ChunkHeader) + @sizeOf(FormatChunk) + @sizeOf(ExtensibleChunk)) / @sizeOf(u8);
    } else {
        pos = (@sizeOf(WavHeader) + @sizeOf(ChunkHeader) + @sizeOf(FormatChunk)) / @sizeOf(u8);
    }

    var delay_buffer = [_]u8{0} ** 4;
    while (!std.mem.eql(u8, "data", &delay_buffer)) {
        try reader.seekTo(pos);
        _ = try reader.read(&delay_buffer);
        pos += 1;
        std.log.debug("{s}\t", .{delay_buffer});
    }

    var data_bytes = [_]u8{0} ** 4;
    _ = try reader.read(&data_bytes);
    const data_size: u32 = std.mem.bytesAsValue(u32, data_bytes[0..]).*;
    std.log.debug("delay_buffer: {s} | 0x{x}", .{ delay_buffer, delay_buffer });
    std.log.debug("data_size: {} | 0x{x}", .{ data_size, data_size });

    const raw_buffer = try allocator.alloc(u8, data_size);
    defer allocator.free(raw_buffer);
    bytes_read = reader.read(raw_buffer) catch {
        return error.ReadFileError;
    };
    if (bytes_read != raw_buffer.len) {
        return error.UnexpectedEOF;
    }

    const wav_size = (wav.stat() catch {
        return error.FailedFileStat;
    }).size;

    std.log.debug("file_size: {}", .{wav_size});
    std.log.debug("wav_header_f_size: {}", .{wav_header.size});
    std.log.debug("header_size: {}", .{@sizeOf(WavHeader)});
    std.log.debug("fmt_size: {}", .{@sizeOf(FormatChunk)});
    std.log.debug("data_size: {}", .{data_size});

    // convert everything to f32
    const src_stride: u8 = @truncate(format_chunk.bits_per_sample / 8);
    const samples = raw_buffer.len / src_stride;
    std.log.debug("number_samples: {}", .{samples});
    const f32_samples = allocator.alloc(f32, samples) catch return error.OutOfMemory;

    const dst_stride = @sizeOf(f32);
    const dst_bytes: []align(4) u8 = std.mem.sliceAsBytes(f32_samples);

    switch (format_chunk.bits_per_sample) {
        8 => {
            unsignedToFloat(u8, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        16 => {
            signedToFloat(i16, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        24 => {
            const i24_samples = try allocator.alloc(i24, samples);
            defer allocator.free(i24_samples);

            // Manually copy and convert each 3-byte sample to aligned i24
            for (0..samples) |i| {
                const bytes = raw_buffer[i * 3 ..][0..3];
                // Read 3 bytes as little-endian i24
                i24_samples[i] = std.mem.readInt(i24, bytes, .little);
            }

            // Now i24_samples is properly aligned, convert to f32
            const i24_bytes: []align(4) u8 = std.mem.sliceAsBytes(i24_samples);
            signedToFloat(i24, @sizeOf(i24), i24_bytes, f32, dst_stride, dst_bytes, samples);
        },
        32 => {
            switch (format_chunk.fmt) {
                .ieee => {
                    @memcpy(f32_samples, std.mem.bytesAsSlice(f32, raw_buffer));
                },
                .pcm, .extensible => {},
                else => return error.UnsupportedFormat,
            }
            signedToFloat(i32, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        64 => {
            switch (format_chunk.fmt) {
                .ieee => {
                    // FIX: this is wrong :)
                    const f64_samples: []align(1) f64 = std.mem.bytesAsSlice(f64, raw_buffer);
                    for (f64_samples, 0..) |s, i| {
                        f32_samples[i] = @as(f32, @floatCast(s));
                    }
                },
                else => return error.UnsupportedFormat,
            }
            signedToFloat(i32, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        else => return error.UnsupportedBitsPerSample,
    }

    return .{ .fmt = format_chunk, .extensible = ext_chunk, .data = f32_samples };
}

pub fn unsignedToFloat(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const half_u = (std.math.maxInt(SrcType) + 1) / 2;
    const half_f = @as(DstType, @floatFromInt(half_u));

    const div_by_half_f = 1.0 / half_f;
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrcType = @Vector(vec_size, SrcType);
        const VecDstType = @Vector(vec_size, DstType);

        // multiplies everything by half
        const half_vec: VecDstType = @splat(half_f);
        const block_len = len - (len % vec_size);

        const div_by_half_f_vec: VecDstType = @splat(div_by_half_f);

        while (i < block_len) : (i += vec_size) {
            const src_values = std.mem.bytesAsValue(VecSrcType, src[i * src_stride ..][0 .. vec_size * src_stride]).*;

            // int to float vector
            const src_f_vec: VecDstType = @floatFromInt(src_values);
            const sub_result: VecDstType = src_f_vec - half_vec;
            const dst_vec: VecDstType = sub_result * div_by_half_f_vec;

            @memcpy(dst[i * dst_stride ..][0 .. vec_size * dst_stride], std.mem.asBytes(&dst_vec)[0 .. vec_size * dst_stride]);
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(src[i * src_stride ..][0..src_stride]));

        const src_sample_f = @as(DstType, @floatFromInt(src_sample.*));
        const dst_sample: DstType = (src_sample_f - half_f) * div_by_half_f;

        @memcpy(dst[i * dst_stride ..][0..dst_stride], std.mem.asBytes(&dst_sample)[0..dst_stride]);
    }
}

pub fn signedToFloat(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const div_by_max = 1.0 / @as(comptime_float, std.math.maxInt(SrcType) + 1);
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrc = @Vector(vec_size, SrcType);
        const VecDst = @Vector(vec_size, DstType);
        const vec_blocks_len = len - (len % vec_size);
        const div_by_max_vec: VecDst = @splat(div_by_max);
        while (i < vec_blocks_len) : (i += vec_size) {
            const src_vec = std.mem.bytesAsValue(VecSrc, src[i * src_stride ..][0 .. vec_size * src_stride]).*;
            const dst_sample: VecDst = @as(VecDst, @floatFromInt(src_vec)) * div_by_max_vec;
            @memcpy(dst[i * dst_stride ..][0 .. vec_size * dst_stride], std.mem.asBytes(&dst_sample)[0 .. vec_size * dst_stride]);
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(src[i * src_stride ..][0..src_stride]));
        const dst_sample: DstType = @as(DstType, @floatFromInt(src_sample.*)) * div_by_max;
        @memcpy(dst[i * dst_stride ..][0..dst_stride], std.mem.asBytes(&dst_sample)[0..dst_stride]);
    }
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
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    var argc = std.process.argsWithAllocator(gpa) catch return error.ErrorReadingArgs;
    defer argc.deinit();
    const p_name = argc.next().?;
    std.log.info("Executing {s}", .{p_name});
    const load = "./assets/M1F1-float32WE-AFsp.wav";
    const audio_name = argc.next() orelse load;
    std.log.info("Audio: {s}", .{audio_name});
    // while (argc.next()) |arg| {
    //     std.log.info("{s}", .{arg});
    // }

    std.debug.print("Pipewire WAV Player\n\n", .{});
    const wave = try loadWave(gpa, audio_name);
    defer wave.deinit(gpa);

    std.log.debug("WAV loaded: {} channels, {} Hz, {} bits, {} samples\n", .{
        wave.fmt.num_channels,
        wave.fmt.sample_rate,
        wave.fmt.bits_per_sample,
        wave.data.len / wave.fmt.num_channels,
    });

    var data: Data = .{
        .loop = undefined,
        .stream = undefined,
        .samples = wave.data,
        .position = 0,
        .channels = wave.fmt.num_channels,
        .sample_rate = wave.fmt.sample_rate,
        .is_playing = true,
        .preferred_format = c.SPA_AUDIO_FORMAT_F32,
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
        .format = c.SPA_AUDIO_FORMAT_F32,
        .channels = data.channels,
        .rate = data.sample_rate,
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

    data.loop = c.pw_thread_loop_new("wav-player", null);
    defer c.pw_thread_loop_destroy(data.loop);

    data.stream = c.pw_stream_new_simple(
        c.pw_thread_loop_get_loop(data.loop),
        "wav-player",
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

    const result = c.pw_stream_connect(
        data.stream,
        c.PW_DIRECTION_OUTPUT,
        c.PW_ID_ANY,
        c.PW_STREAM_FLAG_AUTOCONNECT | c.PW_STREAM_FLAG_MAP_BUFFERS | c.PW_STREAM_FLAG_RT_PROCESS,
        @ptrCast(&params),
        params.len,
    );

    if (result != 0) {
        std.log.err("Failed to connect stream: {}", .{result});
        return error.StreamConnectFailed;
    }

    if (c.pw_thread_loop_start(data.loop) < 0) {
        std.log.err("Failed to start thread loop", .{});
        return error.ThreadLoopStartFailed;
    }
    defer std.log.info("Playback finished", .{});
    defer c.pw_thread_loop_stop(data.loop);

    // Wait for the stream to be ready
    c.pw_thread_loop_lock(data.loop);
    c.pw_thread_loop_wait(data.loop);
    c.pw_thread_loop_unlock(data.loop);

    const stream_state = c.pw_stream_get_state(data.stream, null);
    if (stream_state == c.PW_STREAM_STATE_ERROR) {
        std.log.err("Stream error", .{});
        return error.StreamError;
    }

    std.log.info("Playing WAV file...", .{});

    while (data.is_playing) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}
