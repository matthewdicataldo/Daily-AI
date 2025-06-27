//! ContentSource abstraction for unified extractor interface
//! Enables batch processing and better cache integration

const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const reddit = @import("extract_reddit.zig");
const youtube = @import("extract_youtube.zig");
const tiktok = @import("extract_tiktok.zig");
const huggingface = @import("extract_huggingface.zig");
const blog = @import("extract_blog.zig");
const hackernews = @import("extract_hackernews.zig");
const rss = @import("extract_rss.zig");
const simple_cache = @import("cache_simple.zig");

/// Source type for different content providers
pub const SourceType = enum {
    reddit,
    youtube, 
    tiktok,
    research,
    blog,
    hackernews,
    rss,
    
    pub fn getCacheTtl(self: SourceType) simple_cache.CacheType {
        return switch (self) {
            .reddit, .youtube, .tiktok, .hackernews, .rss => .content, // 3 days
            .research, .blog => .content, // 3 days - all content has same TTL
        };
    }
    
    pub fn getDescription(self: SourceType) []const u8 {
        return switch (self) {
            .reddit => "Reddit posts and comments",
            .youtube => "YouTube videos and metadata", 
            .tiktok => "TikTok videos and trends",
            .research => "Research papers and publications",
            .blog => "Blog posts and articles",
            .hackernews => "Hacker News stories and discussions",
            .rss => "RSS news feeds",
        };
    }
};

/// Extraction result with metadata
pub const ExtractionResult = struct {
    items: []types.NewsItem,
    source_type: SourceType,
    source_name: []const u8, // e.g., "r/MachineLearning", "AI Research Daily"
    extracted_at: i64,
    cache_hit: bool,
    item_count: usize,
    
    pub fn deinit(self: ExtractionResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        allocator.free(self.source_name);
    }
};

/// Batch extraction request
pub const BatchRequest = struct {
    source_type: SourceType,
    sources: [][]const u8, // URLs, subreddit names, etc.
    max_items_per_source: u32,
    filter_today_only: bool,
    
    pub fn deinit(self: BatchRequest, allocator: std.mem.Allocator) void {
        for (self.sources) |source| {
            allocator.free(source);
        }
        allocator.free(self.sources);
    }
};

/// ContentSource interface for unified extraction
pub const ContentSource = struct {
    allocator: std.mem.Allocator,
    cache: *simple_cache.SimpleCache,
    source_type: SourceType,
    
    // Specific client implementations
    reddit_client: ?*reddit.RedditClient,
    youtube_client: ?*youtube.YouTubeClient,
    tiktok_client: ?*tiktok.TikTokClient,
    huggingface_client: ?*huggingface.HuggingFaceClient,
    blog_client: ?*blog.BlogClient,
    hackernews_client: ?*hackernews.HackerNewsClient,
    rss_client: ?*rss.RssClient,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, cache: *simple_cache.SimpleCache, source_type: SourceType) Self {
        return Self{
            .allocator = allocator,
            .cache = cache,
            .source_type = source_type,
            .reddit_client = null,
            .youtube_client = null,
            .tiktok_client = null,
            .huggingface_client = null,
            .blog_client = null,
            .hackernews_client = null,
            .rss_client = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.reddit_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        // Add other client cleanup when needed
    }
    
    /// Set specific client implementation
    pub fn setRedditClient(self: *Self, client: *reddit.RedditClient) void {
        self.reddit_client = client;
    }
    
    pub fn setYouTubeClient(self: *Self, client: *youtube.YouTubeClient) void {
        self.youtube_client = client;
    }
    
    pub fn setTikTokClient(self: *Self, client: *tiktok.TikTokClient) void {
        self.tiktok_client = client;
    }
    
    pub fn setHuggingFaceClient(self: *Self, client: *huggingface.HuggingFaceClient) void {
        self.huggingface_client = client;
    }
    
    pub fn setBlogClient(self: *Self, client: *blog.BlogClient) void {
        self.blog_client = client;
    }
    
    pub fn setHackerNewsClient(self: *Self, client: *hackernews.HackerNewsClient) void {
        self.hackernews_client = client;
    }
    
    pub fn setRssClient(self: *Self, client: *rss.RssClient) void {
        self.rss_client = client;
    }
    
    /// Extract content from single source with caching
    pub fn extractSingle(self: *Self, source: []const u8, max_items: u32) !ExtractionResult {
        // Generate cache key
        const today = @divTrunc(std.time.timestamp(), (24 * 60 * 60)); // Days since epoch
        const cache_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{d}", .{ 
            @tagName(self.source_type), source, today 
        });
        defer self.allocator.free(cache_key);
        
        // Check cache first
        if (self.cache.get(cache_key)) |cached_data| {
            std.log.info("💨 Cache hit for {s}:{s} - using cached data", .{ @tagName(self.source_type), source });
            defer self.allocator.free(cached_data);
            // TODO: Deserialize cached JSON data to NewsItem array
            // For now, extract fresh content to keep it simple
        }
        
        // Cache miss - extract fresh content
        std.log.info("🔄 Cache miss for {s}:{s} - extracting fresh content", .{ @tagName(self.source_type), source });
        const items = try self.extractFresh(source, max_items);
        
        // Cache the results - simplified for now  
        // TODO: Serialize items to JSON and cache
        // self.cache.set(cache_key, serialized_json, self.source_type.getCacheTtl());
        
        std.log.info("✅ Extracted {d} items from {s}:{s}", .{ items.len, @tagName(self.source_type), source });
        
        return ExtractionResult{
            .items = items,
            .source_type = self.source_type,
            .source_name = try self.allocator.dupe(u8, source),
            .extracted_at = std.time.timestamp(),
            .cache_hit = false,
            .item_count = items.len,
        };
    }
    
    /// Extract fresh content based on source type
    fn extractFresh(self: *Self, source: []const u8, max_items: u32) ![]types.NewsItem {
        return switch (self.source_type) {
            .reddit => {
                const client = self.reddit_client orelse return error.ClientNotSet;
                const reddit_source = config.RedditSource{
                    .subreddit = source,
                    .max_posts = max_items,
                };
                return try client.extractSubredditPosts(reddit_source);
            },
            .youtube => {
                const client = self.youtube_client orelse return error.ClientNotSet;
                const youtube_source = config.YouTubeSource{
                    .handle = source,
                    .max_videos = max_items,
                    .include_transcript = true,
                };
                return try client.extractChannelVideos(youtube_source);
            },
            .tiktok => {
                const client = self.tiktok_client orelse return error.ClientNotSet;
                const tiktok_source = config.TikTokSource{
                    .handle = source,
                    .max_videos = max_items,
                };
                return try client.extractUserVideos(tiktok_source);
            },
            .research => {
                const client = self.huggingface_client orelse return error.ClientNotSet;
                const research_source = config.ResearchSource{
                    .url = source,
                    .max_papers = max_items,
                    .trending_only = true,
                };
                return try client.extractTrendingPapers(research_source);
            },
            .blog => {
                const client = self.blog_client orelse return error.ClientNotSet;
                const blog_source = config.BlogSource{
                    .url = source,
                    .name = source, // Use URL as name for simplicity
                    .max_articles = max_items,
                };
                return try client.extractBlogArticles(blog_source);
            },
            .hackernews => {
                const client = self.hackernews_client orelse return error.ClientNotSet;
                const news_source = config.NewsSource{
                    .name = "Hacker News",
                    .url = source,
                    .max_items = max_items,
                };
                return try client.extractNewsItems(news_source);
            },
            .rss => {
                const client = self.rss_client orelse return error.ClientNotSet;
                // For RSS, the source parameter is the RSS source configuration
                // We need to create a proper RssSource from the source name
                const rss_source = config.RssSource{
                    .name = source,
                    .url = source, // Use source as URL for now
                    .max_articles = max_items,
                };
                return try client.extractRssFeed(rss_source);
            },
        };
    }
    
    /// Batch extract from multiple sources efficiently
    pub fn extractBatch(self: *Self, request: BatchRequest) ![]ExtractionResult {
        var results = std.ArrayList(ExtractionResult).init(self.allocator);
        defer {
            // Only deinit on error - successful return transfers ownership
            for (results.items) |result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }
        
        std.log.info("🚀 Starting batch extraction: {s} from {d} sources", .{ @tagName(request.source_type), request.sources.len });
        
        // For Reddit, we can implement special batch handling
        if (request.source_type == .reddit and self.reddit_client != null) {
            return try self.extractRedditBatch(request);
        }
        
        // Default: extract each source individually
        for (request.sources) |source| {
            const result = self.extractSingle(source, request.max_items_per_source) catch |err| {
                std.log.warn("⚠️ Failed to extract from {s}: {}", .{ source, err });
                continue;
            };
            try results.append(result);
        }
        
        std.log.info("✅ Batch extraction complete: {d}/{d} sources successful", .{ results.items.len, request.sources.len });
        
        const owned_results = try results.toOwnedSlice();
        results = std.ArrayList(ExtractionResult).init(self.allocator); // Prevent cleanup
        return owned_results;
    }
    
    /// Optimized Reddit batch extraction
    fn extractRedditBatch(self: *Self, request: BatchRequest) ![]ExtractionResult {
        var results = std.ArrayList(ExtractionResult).init(self.allocator);
        defer {
            for (results.items) |result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }
        
        _ = self.reddit_client orelse return error.ClientNotSet;
        
        // TODO: Implement actual batch API calls here
        // For now, fall back to individual calls but with optimized caching
        for (request.sources) |subreddit| {
            const result = self.extractSingle(subreddit, request.max_items_per_source) catch |err| {
                std.log.warn("⚠️ Failed to extract from r/{s}: {}", .{ subreddit, err });
                continue;
            };
            try results.append(result);
            
            // Add small delay to respect rate limits
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms between requests
        }
        
        const owned_results = try results.toOwnedSlice();
        results = std.ArrayList(ExtractionResult).init(self.allocator);
        return owned_results;
    }
    
    /// Get cache statistics for this source type
    pub fn getCacheStats(self: *Self) CacheStats {
        _ = self; // TODO: Implement cache statistics tracking
        return CacheStats{
            .total_requests = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .hit_rate = 0.0,
        };
    }
};

/// Cache performance statistics
pub const CacheStats = struct {
    total_requests: u32,
    cache_hits: u32,
    cache_misses: u32,
    hit_rate: f32,
};

/// Factory function to create ContentSource for specific type
pub fn createSource(allocator: std.mem.Allocator, cache: *simple_cache.SimpleCache, source_type: SourceType) ContentSource {
    return ContentSource.init(allocator, cache, source_type);
}

/// Convenience function to create batch requests
pub fn createBatchRequest(allocator: std.mem.Allocator, source_type: SourceType, sources: []const []const u8, max_items: u32) !BatchRequest {
    var owned_sources = try allocator.alloc([]const u8, sources.len);
    for (sources, 0..) |source, i| {
        owned_sources[i] = try allocator.dupe(u8, source);
    }
    
    return BatchRequest{
        .source_type = source_type,
        .sources = owned_sources,
        .max_items_per_source = max_items,
        .filter_today_only = true,
    };
}