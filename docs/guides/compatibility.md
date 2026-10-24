# Version compatibility

## Zig

zig-pkl builds with Zig 0.17.0. CI also builds and tests against Zig master, but that job does not block releases and master is not supported.

## Pkl

Evaluation works with Pkl 0.25.3 and newer. CI runs the conformance suite, the integration tests, and every example against the latest patch release of each minor version:

| Pkl | Status |
| --- | --- |
| 0.25.3, 0.26.3, 0.27.2, 0.28.2, 0.29.1, 0.30.2, 0.31.1 | tested on Linux x86_64 |
| 0.32.2 | tested on Linux x86_64 and aarch64, macOS aarch64, and Windows x86_64 |

Code generation needs Pkl 0.32.2. `zig_pkl.supported_pkl` is the newest release tested, and `zig_pkl.version.minimum_supported` the oldest.

## Settings that need a newer release

| Setting | Oldest Pkl |
| --- | --- |
| `http.proxy`, `http.ca_certificates` | 0.26 |
| `external_module_readers`, `external_resource_readers` | 0.27 |
| `http.rewrites` | 0.29 |
| `trace_mode` | 0.30 |
| `http.headers` | 0.32 |

`createEvaluator` checks these against the server version and fails with `error.UnsupportedVersion` instead of sending a request that an older server would misread or ignore. The version is learned lazily: options that every supported release accepts are sent without asking, and the first options that need a newer release start `pkl --version` in the background while the request is in flight. Pass `InitOptions.version = .{ .known = version }` to `Manager.initWithOptions` when you already know the version, or `.unchecked` to skip the check.

`zig_pkl.getVersion(allocator, io, "pkl")` runs `pkl --version` and parses the result.

## Behavior that differs by release

These are differences in Pkl that zig-pkl smooths over or that show up in your programs:

- Pkl before 0.30 sends class and type alias values without a name or module URI. zig-pkl decodes them with empty `name` and `module_uri`.
- `resolvedEvaluatorSettings` exists only from Pkl 0.32. zig-pkl resolves project paths itself, so projects behave the same on every release; see [Projects](projects.md).
- `output.bytes` exists from Pkl 0.29, and `Bytes` values from 0.29.
- Pkl before 0.29 exits when an allow list entry is not a valid regular expression, so `createEvaluator` fails with `error.Closed` rather than `error.Rejected`.
- Pkl 0.30 and newer exit when an evaluator has no allowed modules. zig-pkl refuses those options with `error.NoAllowedModules` on every release.
