# External readers

An external reader is a separate program that Pkl starts to serve a URI scheme. Pkl is the server and the reader is the client: Pkl writes requests to the reader's standard input and reads answers from its standard output. External readers need Pkl 0.27 or newer.

zig-pkl covers both sides.

## Write a reader program

`ExternalClient` runs the reader side of the protocol with the same `ModuleReader` and `ResourceReader` interfaces as [in-process readers](readers.md):

```zig
pub fn main(init: std.process.Init) !void {
    var vault = Vault{};
    const client = zig_pkl.ExternalClient{ .resource_readers = &.{vault.resourceReader()} };
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try client.run(init.gpa, &input.interface, &output.interface);
}
```

`run` returns when Pkl sends its close message or closes standard input. Standard output carries protocol frames only, so write diagnostics to standard error.

The resulting executable works with any Pkl host, not only zig-pkl: the `pkl` CLI (`--external-resource-reader vault=./vault-reader`), `PklProject` settings, and other language bindings.

## Use a reader from zig-pkl

```zig
var options = zig_pkl.Options.restricted();
options.allowed_resources = &.{"vault:"};
options.external_resource_readers = &.{.{
    .scheme = "vault",
    .executable = "/usr/local/bin/vault-reader",
    .arguments = &.{"--region", "eu-west-1"},
}};
const evaluator = try manager.createEvaluator(options, &rejected);
```

Pkl owns the reader process: it starts the executable when it needs the scheme and stops it when the evaluator closes. External readers can also be declared in `PklProject` under `evaluatorSettings`; see [Projects](projects.md) for how their paths resolve.

[`examples/external-reader`](../../examples/external-reader/main.zig) is a single program that plays both roles: run without arguments it evaluates Pkl, and Pkl starts it again with `--serve` as the reader.
