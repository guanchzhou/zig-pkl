# Readers

A reader serves modules or resources for a URI scheme from your program. Pkl asks the reader whenever a module imports `scheme:...` or calls `read("scheme:...")`, and the answer never touches the disk unless the reader reads it.

## Built-in readers

`reader.Embed` serves a fixed table, such as files compiled in with `@embedFile`:

```zig
var embedded = zig_pkl.reader.Embed{
    .scheme_name = "embedded",
    .entries = &.{
        .{ .path = "/base.pkl", .contents = @embedFile("pkl/base.pkl") },
        .{ .path = "/services/api.pkl", .contents = @embedFile("pkl/services/api.pkl") },
    },
};
```

Entries are addressed as `embedded:/base.pkl`. Relative imports and globbing (`import*("embedded:/services/*.pkl")`) work because the reader is hierarchical and globbable by default.

`reader.Filesystem` serves one directory tree through an open `std.Io.Dir` handle. It refuses paths that leave the tree, including through `..` and symlinks. Open the directory with `.iterate = true` when modules glob it.

## Register readers

```zig
const module_readers = [_]zig_pkl.ModuleReader{embedded.moduleReader()};
const resource_readers = [_]zig_pkl.ResourceReader{secrets.resourceReader()};

var builder = try zig_pkl.Builder.restricted(allocator);
defer builder.deinit();
_ = try builder.moduleReaders(&module_readers);
_ = try builder.resourceReaders(&resource_readers);
const evaluator = try manager.createEvaluator(builder.options, &rejected);
```

The builder adds each reader's scheme to the allow lists. Readers, their contexts, and the builder must stay alive until the evaluator is closed.

## Write a reader

A reader is a pointer plus a vtable:

```zig
const Secrets = struct {
    table: []const [2][]const u8,

    fn resourceReader(self: *Secrets) zig_pkl.ResourceReader {
        return .{ .ptr = self, .vtable = &.{
            .scheme = scheme,
            .has_hierarchical_uris = no,
            .is_globbable = no,
            .read = read,
            .list = list,
        } };
    }

    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        const self: *Secrets = @ptrCast(@alignCast(ptr));
        for (self.table) |row| {
            if (std.mem.eql(u8, row[0], uri["secret:".len..])) return allocator.dupe(u8, row[1]);
        }
        return error.SecretNotFound;
    }
    // scheme, no, and list omitted
};
```

- `read` returns bytes allocated with the `allocator` it receives. The manager frees them after replying.
- An error is sent to Pkl as the error's name, and the evaluation fails with that message.
- `list` returns the children of a URI for globbing, also allocated with `allocator`. Readers that are not globbable may return an empty slice.
- Module readers also report `is_local`: whether their modules count as local for Pkl's import rules.

The complete program is [`examples/readers`](../../examples/readers/main.zig).

## Threads

Reader callbacks run on a pool of worker threads, so a slow reader does not hold up other responses. `InitOptions.reader_workers` (default 4) caps the pool, and workers start only when callbacks arrive. When `InitOptions.reader_queue_capacity` (default 64) callbacks are already waiting, Pkl receives an error for the next one instead of the queue growing without bound.

One reader instance may serve several evaluators at once, so make its state thread-safe. `Evaluator.close` waits for that evaluator's running callbacks before it returns.
