# Projects

A `PklProject` file declares evaluator settings and dependencies for the modules beside it. `zig_pkl.project` loads both so that an evaluator behaves like `pkl eval` run inside the project.

## Load a project

```zig
// Any evaluator can evaluate the PklProject file itself.
const loader = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
defer loader.close();

var project = try zig_pkl.project.loadFile(allocator, io, loader, "PklProject");
defer project.deinit();

const evaluator = try manager.createEvaluator(project.options, &rejected);
defer evaluator.close();

const main_uri = try project.moduleUri(allocator, "main.pkl");
defer allocator.free(main_uri);
var tree = try evaluator.evaluateSource(.uri(main_uri), null, &failure);
```

`loadFile` reads `PklProject` and, when present, `PklProject.deps.json` beside it. Create or refresh the lock file with `pkl project resolve`. A project that declares dependencies but has no lock file fails with `error.MissingDependencyLock`.

`project.options` is a complete `Options` value built from `evaluatorSettings`, with `project` filled in from the dependencies. Change any field before creating the evaluator. A project that sets no allow lists leaves `allowed_modules` and `allowed_resources` null; [`examples/project`](../../examples/project/main.zig) fills them from `Options.preconfigured()` in that case.

## Paths and symlinks

`loadFile` resolves the project path to its canonical location, following symlinks. `project.projectUri()` returns that location, and `project.moduleUri(allocator, "relative/path.pkl")` builds URIs beside it. Evaluate project modules through those URIs: Pkl applies the project's dependencies only to modules inside the project directory.

Relative paths in `evaluatorSettings` resolve against the project directory, the same way Pkl 0.32's `resolvedEvaluatorSettings` resolves them. That covers `modulePath`, `moduleCacheDir`, `rootDir`, the working directory of external readers, and reader executables that contain a path separator. Executables given as a bare name, such as `pkl-reader`, are looked up on `PATH` when the reader starts. zig-pkl does this resolution itself, so it gives the same result on every supported Pkl release.

## Dependencies

Local dependencies (`import("../lib/PklProject")`) and remote packages both come from the lock file. Each dependency carries its declared name, so modules import it as `@name/module.pkl`. Local dependencies keep their own dependencies at every level of nesting.

## Settings that need newer Pkl

HTTP proxy and CA settings need Pkl 0.26, external readers 0.27, HTTP rewrites 0.29, `traceMode` 0.30, and HTTP headers 0.32. When a project sets one of these, `createEvaluator` checks the server version and fails with `error.UnsupportedVersion` on an older release. See [Version compatibility](compatibility.md).

## Owned memory

`project.Owned` owns every string and slice in `project.options` and `project.project`. Keep it alive until the evaluators created from those options are closed, then call `deinit`.
