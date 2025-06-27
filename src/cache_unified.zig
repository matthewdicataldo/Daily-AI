const std = @import("std");
const core_types = @import("core_types.zig");

/// Unified caching interface that abstracts different cache backends
/// Consolidates the three separate cache systems: main, simple, and JSON cache
pub const UnifiedCache = struct {
    allocator: std.mem.Allocator,
    backend: CacheBackend,
    
    const Self = @This();

    pub const CacheBackend = union(enum) {
        simple: *@import("cache_simple.zig").SimpleCache,
        skytable: *@import("cache_main.zig").ContentCache,
        json_file: *@import("cache_json.zig").JsonCache,
        memory: MemoryCache,
    };

    pub const CacheType = enum {
        content,     // 3 days TTL - for extracted content
        llm,         // 1 hour TTL - for LLM responses  
        search,      // 30 minutes TTL - for search results
        session,     // Session duration - for temporary data
        
        pub fn getTTL(self: CacheType) u64 {
            return switch (self) {
                .content => 3 * 24 * 60 * 60,      // 3 days
                .llm => 60 * 60,                   // 1 hour
                .search => 30 * 60,                // 30 minutes
                .session => 15 * 60,               // 15 minutes
            };
        }
    };

    pub const CacheEntry = struct {
        data: []const u8,
        timestamp: i64,
        cache_type: CacheType,
        
        pub fn isExpired(self: CacheEntry) bool {
            const now = std.time.timestamp();
            const ttl = self.cache_type.getTTL();
            return (now - self.timestamp) > @as(i64, @intCast(ttl));
        }
    };

    // Simple in-memory cache for fallback
    const MemoryCache = struct {
        entries: std.StringHashMap(CacheEntry),
        
        pub fn init(allocator: std.mem.Allocator) MemoryCache {
            return MemoryCache{
                .entries = std.StringHashMap(CacheEntry).init(allocator),
            };
        }
        
        pub fn deinit(self: *MemoryCache, allocator: std.mem.Allocator) void {
            var iterator = self.entries.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.value_ptr.*.data);
                allocator.free(entry.key_ptr.*);
            }
            self.entries.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, backend_type: BackendType) Self {
        const backend = switch (backend_type) {
            .memory => CacheBackend{ .memory = MemoryCache.init(allocator) },
            .simple => blk: {
                // Try to get global simple cache, fallback to memory
                const simple_cache = @import("cache_simple.zig").getGlobalCache(allocator);
                break :blk CacheBackend{ .simple = simple_cache };
            },
            // For complex backends, default to memory for now to avoid pointer issues
            .skytable, .json_file => CacheBackend{ .memory = MemoryCache.init(allocator) },
        };

        return Self{
            .allocator = allocator,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            .memory => |*cache| cache.deinit(self.allocator),
            .simple => {}, // Global cache, don't deinit
            .skytable, .json_file => {}, // Using memory backend, already handled above
        }
    }

    /// Get cached value by key
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return switch (self.backend) {
            .simple => |cache| cache.get(key),
            .skytable => {
                // Simplified - return null since we're using memory backend fallback
                std.log.debug("Skytable cache get: {s}", .{key});
                return null;
            },
            .json_file => {
                // Simplified - return null since we're using memory backend fallback
                std.log.debug("JSON cache get: {s}", .{key});
                return null;
            },
            .memory => |*cache| blk: {
                if (cache.entries.get(key)) |entry| {
                    if (!entry.isExpired()) {
                        break :blk entry.data;
                    } else {
                        // Remove expired entry
                        _ = cache.entries.remove(key);
                    }
                }
                break :blk null;
            },
        };
    }

    /// Set cached value with automatic TTL based on cache type
    pub fn set(self: *Self, key: []const u8, value: []const u8, cache_type: CacheType) !void {
        return switch (self.backend) {
            .simple => |cache| cache.set(key, value, toSimpleCacheType(cache_type)),
            .skytable => {
                // Simplified - just log for now since we're using memory backend
                std.log.debug("Skytable cache set: {s}", .{key});
            },
            .json_file => {
                // Simplified - just log for now since we're using memory backend  
                std.log.debug("JSON cache set: {s}", .{key});
            },
            .memory => |*cache| {
                const owned_key = try self.allocator.dupe(u8, key);
                const owned_value = try self.allocator.dupe(u8, value);
                const entry = CacheEntry{
                    .data = owned_value,
                    .timestamp = std.time.timestamp(),
                    .cache_type = cache_type,
                };
                try cache.entries.put(owned_key, entry);
            },
        };
    }

    /// Cache NewsItem array with proper serialization
    pub fn cacheNewsItems(self: *Self, key: []const u8, items: []const core_types.NewsItem) !void {
        // Serialize NewsItems to JSON
        var json_string = std.ArrayList(u8).init(self.allocator);
        defer json_string.deinit();
        
        try json_string.appendSlice("[");
        for (items, 0..) |item, i| {
            if (i > 0) try json_string.appendSlice(",");
            
            // Simple JSON serialization for NewsItem
            try std.fmt.format(json_string.writer(), 
                \\{{"title":"{}","url":"{}","content":"{}","source_type":"{}","timestamp":{}}}
            , .{ 
                std.zig.fmtEscapes(item.title),
                std.zig.fmtEscapes(item.url),
                std.zig.fmtEscapes(item.content),
                @tagName(item.source_type),
                item.timestamp 
            });
        }
        try json_string.appendSlice("]");
        
        try self.set(key, json_string.items, .content);
    }

    /// Retrieve cached NewsItem array with deserialization
    pub fn getNewsItems(self: *Self, key: []const u8) ?[]core_types.NewsItem {
        const cached_data = self.get(key) orelse return null;
        
        // Parse JSON back to NewsItems (simplified parser)
        // In a real implementation, you'd use a proper JSON parser
        var items = std.ArrayList(core_types.NewsItem).init(self.allocator) catch return null;
        defer items.deinit();
        
        // For now, return null to avoid complexity - implement proper JSON parsing later
        _ = cached_data;
        return null;
    }

    /// Generate consistent cache keys
    pub fn generateKey(self: *Self, components: []const []const u8) ![]const u8 {
        var key = std.ArrayList(u8).init(self.allocator);
        defer key.deinit();
        
        for (components, 0..) |component, i| {
            if (i > 0) try key.appendSlice(":");
            try key.appendSlice(component);
        }
        
        return key.toOwnedSlice();
    }

    /// Clear expired entries (cleanup)
    pub fn cleanup(self: *Self) void {
        switch (self.backend) {
            .memory => |*cache| {
                var to_remove = std.ArrayList([]const u8).init(self.allocator);
                defer to_remove.deinit();
                
                var iterator = cache.entries.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.*.isExpired()) {
                        to_remove.append(entry.key_ptr.*) catch continue;
                    }
                }
                
                for (to_remove.items) |key| {
                    if (cache.entries.fetchRemove(key)) |removed| {
                        self.allocator.free(removed.value.data);
                        self.allocator.free(removed.key);
                    }
                }
            },
            else => {}, // Other backends handle cleanup internally
        }
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) CacheStats {
        return switch (self.backend) {
            .memory => |*cache| CacheStats{
                .total_entries = @intCast(cache.entries.count()),
                .backend_type = "memory",
            },
            .simple => CacheStats{
                .total_entries = 0, // Would need to implement in SimpleCache
                .backend_type = "simple",
            },
            .skytable => CacheStats{
                .total_entries = 0, // Would need to implement in ContentCache  
                .backend_type = "skytable",
            },
            .json_file => CacheStats{
                .total_entries = 0, // Would need to implement in JsonCache
                .backend_type = "json_file",
            },
        };
    }
};

pub const BackendType = enum {
    memory,
    simple,
    skytable,
    json_file,
};

pub const CacheStats = struct {
    total_entries: u32,
    backend_type: []const u8,
};

// Helper to convert to SimpleCache types
fn toSimpleCacheType(cache_type: UnifiedCache.CacheType) @import("cache_simple.zig").CacheType {
    return switch (cache_type) {
        .content => .content,
        .llm => .content, // Map to closest equivalent
        .search => .content,
        .session => .content,
    };
}

test "unified cache basic operations" {
    var cache = UnifiedCache.init(std.testing.allocator, .memory);
    defer cache.deinit();

    // Test basic set/get
    try cache.set("test_key", "test_value", .session);
    const value = cache.get("test_key");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?);

    // Test cache key generation
    const key = try cache.generateKey(&[_][]const u8{ "source", "reddit", "subreddit" });
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("source:reddit:subreddit", key);
}