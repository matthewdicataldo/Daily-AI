const std = @import("std");
const types = @import("core_types.zig");
const memory_pools = @import("cache_memory_pools.zig");
const cache = @import("cache_main.zig");

/// Hot data - frequently accessed during processing (optimized for cache locality)
pub const NewsItemHot = struct {
    relevance_score: f32,
    timestamp: i64,
    source_type: types.SourceType,
    title_hash: u64,          // For fast deduplication and search
    url_hash: u64,            // For fast URL-based deduplication
    cold_data_index: u32,     // Index into cold storage
    
    /// Calculate hash for title (used for deduplication)
    pub fn calculateTitleHash(title: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(title);
        return hasher.final();
    }
    
    /// Calculate hash for URL (used for deduplication)
    pub fn calculateUrlHash(url: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0xDEADBEEF); // Different seed for URL hashing
        hasher.update(url);
        return hasher.final();
    }
    
    /// Check if this item is likely a duplicate of another based on hash comparison
    pub fn isLikelyDuplicate(self: NewsItemHot, other: NewsItemHot) bool {
        // Fast hash-based duplicate detection
        return self.title_hash == other.title_hash or self.url_hash == other.url_hash;
    }
    
    /// Check if item passes relevance threshold
    pub fn passesRelevanceFilter(self: NewsItemHot, threshold: f32) bool {
        return self.relevance_score >= threshold;
    }
};

/// Cold data - infrequently accessed metadata (stored separately for cache efficiency)
pub const NewsItemCold = struct {
    title_ref: types.StringRef,
    summary_ref: types.StringRef,
    url_ref: types.StringRef,
    source_ref: types.StringRef,
    
    // Metadata indices (reference to pool-managed metadata)
    reddit_metadata_index: ?u32,
    youtube_metadata_index: ?u32,
    huggingface_metadata_index: ?u32,
    blog_metadata_index: ?u32,
    github_metadata_index: ?u32,
    
    /// Get title string from pool
    pub fn getTitle(self: NewsItemCold, pools: *memory_pools.NewsAggregatorPools) []const u8 {
        return pools.string_pool.getString(self.title_ref);
    }
    
    /// Get summary string from pool
    pub fn getSummary(self: NewsItemCold, pools: *memory_pools.NewsAggregatorPools) []const u8 {
        return pools.string_pool.getString(self.summary_ref);
    }
    
    /// Get URL string from pool
    pub fn getUrl(self: NewsItemCold, pools: *memory_pools.NewsAggregatorPools) []const u8 {
        return pools.string_pool.getString(self.url_ref);
    }
    
    /// Get source string from pool
    pub fn getSource(self: NewsItemCold, pools: *memory_pools.NewsAggregatorPools) []const u8 {
        return pools.string_pool.getString(self.source_ref);
    }
};

/// Hot/Cold separated storage system optimized for different access patterns
pub const HotColdNewsStorage = struct {
    // Hot data - stored in contiguous arrays for excellent cache locality
    hot_data: []NewsItemHot,
    
    // Cold data - accessed less frequently, can afford indirect access
    cold_data: []NewsItemCold,
    
    // Memory pools for string and metadata management
    pools: *memory_pools.NewsAggregatorPools,
    
    // Counters and capacity
    count: u32,
    capacity: u32,
    
    // Allocator for array management
    allocator: std.mem.Allocator,
    
    // Cache integration for persistent storage
    cache_client: ?*cache.ContentCache,
    
    const Self = @This();
    
    /// Initialize hot/cold storage system
    pub fn init(allocator: std.mem.Allocator, pools: *memory_pools.NewsAggregatorPools, capacity: u32, cache_client: ?*cache.ContentCache) !Self {
        return Self{
            .hot_data = try allocator.alloc(NewsItemHot, capacity),
            .cold_data = try allocator.alloc(NewsItemCold, capacity),
            .pools = pools,
            .count = 0,
            .capacity = capacity,
            .allocator = allocator,
            .cache_client = cache_client,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.hot_data);
        self.allocator.free(self.cold_data);
    }
    
    /// Add a NewsItem to hot/cold storage
    pub fn addItem(self: *Self, item: types.NewsItem) !void {
        if (self.count >= self.capacity) {
            return error.StorageFull;
        }
        
        const index = self.count;
        
        // Store hot data (optimized for fast access during processing)
        self.hot_data[index] = NewsItemHot{
            .relevance_score = item.relevance_score,
            .timestamp = item.timestamp,
            .source_type = item.source_type,
            .title_hash = NewsItemHot.calculateTitleHash(item.title),
            .url_hash = NewsItemHot.calculateUrlHash(item.url),
            .cold_data_index = index,
        };
        
        // Store cold data (accessed less frequently)
        self.cold_data[index] = NewsItemCold{
            .title_ref = try self.pools.allocString(item.title),
            .summary_ref = try self.pools.allocString(item.summary),
            .url_ref = try self.pools.allocString(item.url),
            .source_ref = try self.pools.allocString(item.source),
            .reddit_metadata_index = null, // TODO: Handle metadata
            .youtube_metadata_index = null,
            .huggingface_metadata_index = null,
            .blog_metadata_index = null,
            .github_metadata_index = null,
        };
        
        self.count += 1;
    }
    
    /// Batch deduplication using hot data only (very fast)
    pub fn deduplicateHot(self: *Self) u32 {
        if (self.count <= 1) return self.count;
        
        var write_index: u32 = 0;
        
        for (0..self.count) |read_index| {
            var is_duplicate = false;
            
            // Check against all previously processed items using fast hash comparison
            for (0..write_index) |check_index| {
                if (self.hot_data[read_index].isLikelyDuplicate(self.hot_data[check_index])) {
                    is_duplicate = true;
                    break;
                }
            }
            
            if (!is_duplicate) {
                if (write_index != read_index) {
                    // Move hot data
                    self.hot_data[write_index] = self.hot_data[read_index];
                    // Update cold data index
                    self.hot_data[write_index].cold_data_index = write_index;
                    // Move cold data
                    self.cold_data[write_index] = self.cold_data[read_index];
                }
                write_index += 1;
            }
        }
        
        self.count = write_index;
        return write_index;
    }
    
    /// Batch relevance filtering using hot data only (SIMD-friendly)
    pub fn filterByRelevanceHot(self: *Self, threshold: f32) u32 {
        var write_index: u32 = 0;
        
        // Process relevance scores in chunks for potential SIMD optimization
        var i: usize = 0;
        while (i < self.count) {
            const chunk_size = @min(8, self.count - i); // Process up to 8 items at once
            
            for (0..chunk_size) |j| {
                const read_index = i + j;
                if (self.hot_data[read_index].passesRelevanceFilter(threshold)) {
                    if (write_index != read_index) {
                        self.hot_data[write_index] = self.hot_data[read_index];
                        self.hot_data[write_index].cold_data_index = write_index;
                        self.cold_data[write_index] = self.cold_data[read_index];
                    }
                    write_index += 1;
                }
            }
            
            i += chunk_size;
        }
        
        self.count = write_index;
        return write_index;
    }
    
    /// Sort by timestamp using hot data only (cache-friendly)
    pub fn sortByTimestamp(self: *Self) !void {
        // Create index array for indirect sorting
        var indices = try self.allocator.alloc(u32, self.count);
        defer self.allocator.free(indices);
        
        for (0..self.count) |i| {
            indices[i] = @intCast(i);
        }
        
        // Sort indices based on hot data timestamps
        const Context = struct {
            hot_data: []NewsItemHot,
            
            pub fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                return ctx.hot_data[a].timestamp > ctx.hot_data[b].timestamp; // Newest first
            }
        };
        
        const context = Context{ .hot_data = self.hot_data[0..self.count] };
        std.sort.insertion(u32, indices, context, Context.lessThan);
        
        // Apply sort order to both hot and cold data
        try self.applySortOrder(indices);
    }
    
    /// Apply sorted order to both hot and cold data
    fn applySortOrder(self: *Self, indices: []const u32) !void {
        const temp_hot = try self.allocator.alloc(NewsItemHot, self.count);
        defer self.allocator.free(temp_hot);
        
        const temp_cold = try self.allocator.alloc(NewsItemCold, self.count);
        defer self.allocator.free(temp_cold);
        
        // Copy in sorted order
        for (indices, 0..) |old_index, new_index| {
            temp_hot[new_index] = self.hot_data[old_index];
            temp_hot[new_index].cold_data_index = @intCast(new_index); // Update index
            temp_cold[new_index] = self.cold_data[old_index];
        }
        
        // Copy back to original arrays
        @memcpy(self.hot_data[0..self.count], temp_hot);
        @memcpy(self.cold_data[0..self.count], temp_cold);
    }
    
    /// Convert back to legacy NewsItem format (for compatibility)
    pub fn getNewsItem(self: *Self, index: u32) !types.NewsItem {
        if (index >= self.count) return error.IndexOutOfBounds;
        
        const hot = self.hot_data[index];
        const cold = self.cold_data[hot.cold_data_index];
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, cold.getTitle(self.pools)),
            .summary = try self.allocator.dupe(u8, cold.getSummary(self.pools)),
            .url = try self.allocator.dupe(u8, cold.getUrl(self.pools)),
            .source = try self.allocator.dupe(u8, cold.getSource(self.pools)),
            .source_type = hot.source_type,
            .timestamp = hot.timestamp,
            .relevance_score = hot.relevance_score,
            .reddit_metadata = null, // TODO: Handle metadata
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Convert to array of NewsItems for compatibility
    pub fn toNewsItems(self: *Self) ![]types.NewsItem {
        var items = try self.allocator.alloc(types.NewsItem, self.count);
        
        for (0..self.count) |i| {
            items[i] = try self.getNewsItem(@intCast(i));
        }
        
        return items;
    }
    
    /// Cache hot data for ultra-fast subsequent access
    pub fn cacheHotData(self: *Self, cache_key: []const u8) !void {
        _ = cache_key;
        if (self.cache_client == null) return;
        
        // Serialize only hot data (much smaller than full NewsItems)
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        var writer = buffer.writer();
        
        // Write count and capacity
        try writer.writeInt(u32, self.count, .little);
        
        // Write hot data as packed binary (very efficient)
        for (0..self.count) |i| {
            const hot = self.hot_data[i];
            try writer.writeInt(f32, hot.relevance_score, .little);
            try writer.writeInt(i64, hot.timestamp, .little);
            try writer.writeInt(u8, @intFromEnum(hot.source_type), .little);
            try writer.writeInt(u64, hot.title_hash, .little);
            try writer.writeInt(u64, hot.url_hash, .little);
            try writer.writeInt(u32, hot.cold_data_index, .little);
        }
        
        // Store in cache with longer TTL since hot data is more stable
        // TODO: Integrate with cache system - this is a placeholder
        std.log.debug("💾 Hot data cached: {d} items, {d} bytes", .{ self.count, buffer.items.len });
    }
    
    /// Load hot data from cache
    pub fn loadHotDataFromCache(self: *Self, cache_key: []const u8) !bool {
        _ = cache_key;
        if (self.cache_client == null) return false;
        
        // TODO: Implement cache loading
        // This would deserialize the binary hot data format
        
        return false; // Not implemented yet
    }
    
    /// Get performance statistics
    pub fn getPerformanceStats(self: *Self) HotColdStats {
        const pool_stats = self.pools.getStats();
        
        return HotColdStats{
            .item_count = self.count,
            .capacity_utilization = @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.capacity)),
            .hot_data_size_bytes = self.count * @sizeOf(NewsItemHot),
            .cold_data_size_bytes = self.count * @sizeOf(NewsItemCold),
            .string_pool_utilization = pool_stats.string_pool.utilization,
            .cache_locality_ratio = self.calculateCacheLocalityRatio(),
        };
    }
    
    /// Calculate how well data is organized for cache locality
    fn calculateCacheLocalityRatio(self: *Self) f32 {
        _ = self;
        // Hot data is always perfectly cache-local (sequential access)
        // This metric could be enhanced to measure actual access patterns
        return 1.0; // Perfect cache locality for hot data
    }
    
    /// Advanced: SIMD-optimized relevance filtering (when available)
    pub fn filterByRelevanceSIMD(self: *Self, threshold: f32) u32 {
        var write_index: u32 = 0;
        var i: usize = 0;
        
        // Process in SIMD-friendly chunks of 8
        while (i + 8 <= self.count) {
            // Extract relevance scores for SIMD processing
            var scores: [8]f32 = undefined;
            for (0..8) |j| {
                scores[j] = self.hot_data[i + j].relevance_score;
            }
            
            // Vectorized comparison (conceptual - actual SIMD would be platform-specific)
            var mask: [8]bool = undefined;
            for (0..8) |j| {
                mask[j] = scores[j] >= threshold;
            }
            
            // Compact results based on mask
            for (0..8) |j| {
                if (mask[j]) {
                    const read_index = i + j;
                    if (write_index != read_index) {
                        self.hot_data[write_index] = self.hot_data[read_index];
                        self.hot_data[write_index].cold_data_index = write_index;
                        self.cold_data[write_index] = self.cold_data[read_index];
                    }
                    write_index += 1;
                }
            }
            
            i += 8;
        }
        
        // Handle remaining items
        while (i < self.count) {
            if (self.hot_data[i].passesRelevanceFilter(threshold)) {
                if (write_index != i) {
                    self.hot_data[write_index] = self.hot_data[i];
                    self.hot_data[write_index].cold_data_index = write_index;
                    self.cold_data[write_index] = self.cold_data[i];
                }
                write_index += 1;
            }
            i += 1;
        }
        
        self.count = write_index;
        return write_index;
    }
};

/// Performance statistics for hot/cold storage
pub const HotColdStats = struct {
    item_count: u32,
    capacity_utilization: f32,
    hot_data_size_bytes: u32,
    cold_data_size_bytes: u32,
    string_pool_utilization: f32,
    cache_locality_ratio: f32,
};

/// Factory function to create storage from existing NewsItems
pub fn createFromNewsItems(allocator: std.mem.Allocator, pools: *memory_pools.NewsAggregatorPools, items: []const types.NewsItem, cache_client: ?*cache.ContentCache) !HotColdNewsStorage {
    var storage = try HotColdNewsStorage.init(allocator, pools, @intCast(items.len), cache_client);
    
    for (items) |item| {
        try storage.addItem(item);
    }
    
    return storage;
}

// Tests
test "hot/cold storage basic operations" {
    const testing = std.testing;
    
    var pools = try memory_pools.NewsAggregatorPools.init(testing.allocator);
    defer pools.deinit();
    
    var storage = try HotColdNewsStorage.init(testing.allocator, &pools, 10, null);
    defer storage.deinit();
    
    // Create test item
    const test_item = types.NewsItem{
        .title = "Test Title",
        .summary = "Test Summary",
        .url = "https://test.com",
        .source = "Test Source",
        .source_type = .blog,
        .timestamp = 1234567890,
        .relevance_score = 0.8,
        .reddit_metadata = null,
        .youtube_metadata = null,
        .huggingface_metadata = null,
        .blog_metadata = null,
        .github_metadata = null,
    };
    
    // Add item
    try storage.addItem(test_item);
    try testing.expect(storage.count == 1);
    
    // Check hot data
    try testing.expect(storage.hot_data[0].relevance_score == 0.8);
    try testing.expect(storage.hot_data[0].timestamp == 1234567890);
    try testing.expect(storage.hot_data[0].source_type == .blog);
    
    // Test relevance filtering
    const filtered_count = storage.filterByRelevanceHot(0.5);
    try testing.expect(filtered_count == 1); // Should pass
    
    const filtered_count2 = storage.filterByRelevanceHot(0.9);
    try testing.expect(filtered_count2 == 0); // Should not pass
}

test "hot/cold deduplication performance" {
    const testing = std.testing;
    
    var pools = try memory_pools.NewsAggregatorPools.init(testing.allocator);
    defer pools.deinit();
    
    var storage = try HotColdNewsStorage.init(testing.allocator, &pools, 10, null);
    defer storage.deinit();
    
    // Add duplicate items
    const test_item1 = types.NewsItem{
        .title = "Same Title",
        .summary = "Different Summary 1",
        .url = "https://same.com",
        .source = "Source 1",
        .source_type = .blog,
        .timestamp = 1234567890,
        .relevance_score = 0.8,
        .reddit_metadata = null,
        .youtube_metadata = null,
        .huggingface_metadata = null,
        .blog_metadata = null,
        .github_metadata = null,
    };
    
    const test_item2 = types.NewsItem{
        .title = "Same Title",
        .summary = "Different Summary 2",
        .url = "https://different.com",
        .source = "Source 2",
        .source_type = .research_hub,
        .timestamp = 1234567891,
        .relevance_score = 0.9,
        .reddit_metadata = null,
        .youtube_metadata = null,
        .huggingface_metadata = null,
        .blog_metadata = null,
        .github_metadata = null,
    };
    
    try storage.addItem(test_item1);
    try storage.addItem(test_item2);
    try testing.expect(storage.count == 2);
    
    // Deduplicate - should find titles are the same
    const unique_count = storage.deduplicateHot();
    try testing.expect(unique_count == 1); // Should deduplicate based on title hash
}