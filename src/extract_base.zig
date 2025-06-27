const std = @import("std");
const core_types = @import("core_types.zig");
const ai_filter = @import("ai_relevance_filter.zig");
const cache_unified = @import("cache_unified.zig");

/// Base extractor interface that all content extractors implement
/// Provides common functionality and enforces consistent patterns
pub const BaseExtractor = struct {
    allocator: std.mem.Allocator,
    ai_filter: ai_filter.AIRelevanceFilter,
    cache: cache_unified.UnifiedCache,
    source_type: core_types.SourceType,
    
    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator, 
        source_type: core_types.SourceType,
        cache_backend: cache_unified.BackendType
    ) Self {
        return Self{
            .allocator = allocator,
            .ai_filter = ai_filter.AIRelevanceFilter.init(allocator),
            .cache = cache_unified.UnifiedCache.init(allocator, cache_backend),
            .source_type = source_type,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ai_filter.deinit();
        self.cache.deinit();
    }

    /// Common pattern for extracting content with caching and filtering
    pub fn extractWithCache(
        self: *Self,
        source_identifier: []const u8,
        extract_fn: fn(*Self, []const u8) anyerror![]core_types.NewsItem,
        max_items: u32
    ) ![]core_types.NewsItem {
        // Generate cache key
        const today = @divTrunc(std.time.timestamp(), (24 * 60 * 60));
        const cache_key_components = [_][]const u8{ 
            @tagName(self.source_type), 
            source_identifier, 
            try std.fmt.allocPrint(self.allocator, "{d}", .{today})
        };
        defer self.allocator.free(cache_key_components[2]);
        
        const cache_key = try self.cache.generateKey(&cache_key_components);
        defer self.allocator.free(cache_key);

        // Check cache first
        if (self.cache.getNewsItems(cache_key)) |cached_items| {
            std.log.info("💨 Cache hit for {s}:{s}", .{ @tagName(self.source_type), source_identifier });
            return cached_items;
        }

        // Cache miss - extract fresh content
        std.log.info("🔄 Cache miss for {s}:{s} - extracting fresh content", .{ @tagName(self.source_type), source_identifier });
        
        const raw_items = try extract_fn(self, source_identifier);
        defer {
            for (raw_items) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(raw_items);
        }

        // Filter for AI relevance
        const filtered_items = try self.filterAIContent(raw_items, max_items);
        
        // Cache the results
        try self.cache.cacheNewsItems(cache_key, filtered_items);
        
        std.log.info("✅ Extracted {d} AI-related items from {s}:{s}", .{ filtered_items.len, @tagName(self.source_type), source_identifier });
        
        return filtered_items;
    }

    /// Common AI content filtering with scoring
    pub fn filterAIContent(self: *Self, items: []const core_types.NewsItem, max_items: u32) ![]core_types.NewsItem {
        var scored_items = std.ArrayList(ScoredItem).init(self.allocator);
        defer scored_items.deinit();

        // Score all items
        for (items) |item| {
            if (self.ai_filter.isAIRelated(item.title, item.summary)) {
                const score = self.ai_filter.calculateRelevanceScore(item.title, item.summary);
                try scored_items.append(ScoredItem{
                    .item = item,
                    .score = score,
                });
            }
        }

        // Sort by score (highest first)
        std.sort.insertion(ScoredItem, scored_items.items, {}, ScoredItem.compare);

        // Take top items and clone them
        const take_count = @min(max_items, scored_items.items.len);
        var result = try self.allocator.alloc(core_types.NewsItem, take_count);
        
        for (scored_items.items[0..take_count], 0..) |scored_item, i| {
            result[i] = try scored_item.item.clone(self.allocator);
            result[i].relevance_score = scored_item.score;
        }

        return result;
    }

    /// Convert raw data to NewsItem with common fields
    pub fn createNewsItem(
        self: *Self,
        title: []const u8,
        url: []const u8,
        content: []const u8,
        author: ?[]const u8,
        metadata: ?[]const u8
    ) !core_types.NewsItem {
        _ = metadata; // Unused for now but kept for future use
        // Calculate relevance score
        const relevance_score = self.ai_filter.calculateRelevanceScore(title, content);
        
        // Get AI content category
        _ = self.ai_filter.categorizeContent(title, content);
        
        return core_types.NewsItem{
            .title = try self.allocator.dupe(u8, title),
            .summary = try self.allocator.dupe(u8, content),
            .url = try self.allocator.dupe(u8, url),
            .source = if (author) |a| try self.allocator.dupe(u8, a) else try self.allocator.dupe(u8, "Unknown"),
            .timestamp = std.time.timestamp(),
            .source_type = self.source_type,
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }

    /// Common error handling and logging
    pub fn handleExtractionError(self: *Self, source: []const u8, err: anyerror) void {
        _ = self;
        std.log.warn("⚠️ Failed to extract from {s}: {}", .{ source, err });
    }

    /// Rate limiting helper
    pub fn rateLimitDelay(self: *Self, delay_ms: u64) void {
        _ = self;
        std.time.sleep(delay_ms * std.time.ns_per_ms);
    }

    /// Common text cleaning utilities
    pub fn cleanText(self: *Self, text: []const u8) ![]const u8 {
        // Remove common HTML entities and excessive whitespace
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var in_whitespace = false;
        for (text) |char| {
            if (std.ascii.isWhitespace(char)) {
                if (!in_whitespace) {
                    try cleaned.append(' ');
                    in_whitespace = true;
                }
            } else {
                try cleaned.append(char);
                in_whitespace = false;
            }
        }
        
        const result = try cleaned.toOwnedSlice();
        
        // Replace common HTML entities
        var final_result = std.ArrayList(u8).init(self.allocator);
        defer final_result.deinit();
        
        var i: usize = 0;
        while (i < result.len) {
            if (i + 4 <= result.len and std.mem.eql(u8, result[i..i+4], "&lt;")) {
                try final_result.append('<');
                i += 4;
            } else if (i + 4 <= result.len and std.mem.eql(u8, result[i..i+4], "&gt;")) {
                try final_result.append('>');
                i += 4;
            } else if (i + 5 <= result.len and std.mem.eql(u8, result[i..i+5], "&amp;")) {
                try final_result.append('&');
                i += 5;
            } else if (i + 6 <= result.len and std.mem.eql(u8, result[i..i+6], "&quot;")) {
                try final_result.append('"');
                i += 6;
            } else {
                try final_result.append(result[i]);
                i += 1;
            }
        }
        
        self.allocator.free(result);
        return final_result.toOwnedSlice();
    }
};

const ScoredItem = struct {
    item: core_types.NewsItem,
    score: f32,
    
    fn compare(context: void, a: ScoredItem, b: ScoredItem) bool {
        _ = context;
        return a.score > b.score; // Higher scores first
    }
};

/// Interface that all extractors must implement
pub const ExtractorInterface = struct {
    /// Extract content from a specific source
    extractFn: *const fn(allocator: std.mem.Allocator, source: []const u8, max_items: u32) anyerror![]core_types.NewsItem,
    
    /// Get human-readable name for this extractor
    getName: *const fn() []const u8,
    
    /// Get supported source types
    getSourceType: *const fn() core_types.SourceType,
};

test "base extractor functionality" {
    const allocator = std.testing.allocator;
    var base = BaseExtractor.init(allocator, .reddit, .memory);
    defer base.deinit();

    // Test news item creation
    const item = try base.createNewsItem(
        "GPT-4 Released by OpenAI",
        "https://openai.com/gpt4",
        "OpenAI has released GPT-4, their latest language model...",
        "OpenAI",
        null
    );
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("GPT-4 Released by OpenAI", item.title);
    try std.testing.expect(item.relevance_score > 0.5);

    // Test text cleaning
    const dirty_text = "This  has    extra   spaces &amp; HTML entities &lt;tag&gt;";
    const clean_text = try base.cleanText(dirty_text);
    defer allocator.free(clean_text);
    try std.testing.expectEqualStrings("This has extra spaces & HTML entities <tag>", clean_text);
}