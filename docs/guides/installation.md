# Installation

zig-pkl needs Zig 0.17.0 and a `pkl` executable. It has no other dependencies.

## Add the package

```sh
zig fetch --save git+https://github.com/guanchzhou/zig-pkl
```

`zig fetch` records the commit and its hash in `build.zig.zon`. To pin a release instead, append the tag: `git+https://github.com/guanchzhou/zig-pkl#v0.1.0`.

Import the module in `build.zig`:

```zig
const zig_pkl = b.dependency("zig_pkl", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig_pkl", zig_pkl.module("zig_pkl"));
```

The same dependency provides the `zig-pkl-gen` code generator as `zig_pkl.artifact("zig-pkl-gen")`. See [Code generation](../codegen.md).

## Install Pkl

zig-pkl talks to `pkl server` over standard input and output. Install Pkl 0.25.3 or newer from the [Pkl releases](https://github.com/apple/pkl/releases) or with a package manager, for example `brew install pkl`. Code generation needs Pkl 0.32.2.

The library never searches for Pkl on its own. You pass the command that starts the server:

```zig
const manager = try zig_pkl.Manager.init(allocator, io, &.{ "pkl", "server" }, zig_pkl.Logger.noop);
```

Use an absolute path when `pkl` is not on `PATH`. The examples in this repository read the path from the `PKL_EXEC` environment variable and fall back to `pkl`.

## Check the setup

```sh
git clone https://github.com/guanchzhou/zig-pkl
cd zig-pkl
zig build test
zig build examples
```

`zig build examples` builds and runs every program in [`examples/`](../../examples). It fails when Pkl cannot be started.
