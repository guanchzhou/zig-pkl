# Security

Pkl modules can import other modules and read resources: files, environment variables, system properties, HTTP URLs, and packages. Every evaluator carries allow lists that decide which of those it may touch. Choose them for the least trusted module the evaluator will see.

## Restricted and preconfigured settings

| | `Options.restricted()` | `Options.preconfigured()` |
| --- | --- | --- |
| Modules | `pkl:`, `repl:` | `pkl:`, `repl:`, `file:`, `modulepath:`, `package:`, `projectpackage:` |
| Resources | none | `pkl:`, `file:`, `modulepath:`, `package:`, `projectpackage:`, `env:`, `prop:` |

`restricted()` is the right default for configuration you did not write. `preconfigured()` adds local files, module paths, and packages but no HTTP, and suits trusted files on disk.

Neither passes the program's environment variables or system properties to Pkl. `env:` and `prop:` reads see only what you put in `Options.env` and `Options.properties`, so `read("env:HOME")` finds nothing unless you add `HOME` yourself.

An evaluator needs at least one module pattern, because even inline text is the module `repl:text`. `createEvaluator` returns `error.NoAllowedModules` when `allowed_modules` is null or empty; Pkl 0.30 and newer would exit instead of rejecting the request. A null `allowed_resources` denies every resource.

## Granting exactly what a module needs

```zig
var options = zig_pkl.Options.restricted();
options.allowed_resources = &.{"env:"};
options.env = &.{.{ .key = "REGION", .value = "eu-west-1" }};
options.timeout_seconds = 5;
```

This evaluator can read `env:REGION` and no other variable. Allow list entries are regular expressions matched against the start of the URI, so `"https://config\\.example\\.com/"` allows one host.

`root_dir` confines `file:` modules and resources to one directory tree. `timeout_seconds` makes Pkl stop an evaluation that runs too long; it is enforced by the server. For a client-side deadline, see [Errors](errors.md).

## Readers add schemes

`Builder.moduleReaders` and `Builder.resourceReaders` add each reader's scheme to the matching allow list, so a reader cannot be registered and then silently blocked. When you assign readers to `Options` directly, add the schemes yourself. See [Readers](readers.md).

## What the client checks

- Responses are decoded with size and depth limits (`value.Limits`), and malformed frames fail the connection with `error.Protocol` instead of being guessed at.
- The server runs as a child process with its own process group on POSIX. `Manager.deinit` closes its input, waits, then terminates the group; see the README limitations for Windows.
- Code generation evaluates defaults with resource reads denied and omits defaults that depend on the generating machine. See [Code generation](../codegen.md#sandbox).

See [`examples/restricted`](../../examples/restricted/main.zig) for the messages Pkl returns when a module reaches outside its allow lists.
