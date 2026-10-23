//! Evaluation source descriptors.

const std = @import("std");

pub const Source = struct {
    module_uri: []const u8,
    module_text: ?[]const u8 = null,

    /// Creates an inline source using Pkl's canonical text module URI.
    pub fn text(contents: []const u8) Source {
        return .{ .module_uri = "repl:text", .module_text = contents };
    }

    /// Creates a source that Pkl loads from the supplied URI.
    pub fn uri(module_uri: []const u8) Source {
        return .{ .module_uri = module_uri };
    }
};

test "text and URI sources preserve their intended module identity" {
    const inline_source = Source.text("answer = 42");
    try std.testing.expectEqualStrings("repl:text", inline_source.module_uri);
    try std.testing.expectEqualStrings("answer = 42", inline_source.module_text.?);

    const custom = Source.uri("custom:/settings.pkl");
    try std.testing.expectEqualStrings("custom:/settings.pkl", custom.module_uri);
    try std.testing.expect(custom.module_text == null);
}
