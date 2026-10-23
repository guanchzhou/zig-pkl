//! Generation of Zig bindings from Pkl modules.
//!
//! `generate` asks a sandboxed Pkl evaluator to describe the target modules
//! with `codegen/Schema.pkl`, plans one Zig file per reachable module,
//! type-checks the result with the Zig compiler, and writes only the files
//! whose contents changed into an output directory it owns. The
//! `zig-pkl-gen` executable and the `zig build codegen` step are thin
//! wrappers around it.

pub const schema = @import("codegen/schema.zig");
pub const names = @import("codegen/names.zig");
pub const plan = @import("codegen/plan.zig");
pub const generator = @import("codegen/generate.zig");
pub const output = @import("codegen/output.zig");
pub const verify = @import("codegen/verify.zig");
pub const Diagnostics = @import("codegen/diagnostics.zig").Diagnostics;
pub const Diagnostic = @import("codegen/diagnostics.zig").Diagnostic;

pub const PackageMapping = plan.PackageMapping;
pub const Options = generator.Options;
pub const Verify = generator.Verify;
pub const Report = output.Report;
pub const generate = generator.generate;
pub const writeFiles = output.writeFiles;

test {
    _ = schema;
    _ = names;
    _ = plan;
    _ = generator;
    _ = output;
    _ = verify;
    _ = @import("codegen/diagnostics.zig");
    _ = @import("codegen/plan_test.zig");
}
