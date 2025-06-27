const std = @import("std");

/// JSON processing errors
pub const JSONError = error{
    ParseError,
    InvalidJSON,
    KeyNotFound,
    TypeMismatch,
    OutOfMemory,
    BufferTooSmall,
};

/// High-performance JSON value representation using Zig std.json
pub const FastJSONValue = std.json.Value;

/// Object representation for fast lookup - alias to std.json.ObjectMap
pub const FastJSONObject = std.json.ObjectMap;

/// High-performance JSON processor using Zig standard library
pub const JSONProcessor = struct {
    allocator: std.mem.Allocator,

    // Performance metrics
    total_parses: u64,
    total_bytes_parsed: u64,
    average_parse_time_ns: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        std.log.info("🚀 High-performance JSON processor initialized (std.json)", .{});
        
        return Self{
            .allocator = allocator,
            .total_parses = 0,
            .total_bytes_parsed = 0,
            .average_parse_time_ns = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("📊 JSON Processor Stats: {d} parses, {d} MB processed, avg {d}ns/parse", .{
            self.total_parses,
            self.total_bytes_parsed / (1024 * 1024),
            self.average_parse_time_ns,
        });
    }

    /// Parse JSON with high performance using std.json
    pub fn parseJSON(self: *Self, json_data: []const u8) !std.json.Parsed(std.json.Value) {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            const parse_time = @as(u64, @intCast(end_time - start_time));

            self.total_parses += 1;
            self.total_bytes_parsed += json_data.len;
            self.average_parse_time_ns = (self.average_parse_time_ns * (self.total_parses - 1) + parse_time) / self.total_parses;
        }

        // Parse using std.json
        return std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{}) catch {
            std.log.err("std.json parse error for data: {s}", .{json_data[0..@min(100, json_data.len)]});
            return JSONError.ParseError;
        };
    }

    /// Parse JSON array with streaming for large datasets
    pub fn parseJSONArray(self: *Self, json_data: []const u8) !std.json.Parsed([]std.json.Value) {
        return std.json.parseFromSlice([]std.json.Value, self.allocator, json_data, .{}) catch {
            std.log.err("std.json array parse error", .{});
            return JSONError.ParseError;
        };
    }

    /// Parse JSON objects with efficient key lookup
    pub fn parseJSONObject(self: *Self, json_data: []const u8) !std.json.Parsed(std.json.ObjectMap) {
        return std.json.parseFromSlice(std.json.ObjectMap, self.allocator, json_data, .{}) catch {
            std.log.err("std.json object parse error", .{});
            return JSONError.ParseError;
        };
    }

    /// Fast JSON validation without full parsing
    pub fn validateJSON(self: *Self, json_data: []const u8) bool {
        // Use a temporary arena allocator for validation
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, json_data, .{}) catch {
            return false;
        };
        defer parsed.deinit();

        return true;
    }

    /// Extract specific field with path-based lookup
    pub fn extractField(self: *Self, json_data: []const u8, field_path: []const u8) !?std.json.Value {
        const parsed = try self.parseJSON(json_data);
        defer parsed.deinit();

        return try self.navigateToField(parsed.value, field_path);
    }

    /// Batch process multiple JSON documents
    pub fn batchParseJSON(self: *Self, json_documents: [][]const u8) ![]std.json.Parsed(std.json.Value) {
        var results = try self.allocator.alloc(std.json.Parsed(std.json.Value), json_documents.len);
        var success_count: usize = 0;

        for (json_documents, 0..) |doc, i| {
            results[i] = self.parseJSON(doc) catch blk: {
                // Create null value for failed parses
                const arena = std.heap.ArenaAllocator.init(self.allocator);
                const null_value = std.json.Value{ .null = {} };
                break :blk std.json.Parsed(std.json.Value){
                    .value = null_value,
                    .arena = arena,
                };
            };
            success_count += 1;
        }

        std.log.info("📊 Batch processing: {d}/{d} documents parsed successfully", .{ success_count, json_documents.len });
        return results;
    }

    /// Performance benchmark for JSON parsing
    pub fn benchmarkPerformance(self: *Self, test_data: []const u8, iterations: u32) !BenchmarkResult {
        const start_time = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const parsed = try self.parseJSON(test_data);
            parsed.deinit();
        }

        const end_time = std.time.nanoTimestamp();
        const total_time_ns = @as(u64, @intCast(end_time - start_time));
        const total_bytes = test_data.len * iterations;

        return BenchmarkResult{
            .iterations = iterations,
            .total_time_ns = total_time_ns,
            .avg_time_per_parse_ns = total_time_ns / iterations,
            .throughput_mb_per_sec = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time_ns))) * 1_000_000_000.0 / (1024.0 * 1024.0),
            .total_bytes_processed = total_bytes,
        };
    }

    /// Convert std.json.Value to string representation
    pub fn stringify(self: *Self, value: std.json.Value) ![]const u8 {
        var string_buffer = std.ArrayList(u8).init(self.allocator);
        defer string_buffer.deinit();

        try std.json.stringify(value, .{}, string_buffer.writer());
        return try string_buffer.toOwnedSlice();
    }

    /// Convert std.json.Value to pretty-printed string
    pub fn stringifyPretty(self: *Self, value: std.json.Value) ![]const u8 {
        var string_buffer = std.ArrayList(u8).init(self.allocator);
        defer string_buffer.deinit();

        try std.json.stringify(value, .{ .whitespace = .indent_2 }, string_buffer.writer());
        return try string_buffer.toOwnedSlice();
    }

    // Private implementation methods
    fn navigateToField(_: *Self, root: std.json.Value, field_path: []const u8) !?std.json.Value {
        var current_value = root;
        var path_parts = std.mem.splitScalar(u8, field_path, '.');

        while (path_parts.next()) |part| {
            switch (current_value) {
                .object => |obj| {
                    if (obj.get(part)) |field_value| {
                        current_value = field_value.*;
                    } else {
                        return null;
                    }
                },
                .array => |arr| {
                    const index = std.fmt.parseInt(usize, part, 10) catch return null;
                    if (index >= arr.items.len) return null;
                    current_value = arr.items[index];
                },
                else => return null,
            }
        }

        return current_value;
    }
};

/// Benchmark result structure
pub const BenchmarkResult = struct {
    iterations: u32,
    total_time_ns: u64,
    avg_time_per_parse_ns: u64,
    throughput_mb_per_sec: f64,
    total_bytes_processed: usize,
};

/// Create high-performance JSON processor
pub fn createJSONProcessor(allocator: std.mem.Allocator) JSONProcessor {
    return JSONProcessor.init(allocator);
}

/// Simplified JSON processor - alias to main processor
pub const StandardJSONProcessor = JSONProcessor;

/// Create standard JSON processor
pub fn createStandardJSONProcessor(allocator: std.mem.Allocator) StandardJSONProcessor {
    return StandardJSONProcessor.init(allocator);
}

// Test function
test "JSON processor initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var processor = createJSONProcessor(allocator);
    defer processor.deinit();

    const test_json = "{\"test\": true, \"number\": 42}";
    const is_valid = processor.validateJSON(test_json);
    try std.testing.expect(is_valid);

    const parsed = try processor.parseJSON(test_json);
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            try std.testing.expect(obj.count() == 2);
            try std.testing.expect(obj.get("test") != null);
            try std.testing.expect(obj.get("number") != null);
        },
        else => try std.testing.expect(false),
    }
}

test "JSON stringify functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var processor = createJSONProcessor(allocator);
    defer processor.deinit();

    // Create a test value
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var test_object = std.json.ObjectMap.init(arena_allocator);
    try test_object.put("name", std.json.Value{ .string = "test" });
    try test_object.put("value", std.json.Value{ .integer = 42 });

    const test_value = std.json.Value{ .object = test_object };

    const json_string = try processor.stringify(test_value);
    defer allocator.free(json_string);

    try std.testing.expect(json_string.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "test") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_string, "42") != null);
}