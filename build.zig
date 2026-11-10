const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const capnp_mod = b.addModule("capnp", .{
        .target = target,
        .optimize = optimize,
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/capnp.zig"),
    });

    const capnp_rpc_mod = b.addModule("capnp_rpc", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/rpc/connection.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-capnp",
        .root_module = capnp_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const compiler_mod = b.addModule("capnpc", .{
        .target = target,
        .optimize = optimize,
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/refactor.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
        },
    });

    const compiler_exe = b.addExecutable(.{
        .name = "capnpc-zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = compiler_mod,
    });

    b.installArtifact(compiler_exe);

    const codegen_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("capnp-tests/codegen.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
            .{ .name = "capnp_rpc", .module = capnp_rpc_mod },
        },
    });

    const codegen_tests_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/codegen_tests.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
            .{ .name = "capnp_rpc", .module = capnp_rpc_mod },
            .{ .name = "capnpc", .module = compiler_mod },
            .{ .name = "codegen", .module = codegen_mod },
        },
    });

    const capnp_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/capnp_tests.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
            .{ .name = "capnpc", .module = compiler_mod },
        },
    });

    const rpc_tests_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/rpc/rpc_tests.zig"),
        .imports = &.{
            .{ .name = "capnp", .module = capnp_mod },
        },
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_module = capnp_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const compiler_tests = b.addTest(.{
        .root_module = compiler_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    });

    const run_compiler_tests = b.addRunArtifact(compiler_tests);

    const codegen_tests = b.addTest(.{
        .root_module = codegen_tests_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    });

    // The generated modules imported by capnp-tests/codegen.zig are not
    // checked into the repository. Generate only the missing artifacts before
    // compiling the codegen tests, and leave existing artifacts untouched.
    const generate_codegen = b.addSystemCommand(&.{ "bash", "codegen_zig.bash" });
    generate_codegen.addArtifactArg(compiler_exe);
    generate_codegen.setCwd(b.path("."));
    codegen_tests.step.dependOn(&generate_codegen.step);
    compiler_tests.step.dependOn(&generate_codegen.step);

    const run_codegen_tests = b.addRunArtifact(codegen_tests);

    const capnp_test = b.addTest(.{
        .root_module = capnp_test_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    });

    const run_capnp_test = b.addRunArtifact(capnp_test);

    const rpc_tests = b.addTest(.{
        .root_module = rpc_tests_mod,
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test_runner.zig"),
        },
    });

    const run_rpc_tests = b.addRunArtifact(rpc_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library and codegen tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_codegen_tests.step);
    test_step.dependOn(&run_capnp_test.step);
    test_step.dependOn(&run_rpc_tests.step);
}
