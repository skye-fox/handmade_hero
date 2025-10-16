const std = @import("std");
const builtin = @import("builtin");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "handmade_hero",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();

    const zigwin32 = b.dependency("zigwin32", .{});
    const zigwin32_module = zigwin32.module("win32");
    exe.root_module.addImport("zigwin32", zigwin32_module); // update: zig fetch --save "git+https://github.com/marlersoft/zigwin32#main"

    if (exe.root_module.resolved_target.?.result.os.tag == .linux) {
        // Create Wayland scanner
        const scanner = Scanner.create(b, .{});
        const wayland_module = b.createModule(.{
            .root_source_file = scanner.result,
        });

        // Add required Wayland protocols
        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

        // Generate bindings for needed interfaces
        scanner.generate("wl_compositor", 4);
        scanner.generate("wl_shm", 1);
        scanner.generate("xdg_wm_base", 1);
        scanner.generate("wl_seat", 9);
        scanner.generate("wl_output", 4);

        exe.root_module.addImport("wayland", wayland_module); // update: zig fetch --save "git+https://codeberg.org/ifreund/zig-wayland#main"
        exe.root_module.linkSystemLibrary("wayland-client", .{});
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
