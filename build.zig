const std = @import("std");

pub fn build(b: *std.Build) void {
    const xit_dep = b.dependency("xit", .{});
    const ansi_art = ansiArtModule(b);

    // wasm
    const wasm_exe = blk: {
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

        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.import_memory = false;
        exe.export_memory = true;
        exe.stack_size = std.wasm.page_size * 8;

        // start small and let the allocator grow on demand up to wasm32's
        // architectural ceiling (65536 pages = 4 GiB)
        const initial_pages = 16;
        const max_pages = 65536;
        exe.initial_memory = std.wasm.page_size * initial_pages;
        exe.max_memory = std.wasm.page_size * max_pages;

        const install_exe = b.addInstallArtifact(exe, .{});

        const wasm_step = b.step("wasm", "Generate the wasm");
        wasm_step.dependOn(&install_exe.step);

        break :blk exe;
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // main
    {
        const exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                // default to ReleaseSafe unless an explicit -Doptimize is passed
                .optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe,
            }),
            .use_llvm = true,
        });
        exe.root_module.addImport("xit", xit_dep.module("xit"));
        exe.root_module.addImport("ansi_art", ansi_art);
        exe.root_module.addAnonymousImport("haxy.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
    }

    // test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("xit", xit_dep.module("xit"));
        unit_tests.root_module.addImport("ansi_art", ansi_art);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }

    // module for using haxy as a library
    // (the commands below consume haxy this way)
    const haxy = b.addModule("haxy", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    haxy.addImport("xit", xit_dep.module("xit"));
    haxy.addImport("ansi_art", ansi_art);
    haxy.addAnonymousImport("haxy.wasm", .{
        .root_source_file = wasm_exe.getEmittedBin(),
    });

    // try
    {
        const exe = b.addExecutable(.{
            .name = "try",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/try.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("haxy", haxy);
        const try_install = b.addInstallArtifact(exe, .{});

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&try_install.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("try", "Try the app");
        run_step.dependOn(&run_cmd.step);
    }

    // testnet
    {
        const server_exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        server_exe.root_module.addImport("xit", xit_dep.module("xit"));
        server_exe.root_module.addImport("ansi_art", ansi_art);
        server_exe.root_module.addAnonymousImport("haxy.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });
        const install_server_exe = b.addInstallArtifact(server_exe, .{});

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
        run_unit_tests.step.dependOn(&install_server_exe.step);
        const test_step = b.step("testnet", "Run network unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}

// reads every ANSI-art text file while configuring the build. sorting keeps
// the generated module stable when directory iteration order changes.
fn ansiArtModule(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "src/embed/ansi", .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open src/embed/ansi: {t}", .{err});
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch |err| std.debug.panic("unable to read src/embed/ansi: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    if (names.items.len == 0) @panic("src/embed/ansi must contain at least one .txt file");

    const contents = b.allocator.alloc([]const u8, names.items.len) catch @panic("OOM");
    for (names.items, contents) |name, *content| {
        content.* = dir.readFileAlloc(io, name, b.allocator, .limited(16 * 1024 * 1024)) catch |err| {
            std.debug.panic("unable to read src/embed/ansi/{s}: {t}", .{ name, err });
        };
    }

    const options = b.addOptions();
    options.addOption([]const []const u8, "art", contents);
    return options.createModule();
}
