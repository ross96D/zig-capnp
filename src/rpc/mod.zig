//! Public entry point for the Cap'n Proto RPC runtime.
//!
//! `Connection` is heap-allocated: `Connection.init` returns a pointer and
//! `Connection.deinit` releases it. This keeps the internal back-pointers from
//! capabilities, questions, and answers stable for the lifetime of the value.

pub const connection = @import("connection.zig");

pub const Connection = connection.Connection;
pub const Capability = connection.Capability;
pub const BootstrapPromise = connection.BootstrapPromise;
pub const Call = connection.Call;
pub const DisembargoCallback = connection.DisembargoCallback;
pub const LocalCapability = connection.LocalCapability;
pub const Promise = connection.Promise;
pub const Request = connection.Request;
pub const Response = connection.Response;
pub const DispatchFn = connection.DispatchFn;

pub const rpc = connection.rpc;
pub const transport = connection.transport;
pub const Side = connection.Side;
pub const Transport = connection.Transport;

pub const transports = @import("transports/mod.zig");
