const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const bench = b.addExecutable("bench", "src/bench.zig");
    bench.setBuildMode(mode);

    const bench_step = b.step("bench", "Compile the benchmarks");
    bench_step.dependOn(&b.addInstallArtifact(bench).step);

    const lib_tests = b.addTest("src/test.zig");
    lib_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&lib_tests.step);
}
