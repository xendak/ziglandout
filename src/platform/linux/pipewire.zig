const std = @import("std");
const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("spa/param/audio/format-utils.h");
});

// FIX: redo this path to a proper place?
const Wav = @import("wav.zig").Wav;

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

// following handmade_hero platform ideas
// ringbuffer + a single global sound buffer
const SOUND_BUFFER_SECONDS = 2;
const SOUND_BUFFER_SIZE = SAMPLE_RATE * SOUND_BUFFER_SECONDS * DEFAULT_CHANNELS;

const SoundBufferError = error{
    OutOfMemory,
};

const SoundBuffer = struct {
    samples: []f32, // Ring buffer of samples
    sample_rate: u32,
    channels: u16,

    // do we need a buffer this huge?
    play_cursor: std.atomic.Value(u64),
    write_cursor: std.atomic.Value(u64),

    const WriteRegion = struct {
        // This is the non wrapped part of our ring buffer
        region1: []f32,
        // This is the wrapped part till safe to write part.
        region2: []f32,

        // TODO: better name this?
        pub fn init(self: @This()) void {
            @memset(self.region1, 0);
            @memset(self.region2, 0);
        }
    };

    pub fn init(allocator: std.mem.Allocator) SoundBufferError!SoundBuffer {
        const samples_array = allocator.alloc(f32, SOUND_BUFFER_SIZE) catch return SoundBufferError.OutOfMemory;

        return .{
            .samples = samples_array,
            .sample_rate = SAMPLE_RATE,
            .channels = DEFAULT_CHANNELS,
            .play_cursor = std.atomic.Value(u64).init(0),
            .write_cursor = std.atomic.Value(u64).init(0),
        };
    }
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }

    pub fn getWriteRegion(self: @This(), start: u64, count: usize) WriteRegion {
        const buffer_size = self.samples.len;
        const start_index = start % buffer_size;
        const remaining_samples = buffer_size - start_index;
        if (count <= remaining_samples) {
            // we dont need to wrap
            return .{
                .region1 = self.samples[start_index..][0..count],
                .region2 = &.{},
            };
        } else {
            // we need to wrap
            return .{
                .region1 = self.samples[start_index..],
                .region2 = self.samples[0 .. count - remaining_samples],
            };
        }
    }
};

const SoundClip = struct {
    samples: []f32,
    channels: u16,
    sample_rate: u32,
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

const PlayingSound = struct {
    data: *const SoundClip,
    position: usize,
    volume: f32,
    loop: bool,
    active: bool,

    pub fn init(data: *const SoundClip, volume: f32, loop: bool) @This() {
        return .{
            .data = data,
            .position = 0,
            .volume = volume,
            .loop = loop,
            .active = true,
        };
    }

    pub fn restart(self: @This()) void {
        self.active = true;
        self.position = 0;
    }

    pub fn isPlaying(self: @This()) bool {
        return self.active and self.position < self.data.samples.len;
    }
};

const MAX_ACTIVE_SFX = 8;
const Audio = struct {
    music: ?PlayingSound,
    // sfx: [MAX_ACTIVE_SFX]?PlayingSound,
    // TODO: make multislot
    sfx: ?PlayingSound,

    master_volume: f32,
    music_volume: f32,
    sfx_volume: f32,

    pub fn init() @This() {
        return .{
            .music = null,
            // .sfx = [_]?PlayingSound{null} ** MAX_ACTIVE_SFX,
            .sfx = null,
            .master_volume = 1.0,
            .music_volume = 0.5,
            .sfx_volume = 1.0,
        };
    }

    pub fn triggerSfx(self: *@This(), clip: *const SoundClip) void {
        if (self.sfx) |*sfx| {
            if (sfx.isPlaying())
                return;
        }

        self.sfx = PlayingSound.init(clip, self.sfx_volume, false);
    }

    pub fn playMusic(self: *@This(), clip: *const SoundClip) void {
        self.music = PlayingSound.init(clip, self.music_volume, true);
    }
};

fn mixSounds(
    audio: *Audio,
    buffer: *SoundBuffer,
    start: u64,
    count: usize,
) void {
    const write_region = buffer.getWriteRegion(start, count);
    write_region.init();

    if (audio.music) |*music| {
        if (music.active) {
            mixSoundIntoBuffer(music, write_region.region1, buffer.channels);
            mixSoundIntoBuffer(music, write_region.region2, buffer.channels);
        }
    }

    if (audio.sfx) |*sfx| {
        if (sfx.active) {
            mixSoundIntoBuffer(sfx, write_region.region1, buffer.channels);
            mixSoundIntoBuffer(sfx, write_region.region2, buffer.channels);
        }
    }
}

fn mixSoundIntoBuffer(
    source: *PlayingSound,
    output: []f32,
    channels: u16,
) void {
    if (output.len == 0) return;
    if (!source.active) return;

    const frames_to_mix = output.len / channels;
    var frame: usize = 0;

    while (frame < frames_to_mix) : (frame += 1) {
        if (source.position >= source.data.samples.len) {
            if (source.loop) {
                source.position = 0;
            } else {
                source.active = false;
                return;
            }
        }

        for (0..channels) |ch| {
            const src_ch = if (ch < source.data.channels) ch else ch % source.data.channels;
            const sample_index = source.position + src_ch;

            if (sample_index < source.data.samples.len) {
                const src_sample = source.data.samples[sample_index] * source.volume;
                output[frame * channels + ch] += src_sample;
            }
        }
        source.position += source.data.channels;
    }
}

const PipewireData = struct {
    loop: ?*c.pw_thread_loop,
    stream: ?*c.pw_stream,
    sound_buffer: *SoundBuffer,
};

fn onProcess(user_data: ?*anyopaque) callconv(.c) void {
    var data: *PipewireData = @ptrCast(@alignCast(user_data.?));

    // FIX: check if actually paly data?

    const pw_buffer: ?*c.pw_buffer = c.pw_stream_dequeue_buffer(data.stream);
    if (pw_buffer == null) {
        std.log.err("out of buffer", .{});
        return;
    }
    defer _ = c.pw_stream_queue_buffer(data.stream, pw_buffer);

    const spa_buffer: ?*c.spa_buffer = pw_buffer.?.buffer;
    var dst: [*]f32 = @ptrCast(@alignCast(spa_buffer.?.datas[0].data));

    // TODO: get preferred format eventually
    const sample_size = @sizeOf(f32);
    const stride = sample_size * data.sound_buffer.channels;
    const max_frames = spa_buffer.?.datas[0].maxsize / stride;
    var n_frames = max_frames;

    if (pw_buffer.?.requested > 0) {
        n_frames = @min(pw_buffer.?.requested, n_frames);
    }

    const samples_to_read = n_frames * data.sound_buffer.channels;

    // check play and set write cursor
    const play_cursor = data.sound_buffer.play_cursor.load(.monotonic);
    const write_region = data.sound_buffer.getWriteRegion(play_cursor, samples_to_read);

    // FIX: maybe set this as function of writeRegion
    @memcpy(dst[0..write_region.region1.len], write_region.region1);
    if (write_region.region2.len > 0)
        @memcpy(dst[write_region.region1.len..][0..write_region.region2.len], write_region.region2);

    const play_cursor_pos = data.sound_buffer.play_cursor.fetchAdd(samples_to_read, .monotonic);
    std.log.debug("PlayCursor_pos: {}", .{play_cursor_pos});

    spa_buffer.?.datas[0].chunk.*.offset = 0;
    spa_buffer.?.datas[0].chunk.*.stride = @intCast(stride);
    // FIX: check this is it * stride or * sample_size
    spa_buffer.?.datas[0].chunk.*.size = @intCast(samples_to_read * stride);
}

fn onStateChanged(
    user_data: ?*anyopaque,
    old_state: c.pw_stream_state,
    state: c.pw_stream_state,
    err: [*c]const u8,
) callconv(.c) void {
    _ = old_state;
    _ = err;

    const data = @as(*PipewireData, @ptrCast(@alignCast(user_data.?)));

    if (state == c.PW_STREAM_STATE_STREAMING or state == c.PW_STREAM_STATE_ERROR) {
        c.pw_thread_loop_signal(data.loop, false);
    }
}

const stream_events = c.pw_stream_events{
    .version = c.PW_VERSION_STREAM_EVENTS,
    .process = onProcess,
    .state_changed = onStateChanged,
};

const AudioTime = struct {
    bytes_to_write: usize,
    cursor: u64,

    pub fn calculate(buffer: *SoundBuffer, fps: f32) @This() {
        const sample_rate_f32: f32 = @floatFromInt(buffer.sample_rate);
        const div: u32 = @intFromFloat(sample_rate_f32 / fps);

        const samples_per_frame = div * buffer.channels;

        const latency = samples_per_frame * SOUND_BUFFER_SECONDS;
        const play_cursor = buffer.play_cursor.load(.monotonic);
        const write_cursor = buffer.write_cursor.load(.monotonic);

        const target_cursor = play_cursor + latency;

        var bytes_to_write: usize = 0;
        if (target_cursor > write_cursor) {
            bytes_to_write = target_cursor - write_cursor;
        }

        return .{
            .bytes_to_write = bytes_to_write,
            .cursor = target_cursor,
        };
    }
};

const ResampleError = error{
    OutOfMemory,
};

// i Think this is wrong
// TODO: refactor this so that we can import anyfile and not just .wav
// FIX: not dupe, but just return inplace?
// this allocates memory the user needs to free
pub fn resampleSoundClip(
    allocator: std.mem.Allocator,
    sound: anytype,
    target_rate: u32,
) ResampleError!SoundClip {
    const src_rate = sound.fmt.sample_rate;
    const channels = sound.fmt.num_channels;

    if (src_rate == target_rate) {
        const samples = allocator.dupe(f32, sound.data) catch return ResampleError.OutOfMemory;
        return SoundClip{
            .sample_rate = src_rate,
            .channels = channels,
            .samples = samples,
        };
    }

    std.log.info("Resampling: {}Hz to {}Hz", .{ src_rate, target_rate });

    // FIX: why f64
    const src_rate_f: f64 = @floatFromInt(src_rate);
    const dst_rate_f: f64 = @floatFromInt(target_rate);
    const rate_ratio: f64 = dst_rate_f / src_rate_f;

    const src_frames = sound.data.len / channels;
    const dst_frames = @as(usize, @intFromFloat(src_rate_f * rate_ratio));
    const dst_samples = dst_frames * channels;

    const resampled: []f32 = allocator.alloc(f32, dst_samples) catch return ResampleError.OutOfMemory;
    errdefer allocator.free(resampled);

    // linear interpolate
    for (0..dst_frames) |frame| {
        const frame_f: f64 = @floatFromInt(frame);
        const src_frame_f: f64 = frame_f / rate_ratio;
        const src_idx: usize = @intFromFloat(@floor(src_frame_f));

        const frac: f64 = src_frame_f - @floor(src_frame_f);

        const next_idx = @min(src_idx + 1, src_frames - 1);

        for (0..channels) |ch| {
            const idx1 = src_idx * channels + ch;
            const idx2 = next_idx * channels + ch;
            const sample1 = sound.data[idx1];
            const sample2 = sound.data[idx2];

            const interpolated = sample1 + @as(f32, @floatCast(frac)) * (sample2 - sample1);
            resampled[frame * channels + ch] = interpolated;
        }
    }

    return SoundClip{
        .samples = resampled,
        .channels = channels,
        .sample_rate = target_rate,
    };
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

    std.debug.print("Pipewire WAV Player\n\n", .{});
    const sfx = try Wav.init(gpa, audio_name);
    defer sfx.deinit(gpa);

    const bg_music = try Wav.init(gpa, "./assets/sinewave_pcms32le.wav");
    defer bg_music.deinit(gpa);

    std.log.debug("BG: WAV loaded: {} channels, {} Hz, {} bits, {} samples\n", .{
        bg_music.fmt.num_channels,
        bg_music.fmt.sample_rate,
        bg_music.fmt.bits_per_sample,
        bg_music.data.len / bg_music.fmt.num_channels,
    });

    std.log.debug("SFX: WAV loaded: {} channels, {} Hz, {} bits, {} samples\n", .{
        sfx.fmt.num_channels,
        sfx.fmt.sample_rate,
        sfx.fmt.bits_per_sample,
        sfx.data.len / sfx.fmt.num_channels,
    });

    const sfx_clip = try resampleSoundClip(gpa, sfx, bg_music.fmt.sample_rate);
    defer gpa.free(sfx_clip.samples);

    const bg = SoundClip{
        .samples = bg_music.data,
        .channels = bg_music.fmt.num_channels,
        .sample_rate = bg_music.fmt.sample_rate,
    };

    var sound_buffer = try SoundBuffer.init(gpa);
    defer sound_buffer.deinit(gpa);

    var audio = Audio.init();
    audio.playMusic(&bg);

    // Pipewire Boilerplate

    var data: PipewireData = .{
        .loop = undefined,
        .stream = undefined,
        .sound_buffer = &sound_buffer,
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

    // FIX: this to use proper stuff
    var audio_info = c.spa_audio_info_raw{
        .format = c.SPA_AUDIO_FORMAT_F32,
        .channels = DEFAULT_CHANNELS,
        .rate = SAMPLE_RATE,
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

    // fps logic
    var timer = try std.time.Timer.start();
    const target_fps: f32 = 60.0;
    const target_ns_per_frame: u64 = @intFromFloat(std.time.ns_per_s / target_fps);
    var frame_count: u64 = 0;
    // Mix loop
    while (frame_count < 600) : (frame_count += 1) {
        const start = timer.read();

        const audio_time = AudioTime.calculate(&sound_buffer, target_fps);
        if (audio_time.bytes_to_write > 0) {
            const write_cursor = sound_buffer.write_cursor.load(.monotonic);
            mixSounds(
                &audio,
                &sound_buffer,
                write_cursor,
                audio_time.bytes_to_write,
            );
            sound_buffer.write_cursor.store(write_cursor + audio_time.bytes_to_write, .monotonic);
        }

        // play sound every now and then
        if (frame_count % 60 == 30) {
            audio.triggerSfx(&sfx_clip);
            std.log.info("Frame {}: Triggered sound effect", .{frame_count});
        }

        // update time
        const end = timer.read();
        const elapsed = end - start;
        if (elapsed < target_ns_per_frame) {
            // we need to sleep till next cycle as we finished everything for this one.
            // dont burn cpu?
            const sleep_ns = target_ns_per_frame - elapsed;
            std.Thread.sleep(sleep_ns);
        }

        // log every second.
        if (frame_count % 60 == 0) {
            const play_cursor = sound_buffer.play_cursor.load(.monotonic);
            const write_cursor = sound_buffer.write_cursor.load(.monotonic);
            const delta = write_cursor - play_cursor;
            const delta_ms = (@as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(DEFAULT_CHANNELS))) /
                (@as(f32, @floatFromInt(SAMPLE_RATE)) / 1000.0);

            std.log.info("Audio buffer: {d:.2}ms ahead", .{delta_ms});
        }
    }
}
