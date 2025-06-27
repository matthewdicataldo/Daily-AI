const std = @import("std");

/// Slim build script - removes 818MB of vendored dependencies
/// Uses package managers and runtime downloads instead
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add zig-network dependency for networking
    const network_dep = b.dependency("network", .{
        .target = target,
        .optimize = optimize,
    });
    
    // Add yazap dependency for CLI parsing
    const yazap_dep = b.dependency("yazap", .{});
    
    // Cross-platform detection
    const is_windows = target.result.os.tag == .windows;
    const shell_cmd = if (is_windows) "cmd" else "sh";
    const shell_flag = if (is_windows) "/C" else "-c";
    
    // Download yt-dlp binary for YouTube extraction (cross-platform)
    const ytdlp_url = if (is_windows)
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
    else
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
    
    const ytdlp_filename = if (is_windows) "yt-dlp.exe" else "yt-dlp";
    
    const download_ytdlp = b.addSystemCommand(&[_][]const u8{
        "curl", "-L", ytdlp_url, "-o", ytdlp_filename
    });
    
    // Make executable on Unix-like systems
    var chmod_ytdlp: ?*std.Build.Step.Run = null;
    if (!is_windows) {
        chmod_ytdlp = b.addSystemCommand(&[_][]const u8{
            "chmod", "+x", ytdlp_filename
        });
        chmod_ytdlp.?.step.dependOn(&download_ytdlp.step);
    }
    
    // IMPROVED: Use Skytable precompiled binary instead of building from source
    // This eliminates the 260MB skytable source tree and Rust build dependency
    const skytable_install_script = if (is_windows)
        "if not exist skyd.exe ( " ++
        "curl -L https://github.com/skytable/skytable/releases/download/v0.8.4/sky-bundle-v0.8.4-x86_64-windows.zip -o sky-bundle.zip && " ++
        "powershell -command \"Expand-Archive -Path sky-bundle.zip -DestinationPath . -Force\" && " ++
        "move sky-bundle-v0.8.4-x86_64-windows\\skyd.exe skyd.exe && " ++
        "rmdir /s /q sky-bundle-v0.8.4-x86_64-windows && " ++
        "del sky-bundle.zip )"
    else
        "if [ ! -f skyd ]; then " ++
        "curl -L https://github.com/skytable/skytable/releases/download/v0.8.4/sky-bundle-v0.8.4-x86_64-linux-gnu.zip -o sky-bundle.zip && " ++
        "unzip -o sky-bundle.zip && " ++
        "chmod +x skyd && " ++
        "rm -f sky-bundle.zip; fi";
        
    const install_skytable = b.addSystemCommand(&[_][]const u8{
        shell_cmd, shell_flag, skytable_install_script
    });
    
    // Start Skytable server using downloaded binary
    const start_script = if (is_windows)
        "start /B .\\skyd.exe --endpoint tcp@127.0.0.1:2003"
    else
        "if ! pgrep -f 'skyd' > /dev/null; then " ++
        "nohup ./skyd --endpoint tcp@127.0.0.1:2003 > skytable.log 2>&1 & " ++
        "sleep 2; fi";
        
    const start_skytable = b.addSystemCommand(&[_][]const u8{
        shell_cmd, shell_flag, start_script
    });
    start_skytable.step.dependOn(&install_skytable.step);

    // Create library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add networking dependency to module
    lib_mod.addImport("network", network_dep.module("network"));
    lib_mod.addImport("yazap", yazap_dep.module("yazap"));

    const lib = b.addStaticLibrary(.{
        .name = "daily_ai",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    lib.root_module.addImport("network", network_dep.module("network"));
    lib.root_module.addImport("yazap", yazap_dep.module("yazap"));
    
    b.installArtifact(lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "daily_ai",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    exe.root_module.addImport("daily_ai_lib", lib_mod);
    exe.root_module.addImport("network", network_dep.module("network"));
    exe.root_module.addImport("yazap", yazap_dep.module("yazap"));
    
    // Dependencies for executable
    exe.step.dependOn(&install_skytable.step);
    exe.step.dependOn(&download_ytdlp.step);
    if (chmod_ytdlp) |chmod| {
        exe.step.dependOn(&chmod.step);
    }
    
    b.installArtifact(exe);

    // Test executables removed for simplified build

    // Default run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    unit_tests.root_module.addImport("network", network_dep.module("network"));
    unit_tests.root_module.addImport("yazap", yazap_dep.module("yazap"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}