const std = @import("std");
const types = @import("core_types.zig");
const firecrawl = @import("external_firecrawl.zig");
const config = @import("core_config.zig");

pub const BlogClient = struct {
    allocator: std.mem.Allocator,
    firecrawl_client: *firecrawl.FirecrawlClient,
    
    pub fn init(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) BlogClient {
        return BlogClient{
            .allocator = allocator,
            .firecrawl_client = firecrawl_client,
        };
    }
    
    /// Extract articles from a blog using comptime configuration
    pub fn extractBlogArticles(self: *BlogClient, source: config.BlogSource) ![]types.NewsItem {
        // First, discover article URLs using the map endpoint
        const article_urls = try self.discoverArticleUrls(source);
        defer {
            for (article_urls) |url| {
                self.allocator.free(url);
            }
            self.allocator.free(article_urls);
        }
        
        std.log.info("📰 Discovered {d} articles from {s}", .{ article_urls.len, source.name });
        for (article_urls, 0..) |url, i| {
            std.log.info("  📄 [{d}] {s}", .{ i + 1, url });
        }
        
        // Then scrape each article
        var articles = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            for (articles.items) |article| {
                article.deinit(self.allocator);
            }
            articles.deinit();
        }
        
        var article_count: u32 = 0;
        for (article_urls) |url| {
            if (article_count >= source.max_articles) break;
            
            const article = self.scrapeArticle(url, source) catch |err| {
                std.log.warn("Failed to scrape article {s}: {}", .{ url, err });
                continue;
            };
            
            if (article) |valid_article| {
                try articles.append(valid_article);
                article_count += 1;
            }
        }
        
        const result = try articles.toOwnedSlice();
        articles = std.ArrayList(types.NewsItem).init(self.allocator); // Prevent cleanup
        return result;
    }
    
    /// Discover article URLs from the blog's main page or sitemap
    fn discoverArticleUrls(self: *BlogClient, source: config.BlogSource) ![][]const u8 {
        // Use Firecrawl's map endpoint to discover URLs
        const urls = self.firecrawl_client.map(source.url, .{
            .include_subdomains = false,
            .limit = source.max_articles * 2, // Get more than needed for filtering
        }) catch |err| {
            std.log.warn("Failed to map {s}, falling back to main page scraping: {}", .{ source.url, err });
            return try self.scrapeMainPageUrls(source);
        };
        
        // Filter URLs to find likely articles
        return try self.filterArticleUrls(urls, source);
    }
    
    /// Fallback: scrape the main page for article links
    fn scrapeMainPageUrls(self: *BlogClient, source: config.BlogSource) ![][]const u8 {
        const response = try self.firecrawl_client.scrape(source.url, .{
            .only_main_content = true,
            .include_links = true,
        });
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            std.log.err("Failed to scrape blog main page {s}: {s}", .{ source.url, response.@"error" orelse "Unknown error" });
            return &[_][]const u8{};
        }
        
        const markdown = response.data.?.markdown orelse return &[_][]const u8{};
        
        // Extract URLs from markdown links
        var urls = std.ArrayList([]const u8).init(self.allocator);
        var lines = std.mem.splitScalar(u8, markdown, '\n');
        
        while (lines.next()) |line| {
            if (self.extractUrlFromMarkdownLink(line)) |url| {
                if (try self.isLikelyArticleUrl(url, source)) {
                    try urls.append(try self.allocator.dupe(u8, url));
                }
            }
        }
        
        return try urls.toOwnedSlice();
    }
    
    /// Filter URLs to find likely articles
    fn filterArticleUrls(self: *BlogClient, urls: [][]const u8, source: config.BlogSource) ![][]const u8 {
        var filtered = std.ArrayList([]const u8).init(self.allocator);
        
        for (urls) |url| {
            if (try self.isLikelyArticleUrl(url, source)) {
                try filtered.append(try self.allocator.dupe(u8, url));
                
                if (filtered.items.len >= source.max_articles) break;
            }
        }
        
        return try filtered.toOwnedSlice();
    }
    
    /// Check if a URL looks like an article (not homepage, about page, etc.)
    fn isLikelyArticleUrl(self: *BlogClient, url: []const u8, source: config.BlogSource) !bool {
        
        // Must be from the same domain
        if (!std.mem.containsAtLeast(u8, url, 1, self.extractDomain(source.url))) {
            return false;
        }
        
        // Exclude common non-article pages
        const exclude_patterns = [_][]const u8{
            "about", "contact", "privacy", "terms", "category", "tag",
            "archive", "author", "search", "login", "register", "admin"
        };
        
        const lower_url = std.ascii.allocLowerString(self.allocator, url) catch return false;
        defer self.allocator.free(lower_url);
        
        for (exclude_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_url, pattern) != null) {
                return false;
            }
        }
        
        // Look for article-like patterns
        const include_patterns = [_][]const u8{
            "/blog/", "/posts/", "/articles/", "/news/", "/2024/", "/2023/"
        };
        
        for (include_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_url, pattern) != null) {
                return true;
            }
        }
        
        // Default: include if it's not the root domain
        const domain = self.extractDomain(source.url);
        return !std.mem.eql(u8, url, source.url) and 
               !std.mem.eql(u8, url, try std.fmt.allocPrint(self.allocator, "https://{s}", .{domain}));
    }
    
    /// Extract domain from URL
    fn extractDomain(self: *BlogClient, url: []const u8) []const u8 {
        _ = self;
        
        var domain_start: usize = 0;
        if (std.mem.startsWith(u8, url, "https://")) {
            domain_start = 8;
        } else if (std.mem.startsWith(u8, url, "http://")) {
            domain_start = 7;
        }
        
        const domain_end = std.mem.indexOf(u8, url[domain_start..], "/") orelse (url.len - domain_start);
        return url[domain_start..domain_start + domain_end];
    }
    
    /// Extract URL from a markdown link [text](url)
    fn extractUrlFromMarkdownLink(self: *BlogClient, line: []const u8) ?[]const u8 {
        _ = self;
        
        if (std.mem.indexOf(u8, line, "](") == null) return null;
        
        const url_start_marker = std.mem.indexOf(u8, line, "](").? + 2;
        const url_end = std.mem.indexOf(u8, line[url_start_marker..], ")") orelse return null;
        
        return line[url_start_marker..url_start_marker + url_end];
    }
    
    /// Scrape a single article and convert to NewsItem
    fn scrapeArticle(self: *BlogClient, url: []const u8, source: config.BlogSource) !?types.NewsItem {
        const response = try self.firecrawl_client.scrape(url, .{
            .only_main_content = true,
            .include_links = false,
        });
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            return null;
        }
        
        const markdown = response.data.?.markdown orelse return null;
        
        // Log detailed markdown content with beautiful formatting
        std.log.info("", .{});
        std.log.info("📄 ========================================", .{});
        std.log.info("📄 Scraped markdown from {s} ({d} chars)", .{ url, markdown.len });
        std.log.info("📄 ========================================", .{});
        std.log.info("📝 Markdown content preview:", .{});
        std.log.info("", .{});
        const preview_len = @min(markdown.len, 800);
        std.log.info("{s}", .{markdown[0..preview_len]});
        if (markdown.len > 800) {
            std.log.info("", .{});
            std.log.info("📄 ...markdown continues for {d} more characters", .{ markdown.len - 800 });
        }
        std.log.info("", .{});
        
        // Parse article content
        const article = try self.parseArticleContent(markdown, url, source);
        
        // Filter by relevance
        if (try self.shouldIncludeArticle(article)) {
            return try self.convertToNewsItem(article, source);
        } else {
            article.deinit(self.allocator);
            return null;
        }
    }
    
    /// Parse article content from markdown
    fn parseArticleContent(self: *BlogClient, markdown: []const u8, url: []const u8, source: config.BlogSource) !PartialArticle {
        var article = PartialArticle{
            .title = try self.allocator.dupe(u8, ""),
            .url = try self.allocator.dupe(u8, url),
            .author = try self.allocator.dupe(u8, ""),
            .publication_date = try self.allocator.dupe(u8, ""),
            .content = std.ArrayList(u8).init(self.allocator),
            .tags = std.ArrayList([]u8).init(self.allocator),
            .read_time_minutes = null,
            .allocator = self.allocator,
        };
        
        var lines = std.mem.splitScalar(u8, markdown, '\n');
        var found_title = false;
        var line_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            line_count += 1;
            
            // Extract title (usually first heading)
            if (!found_title and (std.mem.startsWith(u8, trimmed, "# ") or 
                                  std.mem.startsWith(u8, trimmed, "## "))) {
                self.allocator.free(article.title);
                article.title = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed, "# "));
                found_title = true;
                continue;
            }
            
            // Look for metadata in first few lines
            if (line_count < 20) {
                if (self.isAuthorLine(trimmed)) {
                    self.allocator.free(article.author);
                    article.author = try self.extractAuthor(trimmed);
                    continue;
                }
                
                if (self.isDateLine(trimmed)) {
                    self.allocator.free(article.publication_date);
                    article.publication_date = try self.allocator.dupe(u8, trimmed);
                    continue;
                }
                
                if (self.isTagLine(trimmed)) {
                    try self.parseTagsLine(&article, trimmed);
                    continue;
                }
            }
            
            // Add substantial content to body
            if (trimmed.len > 20 and !std.mem.startsWith(u8, trimmed, "#")) {
                try article.content.appendSlice(trimmed);
                try article.content.append('\n');
            }
        }
        
        // Fallback title extraction from URL if none found
        if (article.title.len == 0) {
            self.allocator.free(article.title);
            article.title = try self.extractTitleFromUrl(url);
        }
        
        // Set default source author if none found
        if (article.author.len == 0) {
            self.allocator.free(article.author);
            article.author = try self.allocator.dupe(u8, source.name);
        }
        
        // Estimate read time
        const word_count = self.estimateWordCount(article.content.items);
        article.read_time_minutes = @max(1, word_count / 200); // Assume 200 words per minute
        
        return article;
    }
    
    fn isAuthorLine(self: *BlogClient, line: []const u8) bool {
        _ = self;
        const lower_line = std.ascii.allocLowerString(std.heap.page_allocator, line) catch return false;
        defer std.heap.page_allocator.free(lower_line);
        
        return std.mem.indexOf(u8, lower_line, "author") != null or
               std.mem.indexOf(u8, lower_line, "by ") != null or
               std.mem.indexOf(u8, lower_line, "written by") != null;
    }
    
    fn isDateLine(self: *BlogClient, line: []const u8) bool {
        _ = self;
        const date_patterns = [_][]const u8{
            "2024", "2023", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "Published", "posted"
        };
        
        for (date_patterns) |pattern| {
            if (std.mem.indexOf(u8, line, pattern) != null) {
                return true;
            }
        }
        
        return false;
    }
    
    fn isTagLine(self: *BlogClient, line: []const u8) bool {
        _ = self;
        const lower_line = std.ascii.allocLowerString(std.heap.page_allocator, line) catch return false;
        defer std.heap.page_allocator.free(lower_line);
        
        return std.mem.indexOf(u8, lower_line, "tags:") != null or
               std.mem.indexOf(u8, lower_line, "categories:") != null or
               std.mem.indexOf(u8, lower_line, "topics:") != null;
    }
    
    fn extractAuthor(self: *BlogClient, line: []const u8) ![]u8 {
        var author_text = line;
        
        // Remove common prefixes
        if (std.mem.indexOf(u8, line, "by ")) |pos| {
            author_text = line[pos + 3..];
        } else if (std.mem.indexOf(u8, line, "Author:")) |pos| {
            author_text = line[pos + 7..];
        } else if (std.mem.indexOf(u8, line, "Written by")) |pos| {
            author_text = line[pos + 10..];
        }
        
        // Clean up the author text
        const trimmed = std.mem.trim(u8, author_text, " \t\r-|");
        return self.allocator.dupe(u8, trimmed);
    }
    
    fn parseTagsLine(self: *BlogClient, article: *PartialArticle, line: []const u8) !void {
        var tag_text = line;
        
        // Remove tag prefixes
        if (std.mem.indexOf(u8, line, ":")) |pos| {
            tag_text = line[pos + 1..];
        }
        
        // Split by common delimiters
        var tag_split = std.mem.splitScalar(u8, tag_text, ',');
        while (tag_split.next()) |tag| {
            const trimmed_tag = std.mem.trim(u8, tag, " \t\r#");
            if (trimmed_tag.len > 1 and trimmed_tag.len < 30) {
                const tag_copy = try self.allocator.dupe(u8, trimmed_tag);
                try article.tags.append(tag_copy);
            }
        }
    }
    
    fn extractTitleFromUrl(self: *BlogClient, url: []const u8) ![]u8 {
        // Extract title from URL path
        const last_slash = std.mem.lastIndexOf(u8, url, "/") orelse return self.allocator.dupe(u8, "Blog Post");
        var title_part = url[last_slash + 1..];
        
        // Remove file extensions
        if (std.mem.lastIndexOf(u8, title_part, ".")) |dot_pos| {
            title_part = title_part[0..dot_pos];
        }
        
        // Replace dashes and underscores with spaces
        var title = try self.allocator.alloc(u8, title_part.len);
        for (title_part, 0..) |char, i| {
            title[i] = if (char == '-' or char == '_') ' ' else char;
        }
        
        return title;
    }
    
    fn estimateWordCount(self: *BlogClient, text: []const u8) u32 {
        _ = self;
        var word_count: u32 = 0;
        var in_word = false;
        
        for (text) |char| {
            if (std.ascii.isAlphabetic(char)) {
                if (!in_word) {
                    word_count += 1;
                    in_word = true;
                }
            } else {
                in_word = false;
            }
        }
        
        return word_count;
    }
    
    fn shouldIncludeArticle(self: *BlogClient, article: PartialArticle) !bool {
        // Filter by content length
        if (article.content.items.len < 200) return false;
        
        // Filter by title length
        if (article.title.len < 10) return false;
        
        // Check for AI/tech relevance
        const ai_keywords = [_][]const u8{
            "AI", "ML", "artificial intelligence", "machine learning", "neural",
            "model", "algorithm", "data science", "technology", "software",
            "programming", "development", "innovation", "research", "GPT",
            "LLM", "language model", "deep learning", "computer vision"
        };
        
        const combined_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ article.title, article.content.items });
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
        
        return false;
    }
    
    fn convertToNewsItem(self: *BlogClient, article: PartialArticle, source: config.BlogSource) !types.NewsItem {
        // Convert tags ArrayList to owned slice
        var tags_slice = try self.allocator.alloc([]const u8, article.tags.items.len);
        for (article.tags.items, 0..) |tag, i| {
            tags_slice[i] = try self.allocator.dupe(u8, tag);
        }
        
        const blog_metadata = types.BlogMetadata{
            .author = if (article.author.len > 0) try self.allocator.dupe(u8, article.author) else null,
            .publication_date = try self.allocator.dupe(u8, article.publication_date),
            .read_time_minutes = article.read_time_minutes,
            .tags = if (tags_slice.len > 0) tags_slice else null,
        };
        
        // Generate summary from content (first 200 chars)
        const content_text = article.content.items;
        const summary_len = @min(content_text.len, 200);
        var summary = try self.allocator.alloc(u8, summary_len + 3);
        @memcpy(summary[0..summary_len], content_text[0..summary_len]);
        if (content_text.len > 200) {
            @memcpy(summary[summary_len..], "...");
        } else {
            summary = summary[0..summary_len];
        }
        
        // Calculate relevance score based on content length and recency
        const content_score = @min(@as(f32, @floatFromInt(content_text.len)) / 2000.0, 1.0);
        const base_score = 0.4 + content_score * 0.6;
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, article.title),
            .summary = summary,
            .url = try self.allocator.dupe(u8, article.url),
            .source = try self.allocator.dupe(u8, source.name),
            .source_type = .blog,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = base_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = blog_metadata,
            .github_metadata = null,
        };
    }
};

const PartialArticle = struct {
    title: []u8,
    url: []u8,
    author: []u8,
    publication_date: []u8,
    content: std.ArrayList(u8),
    tags: std.ArrayList([]u8),
    read_time_minutes: ?u32,
    allocator: std.mem.Allocator,
    
    fn deinit(self: PartialArticle, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.author);
        allocator.free(self.publication_date);
        self.content.deinit();
        
        for (self.tags.items) |tag| {
            allocator.free(tag);
        }
        self.tags.deinit();
    }
};

/// Convenience function to extract articles from all configured blog sources
pub fn extractAllBlogArticles(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) ![]types.NewsItem {
    var client = BlogClient.init(allocator, firecrawl_client);
    var all_articles = std.ArrayList(types.NewsItem).init(allocator);
    
    for (config.Config.blog_sources) |source| {
        std.log.info("Extracting articles from {s}...", .{source.name});
        
        const articles = client.extractBlogArticles(source) catch |err| {
            std.log.err("Failed to extract from {s}: {}", .{ source.name, err });
            continue; // Continue with other blogs
        };
        
        for (articles) |article| {
            try all_articles.append(article);
        }
        
        std.log.info("Extracted {d} articles from {s}", .{ articles.len, source.name });
        allocator.free(articles);
    }
    
    return try all_articles.toOwnedSlice();
}

// Test function
test "Blog client domain extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var firecrawl_client = try firecrawl.FirecrawlClient.init(allocator, "test-key");
    defer firecrawl_client.deinit();
    
    var blog_client = BlogClient.init(allocator, &firecrawl_client);
    
    // Test domain extraction
    const domain = blog_client.extractDomain("https://example.com/blog/post");
    try std.testing.expect(std.mem.eql(u8, domain, "example.com"));
}