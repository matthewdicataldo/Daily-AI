const std = @import("std");
const types = @import("core_types.zig");
const http = @import("common_http.zig");
const utils = @import("core_utils.zig");
const config = @import("core_config.zig");

/// RSS feed parser for AI news aggregation (no API keys required)
pub const RssClient = struct {
    allocator: std.mem.Allocator,
    http_client: *http.HttpClient,
    user_agent: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, http_client: *http.HttpClient) RssClient {
        return RssClient{
            .allocator = allocator,
            .http_client = http_client,
            .user_agent = "daily-ai-news/1.0",
        };
    }
    
    pub fn deinit(self: *RssClient) void {
        _ = self;
        // HTTP client is managed by caller
    }
    
    /// Extract articles from RSS feed
    pub fn extractRssFeed(self: *RssClient, source: config.RssSource) ![]types.NewsItem {
        std.log.info("📡 Fetching RSS feed: {s}...", .{source.name});
        
        // Build HTTP request
        var headers = [_]types.HttpRequest.Header{
            .{ .name = "User-Agent", .value = self.user_agent },
            .{ .name = "Accept", .value = "application/rss+xml, application/xml, text/xml" },
        };
        
        const request = types.HttpRequest{
            .method = .GET,
            .url = source.url,
            .headers = headers[0..],
            .body = "",
        };
        
        const response = try self.http_client.makeRequest(request);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            std.log.err("RSS request failed with status {d}: {s}", .{ response.status_code, response.body });
            return error.RssRequestFailed;
        }
        
        // Parse RSS XML
        return try self.parseRssXml(response.body, source);
    }
    
    /// Parse RSS XML and extract news items
    fn parseRssXml(self: *RssClient, xml_content: []const u8, source: config.RssSource) ![]types.NewsItem {
        var items = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            // Clean up on error
            for (items.items) |item| {
                item.deinit(self.allocator);
            }
            items.deinit();
        }
        
        // Simple XML parsing - look for <item> tags
        var lines = std.mem.splitScalar(u8, xml_content, '\n');
        var current_item: ?RssItem = null;
        var item_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Start of new item
            if (std.mem.indexOf(u8, trimmed, "<item>") != null or std.mem.indexOf(u8, trimmed, "<item ") != null) {
                if (current_item) |item| {
                    item.deinit(self.allocator);
                }
                current_item = RssItem.init(self.allocator);
            }
            // End of item - process it
            else if (std.mem.indexOf(u8, trimmed, "</item>") != null) {
                if (current_item) |item| {
                    // Process the item
                    if (try self.shouldIncludeItem(item, source)) {
                        const news_item = try self.convertToNewsItem(item, source);
                        try items.append(news_item);
                        item_count += 1;
                        
                        if (item_count >= source.max_articles) {
                            item.deinit(self.allocator);
                            current_item = null;
                            break;
                        }
                    }
                    // Clean up the item after processing
                    item.deinit(self.allocator);
                }
                current_item = null;
            }
            // Parse item fields
            else if (current_item != null) {
                try self.parseItemField(&current_item.?, trimmed);
            }
        }
        
        // Handle last item if exists
        if (current_item) |item| {
            if (try self.shouldIncludeItem(item, source) and item_count < source.max_articles) {
                const news_item = try self.convertToNewsItem(item, source);
                try items.append(news_item);
            }
            // Clean up the last item
            item.deinit(self.allocator);
        }
        
        std.log.info("✅ Extracted {d} articles from {s}", .{ items.items.len, source.name });
        
        const result = try items.toOwnedSlice();
        items = std.ArrayList(types.NewsItem).init(self.allocator); // Prevent cleanup
        return result;
    }
    
    /// Parse individual RSS item fields
    fn parseItemField(self: *RssClient, item: *RssItem, line: []const u8) !void {
        // Title
        if (std.mem.indexOf(u8, line, "<title>") != null) {
            if (try self.extractXmlContent(line, "title")) |content| {
                if (item.title) |old_title| self.allocator.free(old_title);
                item.title = try self.allocator.dupe(u8, content);
            }
        }
        // Link
        else if (std.mem.indexOf(u8, line, "<link>") != null) {
            if (try self.extractXmlContent(line, "link")) |content| {
                if (item.link) |old_link| self.allocator.free(old_link);
                item.link = try self.allocator.dupe(u8, content);
            }
        }
        // Description
        else if (std.mem.indexOf(u8, line, "<description>") != null) {
            if (try self.extractXmlContent(line, "description")) |content| {
                if (item.description) |old_desc| self.allocator.free(old_desc);
                item.description = try self.allocator.dupe(u8, content);
            }
        }
        // Publication date
        else if (std.mem.indexOf(u8, line, "<pubDate>") != null) {
            if (try self.extractXmlContent(line, "pubDate")) |content| {
                if (item.pub_date) |old_date| self.allocator.free(old_date);
                item.pub_date = try self.allocator.dupe(u8, content);
            }
        }
        // GUID/ID
        else if (std.mem.indexOf(u8, line, "<guid>") != null) {
            if (try self.extractXmlContent(line, "guid")) |content| {
                if (item.guid) |old_guid| self.allocator.free(old_guid);
                item.guid = try self.allocator.dupe(u8, content);
            }
        }
    }
    
    /// Extract content between XML tags
    fn extractXmlContent(self: *RssClient, line: []const u8, tag: []const u8) !?[]const u8 {
        
        const open_tag = try std.fmt.allocPrint(self.allocator, "<{s}>", .{tag});
        defer self.allocator.free(open_tag);
        const close_tag = try std.fmt.allocPrint(self.allocator, "</{s}>", .{tag});
        defer self.allocator.free(close_tag);
        
        const start_pos = std.mem.indexOf(u8, line, open_tag) orelse return null;
        const content_start = start_pos + open_tag.len;
        
        const end_pos = std.mem.indexOf(u8, line[content_start..], close_tag) orelse return null;
        const content_end = content_start + end_pos;
        
        if (content_end <= content_start) return null;
        
        const content = line[content_start..content_end];
        
        // Clean up HTML entities and CDATA
        return try self.cleanXmlContent(content);
    }
    
    /// Clean XML content (remove CDATA, decode entities)
    fn cleanXmlContent(self: *RssClient, content: []const u8) ![]const u8 {
        var cleaned = content;
        
        // Remove CDATA wrapper
        if (std.mem.startsWith(u8, cleaned, "<![CDATA[") and std.mem.endsWith(u8, cleaned, "]]>")) {
            cleaned = cleaned[9..cleaned.len - 3];
        }
        
        // Basic HTML entity decoding
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        var i: usize = 0;
        while (i < cleaned.len) {
            if (cleaned[i] == '&') {
                // Look for entity
                if (std.mem.startsWith(u8, cleaned[i..], "&amp;")) {
                    try result.append('&');
                    i += 5;
                } else if (std.mem.startsWith(u8, cleaned[i..], "&lt;")) {
                    try result.append('<');
                    i += 4;
                } else if (std.mem.startsWith(u8, cleaned[i..], "&gt;")) {
                    try result.append('>');
                    i += 4;
                } else if (std.mem.startsWith(u8, cleaned[i..], "&quot;")) {
                    try result.append('"');
                    i += 6;
                } else if (std.mem.startsWith(u8, cleaned[i..], "&apos;")) {
                    try result.append('\'');
                    i += 6;
                } else {
                    try result.append(cleaned[i]);
                    i += 1;
                }
            } else {
                try result.append(cleaned[i]);
                i += 1;
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Check if RSS item should be included based on filters
    fn shouldIncludeItem(self: *RssClient, item: RssItem, source: config.RssSource) !bool {
        // Must have title and link
        if (item.title == null or item.link == null) return false;
        
        // Check age (if pub_date is available)
        if (item.pub_date) |pub_date| {
            // Simple date check - if it contains recent date patterns
            const now = std.time.timestamp();
            const max_age_seconds = source.max_age_days * 24 * 60 * 60;
            
            // Parse date would go here - for now, accept all
            _ = pub_date;
            _ = now;
            _ = max_age_seconds;
        }
        
        // AI keyword filtering (if enabled)
        if (source.filter_ai_keywords) {
            const ai_keywords = [_][]const u8{
                "AI", "artificial intelligence", "machine learning", "neural network",
                "deep learning", "ChatGPT", "GPT", "LLM", "Claude", "OpenAI",
                "Anthropic", "automation", "algorithm", "model", "training"
            };
            
            const title = item.title.?;
            const description = item.description orelse "";
            
            const combined_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ title, description });
            defer self.allocator.free(combined_text);
            
            const lower_text = try std.ascii.allocLowerString(self.allocator, combined_text);
            defer self.allocator.free(lower_text);
            
            for (ai_keywords) |keyword| {
                const lower_keyword = try std.ascii.allocLowerString(self.allocator, keyword);
                defer self.allocator.free(lower_keyword);
                
                if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
                    return true;
                }
            }
            
            return false; // No AI keywords found
        }
        
        return true; // Include all items if no filtering
    }
    
    /// Convert RSS item to NewsItem
    fn convertToNewsItem(self: *RssClient, item: RssItem, source: config.RssSource) !types.NewsItem {
        const title = item.title orelse "Untitled";
        const url = item.link orelse "";
        
        // Generate summary from description
        var summary: []u8 = undefined;
        if (item.description) |desc| {
            // Remove HTML tags from description
            const clean_desc = try self.stripHtmlTags(desc);
            defer self.allocator.free(clean_desc);
            
            // Truncate to reasonable length
            if (clean_desc.len > 300) {
                summary = try std.fmt.allocPrint(self.allocator, "{s}...", .{clean_desc[0..300]});
            } else {
                summary = try self.allocator.dupe(u8, clean_desc);
            }
        } else {
            summary = try self.allocator.dupe(u8, title);
        }
        
        // Calculate relevance score
        const relevance_score = self.calculateRelevanceScore(title, item.description orelse "");
        
        // Parse timestamp (simplified)
        const timestamp = if (item.pub_date) |_| 
            std.time.timestamp() // Use current time for now
        else 
            types.getCurrentTimestamp();
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, title),
            .summary = summary,
            .url = try self.allocator.dupe(u8, url),
            .source = try std.fmt.allocPrint(self.allocator, "RSS: {s}", .{source.name}),
            .source_type = .web_crawl,
            .timestamp = timestamp,
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Strip HTML tags from text
    fn stripHtmlTags(self: *RssClient, html: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        var in_tag = false;
        for (html) |c| {
            if (c == '<') {
                in_tag = true;
            } else if (c == '>') {
                in_tag = false;
            } else if (!in_tag) {
                try result.append(c);
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Calculate relevance score for RSS items
    fn calculateRelevanceScore(self: *RssClient, title: []const u8, description: []const u8) f32 {
        _ = self;
        
        var relevance: f32 = 0.3; // Base score
        
        // High-value AI keywords
        const high_value_keywords = [_][]const u8{
            "ChatGPT", "GPT-4", "Claude", "OpenAI", "Anthropic", "breakthrough",
            "release", "launch", "announcement"
        };
        
        // Medium-value AI keywords
        const medium_value_keywords = [_][]const u8{
            "artificial intelligence", "machine learning", "neural network",
            "deep learning", "AI", "algorithm", "model"
        };
        
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const combined_text = std.fmt.allocPrint(temp_allocator, "{s} {s}", .{ title, description }) catch return relevance;
        const lower_text = std.ascii.allocLowerString(temp_allocator, combined_text) catch return relevance;
        
        // Score high-value keywords
        for (high_value_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
            if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
                relevance += 0.4;
            }
        }
        
        // Score medium-value keywords
        for (medium_value_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
            if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
                relevance += 0.2;
            }
        }
        
        // Boost for title mentions (titles are more important)
        const lower_title = std.ascii.allocLowerString(temp_allocator, title) catch title;
        for (high_value_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
            if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
                relevance += 0.2; // Extra boost for title mentions
            }
        }
        
        return @min(relevance, 1.0);
    }
};

/// Temporary RSS item structure for parsing
const RssItem = struct {
    title: ?[]u8,
    link: ?[]u8,
    description: ?[]u8,
    pub_date: ?[]u8,
    guid: ?[]u8,
    allocator: std.mem.Allocator,
    
    fn init(allocator: std.mem.Allocator) RssItem {
        return RssItem{
            .title = null,
            .link = null,
            .description = null,
            .pub_date = null,
            .guid = null,
            .allocator = allocator,
        };
    }
    
    fn deinit(self: RssItem, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.link) |link| allocator.free(link);
        if (self.description) |desc| allocator.free(desc);
        if (self.pub_date) |date| allocator.free(date);
        if (self.guid) |guid| allocator.free(guid);
    }
};

/// Helper function to extract RSS content
pub fn extractRssContent(allocator: std.mem.Allocator, sources: []const config.RssSource) ![]types.NewsItem {
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var rss_client = RssClient.init(allocator, &http_client);
    defer rss_client.deinit();
    
    var all_items = std.ArrayList(types.NewsItem).init(allocator);
    defer {
        for (all_items.items) |item| {
            item.deinit(allocator);
        }
        all_items.deinit();
    }
    
    for (sources) |source| {
        const items = rss_client.extractRssFeed(source) catch |err| {
            std.log.warn("⚠️ Failed to extract from RSS {s}: {}", .{ source.name, err });
            continue;
        };
        defer {
            for (items) |item| {
                item.deinit(allocator);
            }
            allocator.free(items);
        }
        
        for (items) |item| {
            try all_items.append(try item.clone(allocator));
        }
        
        // Rate limiting between feeds
        std.time.sleep(500 * std.time.ns_per_ms);
    }
    
    const result = try all_items.toOwnedSlice();
    all_items = std.ArrayList(types.NewsItem).init(allocator); // Prevent cleanup
    return result;
}

// Test function
test "RSS client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    _ = RssClient.init(allocator, &http_client);
}