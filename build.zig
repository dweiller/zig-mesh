const std = @import("std");

const bench = @import("src/bench.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const bench_step = b.step("bench", "Compile the benchmarks");

    inline for (std.meta.fields(@TypeOf(bench.benchmarks))) |field| {
        const name = field.name;
        const step_name = "bench-" ++ name;

        const bench_opts = b.addOptions();
        bench_opts.addOption([]const u8, "name", name);

        const bench_exe = b.addExecutable(step_name, "src/bench.zig");
        bench_exe.setBuildMode(mode);
        bench_exe.addPackage(bench_opts.getPackage("@benchmark"));
        bench_exe.override_dest_dir = .{ .custom = b.pathJoin(&.{ "bench", @tagName(mode) }) };
        bench_exe.install();

        const run_step = bench_exe.run();
        run_step.step.dependOn(&bench_exe.install_step.?.step);

        const step = b.step(step_name, "Run the " ++ name ++ " benchmark");
        step.dependOn(&run_step.step);

        bench_step.dependOn(&run_step.step);
    }

    const lib_tests = b.addTest("src/test.zig");
    lib_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&lib_tests.step);
}
