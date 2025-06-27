const std = @import("std");
const types = @import("core_types.zig");

/// Streaming progress reporter for real-time terminal output
pub const ProgressStream = struct {
    allocator: std.mem.Allocator,
    operations: std.StringHashMap(OperationProgress),
    start_time: i64,
    last_update_time: i64,
    total_operations: u32,
    completed_operations: u32,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub const OperationProgress = struct {
        id: []const u8,
        name: []const u8,
        status: Status,
        progress: f32, // 0.0 to 1.0
        current_step: []const u8,
        items_processed: u32,
        total_items: ?u32,
        error_message: ?[]const u8,
        start_time: i64,
        
        pub const Status = enum {
            pending,
            running,
            completed,
            failed,
            
            pub fn toString(self: Status) []const u8 {
                return switch (self) {
                    .pending => "pending",
                    .running => "running", 
                    .completed => "completed",
                    .failed => "failed",
                };
            }
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .operations = std.StringHashMap(OperationProgress).init(allocator),
            .start_time = std.time.milliTimestamp(),
            .last_update_time = 0,
            .total_operations = 0,
            .completed_operations = 0,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.operations.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.current_step);
            if (entry.value_ptr.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.operations.deinit();
    }
    
    /// Register a new operation to track
    pub fn registerOperation(self: *Self, id: []const u8, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const operation = OperationProgress{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .status = .pending,
            .progress = 0.0,
            .current_step = try self.allocator.dupe(u8, "Initializing..."),
            .items_processed = 0,
            .total_items = null,
            .error_message = null,
            .start_time = std.time.milliTimestamp(),
        };
        
        try self.operations.put(try self.allocator.dupe(u8, id), operation);
        self.total_operations += 1;
        
        try self.emitUpdate();
    }
    
    /// Update operation progress
    pub fn updateOperation(self: *Self, id: []const u8, progress: f32, step: []const u8, items_processed: u32, total_items: ?u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.operations.getPtr(id)) |op| {
            self.allocator.free(op.current_step);
            op.current_step = try self.allocator.dupe(u8, step);
            op.progress = std.math.clamp(progress, 0.0, 1.0);
            op.items_processed = items_processed;
            op.total_items = total_items;
            op.status = if (progress >= 1.0) .completed else .running;
            
            if (op.status == .completed and progress >= 1.0) {
                self.completed_operations += 1;
            }
        }
        
        // Throttle updates to avoid spam (max every 100ms)
        const now = std.time.milliTimestamp();
        if (now - self.last_update_time > 100) {
            try self.emitUpdate();
            self.last_update_time = now;
        }
    }
    
    /// Mark operation as failed
    pub fn failOperation(self: *Self, id: []const u8, error_message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.operations.getPtr(id)) |op| {
            op.status = .failed;
            if (op.error_message) |old_msg| {
                self.allocator.free(old_msg);
            }
            op.error_message = try self.allocator.dupe(u8, error_message);
        }
        
        try self.emitUpdate();
    }
    
    /// Emit JSON progress update to stdout
    fn emitUpdate(self: *Self) !void {
        const now = std.time.milliTimestamp();
        const elapsed_seconds = @as(f64, @floatFromInt(now - self.start_time)) / 1000.0;
        
        // Calculate overall progress
        var total_progress: f32 = 0.0;
        var active_operations = std.ArrayList(OperationProgress).init(self.allocator);
        defer active_operations.deinit();
        
        var iterator = self.operations.iterator();
        while (iterator.next()) |entry| {
            const op = entry.value_ptr.*;
            total_progress += op.progress;
            if (op.status == .running or op.status == .pending) {
                try active_operations.append(op);
            }
        }
        
        const overall_progress = if (self.total_operations > 0) 
            total_progress / @as(f32, @floatFromInt(self.total_operations)) else 0.0;
        
        // Build JSON progress update
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();
        
        try json_buffer.appendSlice("{\"type\":\"progress\",\"data\":{");
        try std.fmt.format(json_buffer.writer(), "\"overall_progress\":{d:.2},", .{overall_progress});
        try std.fmt.format(json_buffer.writer(), "\"elapsed_seconds\":{d:.1},", .{elapsed_seconds});
        try std.fmt.format(json_buffer.writer(), "\"total_operations\":{d},", .{self.total_operations});
        try std.fmt.format(json_buffer.writer(), "\"completed_operations\":{d},", .{self.completed_operations});
        
        // Add active operations
        try json_buffer.appendSlice("\"active_operations\":[");
        for (active_operations.items, 0..) |op, i| {
            if (i > 0) try json_buffer.appendSlice(",");
            try json_buffer.appendSlice("{");
            try std.fmt.format(json_buffer.writer(), "\"id\":\"{s}\",", .{op.id});
            try std.fmt.format(json_buffer.writer(), "\"name\":\"{s}\",", .{op.name});
            try std.fmt.format(json_buffer.writer(), "\"status\":\"{s}\",", .{op.status.toString()});
            try std.fmt.format(json_buffer.writer(), "\"progress\":{d:.2},", .{op.progress});
            try std.fmt.format(json_buffer.writer(), "\"current_step\":\"{s}\",", .{op.current_step});
            try std.fmt.format(json_buffer.writer(), "\"items_processed\":{d}", .{op.items_processed});
            if (op.total_items) |total| {
                try std.fmt.format(json_buffer.writer(), ",\"total_items\":{d}", .{total});
            }
            try json_buffer.appendSlice("}");
        }
        try json_buffer.appendSlice("]");
        
        // Add summary message with elapsed time
        try std.fmt.format(json_buffer.writer(), ",\"elapsed_seconds\":{d:.1}", .{elapsed_seconds});
        try std.fmt.format(json_buffer.writer(), ",\"summary\":\"Processing {d}/{d} operations ({d:.0}% complete, {d:.1}s elapsed)\"", .{
            self.completed_operations, self.total_operations, overall_progress * 100.0, elapsed_seconds
        });
        
        try json_buffer.appendSlice("}}\n");
        
        // Output to stdout
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(json_buffer.items);
    }
    
    /// Emit final completion status
    pub fn complete(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.milliTimestamp();
        const elapsed_seconds = @as(f64, @floatFromInt(now - self.start_time)) / 1000.0;
        
        // Count failed operations
        var failed_count: u32 = 0;
        var iterator = self.operations.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.status == .failed) {
                failed_count += 1;
            }
        }
        
        // Build completion JSON
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();
        
        try json_buffer.appendSlice("{\"type\":\"completion\",\"data\":{");
        try std.fmt.format(json_buffer.writer(), "\"total_time_seconds\":{d:.1},", .{elapsed_seconds});
        try std.fmt.format(json_buffer.writer(), "\"total_operations\":{d},", .{self.total_operations});
        try std.fmt.format(json_buffer.writer(), "\"completed_operations\":{d},", .{self.completed_operations});
        try std.fmt.format(json_buffer.writer(), "\"failed_operations\":{d},", .{failed_count});
        try std.fmt.format(json_buffer.writer(), "\"success_rate\":{d:.1}", .{
            if (self.total_operations > 0) 
                @as(f64, @floatFromInt(self.completed_operations)) / @as(f64, @floatFromInt(self.total_operations)) * 100.0 
            else 100.0
        });
        try json_buffer.appendSlice("}}\n");
        
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(json_buffer.items);
    }
};

/// Progress tracking helper for individual operations
pub const OperationTracker = struct {
    stream: *ProgressStream,
    operation_id: []const u8,
    
    pub fn init(stream: *ProgressStream, operation_id: []const u8) OperationTracker {
        return OperationTracker{
            .stream = stream,
            .operation_id = operation_id,
        };
    }
    
    pub fn update(self: OperationTracker, progress: f32, step: []const u8, items_processed: u32, total_items: ?u32) !void {
        try self.stream.updateOperation(self.operation_id, progress, step, items_processed, total_items);
    }
    
    pub fn fail(self: OperationTracker, error_message: []const u8) !void {
        try self.stream.failOperation(self.operation_id, error_message);
    }
    
    pub fn complete(self: OperationTracker, final_message: []const u8) !void {
        try self.stream.updateOperation(self.operation_id, 1.0, final_message, 0, null);
    }
};