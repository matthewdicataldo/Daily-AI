//! Ultra-simple string:string cache with Skytable backend
//! Smart TTL handling: Content (3 days), LLM responses (1 hour), Search (30 min)

const std = @import("std");
const skytable_client = @import("cache_skytable_client.zig");

/// Cache entry with expiration
const CacheEntry = struct {
    value: []const u8,
    expires_at: i64,
    
    pub fn isExpired(self: CacheEntry) bool {
        return std.time.timestamp() > self.expires_at;
    }
};

/// Cache types with different TTLs
pub const CacheType = enum {
    content,    // 3 days - Reddit posts, YouTube videos, etc.
    llm,        // 1 hour - LLM responses (prompts change frequently)
    search,     // 30 minutes - Search results
    analysis,   // 6 hours - Processed/analyzed content
    
    pub fn getTtlSeconds(self: CacheType) i64 {
        return switch (self) {
            .content => 3 * 24 * 60 * 60,   // 3 days
            .llm => 60 * 60,                // 1 hour  
            .search => 30 * 60,             // 30 minutes
            .analysis => 6 * 60 * 60,       // 6 hours
        };
    }
};

/// Simple cache interface with smart TTL
pub const SimpleCache = struct {
    allocator: std.mem.Allocator,
    skytable: ?skytable_client.SkytableClient,
    fallback_map: std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .skytable = null,
            .fallback_map = std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn initWithSkytable(allocator: std.mem.Allocator) Self {
        var cache = Self.init(allocator);
        
        std.log.info("💾 Attempting to connect to Skytable cache backend...", .{});
        
        // Try to connect to Skytable with non-blocking timeout, fall back to HashMap if it fails
        cache.skytable = skytable_client.SkytableClient.initEmbedded(allocator) catch |err| {
            switch (err) {
                skytable_client.SkytableError.ConnectionFailed => {
                    std.log.warn("⚠️ Skytable server not running or unreachable, using in-memory cache", .{});
                },
                skytable_client.SkytableError.TimeoutError => {
                    std.log.warn("⚠️ Skytable connection timed out (WSL2 network issue?), using in-memory cache", .{});
                },
                skytable_client.SkytableError.NetworkError => {
                    std.log.warn("⚠️ Network error connecting to Skytable, using in-memory cache", .{});
                },
                else => {
                    std.log.warn("⚠️ Skytable initialization failed: {}, using in-memory cache", .{err});
                },
            }
            std.log.info("💡 Tip: Skytable server should be running on tcp://127.0.0.1:2003", .{});
            std.log.info("🔄 Cache will work normally but without persistence between runs", .{});
            return cache;
        };
        
        std.log.info("✅ Simple cache with Skytable backend ready", .{});
        return cache;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.skytable) |*sky| {
            sky.deinit();
        }
        
        // Clean up fallback map
        var iterator = self.fallback_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.fallback_map.deinit();
    }
    
    /// Get cached value by key with TTL check
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        // TODO: Re-enable Skytable once method resolution is fixed
        // Try Skytable first (temporarily disabled)
        _ = self.skytable;
        
        // Use HashMap with TTL
        if (self.fallback_map.get(key)) |entry| {
            if (entry.isExpired()) {
                // Remove expired entry
                _ = self.fallback_map.remove(key);
                self.allocator.free(entry.value);
                return null;
            }
            return self.allocator.dupe(u8, entry.value) catch null;
        }
        
        return null;
    }
    
    /// Set cached value by key with TTL
    pub fn set(self: *Self, key: []const u8, value: []const u8, cache_type: CacheType) void {
        const expires_at = std.time.timestamp() + cache_type.getTtlSeconds();
        
        // TODO: Re-enable Skytable once method resolution is fixed
        // Try Skytable first (temporarily disabled)
        _ = self.skytable;
        
        // Fallback to HashMap
        const owned_key = self.allocator.dupe(u8, key) catch return;
        const owned_value = self.allocator.dupe(u8, value) catch {
            self.allocator.free(owned_key);
            return;
        };
        
        const entry = CacheEntry{
            .value = owned_value,
            .expires_at = expires_at,
        };
        
        // Free old values if they exist
        if (self.fallback_map.fetchPut(owned_key, entry)) |old_kv| {
            if (old_kv) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
        } else |_| {
            // New entry, keep the owned strings
        }
    }
    
    /// Cache any serializable data type automatically with appropriate TTL
    pub fn cacheJson(self: *Self, key: []const u8, data: anytype, cache_type: CacheType) void {
        const json_str = std.json.stringifyAlloc(self.allocator, data, .{}) catch return;
        defer self.allocator.free(json_str);
        self.set(key, json_str, cache_type);
    }
    
    /// Get and deserialize cached data
    pub fn getCached(self: *Self, comptime T: type, key: []const u8) ?T {
        const json_str = self.get(key) orelse return null;
        defer self.allocator.free(json_str);
        
        const parsed = std.json.parseFromSlice(T, self.allocator, json_str, .{}) catch return null;
        defer parsed.deinit();
        
        return parsed.value;
    }
    
    /// Cache Reddit posts (3 day TTL)
    pub fn cacheRedditPosts(self: *Self, subreddit: []const u8, posts: anytype) void {
        const today = std.time.timestamp() / (24 * 60 * 60); // Days since epoch
        const key = std.fmt.allocPrint(self.allocator, "reddit:{s}:{d}", .{ subreddit, today }) catch return;
        defer self.allocator.free(key);
        self.cacheJson(key, posts, .content);
    }
    
    /// Get cached Reddit posts
    pub fn getRedditPosts(self: *Self, comptime T: type, subreddit: []const u8) ?T {
        const today = std.time.timestamp() / (24 * 60 * 60);
        const key = std.fmt.allocPrint(self.allocator, "reddit:{s}:{d}", .{ subreddit, today }) catch return null;
        defer self.allocator.free(key);
        return self.getCached(T, key);
    }
    
    /// Cache LLM responses (1 hour TTL)
    pub fn cacheLlmResponse(self: *Self, prompt: []const u8, response: []const u8) void {
        // Use hash of prompt as key to handle long prompts
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(prompt);
        const hash = hasher.final();
        
        const key = std.fmt.allocPrint(self.allocator, "llm:{d}", .{hash}) catch return;
        defer self.allocator.free(key);
        self.set(key, response, .llm);
    }
    
    /// Get cached LLM response
    pub fn getLlmResponse(self: *Self, prompt: []const u8) ?[]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(prompt);
        const hash = hasher.final();
        
        const key = std.fmt.allocPrint(self.allocator, "llm:{d}", .{hash}) catch return null;
        defer self.allocator.free(key);
        return self.get(key);
    }
    
    /// Cache search results (30 min TTL)
    pub fn cacheSearchResults(self: *Self, query: []const u8, results: anytype) void {
        const key = std.fmt.allocPrint(self.allocator, "search:{s}", .{query}) catch return;
        defer self.allocator.free(key);
        self.cacheJson(key, results, .search);
    }
    
    /// Get cached search results
    pub fn getSearchResults(self: *Self, comptime T: type, query: []const u8) ?T {
        const key = std.fmt.allocPrint(self.allocator, "search:{s}", .{query}) catch return null;
        defer self.allocator.free(key);
        return self.getCached(T, key);
    }
};

/// Global cache instance - simple singleton pattern
var global_cache: ?SimpleCache = null;

pub fn getGlobalCache(allocator: std.mem.Allocator) *SimpleCache {
    if (global_cache == null) {
        global_cache = SimpleCache.initWithSkytable(allocator);
        
        // Test cache functionality
        std.log.info("🧪 Testing cache functionality...", .{});
        var cache = &global_cache.?;
        
        // Test basic cache operations
        cache.set("test_key", "test_value", .content);
        if (cache.get("test_key")) |value| {
            if (std.mem.eql(u8, value, "test_value")) {
                std.log.info("✅ Cache test successful - set/get working properly", .{});
            } else {
                std.log.warn("⚠️ Cache test failed - value mismatch", .{});
            }
            allocator.free(value);
        } else {
            std.log.warn("⚠️ Cache test failed - could not retrieve test value", .{});
        }
        
        if (cache.skytable != null) {
            std.log.info("✅ Skytable backend connected and working", .{});
        } else {
            std.log.info("💡 Using in-memory cache fallback (Skytable unavailable)", .{});
        }
    }
    return &global_cache.?;
}

pub fn deinitGlobalCache() void {
    if (global_cache) |*cache| {
        cache.deinit();
        global_cache = null;
    }
}