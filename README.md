# Zig Meshing Allocator

This project is an attempt at implementing a meshing allocator for Zig. The structure of the allocator is a combination of ideas taken from [rpmalloc](https://github.com/mjansson/rpmalloc), and the papers describing [mimalloc](https://www.microsoft.com/en-us/research/publication/mimalloc-free-list-sharding-in-action) and [Mesh](https://people.cs.umass.edu/~emery/pubs/berger-pldi2001.pdf).

## WIP

This project is under development and should be currently be considered experimental/expoloratory; there is no documentation and it is not well tested. There are likely a variety of issues—contributions of any kind (PRs, suggestions for improvements, resources or ideas related to benchmarking or testing) are welcome.

## Usage

To use the allocator in your own project you can use the Zig package manager by putting this in your `build.zig`
```zig
pub fn build(b: *std.Build) void {
    // -- snip --
    const mesh = b.dependency("mesh").module("mesh"); // get the mesh allocator module
    // -- snip --
    exe.addModule(mesh); // add the mesh allocator module as a depenency of exe
    // -- snip --
}
```
and this to the dependencies section of your `build.zig.zon`.
```zig
    .mesh = .{
        .url = "https://github.com/dweiller/zig-mesh/archive/[[COMMIT_SHA]].tar.gz"
    },
```
where `[[COMMIT_SHA]]` should be replaced with full SHA of the desired revision. You can then import and
initialise an instance of the allocator as follows:
```zig
const mesh = @import("mesh");
pub fn main() !void {
    var mesher = try mesh.Allocactor.init(.{});
    defer mesher.deinit();

    const allocator = mesher.allocator();
    // -- snip --
}
```

## Notes

  - meshing depends on the virtual memory mapping facilities of the operating system, the current implementation works on Linux, with other systems untested
  - memory is mapped (and checked for meshing) in 64KiB slabs dedicated to a given size class, with one page of metadata heading each slab (this means the `std.mem.page_size` must be <= 32KiB)
  - no consideration has yet been given to multi-threaded use
  - the current implementation uses one file descriptor per slab, which might cause some applications to hit file descriptor limits
