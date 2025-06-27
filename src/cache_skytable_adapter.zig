const std = @import("std");
const types = @import("core_types.zig");
const hot_cold_storage = @import("cache_hot_cold.zig");
const cache = @import("cache_main.zig");
const memory_pools = @import("cache_memory_pools.zig");

/// Adapter that integrates hot/cold storage with Skytable cache
/// Provides intelligent caching strategies based on data access patterns
pub const SkytableHotColdAdapter = struct {
    allocator: std.mem.Allocator,
    cache_client: *cache.ContentCache,
    pools: *memory_pools.NewsAggregatorPools,
    
    // Cache performance metrics
    hot_cache_hits: u64,
    hot_cache_misses: u64,
    cold_cache_hits: u64,
    cold_cache_misses: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, cache_client: *cache.ContentCache, pools: *memory_pools.NewsAggregatorPools) Self {
        return Self{
            .allocator = allocator,
            .cache_client = cache_client,
            .pools = pools,
            .hot_cache_hits = 0,
            .hot_cache_misses = 0,
            .cold_cache_hits = 0,
            .cold_cache_misses = 0,
        };
    }
    
    /// Cache hot data separately from cold data for optimal retrieval
    pub fn cacheHotColdData(self: *Self, source_url: []const u8, source_type: types.SourceType, storage: *hot_cold_storage.HotColdNewsStorage) !void {
        // Generate separate cache keys for hot and cold data
        const hot_cache_key = try self.generateHotCacheKey(source_url, source_type);
        defer self.allocator.free(hot_cache_key);
        
        const cold_cache_key = try self.generateColdCacheKey(source_url, source_type);
        defer self.allocator.free(cold_cache_key);
        
        // Cache hot data (frequently accessed during processing)
        try self.cacheHotData(hot_cache_key, storage);
        
        // Cache cold data (accessed less frequently, can use different TTL)
        try self.cacheColdData(cold_cache_key, storage);
        
        std.log.debug("💾 Cached hot/cold data for {s}: {d} items", .{ source_url, storage.count });
    }
    
    /// Try to load cached hot/cold data
    pub fn loadCachedHotColdData(self: *Self, source_url: []const u8, source_type: types.SourceType, capacity: u32) !?hot_cold_storage.HotColdNewsStorage {
        const hot_cache_key = try self.generateHotCacheKey(source_url, source_type);
        defer self.allocator.free(hot_cache_key);
        
        const cold_cache_key = try self.generateColdCacheKey(source_url, source_type);
        defer self.allocator.free(cold_cache_key);
        
        // Check if both hot and cold data are available
        const hot_cached = try self.cache_client.isCached(hot_cache_key, source_type);
        const cold_cached = try self.cache_client.isCached(cold_cache_key, source_type);
        
        if (hot_cached and cold_cached) {
            // Load both hot and cold data
            if (try self.loadHotData(hot_cache_key, capacity)) |hot_data| {
                if (try self.loadColdData(cold_cache_key, @intCast(hot_data.len))) |cold_data| {
                    self.hot_cache_hits += 1;
                    self.cold_cache_hits += 1;
                    
                    var storage = try hot_cold_storage.HotColdNewsStorage.init(self.allocator, self.pools, capacity, self.cache_client);
                    storage.hot_data = hot_data;
                    storage.cold_data = cold_data;
                    storage.count = @intCast(hot_data.len);
                    
                    std.log.debug("🎯 Cache hit for {s}: loaded {d} items", .{ source_url, storage.count });
                    return storage;
                } else {
                    // Cold data load failed, cleanup hot data
                    self.allocator.free(hot_data);
                    self.cold_cache_misses += 1;
                }
            } else {
                self.hot_cache_misses += 1;
            }
        } else {
            if (!hot_cached) self.hot_cache_misses += 1;
            if (!cold_cached) self.cold_cache_misses += 1;
        }
        
        std.log.debug("💥 Cache miss for {s}", .{source_url});
        return null;
    }
    
    /// Generate cache key for hot data
    fn generateHotCacheKey(self: *Self, source_url: []const u8, source_type: types.SourceType) ![]const u8 {
        const type_prefix = switch (source_type) {
            .reddit => "reddit_hot",
            .youtube => "youtube_hot",
            .research_hub => "research_hot",
            .blog => "blog_hot",
            .web_crawl => "news_hot",
            else => "misc_hot",
        };
        
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(source_url);
        const url_hash = hasher.final();
        
        return try std.fmt.allocPrint(self.allocator, "hot_cold_cache:{s}:{x}", .{ type_prefix, url_hash });
    }
    
    /// Generate cache key for cold data
    fn generateColdCacheKey(self: *Self, source_url: []const u8, source_type: types.SourceType) ![]const u8 {
        const type_prefix = switch (source_type) {
            .reddit => "reddit_cold",
            .youtube => "youtube_cold",
            .research_hub => "research_cold",
            .blog => "blog_cold",
            .web_crawl => "news_cold",
            else => "misc_cold",
        };
        
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(source_url);
        const url_hash = hasher.final();
        
        return try std.fmt.allocPrint(self.allocator, "hot_cold_cache:{s}:{x}", .{ type_prefix, url_hash });
    }
    
    /// Cache hot data using binary format for maximum efficiency
    fn cacheHotData(self: *Self, cache_key: []const u8, storage: *hot_cold_storage.HotColdNewsStorage) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        var writer = buffer.writer();
        
        // Write header
        try writer.writeInt(u32, 0xDEADBEEF, .little); // Magic number for validation
        try writer.writeInt(u32, 1, .little); // Version
        try writer.writeInt(u32, storage.count, .little);
        
        // Write hot data as packed binary (extremely efficient)
        for (0..storage.count) |i| {
            const hot = storage.hot_data[i];
            const score_bytes = std.mem.asBytes(&hot.relevance_score);
            try writer.writeAll(score_bytes);
            try writer.writeInt(i64, hot.timestamp, .little);
            try writer.writeInt(u8, @intFromEnum(hot.source_type), .little);
            try writer.writeInt(u64, hot.title_hash, .little);
            try writer.writeInt(u64, hot.url_hash, .little);
            try writer.writeInt(u32, hot.cold_data_index, .little);
        }
        
        // Store in Skytable with appropriate TTL
        try self.storeInSkytable(cache_key, buffer.items, .hot_data);
    }
    
    /// Cache cold data using compressed format
    fn cacheColdData(self: *Self, cache_key: []const u8, storage: *hot_cold_storage.HotColdNewsStorage) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        var writer = buffer.writer();
        
        // Write header
        try writer.writeInt(u32, 0xBEEFCAFE, .little); // Magic number for cold data
        try writer.writeInt(u32, 1, .little); // Version
        try writer.writeInt(u32, storage.count, .little);
        
        // Write cold data with string references
        for (0..storage.count) |i| {
            const cold = storage.cold_data[i];
            
            // Write string references
            try writer.writeInt(u32, cold.title_ref.offset, .little);
            try writer.writeInt(u32, cold.title_ref.length, .little);
            try writer.writeInt(u32, cold.summary_ref.offset, .little);
            try writer.writeInt(u32, cold.summary_ref.length, .little);
            try writer.writeInt(u32, cold.url_ref.offset, .little);
            try writer.writeInt(u32, cold.url_ref.length, .little);
            try writer.writeInt(u32, cold.source_ref.offset, .little);
            try writer.writeInt(u32, cold.source_ref.length, .little);
            
            // Write metadata indices (null-encoded as MAX_INT)
            const null_marker = std.math.maxInt(u32);
            try writer.writeInt(u32, cold.reddit_metadata_index orelse null_marker, .little);
            try writer.writeInt(u32, cold.youtube_metadata_index orelse null_marker, .little);
            try writer.writeInt(u32, cold.huggingface_metadata_index orelse null_marker, .little);
            try writer.writeInt(u32, cold.blog_metadata_index orelse null_marker, .little);
            try writer.writeInt(u32, cold.github_metadata_index orelse null_marker, .little);
        }
        
        // Also cache the string pool data for cold data reconstruction
        const pool_stats = self.pools.getStats();
        try writer.writeInt(u32, @intCast(pool_stats.string_pool.used), .little);
        // Note: We would need access to the raw string pool buffer here
        // For now, this is a conceptual implementation
        
        // Store in Skytable with longer TTL for cold data
        try self.storeInSkytable(cache_key, buffer.items, .cold_data);
    }
    
    /// Load hot data from cache
    fn loadHotData(self: *Self, cache_key: []const u8, capacity: u32) !?[]hot_cold_storage.NewsItemHot {
        const cached_data = self.loadFromSkytable(cache_key) catch |err| {
            std.log.debug("Failed to load hot data from cache: {}", .{err});
            return null;
        };
        defer self.allocator.free(cached_data);
        
        if (cached_data.len < 12) return null; // Too small to be valid
        
        var stream = std.io.fixedBufferStream(cached_data);
        var reader = stream.reader();
        
        // Validate header
        const magic = try reader.readInt(u32, .little);
        if (magic != 0xDEADBEEF) return null;
        
        const version = try reader.readInt(u32, .little);
        if (version != 1) return null;
        
        const count = try reader.readInt(u32, .little);
        if (count > capacity) return null;
        
        // Allocate and read hot data
        var hot_data = try self.allocator.alloc(hot_cold_storage.NewsItemHot, count);
        
        for (0..count) |i| {
            hot_data[i] = hot_cold_storage.NewsItemHot{
                .relevance_score = blk: {
                    var score: f32 = undefined;
                    _ = try reader.readAll(std.mem.asBytes(&score));
                    break :blk score;
                },
                .timestamp = try reader.readInt(i64, .little),
                .source_type = @enumFromInt(try reader.readInt(u8, .little)),
                .title_hash = try reader.readInt(u64, .little),
                .url_hash = try reader.readInt(u64, .little),
                .cold_data_index = try reader.readInt(u32, .little),
            };
        }
        
        return hot_data;
    }
    
    /// Load cold data from cache
    fn loadColdData(self: *Self, cache_key: []const u8, count: u32) !?[]hot_cold_storage.NewsItemCold {
        const cached_data = self.loadFromSkytable(cache_key) catch |err| {
            std.log.debug("Failed to load cold data from cache: {}", .{err});
            return null;
        };
        defer self.allocator.free(cached_data);
        
        if (cached_data.len < 12) return null;
        
        var stream = std.io.fixedBufferStream(cached_data);
        var reader = stream.reader();
        
        // Validate header
        const magic = try reader.readInt(u32, .little);
        if (magic != 0xBEEFCAFE) return null;
        
        const version = try reader.readInt(u32, .little);
        if (version != 1) return null;
        
        const stored_count = try reader.readInt(u32, .little);
        if (stored_count != count) return null;
        
        // Allocate and read cold data
        var cold_data = try self.allocator.alloc(hot_cold_storage.NewsItemCold, count);
        
        const null_marker = std.math.maxInt(u32);
        for (0..count) |i| {
            // Read string references
            const title_offset = try reader.readInt(u32, .little);
            const title_length = try reader.readInt(u32, .little);
            const summary_offset = try reader.readInt(u32, .little);
            const summary_length = try reader.readInt(u32, .little);
            const url_offset = try reader.readInt(u32, .little);
            const url_length = try reader.readInt(u32, .little);
            const source_offset = try reader.readInt(u32, .little);
            const source_length = try reader.readInt(u32, .little);
            
            // Read metadata indices
            const reddit_idx = try reader.readInt(u32, .little);
            const youtube_idx = try reader.readInt(u32, .little);
            const huggingface_idx = try reader.readInt(u32, .little);
            const blog_idx = try reader.readInt(u32, .little);
            const github_idx = try reader.readInt(u32, .little);
            
            cold_data[i] = hot_cold_storage.NewsItemCold{
                .title_ref = types.StringRef{ .offset = title_offset, .length = title_length },
                .summary_ref = types.StringRef{ .offset = summary_offset, .length = summary_length },
                .url_ref = types.StringRef{ .offset = url_offset, .length = url_length },
                .source_ref = types.StringRef{ .offset = source_offset, .length = source_length },
                .reddit_metadata_index = if (reddit_idx == null_marker) null else reddit_idx,
                .youtube_metadata_index = if (youtube_idx == null_marker) null else youtube_idx,
                .huggingface_metadata_index = if (huggingface_idx == null_marker) null else huggingface_idx,
                .blog_metadata_index = if (blog_idx == null_marker) null else blog_idx,
                .github_metadata_index = if (github_idx == null_marker) null else github_idx,
            };
        }
        
        // TODO: Restore string pool data for string references to work
        // This requires coordination with the string pool
        
        return cold_data;
    }
    
    /// Store data in Skytable with appropriate TTL based on data type
    fn storeInSkytable(self: *Self, cache_key: []const u8, data: []const u8, data_type: enum { hot_data, cold_data }) !void {
        // Use different TTLs for hot vs cold data
        const ttl: u32 = switch (data_type) {
            .hot_data => 2 * 3600,    // 2 hours for hot data (processed frequently)
            .cold_data => 8 * 3600,   // 8 hours for cold data (string data is more stable)
        };
        
        // Create a cache entry for Skytable
        const entry = cache.CacheEntry{
            .content = data,
            .timestamp = std.time.timestamp(),
            .ttl_seconds = ttl,
            .source_type = .web_crawl, // Generic type for internal cache data
            .content_hash = std.hash.Wyhash.hash(0, data),
        };
        
        // Serialize and store
        const entry_data = try self.serializeCacheEntryBinary(entry);
        defer self.allocator.free(entry_data);
        
        try self.cache_client.skytable.cacheSet(cache_key, entry_data);
        
        std.log.debug("📥 Stored {s} data in Skytable: {d} bytes", .{ @tagName(data_type), data.len });
    }
    
    /// Load data from Skytable
    fn loadFromSkytable(self: *Self, cache_key: []const u8) ![]const u8 {
        const entry_data = try self.cache_client.skytable.cacheGet(cache_key) orelse return error.CacheKeyNotFound;
        defer self.allocator.free(entry_data);
        
        const entry = try self.deserializeCacheEntryBinary(entry_data);
        defer entry.deinit(self.allocator);
        
        // Check if expired
        if (entry.isExpired()) {
            _ = self.cache_client.skytable.cacheDelete(cache_key) catch {};
            return error.CacheEntryExpired;
        }
        
        return try self.allocator.dupe(u8, entry.content);
    }
    
    /// Serialize cache entry to binary format
    fn serializeCacheEntryBinary(self: *Self, entry: cache.CacheEntry) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        var writer = buffer.writer();
        
        try writer.writeInt(i64, entry.timestamp, .little);
        try writer.writeInt(u32, entry.ttl_seconds, .little);
        try writer.writeInt(u8, @intFromEnum(entry.source_type), .little);
        try writer.writeInt(u64, entry.content_hash, .little);
        try writer.writeInt(u32, @intCast(entry.content.len), .little);
        try writer.writeAll(entry.content);
        
        return try self.allocator.dupe(u8, buffer.items);
    }
    
    /// Deserialize cache entry from binary format
    fn deserializeCacheEntryBinary(self: *Self, data: []const u8) !cache.CacheEntry {
        if (data.len < 25) return error.InvalidCacheEntry; // Minimum size check
        
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();
        
        const timestamp = try reader.readInt(i64, .little);
        const ttl_seconds = try reader.readInt(u32, .little);
        const source_type: types.SourceType = @enumFromInt(try reader.readInt(u8, .little));
        const content_hash = try reader.readInt(u64, .little);
        const content_len = try reader.readInt(u32, .little);
        
        if (data.len < 25 + content_len) return error.InvalidCacheEntry;
        
        const content = try self.allocator.dupe(u8, data[25..25 + content_len]);
        
        return cache.CacheEntry{
            .content = content,
            .timestamp = timestamp,
            .ttl_seconds = ttl_seconds,
            .source_type = source_type,
            .content_hash = content_hash,
        };
    }
    
    /// Get cache performance statistics
    pub fn getCacheStats(self: Self) CachePerformanceStats {
        const total_hot_accesses = self.hot_cache_hits + self.hot_cache_misses;
        const total_cold_accesses = self.cold_cache_hits + self.cold_cache_misses;
        
        return CachePerformanceStats{
            .hot_cache_hit_rate = if (total_hot_accesses > 0) 
                @as(f32, @floatFromInt(self.hot_cache_hits)) / @as(f32, @floatFromInt(total_hot_accesses))
            else 0.0,
            .cold_cache_hit_rate = if (total_cold_accesses > 0)
                @as(f32, @floatFromInt(self.cold_cache_hits)) / @as(f32, @floatFromInt(total_cold_accesses))
            else 0.0,
            .total_hot_accesses = total_hot_accesses,
            .total_cold_accesses = total_cold_accesses,
        };
    }
    
    /// Log cache performance metrics
    pub fn logCachePerformance(self: Self) void {
        const stats = self.getCacheStats();
        
        std.log.info("📊 Hot/Cold Cache Performance:", .{});
        std.log.info("   - Hot data hit rate: {d:.1}% ({d}/{d})", .{ 
            stats.hot_cache_hit_rate * 100, self.hot_cache_hits, stats.total_hot_accesses 
        });
        std.log.info("   - Cold data hit rate: {d:.1}% ({d}/{d})", .{ 
            stats.cold_cache_hit_rate * 100, self.cold_cache_hits, stats.total_cold_accesses 
        });
        
        if (stats.hot_cache_hit_rate < 0.5) {
            std.log.warn("⚠️ Hot cache hit rate is low - consider adjusting TTL or cache size", .{});
        }
        if (stats.cold_cache_hit_rate < 0.3) {
            std.log.warn("⚠️ Cold cache hit rate is low - this is expected for string data", .{});
        }
    }
};

/// Cache performance statistics
pub const CachePerformanceStats = struct {
    hot_cache_hit_rate: f32,
    cold_cache_hit_rate: f32,
    total_hot_accesses: u64,
    total_cold_accesses: u64,
};