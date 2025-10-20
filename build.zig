const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "wayland",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const p_step = b.step("p", "Build and run with ReleaseFast");
    const fast_exe = b.addExecutable(.{
        .name = "wayland-fast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run_fast_cmd = b.addRunArtifact(fast_exe);
    if (b.args) |args| {
        run_fast_cmd.addArgs(args);
    }

    p_step.dependOn(&run_fast_cmd.step);

    // AUDIO
    const audio = b.addExecutable(.{
        .name = "zigaudio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/linux/pipewire.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    audio.addCSourceFile(.{
        .file = b.path("src/platform/linux/audio.c"),
        .flags = &.{"-std=gnu99"},
    });

    // audio.linkSystemLibrary2(
    //     "pipewire-0.3",
    //     .{ .use_pkg_config = .force },
    // );
    audio.linkSystemLibrary2(
        "libpipewire-0.3",
        .{
            .use_pkg_config = .force,
        },
    );
    audio.linkLibC();

    const audio_step = b.step("audio", "audio the app");

    const audio_cmd = b.addRunArtifact(audio);
    audio_cmd.setCwd(b.path("./"));
    audio_step.dependOn(&audio_cmd.step);

    audio_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        audio_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
