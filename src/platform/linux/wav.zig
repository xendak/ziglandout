const std = @import("std");

const conv = @import("conversion.zig");

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

pub const Wav = struct {
    fmt: FormatChunk,
    extensible: ?ExtensibleChunk,
    // we're focing f32 internally
    data: []f32,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn init(allocator: std.mem.Allocator, sound_file: []const u8) !@This() {
        return loadWave(allocator, sound_file) catch {
            return error.FailedToLoadWav;
        };
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
            conv.unsignedToFloat(u8, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        16 => {
            conv.signedToFloat(i16, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
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
            conv.signedToFloat(i24, @sizeOf(i24), i24_bytes, f32, dst_stride, dst_bytes, samples);
        },
        32 => {
            switch (format_chunk.fmt) {
                .ieee => {
                    @memcpy(f32_samples, std.mem.bytesAsSlice(f32, raw_buffer));
                },
                .pcm, .extensible => {},
                else => return error.UnsupportedFormat,
            }
            conv.signedToFloat(i32, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
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
            conv.signedToFloat(i32, src_stride, raw_buffer, f32, dst_stride, dst_bytes, samples);
        },
        else => return error.UnsupportedBitsPerSample,
    }

    return .{ .fmt = format_chunk, .extensible = ext_chunk, .data = f32_samples };
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
