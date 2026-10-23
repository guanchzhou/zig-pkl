//! Zig bindings for the Pkl message-passing API and pkl-binary encoding.

const std = @import("std");

pub const msgpack = @import("protocol/msgpack.zig");
pub const protocol = @import("protocol/message.zig");
pub const value = @import("value/value.zig");
pub const convert = @import("value/convert.zig");
pub const Backend = @import("backend.zig").Backend;
pub const subprocess = @import("backends/subprocess.zig");
pub const version = @import("evaluator/version.zig");
pub const logger = @import("evaluator/logger.zig");
pub const reader = @import("evaluator/reader.zig");
pub const source = @import("evaluator/source.zig");
pub const uri = @import("evaluator/uri.zig");
pub const project = @import("evaluator/project.zig");
pub const external_client = @import("evaluator/external.zig");
pub const options = @import("evaluator/options.zig");
pub const manager = @import("evaluator/manager.zig");

pub const Message = protocol.Message;
pub const OwnedMessage = protocol.Owned;
pub const Value = value.Value;
pub const Tree = value.Tree;
pub const ReferenceAccess = value.ReferenceAccess;
pub const Manager = manager.Manager;
pub const Evaluator = manager.Evaluator;
pub const Cancellation = manager.Cancellation;
pub const InitOptions = manager.InitOptions;
pub const VersionCheck = manager.VersionCheck;
pub const RequestOptions = manager.RequestOptions;
pub const Options = options.Options;
pub const Builder = options.Builder;
pub const Version = version.Version;
pub const Logger = logger.Logger;
pub const ModuleReader = reader.ModuleReader;
pub const ResourceReader = reader.ResourceReader;
pub const Source = source.Source;
pub const Project = project.Owned;
pub const ExternalClient = external_client.Client;
pub const Subprocess = subprocess.Subprocess;

pub const getVersion = version.query;
pub const supported_pkl = version.supported;

test {
    _ = msgpack;
    _ = protocol;
    _ = value;
    _ = convert;
    _ = subprocess;
    _ = version;
    _ = logger;
    _ = reader;
    _ = source;
    _ = uri;
    _ = project;
    _ = external_client;
    _ = options;
    _ = manager;
}
