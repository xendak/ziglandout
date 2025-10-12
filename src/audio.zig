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
    sample_data: SampleData,
    position: usize,
    channels: u16,
    sample_rate: u32,
    is_playing: bool,
};

fn onProcess(user_data: ?*anyopaque) callconv(.c) void {
    var data: *Data = @ptrCast(@alignCast(user_data.?));

    if (!data.is_playing) {
        _ = c.pw_main_loop_quit(data.loop);
        return;
    }

    const pw_buffer: ?*c.pw_buffer = c.pw_stream_dequeue_buffer(data.stream);
    if (pw_buffer == null) {
        std.log.err("out of buffer", .{});
        return;
    }

    const spa_buffer: ?*c.spa_buffer = pw_buffer.?.buffer;
    var dst: [*]i16 = @ptrCast(@alignCast(spa_buffer.?.datas[0].data));

    const stride = @sizeOf(i16) * data.channels;
    const max_frames = spa_buffer.?.datas[0].maxsize / stride;
    var n_frames = max_frames;

    if (pw_buffer.?.requested > 0) {
        n_frames = @min(pw_buffer.?.requested, n_frames);
    }

    // Calculate how many frames we can actually write
    const frames_remaining = switch (data.sample_data) {
        .pcm16 => |samples| samples.len / data.channels - data.position,
        .pcm8 => |samples| samples.len / data.channels - data.position,
        .pcm24 => |samples| samples.len / data.channels - data.position,
        .pcm32 => |samples| samples.len / data.channels - data.position,
        .float32 => |samples| samples.len / data.channels - data.position,
        .float64 => |samples| samples.len / data.channels - data.position,
    };

    const frames_to_write = @min(n_frames, frames_remaining);

    if (frames_to_write == 0) {
        data.is_playing = false;
        spa_buffer.?.datas[0].chunk.*.size = 0;
        _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);
        return;
    }

    // Write the audio data based on the format
    switch (data.sample_data) {
        .pcm16 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                dst[i - start_idx] = samples[i];
            }
        },
        .pcm8 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                // Correct conversion from u8 (0-255) to i16 (-32768 to 32767)
                // 1. Cast the u8 sample to a wider integer type (like i32) to avoid overflow during calculations.
                const u8_sample = @as(i32, samples[i]);

                // 2. Scale the value.
                //    A u8 value represents the high byte of a signed 16-bit sample,
                //    so we shift it left by 8 bits (multiply by 256).
                const scaled_sample = u8_sample * 256;

                // 3. Offset the scaled sample to shift the range from [0, 65280]
                //    to [-32768, 32512], which is approximately correct for PCM8.
                const offset_sample: i16 = @intCast(scaled_sample - 32768);
                // 4. Safely cast the result back to i16.
                dst[i - start_idx] = @as(i16, offset_sample);
            }
        },
        .pcm24 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                // Convert 24-bit to 16-bit (right shift by 8)
                dst[i - start_idx] = @as(i16, @intCast(@as(i32, samples[i]) >> 8));
            }
        },
        .pcm32 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                // Convert 32-bit to 16-bit (right shift by 16)
                dst[i - start_idx] = @as(i16, @intCast(samples[i] >> 16));
            }
        },
        .float32 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                // Convert float to 16-bit
                const val = std.math.clamp(samples[i] * 32767.0, -32768.0, 32767.0);
                dst[i - start_idx] = @as(i16, @intFromFloat(val));
            }
        },
        .float64 => |samples| {
            const start_idx = data.position * data.channels;
            const end_idx = start_idx + frames_to_write * data.channels;

            for (start_idx..end_idx) |i| {
                // Convert double to 16-bit
                const val = std.math.clamp(samples[i] * 32767.0, -32768.0, 32767.0);
                dst[i - start_idx] = @as(i16, @intFromFloat(val));
            }
        },
    }

    data.position += frames_to_write;

    if (frames_to_write < n_frames) {
        data.is_playing = false;
    }

    spa_buffer.?.datas[0].chunk.*.offset = 0;
    spa_buffer.?.datas[0].chunk.*.stride = @intCast(stride);
    spa_buffer.?.datas[0].chunk.*.size = @intCast(frames_to_write * stride);

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
    extensible: ExtensibleChunk,
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

    // Bits per sample analysis ?
    // TODO: remake this i think?
    // we need to properly read everything and still classify as pcm16 pcm32f pcm32_fle
    // i think the order of the check is inversed here.. we know its pcm or extensible or iee before we analyze the bit sample
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
            0x1 => .pcm,
            0x3 => .ieee,
            else => return error.UnsupportedFormat,
        };
        // format_chunk.bits_per_sample = ext_chunk.?.bits_per_sample;

        pos = (@sizeOf(WavHeader) + @sizeOf(ChunkHeader) + @sizeOf(FormatChunk) + @sizeOf(ExtensibleChunk)) / @sizeOf(u8);
    } else {
        pos = (@sizeOf(WavHeader) + @sizeOf(ChunkHeader) + @sizeOf(FormatChunk)) / @sizeOf(u8);
        // may contain a format we dont support yet?
    }

    // while we dont read "data", keep reading, ignore the strange formats?
    // read by 4 bytes so we can do proper comparison?
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

    // allocator.alignedAlloc(comptime T: type, comptime alignment: ?Alignment, n: usize)
    const raw_buffer = try allocator.alloc(u8, data_size);
    errdefer allocator.free(raw_buffer);
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

    const sample_data = switch (format_chunk.fmt) {
        .pcm, .extensible => blk: { // PCM
            switch (format_chunk.bits_per_sample) {
                8 => break :blk SampleData{ .pcm8 = raw_buffer },
                16 => break :blk SampleData{ .pcm16 = @alignCast(std.mem.bytesAsSlice(i16, raw_buffer)) },
                24 => {
                    // zig has aligment of 4 for this.
                    // assuming LE for now
                    const num_samples = raw_buffer.len / 3;
                    const samples = try allocator.alloc(i24, num_samples);
                    for (0..num_samples) |idx| {
                        const byte = idx * 3;
                        const byte_0 = @as(i32, raw_buffer[byte]);
                        const byte_1 = @as(i32, raw_buffer[byte + 1]);
                        const byte_2 = @as(i32, raw_buffer[byte + 2]);

                        var val: i32 = 0;
                        val |= @as(i32, byte_0) << 8;
                        val |= @as(i32, byte_1) << 16;
                        val |= @as(i32, byte_2) << 24;

                        samples[idx] = @intCast(val >> 8);
                    }
                    // allocator.free(raw_buffer);
                    break :blk SampleData{ .pcm24 = samples };
                },
                32 => break :blk SampleData{ .pcm32 = @alignCast(std.mem.bytesAsSlice(i32, raw_buffer)) },
                else => return error.UnsopportedBitsPerSample,
            }
        },
        .ieee => blk: { // IEEE Float
            switch (format_chunk.bits_per_sample) {
                32 => break :blk SampleData{ .float32 = @alignCast(std.mem.bytesAsSlice(f32, raw_buffer)) },
                64 => break :blk SampleData{ .float64 = @alignCast(std.mem.bytesAsSlice(f64, raw_buffer)) },
                else => return error.UnsopportedBitsPerSample,
            }
        },
        else => return error.UnsupportedFormat,
    };

    return .{ .fmt = format_chunk, .extensible = undefined, .data = sample_data };
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
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    // const load = "./assets/full_scale_pcm16.wav";
    // const load = "./assets/d_flat_pcm16.wav";
    // const load = "./assets/sinewave_pcms32le.wav";
    // const load = "./assets/M1F1-int32WE-AFsp.wav";
    // const load = "./assets/M1F1-float32-AFsp.wav";
    const load = "./assets/M1F1-float32WE-AFsp.wav";
    // const load = "./assets/M1F1-float64-AFsp.wav";
    // const load = "./assets/full_scale_pcm16.wav";
    std.debug.print("Pipewire WAV Player, {s}\n", .{load});
    const wave = try loadWave(gpa, load);
    defer wave.deinit(gpa);

    std.log.debug("WAV loaded: {} channels, {} Hz, {} bits, {} samples\n", .{
        wave.fmt.num_channels,
        wave.fmt.sample_rate,
        wave.fmt.bits_per_sample,
        switch (wave.data) {
            .pcm8 => |d| d.len,
            .pcm16 => |d| d.len,
            .pcm24 => |d| d.len,
            .pcm32 => |d| d.len,
            .float32 => |d| d.len,
            .float64 => |d| d.len,
        } / wave.fmt.num_channels,
    });

    var data: Data = .{
        .loop = undefined,
        .stream = undefined,
        .sample_data = wave.data,
        .position = 0,
        .channels = wave.fmt.num_channels,
        .sample_rate = wave.fmt.sample_rate,
        .is_playing = true,
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

    // const fmt = switch(wave.fmt.)

    var audio_info = c.spa_audio_info_raw{
        .format = c.SPA_AUDIO_FORMAT_S16,
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

    data.loop = c.pw_main_loop_new(null);
    defer c.pw_main_loop_destroy(data.loop);

    data.stream = c.pw_stream_new_simple(
        c.pw_main_loop_get_loop(data.loop),
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

    std.log.info("Playing WAV file...", .{});
    _ = c.pw_main_loop_run(data.loop);
    std.log.info("Playback finished", .{});
}
