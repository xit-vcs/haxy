const std = @import("std");

pub fn build(b: *std.Build) void {
    const xit_dep = b.dependency("xit", .{});

    // wasm
    const install_wasm_exe = blk: {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_wasm.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            }),
        });
        exe.root_module.addImport("xit", xit_dep.module("xit"));

        exe.global_base = 6560;
        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.import_memory = false;
        exe.export_memory = true;
        exe.stack_size = std.wasm.page_size;

        const initial_pages = 16;
        const max_pages = 256;
        exe.initial_memory = std.wasm.page_size * initial_pages;
        exe.max_memory = std.wasm.page_size * max_pages;

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);

        const wasm_step = b.step("wasm", "Generate the wasm");
        wasm_step.dependOn(&install_exe.step);

        break :blk install_exe;
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // main
    const install_main_exe = blk: {
        const exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("xit", xit_dep.module("xit"));
        exe.step.dependOn(&install_wasm_exe.step);

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        break :blk install_exe;
    };

    // module for using haxy as a library
    // (the commands below consume haxy this way)
    const haxy = b.addModule("haxy", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    haxy.addImport("xit", xit_dep.module("xit"));

    // test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("haxy", haxy);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&install_main_exe.step);
        test_step.dependOn(&run_unit_tests.step);
    }

    // testnet
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testnet.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("haxy", haxy);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        const test_step = b.step("testnet", "Run network unit tests");
        test_step.dependOn(&install_main_exe.step);
        test_step.dependOn(&run_unit_tests.step);
    }
}
