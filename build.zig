const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const enable_builtin_extension = b.option(
        bool,
        "enable_builtin_extension",
        "Enable the built-in compile-time extension adapter",
    ) orelse false;
    const vm_lab_dir = b.option(
        []const u8,
        "vm_lab_dir",
        "Shared VM lab root directory (default: /home/a/vm_lab)",
    ) orelse "/home/a/vm_lab";
    const vm_host = b.option(
        []const u8,
        "vm_host",
        "Registered remote host name for vm-remote-matrix step",
    ) orelse "";
    const config = b.addOptions();
    config.addOption(bool, "enable_builtin_extension", enable_builtin_extension);
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("alldriver", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .imports = &.{
            .{ .name = "alldriver_config", .module = config.createModule() },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "alldriver",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "alldriver" is the name you will use in your source code to
                // import this module (e.g. `@import("alldriver")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "alldriver", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    const tools_exe = b.addExecutable(.{
        .name = "alldriver_tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "alldriver", .module = mod },
                .{ .name = "alldriver_config", .module = config.createModule() },
            },
        }),
    });
    b.installArtifact(tools_exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tools_step = b.step("tools", "Run alldriver_tools commands (pass args after --)");
    const run_tools_cmd = b.addRunArtifact(tools_exe);
    tools_step.dependOn(&run_tools_cmd.step);
    if (b.args) |args| {
        run_tools_cmd.addArgs(args);
    }

    const example_specs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "example-01-discover", .path = "examples/01_discover.zig" },
        .{ .name = "example-02-launch-and-navigate", .path = "examples/02_launch_and_navigate.zig" },
        .{ .name = "example-03-attach-existing-endpoint", .path = "examples/03_attach_existing_endpoint.zig" },
        .{ .name = "example-04-dom-interactions-and-waits", .path = "examples/04_dom_interactions_and_waits.zig" },
        .{ .name = "example-05-network-interception", .path = "examples/05_network_interception.zig" },
        .{ .name = "example-06-cookies-and-storage", .path = "examples/06_cookies_and_storage.zig" },
        .{ .name = "example-07-screenshots-and-tracing", .path = "examples/07_screenshots_and_tracing.zig" },
        .{ .name = "example-08-async-api", .path = "examples/08_async_api.zig" },
        .{ .name = "example-09-modern-contexts-and-targets", .path = "examples/09_modern_contexts_and_targets.zig" },
        .{ .name = "example-10-webview-discovery-and-attach", .path = "examples/10_webview_discovery_and_attach.zig" },
        .{ .name = "example-11-mobile-webview-attach", .path = "examples/11_mobile_webview_attach.zig" },
        .{ .name = "example-12-managed-cache-and-profile-modes", .path = "examples/12_managed_cache_and_profile_modes.zig" },
        .{ .name = "example-13-capability-aware-flow", .path = "examples/13_capability_aware_flow.zig" },
        .{ .name = "example-14-electron-webview", .path = "examples/14_electron_webview.zig" },
        .{ .name = "example-16-wait-targets", .path = "examples/16_wait_targets.zig" },
        .{ .name = "example-17-event-hooks", .path = "examples/17_event_hooks.zig" },
        .{ .name = "example-18-cookie-header-export", .path = "examples/18_cookie_header_export.zig" },
        .{ .name = "example-19-session-cache", .path = "examples/19_session_cache.zig" },
        .{ .name = "example-20-timeout-and-cancel", .path = "examples/20_timeout_and_cancel.zig" },
        .{ .name = "example-21-lightpanda-runtime-download", .path = "examples/21_lightpanda_runtime_download.zig" },
    };
    const examples_step = b.step("examples", "Build all library usage examples");
    inline for (example_specs) |spec| {
        const example_exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "alldriver", .module = mod },
                },
            }),
        });
        const install_example = b.addInstallArtifact(example_exe, .{
            .dest_dir = .{ .override = .{ .custom = "examples" } },
        });
        examples_step.dependOn(&install_example.step);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const tools_tests = b.addTest(.{
        .root_module = tools_exe.root_module,
    });
    const run_tools_tests = b.addRunArtifact(tools_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tools_tests.step);

    const vm_prereq_cmd = b.addRunArtifact(tools_exe);
    vm_prereq_cmd.addArgs(&.{"vm-check-prereqs"});
    const vm_prereq_step = b.step("vm-prereqs", "Check VM/QEMU prerequisites");
    vm_prereq_step.dependOn(&vm_prereq_cmd.step);

    const vm_image_sources_cmd = b.addRunArtifact(tools_exe);
    vm_image_sources_cmd.addArgs(&.{ "vm-image-sources", "--check" });
    const vm_image_sources_step = b.step("vm-image-sources", "List and verify official VM image source links");
    vm_image_sources_step.dependOn(&vm_image_sources_cmd.step);

    const vm_init_cmd = b.addRunArtifact(tools_exe);
    vm_init_cmd.addArgs(&.{ "vm-init-lab", "--project", "alldriver", "--lab-dir", vm_lab_dir });
    const vm_init_step = b.step("vm-init", "Initialize shared VM lab");
    vm_init_step.dependOn(&vm_init_cmd.step);

    const vm_linux_create_cmd = b.addRunArtifact(tools_exe);
    vm_linux_create_cmd.addArgs(&.{ "vm-create-linux", "--project", "alldriver", "--name", "linux-matrix", "--lab-dir", vm_lab_dir });
    const vm_linux_create_step = b.step("vm-linux-create", "Create Linux matrix VM assets");
    vm_linux_create_step.dependOn(&vm_linux_create_cmd.step);

    const vm_linux_matrix_cmd = b.addRunArtifact(tools_exe);
    vm_linux_matrix_cmd.addArgs(&.{ "vm-run-linux-matrix", "--project", "alldriver", "--name", "linux-matrix", "--lab-dir", vm_lab_dir });
    const vm_linux_matrix_step = b.step("vm-linux-matrix", "Run Linux matrix inside VM and collect artifacts");
    vm_linux_matrix_step.dependOn(&vm_linux_matrix_cmd.step);

    const vm_remote_matrix_cmd = b.addRunArtifact(tools_exe);
    vm_remote_matrix_cmd.addArgs(&.{ "vm-run-remote-matrix", "--project", "alldriver", "--host", vm_host, "--lab-dir", vm_lab_dir });
    const vm_remote_matrix_step = b.step("vm-remote-matrix", "Run matrix on a registered remote host (set -Dvm_host=...)");
    vm_remote_matrix_step.dependOn(&vm_remote_matrix_cmd.step);

    const vm_ga_bundle_cmd = b.addRunArtifact(tools_exe);
    vm_ga_bundle_cmd.addArgs(&.{ "vm-ga-collect-and-bundle", "--project", "alldriver", "--linux-host", "linux-matrix", "--macos-host", "macos-host", "--windows-host", "windows-host", "--lab-dir", vm_lab_dir });
    const vm_ga_bundle_step = b.step("vm-ga-bundle", "Collect Linux/macOS/Windows matrix evidence and build GA bundle");
    vm_ga_bundle_step.dependOn(&vm_ga_bundle_cmd.step);

    const production_gate_cmd = b.addRunArtifact(tools_exe);
    production_gate_cmd.addArgs(&.{"production-gate"});
    const production_gate_step = b.step("production-gate", "Run production readiness gate (tests, matrix policy, docs, markers, release bundle)");
    production_gate_step.dependOn(&production_gate_cmd.step);

    const qemu_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const qemu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = qemu_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "alldriver_config", .module = config.createModule() },
            },
        }),
    });
    const run_qemu_tests = b.addRunArtifact(qemu_tests);
    const qemu_step = b.step("test-qemu-aarch64", "Run tests for Linux aarch64 target (invoke with -fqemu)");
    qemu_step.dependOn(&run_qemu_tests.step);

    const compile_matrix_specs = [_]struct {
        name: []const u8,
        query: std.Target.Query,
    }{
        .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
        .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
        .{ .name = "windows-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
    };

    const compile_matrix_step = b.step("test-build-matrix", "Compile test binaries for Linux/macOS/Windows (x64+arm64)");
    inline for (compile_matrix_specs) |spec| {
        const matrix_target = b.resolveTargetQuery(spec.query);
        const matrix_mod_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = matrix_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "alldriver_config", .module = config.createModule() },
                },
            }),
        });
        compile_matrix_step.dependOn(&matrix_mod_test.step);

        const matrix_tools_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools_main.zig"),
                .target = matrix_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "alldriver", .module = mod },
                    .{ .name = "alldriver_config", .module = config.createModule() },
                },
            }),
        });
        compile_matrix_step.dependOn(&matrix_tools_test.step);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
