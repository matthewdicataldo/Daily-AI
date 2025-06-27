const std = @import("std");

/// Simple .env file validation and logging
pub fn loadDotEnv(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn("⚠️ .env file not found at {s}", .{file_path});
            return;
        },
        else => return err,
    };
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB limit
    defer allocator.free(content);
    
    var env_var_count: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip empty lines and comments
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }
        
        // Look for KEY=VALUE format
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");
            
            // Remove quotes if present
            if (value.len >= 2) {
                if ((std.mem.startsWith(u8, value, "\"") and std.mem.endsWith(u8, value, "\"")) or
                    (std.mem.startsWith(u8, value, "'") and std.mem.endsWith(u8, value, "'"))) {
                    value = value[1..value.len - 1];
                }
            }
            
            // Log that we found environment variable (don't log the value for security)
            std.log.info("🔧 Found env var: {s}", .{key});
            env_var_count += 1;
        }
    }
    
    if (env_var_count > 0) {
        std.log.info("✅ .env file loaded: {d} environment variables found", .{env_var_count});
    } else {
        std.log.warn("⚠️ .env file is empty or contains no valid KEY=VALUE pairs", .{});
    }
}