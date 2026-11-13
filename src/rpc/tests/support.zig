const std = @import("std");
const capnp = @import("capnp");
const rpc = @import("../generated/rpc.zig");
const connection = @import("../connection.zig");
const transports = @import("../transports/mod.zig");
const testing = std.testing;

pub const TestInterface = struct {
    pub const id: u64 = 0x8f13b9d2a7c4e601;

    pub fn dispatch(
        _: *anyopaque,
        method_id: u16,
        call: connection.Call,
    ) anyerror!void {
        switch (method_id) {
            0 => {
                const input = try call.params.asText();
                if (!std.mem.eql(u8, input, "ping")) return error.UnexpectedParams;
                try call.results.setText("pong");
            },
            1 => return error.MethodFailed,
            else => return error.MethodNotFound,
        }
    }
};

pub const EchoInterface = struct {
    pub const id: u64 = 0x4b7e2d9a1c6f8035;

    pub fn dispatch(_: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        if (method_id != 0) return error.MethodNotFound;
        try call.results.setText(try call.params.asText());
    }
};

pub const ProviderInterface = struct {
    pub const id: u64 = 0xd2a6f4c81b903e57;

    pub fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        const state: *ProviderState = @ptrCast(@alignCast(context));
        switch (method_id) {
            0 => {
                state.calls += 1;
                const index = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(index);
            },
            1 => {
                if (call.capabilities.len != 1) return error.MissingCapability;
                // The params content must survive adding a capability to the
                // request's cap table.
                if (try call.params.asCapability() != 0) return error.UnexpectedParams;

                var request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer request.deinit();
                var params = try request.params();
                try params.content().setText("from-client");
                var response = try request.send();
                defer response.deinit();

                const payload = try response.payload();
                try call.results.setText(try (try payload.content()).asText());
            },
            2 => {
                const promise = try call.connection.newPromise();
                state.promise = promise;
                const index = try call.addResultCapability(promise);
                call.results.setCapability(index);
            },
            3 => {
                if (call.capabilities.len != 1) return error.MissingCapability;
                switch (call.capabilities[0]) {
                    .local => try call.results.setText("local-answer"),
                    else => return error.NotLocalAnswer,
                }
            },
            4 => {
                // Return the caller's own capability: this is encoded as
                // receiverHosted and decoded back into a local handle.
                if (call.capabilities.len != 1) return error.MissingCapability;
                const index = try call.addResultCapability(call.capabilities[0]);
                call.results.setCapability(index);
            },
            5 => {
                // Return two references to the same capability so tests can
                // exercise releasing result caps that the caller never took.
                _ = try call.addLocalResultCapability(state.echo);
                _ = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(0);
            },
            6 => {
                // Store a borrowed capability parameter for later use by the
                // test after the capability's answer resolves.
                if (call.capabilities.len != 1) return error.MissingCapability;
                if (state.stored) |old| old.release();
                state.stored = call.capabilities[0].retain();
                try call.results.setText("stored");
            },
            7 => {
                // Resolve our stored promise to the capability parameter.
                if (call.capabilities.len != 1) return error.MissingCapability;
                const promise = state.promise orelse return error.MissingPromise;
                try call.connection.resolvePromise(promise, call.capabilities[0]);
                try call.results.setText("resolved-to-param");
            },
            else => return error.MethodNotFound,
        }
    }
};

pub fn recordDisembargo(context: *anyopaque, embargo_id: u32) void {
    const result: *u32 = @ptrCast(@alignCast(context));
    result.* = embargo_id;
}

pub const ProviderState = struct {
    echo: connection.LocalCapability,
    promise: ?connection.Capability = null,
    stored: ?connection.Capability = null,
    calls: usize = 0,
};

pub fn scriptedPump(
    client: *connection.Connection,
    server: *connection.Connection,
    link: *transports.Scripted,
) !void {
    while (true) {
        var progressed = false;
        while (try link.deliverNext(.client)) {
            try server.step();
            progressed = true;
        }
        while (try link.deliverNext(.server)) {
            try client.step();
            progressed = true;
        }
        if (!progressed) return;
    }
}

pub fn messageIsReturnException(bytes: []const u8) !bool {
    var message = try capnp.Message.fromBytes(bytes, testing.allocator);
    defer message.deinit(testing.allocator);

    const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
    const return_ = (try root.@"return"()) orelse return error.NotReturn;
    return return_.which() == .exception;
}

pub fn messageIsCall(bytes: []const u8) !bool {
    var message = try capnp.Message.fromBytes(bytes, testing.allocator);
    defer message.deinit(testing.allocator);

    const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
    return root.which() == .call;
}

/// Read the imported capability id from a Call's target. Fails when the message
/// is not a Call or the target is a promisedAnswer.
pub fn callTargetImportedCap(bytes: []const u8) !u32 {
    var message = try capnp.Message.fromBytes(bytes, testing.allocator);
    defer message.deinit(testing.allocator);

    const root = try message.getRootStruct(rpc.Message.Reader, rpc.Message.reader_trait);
    const call = (try root.call()) orelse return error.NotCall;
    const target = try call.target();
    return target.importedCap() orelse return error.NotImportedCap;
}

pub fn scriptedBootstrap(
    server: *connection.Connection,
    client: *connection.Connection,
    link: *transports.Scripted,
    capability: connection.LocalCapability,
) !connection.Capability {
    server.setBootstrap(try server.initLocal(capability));

    var promise = try client.bootstrapStart();
    try scriptedPump(client, server, link);
    const bootstrapped = try promise.wait();
    try scriptedPump(client, server, link);
    return bootstrapped;
}

pub const PipelineInterface = struct {
    pub const id: u64 = 0x9d7a02c4e8b1635f;

    pub fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        const state: *ProviderState = @ptrCast(@alignCast(context));
        switch (method_id) {
            0 => {
                // Wait for a client-provided capability before returning a
                // local capability. This keeps the handler busy long enough
                // for a dependent pipelined call to arrive.
                if (call.capabilities.len != 1) return error.MissingCapability;

                var echo_request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer echo_request.deinit();
                var echo_params = try echo_request.params();
                try echo_params.content().setText("wait");
                var echo_response = try echo_request.send();
                defer echo_response.deinit();
                const echo_payload = try echo_response.payload();
                _ = try (try echo_payload.content()).asText();

                const index = try call.addLocalResultCapability(state.echo);
                call.results.setCapability(index);
            },
            1 => {
                // The capability parameter is the promised result of method 0.
                // It is resolved locally by the time this call is dispatched.
                if (call.capabilities.len != 1) return error.MissingCapability;

                var echo_request = try call.connection.beginCall(call.capabilities[0], EchoInterface.id, 0);
                defer echo_request.deinit();
                var echo_params = try echo_request.params();
                try echo_params.content().setText("pipelined");
                var echo_response = try echo_request.send();
                defer echo_response.deinit();
                const echo_payload = try echo_response.payload();
                try call.results.setText(try (try echo_payload.content()).asText());
            },
            else => return error.MethodNotFound,
        }
    }
};

pub const DestroyCounter = struct {
    count: usize = 0,
};

pub fn countDestroy(context: *anyopaque) void {
    const counter: *DestroyCounter = @ptrCast(@alignCast(context));
    counter.count += 1;
}

pub const RecursiveState = struct {
    capability: ?connection.Capability = null,
};

pub const RecursiveInterface = struct {
    pub const id: u64 = 0x3f5a71c24d8b9e60;

    pub fn dispatch(context: *anyopaque, method_id: u16, call: connection.Call) anyerror!void {
        if (method_id != 0) return error.MethodNotFound;
        const state: *RecursiveState = @ptrCast(@alignCast(context));
        const depth = try std.fmt.parseInt(u16, try call.params.asText(), 10);
        if (depth == 0) {
            try call.results.setText("done");
            return;
        }

        const capability = state.capability orelse return error.MissingCapability;
        var request = try call.connection.beginCall(capability, id, 0);
        defer request.deinit();

        var buffer: [8]u8 = undefined;
        const text = try std.fmt.bufPrintSentinel(&buffer, "{d}", .{depth - 1}, 0);
        var params = try request.params();
        try params.content().setText(text);

        var response = try request.send();
        defer response.deinit();
        const payload = try response.payload();
        try call.results.setText(try (try payload.content()).asText());
    }
};
