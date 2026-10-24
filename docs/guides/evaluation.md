# Evaluation

An evaluator turns a module, or an expression inside a module, into a value. You read that value either as a typed Zig value or as a dynamic tree.

## Sources

`zig_pkl.Source` names what to evaluate:

- `Source.uri("file:///srv/app/config.pkl")` loads a module by URI. Use `uri.fromFile(allocator, io, path)` to build the `file:` URI of a path; it resolves relative paths and symlinks the way Pkl expects.
- `Source.text("port = 8080")` evaluates inline text as the module `repl:text`. Relative imports from inline text do not resolve, so import by absolute URI.

Any URI scheme an evaluator allows works, including `package:`, `modulepath:`, and schemes served by your own [readers](readers.md).

## Whole modules and expressions

```zig
var tree = try evaluator.evaluateSource(source, null, &failure);       // the module
var port = try evaluator.evaluateSource(source, "port", &failure);     // one expression
var url = try evaluator.evaluateSource(source, "url(\"/health\")", &failure);
```

An expression is evaluated inside the module, so it can call the module's functions and read its properties. See [`examples/expressions`](../../examples/expressions/main.zig).

## Typed values

`evaluateInto` evaluates and copies the result into a Zig type:

```zig
const App = struct {
    name: []const u8,
    port: u16,
    timeout: zig_pkl.convert.Duration,
    max_upload: zig_pkl.convert.DataSize,
    tags: []const []const u8,
    limits: zig_pkl.convert.Map([]const u8, i64),
    database: struct { host: []const u8, port: u16 = 5432 },

    pub const pkl_names = .{ .max_upload = "maxUpload" };
};

const app = try evaluator.evaluateInto(App, allocator, source, null, &failure);
defer zig_pkl.convert.freeInto(App, allocator, app);
```

`convert.into` and `convert.from` do the same conversion on a tree you already have. The supported Zig types are:

| Pkl | Zig |
| --- | --- |
| `Boolean` | `bool` |
| `Int`, `Int8` to `UInt64` | any integer type; out-of-range values fail with `error.Overflow` |
| `Float`, `Int` | `f32`, `f64` |
| `String` | `[]const u8` |
| `List`, `Listing`, `Set` | slices |
| `Map`, `Mapping` | `convert.Map(K, V)` |
| `Pair` | `convert.Pair(A, B)` |
| `Duration`, `DataSize` | `convert.Duration`, `convert.DataSize` |
| `Regex`, `Bytes`, `IntSeq` | `convert.Regex`, `convert.Bytes`, `convert.IntSeq` |
| `null` | optionals |
| string literal unions | enums |
| classes and `Dynamic` objects | structs |
| unions of classes | tagged unions |
| `Any`, `unknown` | `convert.Dynamic`, an owned copy of the tree |
| `pkl:ref` references | `convert.Reference(D, T)` |

A `Dynamic` object decodes from its properties only, so `tags { "a"; "b" }` in an untyped module does not fill a slice; write `tags = new Listing { "a"; "b" }` or declare the property's type. Struct fields match Pkl property names. Declare `pkl_names` for fields named differently, `pkl_class` to tie a struct to a Pkl class, and `pkl_subclasses` for subclasses it also accepts. Fields with defaults may be missing from the value. The [`convert` reference](../../src/value/convert.zig) lists the rules for picking a union member.

[Code generation](../codegen.md) writes these types for you from the Pkl module. See [`examples/typed`](../../examples/typed/main.zig) for hand-written types.

## Dynamic values

`evaluateSource` returns a `value.Tree`. Its `root` is a `zig_pkl.Value`, a tagged union with one member per pkl-binary kind: `object`, `list`, `listing`, `set`, `map`, `mapping`, `string`, `int`, `float`, `duration`, `data_size`, `pair`, `regex`, `bytes`, `class`, `type_alias`, `reference`, and others.

```zig
var tree = try evaluator.evaluateSource(source, null, &failure);
defer tree.deinit();
const name = zig_pkl.value.findProperty(tree.root, "name").?.string;
for (tree.root.object.members) |member| switch (member) {
    .property => |property| std.debug.print("{s}\n", .{property.name}),
    .entry => |entry| _ = entry,
    .element => |element| _ = element,
};
```

Lists keep their kind: a `List` arrives as `.list` and a `Listing` as `.listing`, so the distinction survives a round trip through `value.encode`. See [`examples/dynamic`](../../examples/dynamic/main.zig).

## Module output

A module renders its output through `output`. Evaluate the parts you need as expressions:

```zig
var text = try evaluator.evaluateSource(source, "output.text", &failure);
var files = try evaluator.evaluateSource(source, "output.files.toMap().mapValues((_, file) -> file.text)", &failure);
var bytes = try evaluator.evaluateSource(source, "output.bytes", &failure); // Pkl 0.29 and newer
```

Set `Options.output_format` to a `pkl eval --format` name such as `"json"`, `"yaml"`, `"pcf"`, `"plist"`, `"properties"`, `"textproto"`, `"jsonnet"`, or `"xml"` to choose the renderer for modules that do not set one, as `pkl eval --format` does. See [`examples/output`](../../examples/output/main.zig).
