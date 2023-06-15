const std = @import("std");

const bench = @import("src/bench.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const mesh = b.addModule("mesh", .{
        .source_file = .{ .path = "src/mesh.zig" },
    });

    const bench_step = b.step("bench", "Compile the benchmarks");

    const bench_allocator = b.option(bench.Alloc, "allocator", "The allocator to benchmark; defaults to mesh") orelse .mesh;

    inline for (std.meta.fields(@TypeOf(bench.benchmarks))) |field| {
        for (std.meta.tags(bench.Alloc)) |alloc| {
            inline for (std.meta.fields(@TypeOf(@field(bench.benchmarks, field.name)))) |sub_field| {
                const bench_exe = addBenchmark(b, field.name, sub_field.name, optimize, alloc);
                const bench_install = b.addInstallArtifact(bench_exe);
                if (alloc == bench_allocator) {
                    bench_step.dependOn(&bench_install.step);
                }
            }
        }
    }

    const standalone_test_step = b.step("standalone", "Build the standalone tests");

    const standalone_options = b.addOptions();
    const standalone_pauses = b.option(bool, "pauses", "Insert pauses into standalone tests (default: false)") orelse false;
    standalone_options.addOption(bool, "pauses", standalone_pauses);

    for (standalone_tests) |test_name| {
        const exe_name = test_name[0 .. test_name.len - 4];
        const test_exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = .{ .path = b.pathJoin(&.{ "test", test_name }) },
            .optimize = optimize,
        });
        test_exe.addModule("mesh", mesh);
        test_exe.addOptions("build_options", standalone_options);
        test_exe.override_dest_dir = .{ .custom = "test" };

        const install_step = b.addInstallArtifact(test_exe);
        standalone_test_step.dependOn(&install_step.step);
    }

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .optimize = optimize,
    });

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
    optimize: std.builtin.Mode,
    alloc: bench.Alloc,
) *std.build.Step.Compile {
    const step_name = std.fmt.comptimePrint("bench-{s}-{s}", .{ name, subname });

    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "name", name);
    bench_opts.addOption([]const u8, "subname", subname);
    bench_opts.addOption(bench.Alloc, "allocator", alloc);

    const bench_exe = b.addExecutable(.{
        .name = step_name,
        .root_source_file = .{ .path = "src/bench.zig" },
        .optimize = optimize,
    });
    bench_exe.addOptions("@benchmark", bench_opts);
    bench_exe.override_dest_dir = .{ .custom = b.pathJoin(&.{ "bench", @tagName(optimize), @tagName(alloc) }) };

    return bench_exe;
}
