const std = @import("std");

const bench = @import("src/bench.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const bench_step = b.step("bench", "Compile the benchmarks");

    const bench_allocator = b.option(bench.Alloc, "allocator", "The allocator to benchmark; defaults to mesh") orelse .mesh;

    inline for (std.meta.fields(@TypeOf(bench.benchmarks))) |field| {
        for (std.meta.tags(bench.Alloc)) |alloc| {
            inline for (std.meta.fields(@TypeOf(@field(bench.benchmarks, field.name)))) |sub_field| {
                const bench_exe = addBenchmark(b, field.name, sub_field.name, mode, alloc);
                if (alloc == bench_allocator) {
                    bench_step.dependOn(&bench_exe.install_step.?.step);
                }
            }
        }
    }

    const standalone_test_step = b.step("standalone", "Build the standalone tests");

    for (standalone_tests) |test_name| {
        const test_exe = b.addExecutable(test_name, b.pathJoin(&.{ "test", test_name }));
        test_exe.setBuildMode(mode);
        test_exe.addPackagePath("mesh", "src/mesh.zig");
        test_exe.override_dest_dir = .{ .custom = "test" };

        const install_step = b.addInstallArtifact(test_exe);
        standalone_test_step.dependOn(&install_step.step);
    }

    const lib_tests = b.addTest("src/test.zig");
    lib_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&lib_tests.step);

    b.default_step = test_step;
}

const standalone_tests = [_][]const u8{
    "create-destroy-loop.zig",
};

fn addBenchmark(
    b: *std.build.Builder,
    comptime name: []const u8,
    comptime subname: []const u8,
    mode: std.builtin.Mode,
    alloc: bench.Alloc,
) *std.build.LibExeObjStep {
    const step_name = std.fmt.comptimePrint("bench-{s}-{s}", .{ name, subname });

    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "name", name);
    bench_opts.addOption([]const u8, "subname", subname);
    bench_opts.addOption(bench.Alloc, "allocator", alloc);

    const bench_exe = b.addExecutable(step_name, "src/bench.zig");
    bench_exe.setBuildMode(mode);
    bench_exe.addPackage(bench_opts.getPackage("@benchmark"));
    bench_exe.override_dest_dir = .{ .custom = b.pathJoin(&.{ "bench", @tagName(mode), @tagName(alloc) }) };

    _ = b.addInstallArtifact(bench_exe);
    return bench_exe;
}
