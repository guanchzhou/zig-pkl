# Code generation

`zig-pkl-gen` turns Pkl modules into Zig types that decode with `zig_pkl.convert`. Each module becomes one Zig file. The generated `decode`, `deinit`, and `load` helpers use the same ownership rules as the typed core: the caller owns every decoded value and releases it with `deinit` and the allocator it decoded with.

Generation needs Pkl 0.32.2. The generator runs `pkl server` from `--pkl`, `PKL_EXEC`, or `pkl` on `PATH`, in that order.

## Quick start

```pkl
// pkl/Service.pkl
@zig.Package { name = "service" }
module example.Service

import "@zig/zig.pkl"

host: String = "127.0.0.1"

@zig.Name { value = "listen_port" }
port: UInt16 = 8080

routes: Listing<Route>

class Route {
  path: String
}
```

```sh
zig-pkl-gen --library path/to/zig-pkl --project-dir . -o src/bindings pkl/Service.pkl
```

```zig
const Service = @import("bindings").service;

var failure: ?[]u8 = null;
defer if (failure) |text| manager.allocator.free(text);
var service = try Service.load(allocator, evaluator, .uri(module_uri), &failure);
defer service.deinit(allocator);
std.debug.print("{s}:{d}\n", .{ service.host, service.listen_port });
```

`load` evaluates a module that amends or matches the schema. `decode` converts an already evaluated `zig_pkl.Value`. Both return `zig_pkl.convert.Error` values such as `error.TypeMismatch` and `error.MissingField` when the data does not fit the bindings.

[`examples/codegen`](../examples/codegen) is a complete consumer: a separate Zig package that depends on `zig_pkl` by path, checks in its bindings, and regenerates them with its own `zig build codegen` step.

## The `@zig` annotations

The annotations live in [`codegen/zig.pkl`](../codegen/zig.pkl), published as the Pkl package `package://pkg.pkl-lang.org/github.com/guanchzhou/zig-pkl/zig`. Its version matches the zig-pkl release. Depend on it from a `PklProject` and run `pkl project resolve`:

```pkl
// PklProject
amends "pkl:Project"

dependencies {
  ["zig"] { uri = "package://pkg.pkl-lang.org/github.com/guanchzhou/zig-pkl/zig@0.1.1" }
}
```

A project can also depend on a checkout directly with `["zig"] = import("path/to/zig-pkl/codegen/PklProject")`. Modules then import the annotations as `import "@zig/zig.pkl"`.

| Annotation | Applies to | Effect |
| --- | --- | --- |
| `@zig.Package { name = "a.b" }` | module | Writes the module to `a/b.zig`, reachable from the index as `a.b`. |
| `@zig.Name { value = "id" }` | class, type alias, property | Uses `id` as the Zig name. |
| `@zig.Field { boxed = true }` | property | Stores the value behind `*const`. |
| `@zig.Field { type = "..." }` | property | Uses the Zig type expression verbatim. It must be a single type expression without comments, blocks, or declarations, and decode with `zig_pkl.convert`. |

The annotations validate their arguments, so an invalid `@zig.Name` fails during Pkl evaluation with the constraint that it violates.

## Type mapping

| Pkl | Zig |
| --- | --- |
| `Boolean` | `bool` |
| `Int` | `i64` |
| `Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32`, `UInt` | `i8`, `i16`, `i32`, `u8`, `u16`, `u32`, `u64` |
| `Float`, `Number` | `f64` |
| `String`, `Char`, `Uri` | `[]const u8` |
| `T?` | `?T` |
| `List<T>`, `Listing<T>`, `Set<T>`, `Collection<T>` | `[]const T` |
| `Map<K, V>`, `Mapping<K, V>` | `zig_pkl.convert.Map(K, V)`, in evaluation order |
| `Pair<A, B>` | `zig_pkl.convert.Pair(A, B)` |
| `Duration`, `DataSize` | `zig_pkl.convert.Duration`, `zig_pkl.convert.DataSize` |
| `Regex`, `Bytes`, `IntSeq` | `zig_pkl.convert.Regex`, `zig_pkl.convert.Bytes`, `zig_pkl.convert.IntSeq` |
| `Dynamic`, `Any`, `Typed`, `Object` | `zig_pkl.convert.Dynamic`, an owned deep copy of the value |
| `ref.Reference<D, T>` from `pkl:ref` | `zig_pkl.convert.Reference(D, T)`: the domain, the access path, and the raw value |
| `ref.Access` | `zig_pkl.convert.Access` |
| `"a" \| "b"` | `enum { a, b }` |
| `A \| B` | `union(enum) { a: A, b: B }` |
| class, including a `local` class | `struct` |
| abstract class with subclasses | `union(enum)` with one member per concrete subclass |
| module | the generated file's own struct |
| `typealias X = T` | `pub const X = T;` |

Details:

- Properties become `snake_case` fields; classes and type aliases keep their names. A field whose Pkl name differs is listed in `pkl_names`, which `convert` uses to find the property.
- Inherited properties are copied into each subclass. A subclass property redeclared without a type, such as `port = 8443`, keeps the parent's type, `@zig.Name`, `@zig.Field`, and documentation, and takes the new default. A `hidden` property, and an override that does not repeat `hidden`, stays out of the struct. Each struct records its Pkl class in `pkl_class` and its known subclasses in `pkl_subclasses`, so a field of an open class type also decodes instances of its subclasses.
- A property must declare a type. An untyped property that does not override one is an error; declare `Any` or `Dynamic` to keep the value dynamic. Unsupported `pkl:base` classes and aliases, and unbound type variables, are errors too.
- A union of string literals with other types becomes a tagged union whose literal members are `void`. `Null` in a union makes the result optional.
- A union value decodes into, in order: a literal member; the member whose `pkl_class` is the value's class; a member listing it in `pkl_subclasses`; a member of exactly the value's kind (an `Int` only into an integer, a `Float` only into a float); any member that accepts the value's shape; a `Dynamic` member. `Float | Int` and `Int | Float` therefore decode `1` and `1.5` the same way. Members that accept the same values, such as `List<Int> | Set<Int>` or `Int8 | Int16`, are rejected.
- Unions, enums, and classes declared inline get a name derived from their owner: `Route.method` becomes `RouteMethod`; a module property `mode` becomes `Mode`. Names that are taken gain a numeric suffix.
- Generic type aliases are expanded where they are used.
- A type that contains itself by value, directly, through other modules, or through a nullable alias such as `typealias MaybeNode = Node?`, has those fields stored as `*const T` (`?*const T` for optionals). Fields reached through slices or maps stay by value.
- Modules are ordered by URI, and the members of a subclass union are ordered by qualified class name. Properties, classes, and the members of an inline union keep their Pkl declaration order. Either way, the order of the modules on the command line does not change the output.
- Defaults are emitted for booleans, integers that fit the field type, floats, strings, enum members, literal union members, `null`, durations, data sizes, and listings, lists, sets, maps, and mappings of those. Defaults that are objects stay with Pkl, and the field has no Zig default. Any other default that cannot be represented, or that fails to evaluate, is reported as a warning and leaves the field without a Zig default.

## Output layout

One file is written per described module, plus the index file (`root.zig` by default). `--index-file` takes a normalized relative `.zig` path inside the output directory, such as `gen/all.zig`; the module files are placed in its directory. Absolute paths, `..`, `.`, empty segments, backslashes, and names without `.zig` are usage errors.

```zig
//! Bindings for every generated Pkl module. Regenerate this file instead of editing it.

pub const fixture = struct {
    pub const app = @import("fixture/app.zig");
};
```

The path comes from, in order: the longest matching `--package` mapping, `@zig.Package`, and finally the module name, with each segment converted to `snake_case`. A mapping matches a module name (`app.config`), a name prefix (`app`), or, when it contains `:`, a module URI or URI prefix. The unmatched part of the name or URI is appended:

```sh
zig-pkl-gen --package 'projectpackage://example.com/shared@1.0.0#/=vendor.shared' ...
```

Generated files import `std` and the module `zig_pkl`, so the consuming module must provide `zig_pkl` under that name.

## Incremental regeneration

The generator records every file it writes, with its SHA-256, in `.zig-pkl-gen-manifest` in the output directory. On the next run it writes only files that differ and deletes files that are listed in the manifest but no longer planned.

It never replaces or deletes a file that it did not write or that changed since: a planned path occupied by a handwritten file, a listed file that was edited, a malformed manifest, or a manifest entry outside the output directory fails the run before anything is written. `--force` overrides this and adopts the files. `--check` writes nothing and exits with status 1 when any file, including the manifest, would change, which suits CI.

## Type checking

Before writing, the generator compiles the bindings with `zig test -fno-emit-bin` against the zig-pkl sources, staging them in a temporary directory that it removes afterwards. Bindings that do not type-check fail the run with the compiler's errors and leave the output directory unchanged. `--library` (or `ZIG_PKL_LIBRARY`) names the zig-pkl source directory, `--zig` (or `ZIG`) the compiler, and `--no-verify` skips the check.

## Sandbox

Pkl evaluates the defaults while describing the modules. Resource reads (`file:`, `env:`, `prop:`, `https:`, and every other resource scheme) are denied, environment variables and external properties are empty, and no resource readers run. A default that reads a resource fails to evaluate, is reported as a warning, and is left out of the bindings. `--allow-resource <regex>` allows reads of matching URIs; allowing `env:` or `prop:` also exposes the environment or the properties.

`pkl:platform` is part of the standard library, and the module allowlist cannot exclude it. In a described module that imports it, or whose source mentions it, a default is copied only when the declaration is a literal scalar (`"stable"`, `1`, `true`, `1.s`, `4.mb`). Every other default in that module is reported as a warning and left out, so a local or another property cannot carry the host operating system or architecture into the bindings. The generator reads the source of every described module, including the file behind a local project dependency, and nothing else. An `import(...)` expression whose argument is not a plain string, or contains an escape, is treated the same way. When a module's source cannot be read, none of its defaults are copied. A default in a module that does not mention `pkl:platform` can still copy a host value by reading a property of some other module. Other module imports are evaluated. An import of a local file can therefore copy that file's values into a default; those values are part of the module being described.

The same modules, options, and Pkl version produce the same files on every platform, aside from a default that copies a host value from a module the declaration does not identify as `pkl:platform`. Every file is canonicalized with the Zig formatter. `--library` (or `ZIG_PKL_LIBRARY`) is required for the default type-check; `--no-verify` writes the files without it.

## Diagnostics

The generator reports every problem it finds in one run, each with the `uri:line:column` of the Pkl declaration:

```text
file:///.../collision.pkl:4:1: error: properties `fooBar` and `foo_bar` both map to field `foo_bar`; rename one with `@zig.Name`
```

Rejected inputs include name collisions between fields, declarations, files, and index namespaces; invalid `@zig.Name` and `@zig.Package` values; `@zig.Name` on a module, which `@zig.Package` replaces; `@zig` annotations imported from a module other than the zig-pkl annotations package; function, `nothing`, undeclared, and unsupported types; and unions whose members accept the same values. Each problem is reported once. Pkl evaluation errors, including annotation constraint failures, are reported verbatim. Warnings, such as defaults that cannot be represented, are printed without failing the run.

## CLI

```text
Usage: zig-pkl-gen [options] <module>...

  -o, --output-dir <dir>    Directory for generated files (required)
  --project-dir <dir>       Directory with the PklProject that resolves @dependency imports
  --package <match>=<path>  Place modules whose name or URI starts with <match> under <path>
  --index-file <path>       Index file, a relative .zig path inside the output
                            directory; modules go in its directory (default: root.zig)
  --pkl <path>              Pkl executable (default: $PKL_EXEC, then pkl on PATH)
  --allow-resource <regex>  Let defaults read resources whose URI matches this Pkl
                            pattern, such as file: or env:HOME (repeatable; default: none)
  --library <dir>           zig-pkl source directory used to type-check the bindings
                            (default: $ZIG_PKL_LIBRARY)
  --zig <path>              Zig executable for type-checking (default: $ZIG, then zig)
  --no-verify               Write the bindings without type-checking them
  --check                   Exit with status 1 when any generated file is out of date
  --force                   Overwrite or delete files the generator did not write
  -h, --help                Show this help
  --version                 Print the zig-pkl version
```

Exit status is 0 on success, 1 when generation fails, type-checking fails, a file is not owned by the generator, or `--check` finds stale files, and 2 for usage errors.

## Library API

`zig_pkl.codegen.generate(allocator, io, manager, options, &diagnostics)` runs the same pipeline on an existing `Manager`; `options.verify` is either `.skip` or `.{ .check = ... }` with the toolchain to type-check with. `generateWithExecutable` starts and stops its own server. `zig_pkl.codegen.plan.plan` is the pure planning stage: it maps a `schema.Description` to files without Pkl or the file system. `zig_pkl.codegen.verify.check` type-checks a plan, and `writeFiles` applies one to a directory under the manifest rules above.

## Build integration

From a dependent package:

```zig
const zig_pkl = b.dependency("zig_pkl", .{ .target = target, .optimize = optimize });
const codegen = b.addRunArtifact(zig_pkl.artifact("zig-pkl-gen"));
codegen.setCwd(b.path("."));
codegen.addArgs(&.{ "--zig", b.graph.zig_exe, "--library" });
codegen.addDirectoryArg(zig_pkl.path("."));
codegen.addArgs(&.{ "--project-dir", ".", "-o", "src/bindings", "pkl/Service.pkl" });
codegen.addPassthruArgs();
b.step("codegen", "Regenerate the Pkl bindings").dependOn(&codegen.step);
```

Checking the bindings in keeps ordinary builds free of a Pkl dependency. `zig build codegen -- --check` verifies them.

In this repository:

- `zig build codegen` regenerates `tests/codegen/snapshots` and `examples/codegen/src/bindings`. Arguments after `--` are passed to every run.
- `zig build codegen-test` runs the planner tests, which type-check every planned fixture; the live tests against Pkl, which skip when Pkl is absent unless `ZIG_PKL_REQUIRE_PKL=1`; decoding of an evaluated configuration through the generated loaders; compilation of the snapshot bindings for x86_64 and aarch64 Linux, x86_64 and aarch64 macOS, x86_64 Windows, riscv64 Linux, and x86 Linux; and the example package's tests.

## Limitations

- An abstract class becomes a union of the concrete subclasses found in the described modules. A subclass declared in a module that the targets never reference is not a member, and its values fail to decode.
- A value of an open class decodes into the declared struct and loses fields that only a subclass declares.
- `Set<T>` decodes to a slice; Zig does not check uniqueness.
- `Int` maps to `i64`. `UInt` maps to `u64` even though Pkl limits it to the `Int` range.
- Constraints on types, such as `Int(isPositive)`, are not represented in Zig; Pkl enforces them during evaluation.
- Recursive type aliases are rejected by Pkl, so recursion is only supported through classes.
- `pkl:base` type aliases are mapped from a fixed table for Pkl 0.32.2. Aliases from other standard library modules are expanded through reflection.
- Object defaults are not copied into Zig, and regex, bytes, reference, and pair defaults are reported as unrepresentable; Pkl still applies all of them when it evaluates a configuration.
- `ref.Domain` and its subclasses decode as `Dynamic`, because the domain object is only described by its class.
- Type-checking needs the zig-pkl sources on disk and a Zig compiler; without them, pass `--no-verify`.
- A default that does not mention `pkl:platform`, in a module that does not import it, can still copy a host value from another module. That value is the machine where generation ran.
