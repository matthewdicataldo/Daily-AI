const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const firecrawl = @import("external_firecrawl.zig");

pub const HackerNewsClient = struct {
    allocator: std.mem.Allocator,
    firecrawl_client: *firecrawl.FirecrawlClient,
    
    pub fn init(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) HackerNewsClient {
        return HackerNewsClient{
            .allocator = allocator,
            .firecrawl_client = firecrawl_client,
        };
    }
    
    /// Extract articles from a Hacker News source
    pub fn extractNewsItems(self: *HackerNewsClient, source: config.NewsSource) ![]types.NewsItem {
        std.log.info("Extracting articles from {s}...", .{source.name});
        
        // Scrape the main Hacker News page
        const response = try self.firecrawl_client.scrape(source.url, .{
            .include_html = false,
            .include_raw_html = false,
            .only_main_content = true,
            .include_links = true,
            .wait_for = 2000,
        });
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            std.log.err("Failed to scrape {s}: {s}", .{ source.name, response.@"error" orelse "Unknown error" });
            return error.ParseError;
        }
        
        const markdown = response.data.?.markdown orelse "";
        return try self.parseHackerNewsMarkdown(markdown, source);
    }
    
    /// Parse Hacker News markdown content to extract news items
    fn parseHackerNewsMarkdown(self: *HackerNewsClient, markdown: []const u8, source: config.NewsSource) ![]types.NewsItem {
        var items = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            // Only deinit the ArrayList, not the items (they're returned)
            items.deinit();
        }
        
        var lines = std.mem.splitScalar(u8, markdown, '\n');
        var current_title: ?[]const u8 = null;
        var current_url: ?[]const u8 = null;
        var line_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            line_count += 1;
            
            // Look for links that might be HN article titles
            // Hacker News links typically look like: [Title](https://example.com)
            if (std.mem.indexOf(u8, trimmed, "](http")) |_| {
                if (extractLinkFromMarkdown(trimmed)) |link_info| {
                    current_title = link_info.title;
                    current_url = link_info.url;
                    
                    // Filter for AI-related content
                    if (isAIRelated(current_title.?)) {
                        const news_item = try self.createNewsItem(
                            current_title.?,
                            current_url.?,
                            source,
                        );
                        try items.append(news_item);
                        
                        if (items.items.len >= source.max_items) {
                            break;
                        }
                    }
                }
            }
            
            // Stop processing after reasonable number of lines to avoid infinite parsing
            if (line_count > 1000) break;
        }
        
        std.log.info("Extracted {d} items from {s}", .{ items.items.len, source.name });
        return try items.toOwnedSlice();
    }
    
    /// Create a NewsItem from extracted Hacker News data
    fn createNewsItem(self: *HackerNewsClient, title: []const u8, url: []const u8, source: config.NewsSource) !types.NewsItem {
        const current_timestamp = types.getCurrentTimestamp();
        
        // Calculate relevance score based on AI keywords
        const relevance_score = calculateRelevanceScore(title);
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, title),
            .summary = try self.allocator.dupe(u8, title), // Use title as summary initially
            .url = try self.allocator.dupe(u8, url),
            .source = try self.allocator.dupe(u8, source.name),
            .source_type = .blog, // Treat news items as blog-type for processing
            .timestamp = current_timestamp,
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = types.BlogMetadata{
                .author = null,
                .publication_date = try types.timestampToString(self.allocator, current_timestamp),
                .read_time_minutes = 5, // Estimate
                .tags = null,
            },
            .github_metadata = null,
        };
    }
};

/// Extract title and URL from markdown link format
fn extractLinkFromMarkdown(line: []const u8) ?struct { title: []const u8, url: []const u8 } {
    // Look for pattern: [title](url)
    const start_bracket = std.mem.indexOf(u8, line, "[") orelse return null;
    const end_bracket = std.mem.indexOf(u8, line[start_bracket..], "]") orelse return null;
    const start_paren = std.mem.indexOf(u8, line[start_bracket + end_bracket..], "(") orelse return null;
    const end_paren = std.mem.indexOf(u8, line[start_bracket + end_bracket + start_paren..], ")") orelse return null;
    
    const title_start = start_bracket + 1;
    const title_end = start_bracket + end_bracket;
    const url_start = start_bracket + end_bracket + start_paren + 1;
    const url_end = start_bracket + end_bracket + start_paren + end_paren;
    
    if (title_end <= title_start or url_end <= url_start) return null;
    
    const title = line[title_start..title_end];
    const url = line[url_start..url_end];
    
    // Basic validation
    if (title.len == 0 or url.len == 0) return null;
    if (!std.mem.startsWith(u8, url, "http")) return null;
    
    return .{ .title = title, .url = url };
}

/// Check if a title is related to AI/ML topics
fn isAIRelated(title: []const u8) bool {
    const ai_keywords = [_][]const u8{
        "AI", "artificial intelligence", "machine learning", "ML", "neural", "deep learning",
        "GPT", "LLM", "transformer", "ChatGPT", "Claude", "OpenAI", "Anthropic",
        "computer vision", "NLP", "natural language", "algorithm", "model", "training",
        "inference", "embedding", "vector", "AGI", "automation", "robot", "autonomous",
        "data science", "analytics", "prediction", "classification", "regression"
    };
    
    const lower_title = std.ascii.allocLowerString(std.heap.page_allocator, title) catch return false;
    defer std.heap.page_allocator.free(lower_title);
    
    for (ai_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
        defer std.heap.page_allocator.free(lower_keyword);
        
        if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
            return true;
        }
    }
    
    return false;
}

/// Calculate relevance score for Hacker News item
fn calculateRelevanceScore(title: []const u8) f32 {
    var score: f32 = 0.5; // Base score
    
    const high_value_keywords = [_][]const u8{ "AI", "GPT", "machine learning", "OpenAI", "Claude", "neural" };
    const medium_value_keywords = [_][]const u8{ "algorithm", "model", "data", "automation", "robot" };
    
    const lower_title = std.ascii.allocLowerString(std.heap.page_allocator, title) catch return score;
    defer std.heap.page_allocator.free(lower_title);
    
    for (high_value_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
        defer std.heap.page_allocator.free(lower_keyword);
        
        if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
            score += 0.3;
        }
    }
    
    for (medium_value_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
        defer std.heap.page_allocator.free(lower_keyword);
        
        if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
            score += 0.1;
        }
    }
    
    return @min(score, 1.0);
}

/// Extract all news items from configured sources
pub fn extractAllNewsItems(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) ![]types.NewsItem {
    var all_items = std.ArrayList(types.NewsItem).init(allocator);
    defer {
        // Only deinit the ArrayList, not the items (they're returned)
        all_items.deinit();
    }
    
    var client = HackerNewsClient.init(allocator, firecrawl_client);
    
    for (config.Config.news_sources) |source| {
        const items = client.extractNewsItems(source) catch |err| {
            std.log.err("Failed to extract from {s}: {}", .{ source.name, err });
            continue;
        };
        defer allocator.free(items);
        
        for (items) |item| {
            try all_items.append(item);
        }
    }
    
    return try all_items.toOwnedSlice();
}

test "Hacker News link extraction" {
    const test_line = "Check out this [Amazing AI Tool](https://example.com/ai-tool) for developers";
    const result = extractLinkFromMarkdown(test_line);
    
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Amazing AI Tool", result.?.title);
    try std.testing.expectEqualStrings("https://example.com/ai-tool", result.?.url);
}

test "AI relevance detection" {
    try std.testing.expect(isAIRelated("New AI Model Released"));
    try std.testing.expect(isAIRelated("Machine Learning Breakthrough"));
    try std.testing.expect(!isAIRelated("Random News Article"));
    try std.testing.expect(isAIRelated("GPT-4 Update"));
}