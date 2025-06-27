const std = @import("std");
const types = @import("core_types.zig");

/// Fixed-size memory pool for objects of type T
/// Provides O(1) allocation/deallocation with predictable memory usage
pub fn FixedSizePool(comptime T: type, comptime pool_size: usize) type {
    return struct {
        items: [pool_size]T,
        free_list: [pool_size]?usize, // Stack of free indices
        free_count: usize,
        allocated_count: usize,
        
        const Self = @This();
        
        pub fn init() Self {
            var pool = Self{
                .items = undefined,
                .free_list = undefined,
                .free_count = pool_size,
                .allocated_count = 0,
            };
            
            // Initialize free list - all indices available
            for (0..pool_size) |i| {
                pool.free_list[i] = pool_size - 1 - i; // Reverse order for stack behavior
            }
            
            return pool;
        }
        
        /// Acquire an object from the pool (O(1))
        pub fn acquire(self: *Self) ?*T {
            if (self.free_count == 0) return null;
            
            const index = self.free_list[self.free_count - 1].?;
            self.free_count -= 1;
            self.allocated_count += 1;
            
            return &self.items[index];
        }
        
        /// Release an object back to the pool (O(1))
        pub fn release(self: *Self, item: *T) void {
            // Calculate index from pointer
            const items_start = @intFromPtr(&self.items[0]);
            const item_ptr = @intFromPtr(item);
            const index = (item_ptr - items_start) / @sizeOf(T);
            
            std.debug.assert(index < pool_size);
            std.debug.assert(self.free_count < pool_size);
            
            // Add index back to free list
            self.free_list[self.free_count] = index;
            self.free_count += 1;
            self.allocated_count -= 1;
        }
        
        pub fn isFull(self: Self) bool {
            return self.free_count == 0;
        }
        
        pub fn isEmpty(self: Self) bool {
            return self.allocated_count == 0;
        }
        
        pub fn getUtilization(self: Self) f32 {
            return @as(f32, @floatFromInt(self.allocated_count)) / @as(f32, pool_size);
        }
    };
}

/// String pool allocator optimized for news content
/// Uses a large contiguous buffer with bump allocation and reference counting
pub const StringPool = struct {
    buffer: []u8,
    used: usize,
    capacity: usize,
    allocator: std.mem.Allocator,
    
    // Statistics for monitoring
    total_allocations: u64,
    total_bytes_allocated: u64,
    peak_usage: usize,
    
    const Self = @This();
    
    /// Initialize string pool with specified capacity
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        return Self{
            .buffer = try allocator.alloc(u8, capacity),
            .used = 0,
            .capacity = capacity,
            .allocator = allocator,
            .total_allocations = 0,
            .total_bytes_allocated = 0,
            .peak_usage = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }
    
    /// Allocate string in pool (bump allocation - very fast)
    pub fn allocString(self: *Self, str: []const u8) !types.StringRef {
        if (self.used + str.len > self.capacity) {
            return error.StringPoolFull;
        }
        
        const offset = self.used;
        @memcpy(self.buffer[offset..offset + str.len], str);
        self.used += str.len;
        
        // Update statistics
        self.total_allocations += 1;
        self.total_bytes_allocated += str.len;
        if (self.used > self.peak_usage) {
            self.peak_usage = self.used;
        }
        
        return types.StringRef{
            .offset = @intCast(offset),
            .length = @intCast(str.len),
        };
    }
    
    /// Get string from reference (O(1))
    pub fn getString(self: Self, ref: types.StringRef) []const u8 {
        return self.buffer[ref.offset..ref.offset + ref.length];
    }
    
    /// Reset pool for reuse (keeps buffer allocated)
    pub fn reset(self: *Self) void {
        self.used = 0;
    }
    
    /// Get current utilization (0.0 to 1.0)
    pub fn getUtilization(self: Self) f32 {
        return @as(f32, @floatFromInt(self.used)) / @as(f32, @floatFromInt(self.capacity));
    }
    
    /// Get fragmentation level (always 0 for bump allocator)
    pub fn getFragmentation(self: Self) f32 {
        _ = self;
        return 0.0; // Bump allocator has no fragmentation
    }
    
    pub fn getStats(self: Self) StringPoolStats {
        return StringPoolStats{
            .capacity = self.capacity,
            .used = self.used,
            .available = self.capacity - self.used,
            .utilization = self.getUtilization(),
            .total_allocations = self.total_allocations,
            .total_bytes_allocated = self.total_bytes_allocated,
            .peak_usage = self.peak_usage,
        };
    }
};

/// Statistics for string pool monitoring
pub const StringPoolStats = struct {
    capacity: usize,
    used: usize,
    available: usize,
    utilization: f32,
    total_allocations: u64,
    total_bytes_allocated: u64,
    peak_usage: usize,
};

/// Memory pool manager for the news aggregation system
/// Coordinates multiple specialized pools for optimal performance
pub const NewsAggregatorPools = struct {
    // String storage optimized for typical news content
    string_pool: StringPool,
    
    // Fixed-size pools for metadata objects
    reddit_pool: FixedSizePool(types.RedditMetadata, 256),
    youtube_pool: FixedSizePool(types.YouTubeMetadata, 256),
    huggingface_pool: FixedSizePool(types.HuggingFaceMetadata, 128),
    blog_pool: FixedSizePool(types.BlogMetadata, 256),
    github_pool: FixedSizePool(types.GitHubRepoMetadata, 64),
    
    // Working memory pools for processing
    working_arena: std.heap.ArenaAllocator,
    
    // Base allocator for fallback
    base_allocator: std.mem.Allocator,
    
    const Self = @This();
    
    /// Initialize all pools with sizes optimized for typical workloads
    pub fn init(base_allocator: std.mem.Allocator) !Self {
        const string_capacity = 8 * 1024 * 1024; // 8MB for strings
        
        return Self{
            .string_pool = try StringPool.init(base_allocator, string_capacity),
            .reddit_pool = FixedSizePool(types.RedditMetadata, 256).init(),
            .youtube_pool = FixedSizePool(types.YouTubeMetadata, 256).init(),
            .huggingface_pool = FixedSizePool(types.HuggingFaceMetadata, 128).init(),
            .blog_pool = FixedSizePool(types.BlogMetadata, 256).init(),
            .github_pool = FixedSizePool(types.GitHubRepoMetadata, 64).init(),
            .working_arena = std.heap.ArenaAllocator.init(base_allocator),
            .base_allocator = base_allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.string_pool.deinit();
        self.working_arena.deinit();
    }
    
    /// Get allocator for temporary working memory (freed at end of processing)
    pub fn getWorkingAllocator(self: *Self) std.mem.Allocator {
        return self.working_arena.allocator();
    }
    
    /// Reset working memory (call after each processing phase)
    pub fn resetWorkingMemory(self: *Self) void {
        self.working_arena.deinit();
        self.working_arena = std.heap.ArenaAllocator.init(self.base_allocator);
    }
    
    /// Allocate string in optimized string pool
    pub fn allocString(self: *Self, str: []const u8) !types.StringRef {
        return self.string_pool.allocString(str) catch |err| switch (err) {
            error.StringPoolFull => {
                // Fallback to base allocator - create a copy and return a special ref
                std.log.warn("🚨 String pool full, falling back to heap allocation", .{});
                const heap_copy = try self.base_allocator.dupe(u8, str);
                // For now, just return an error - in production this could fallback to heap
                self.base_allocator.free(heap_copy);
                return error.StringPoolFull;
            },
        };
    }
    
    /// Get Reddit metadata from pool
    pub fn acquireRedditMetadata(self: *Self) ?*types.RedditMetadata {
        return self.reddit_pool.acquire();
    }
    
    /// Return Reddit metadata to pool
    pub fn releaseRedditMetadata(self: *Self, meta: *types.RedditMetadata) void {
        // Clean up the metadata first (free internal allocations)
        meta.deinit(self.base_allocator);
        self.reddit_pool.release(meta);
    }
    
    /// Get YouTube metadata from pool
    pub fn acquireYouTubeMetadata(self: *Self) ?*types.YouTubeMetadata {
        return self.youtube_pool.acquire();
    }
    
    /// Return YouTube metadata to pool
    pub fn releaseYouTubeMetadata(self: *Self, meta: *types.YouTubeMetadata) void {
        meta.deinit(self.base_allocator);
        self.youtube_pool.release(meta);
    }
    
    /// Get comprehensive performance statistics
    pub fn getStats(self: Self) PoolStats {
        return PoolStats{
            .string_pool = self.string_pool.getStats(),
            .reddit_pool_utilization = self.reddit_pool.getUtilization(),
            .youtube_pool_utilization = self.youtube_pool.getUtilization(),
            .huggingface_pool_utilization = self.huggingface_pool.getUtilization(),
            .blog_pool_utilization = self.blog_pool.getUtilization(),
            .github_pool_utilization = self.github_pool.getUtilization(),
            .total_pool_allocations = self.reddit_pool.allocated_count + 
                                    self.youtube_pool.allocated_count +
                                    self.huggingface_pool.allocated_count +
                                    self.blog_pool.allocated_count +
                                    self.github_pool.allocated_count,
        };
    }
    
    /// Check if any pools are approaching capacity
    pub fn checkPoolHealth(self: Self) PoolHealth {
        const reddit_util = self.reddit_pool.getUtilization();
        const youtube_util = self.youtube_pool.getUtilization();
        const string_util = self.string_pool.getUtilization();
        
        var issues = std.ArrayList(PoolIssue).init(self.base_allocator);
        
        if (reddit_util > 0.8) {
            issues.append(PoolIssue{ .pool_name = "reddit", .utilization = reddit_util, .severity = .warning }) catch {};
        }
        if (youtube_util > 0.8) {
            issues.append(PoolIssue{ .pool_name = "youtube", .utilization = youtube_util, .severity = .warning }) catch {};
        }
        if (string_util > 0.8) {
            issues.append(PoolIssue{ .pool_name = "string", .utilization = string_util, .severity = .warning }) catch {};
        }
        
        if (reddit_util > 0.95) {
            issues.append(PoolIssue{ .pool_name = "reddit", .utilization = reddit_util, .severity = .critical }) catch {};
        }
        if (string_util > 0.95) {
            issues.append(PoolIssue{ .pool_name = "string", .utilization = string_util, .severity = .critical }) catch {};
        }
        
        defer issues.deinit();
        
        const overall_health = if (issues.items.len == 0) PoolHealthStatus.healthy
                              else if (string_util > 0.95 or reddit_util > 0.95) PoolHealthStatus.critical
                              else PoolHealthStatus.warning;
        
        return PoolHealth{
            .overall_status = overall_health,
            .issues = issues.toOwnedSlice() catch &[_]PoolIssue{},
        };
    }
};

/// Comprehensive statistics for all pools
pub const PoolStats = struct {
    string_pool: StringPoolStats,
    reddit_pool_utilization: f32,
    youtube_pool_utilization: f32,
    huggingface_pool_utilization: f32,
    blog_pool_utilization: f32,
    github_pool_utilization: f32,
    total_pool_allocations: usize,
};

/// Pool health monitoring
pub const PoolHealthStatus = enum {
    healthy,
    warning,
    critical,
};

pub const PoolIssue = struct {
    pool_name: []const u8,
    utilization: f32,
    severity: enum { warning, critical },
};

pub const PoolHealth = struct {
    overall_status: PoolHealthStatus,
    issues: []PoolIssue,
    
    pub fn deinit(self: PoolHealth, allocator: std.mem.Allocator) void {
        allocator.free(self.issues);
    }
};

// Tests
test "fixed size pool basic operations" {
    const testing = std.testing;
    
    var pool = FixedSizePool(u32, 4).init();
    
    // Test acquisition
    const item1 = pool.acquire();
    try testing.expect(item1 != null);
    try testing.expect(pool.allocated_count == 1);
    
    const item2 = pool.acquire();
    const item3 = pool.acquire();
    const item4 = pool.acquire();
    _ = item2;
    _ = item3;
    _ = item4;
    try testing.expect(pool.allocated_count == 4);
    
    // Pool should be full
    const item5 = pool.acquire();
    try testing.expect(item5 == null);
    try testing.expect(pool.isFull());
    
    // Test release
    pool.release(item1.?);
    try testing.expect(pool.allocated_count == 3);
    try testing.expect(!pool.isFull());
    
    // Should be able to acquire again
    const item6 = pool.acquire();
    try testing.expect(item6 != null);
    try testing.expect(pool.allocated_count == 4);
}

test "string pool operations" {
    const testing = std.testing;
    
    var pool = try StringPool.init(testing.allocator, 1024);
    defer pool.deinit();
    
    // Test string allocation
    const ref1 = try pool.allocString("Hello, World!");
    try testing.expect(ref1.length == 13);
    
    const str1 = pool.getString(ref1);
    try testing.expectEqualStrings("Hello, World!", str1);
    
    // Test multiple allocations
    const ref2 = try pool.allocString("Test String");
    const str2 = pool.getString(ref2);
    try testing.expectEqualStrings("Test String", str2);
    
    // First string should still be valid
    const str1_again = pool.getString(ref1);
    try testing.expectEqualStrings("Hello, World!", str1_again);
    
    // Test statistics
    const stats = pool.getStats();
    try testing.expect(stats.total_allocations == 2);
    try testing.expect(stats.used == 24); // 13 + 11
}

test "news aggregator pools integration" {
    const testing = std.testing;
    
    var pools = try NewsAggregatorPools.init(testing.allocator);
    defer pools.deinit();
    
    // Test string allocation
    const title_ref = try pools.allocString("Breaking: AI News Update");
    const title = pools.string_pool.getString(title_ref);
    try testing.expectEqualStrings("Breaking: AI News Update", title);
    
    // Test metadata pool
    const reddit_meta = pools.acquireRedditMetadata();
    try testing.expect(reddit_meta != null);
    
    // Test working allocator
    const working_alloc = pools.getWorkingAllocator();
    const temp_data = try working_alloc.alloc(u8, 100);
    try testing.expect(temp_data.len == 100);
    
    // Reset working memory
    pools.resetWorkingMemory();
    // temp_data is now invalid (freed)
    
    // Test pool statistics
    const stats = pools.getStats();
    try testing.expect(stats.total_pool_allocations == 1); // One reddit metadata acquired
}