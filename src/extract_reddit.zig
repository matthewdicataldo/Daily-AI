const std = @import("std");
const types = @import("core_types.zig");
const firecrawl = @import("external_firecrawl.zig");
const config = @import("core_config.zig");
const reddit_api = @import("extract_reddit_api.zig");
const http = @import("common_http.zig");
const utils = @import("core_utils.zig");

pub const RedditClient = struct {
    allocator: std.mem.Allocator,
    firecrawl_client: *firecrawl.FirecrawlClient,
    reddit_api: ?reddit_api.RedditApiClient,
    http_client: ?*http.HttpClient,
    
    pub fn init(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) RedditClient {
        return RedditClient{
            .allocator = allocator,
            .firecrawl_client = firecrawl_client,
            .reddit_api = null,
            .http_client = null,
        };
    }
    
    pub fn initWithApi(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient, api_keys: *const config.ApiKeys) !RedditClient {
        const http_client = try allocator.create(http.HttpClient);
        http_client.* = try http.HttpClient.init(allocator);
        
        const reddit_api_client = reddit_api.RedditApiClient.init(
            allocator,
            http_client,
            api_keys.reddit_client_id,
            api_keys.reddit_client_secret,
            api_keys.reddit_user_agent
        );
        
        return RedditClient{
            .allocator = allocator,
            .firecrawl_client = firecrawl_client,
            .reddit_api = reddit_api_client,
            .http_client = http_client,
        };
    }
    
    pub fn deinit(self: *RedditClient) void {
        if (self.reddit_api) |*api| {
            api.deinit();
        }
        if (self.http_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
    }
    
    /// Extract posts from a subreddit using comprehensive Reddit API data
    pub fn extractSubredditPosts(self: *RedditClient, source: config.RedditSource) ![]types.NewsItem {
        if (self.reddit_api) |*api| {
            // Use Reddit API for comprehensive data
            return try self.extractWithApi(api, source);
        } else {
            // Fallback to web scraping (legacy method)
            return try self.extractWithScraping(source);
        }
    }
    
    /// Extract posts using Reddit API with full metadata
    fn extractWithApi(self: *RedditClient, api: *reddit_api.RedditApiClient, source: config.RedditSource) ![]types.NewsItem {
        std.log.info("📱 Extracting r/{s} posts using Reddit API...", .{source.subreddit});
        
        // Fetch posts from Reddit API
        const reddit_posts = try api.getSubredditPosts(source.subreddit, .hot, source.max_posts);
        defer {
            for (reddit_posts) |post| {
                post.deinit(self.allocator);
            }
            self.allocator.free(reddit_posts);
        }
        
        var news_items = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            // Only deinit on error - successful return takes ownership
            for (news_items.items) |item| {
                item.deinit(self.allocator);
            }
            news_items.deinit();
        }
        
        for (reddit_posts) |reddit_post| {
            // Convert Reddit API post to NewsItem with comprehensive details
            const news_item = try self.convertRedditPostToNewsItem(reddit_post, source);
            
            // Apply AI relevance filtering
            if (self.isAIRelatedPost(news_item)) {
                try news_items.append(news_item);
            } else {
                news_item.deinit(self.allocator);
            }
        }
        
        std.log.info("✅ Extracted {d} AI-related posts from r/{s}", .{ news_items.items.len, source.subreddit });
        const result = try news_items.toOwnedSlice();
        news_items = std.ArrayList(types.NewsItem).init(self.allocator); // Prevent cleanup
        return result;
    }
    
    /// Fallback extraction using web scraping
    fn extractWithScraping(self: *RedditClient, source: config.RedditSource) ![]types.NewsItem {
        const url = try std.fmt.allocPrint(self.allocator, "https://old.reddit.com/r/{s}/", .{source.subreddit});
        defer self.allocator.free(url);
        
        // Scrape the subreddit page
        const response = try self.firecrawl_client.scrape(url, .{
            .only_main_content = true,
            .include_links = true,
        });
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            std.log.err("Failed to scrape r/{s}: {s}", .{ source.subreddit, response.@"error" orelse "Unknown error" });
            return types.AppError.FirecrawlError;
        }
        
        const markdown = response.data.?.markdown orelse {
            std.log.warn("No markdown content for r/{s}", .{source.subreddit});
            return &[_]types.NewsItem{};
        };
        
        // Parse Reddit posts from markdown content
        return try self.parseRedditMarkdown(markdown, source);
    }
    
    /// Convert Reddit API post to comprehensive NewsItem with all requested details
    fn convertRedditPostToNewsItem(self: *RedditClient, reddit_post: reddit_api.RedditPost, source: config.RedditSource) !types.NewsItem {
        // Build comprehensive summary including all details you requested:
        // - Full title, author, upvotes, full text description
        // - Markdown copy of main link or processed content
        
        var summary_parts = std.ArrayList(u8).init(self.allocator);
        defer summary_parts.deinit();
        
        const writer = summary_parts.writer();
        
        // Add post metadata header
        try writer.print("**Author:** u/{s}\n", .{reddit_post.author});
        try writer.print("**Score:** {d} upvotes ({d:.1}% upvoted)\n", .{ reddit_post.score, reddit_post.upvote_ratio * 100 });
        try writer.print("**Comments:** {d}\n", .{reddit_post.num_comments});
        if (reddit_post.flair_text) |flair| {
            try writer.print("**Flair:** {s}\n", .{flair});
        }
        try writer.print("**Subreddit:** r/{s}\n\n", .{reddit_post.subreddit});
        
        // Add full post content
        if (reddit_post.is_self and reddit_post.selftext != null and reddit_post.selftext.?.len > 0) {
            // Self post with text content
            try writer.print("**Post Content:**\n{s}\n\n", .{reddit_post.selftext.?});
        } else if (reddit_post.url) |post_url| {
            // Link post - process the linked content
            try writer.print("**Link:** {s}\n\n", .{post_url});
            
            // Try to fetch and process the linked content
            if (try self.processLinkedContent(post_url)) |processed_content| {
                defer self.allocator.free(processed_content);
                try writer.print("**Linked Content Summary:**\n{s}\n\n", .{processed_content});
            }
        }
        
        // Add Reddit permalink for reference
        try writer.print("**Reddit Link:** https://reddit.com{s}", .{reddit_post.permalink});
        
        const comprehensive_summary = try self.allocator.dupe(u8, summary_parts.items);
        
        // Create Reddit metadata with comprehensive information
        const reddit_metadata = types.RedditMetadata{
            .subreddit = try self.allocator.dupe(u8, reddit_post.subreddit),
            .author = try self.allocator.dupe(u8, reddit_post.author),
            .post_id = try self.allocator.dupe(u8, reddit_post.id),
            .upvotes = reddit_post.score,
            .comment_count = reddit_post.num_comments,
            .created_utc = reddit_post.created_utc,
            .permalink = try self.allocator.dupe(u8, reddit_post.permalink),
            .flair = if (reddit_post.flair_text) |flair| try self.allocator.dupe(u8, flair) else null,
            .is_self_post = reddit_post.is_self,
            .upvote_ratio = reddit_post.upvote_ratio,
            .selftext = if (reddit_post.selftext) |text| try self.allocator.dupe(u8, text) else null,
            .top_comments = null, // TODO: Extract comments when available
        };
        
        // Calculate relevance score
        const relevance_score = self.calculateRedditRelevance(reddit_post);
        
        // Determine URL (external link or Reddit permalink)
        const item_url = if (reddit_post.url) |url| 
            try self.allocator.dupe(u8, url) 
        else blk: {
            const permalink_url = try std.fmt.allocPrint(self.allocator, "https://reddit.com{s}", .{reddit_post.permalink});
            break :blk permalink_url;
        };
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, reddit_post.title),
            .summary = comprehensive_summary,
            .url = item_url,
            .source = try std.fmt.allocPrint(self.allocator, "r/{s}", .{source.subreddit}),
            .source_type = .reddit,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = relevance_score,
            .reddit_metadata = reddit_metadata,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Process linked content from Reddit posts (YouTube videos, articles, etc.)
    fn processLinkedContent(self: *RedditClient, url: []const u8) !?[]const u8 {
        // Check if it's a YouTube video
        if (std.mem.indexOf(u8, url, "youtube.com") != null or std.mem.indexOf(u8, url, "youtu.be") != null) {
            // For YouTube links, we could extract video info, but for now return the URL
            return try std.fmt.allocPrint(self.allocator, "YouTube Video: {s}", .{url});
        }
        
        // For other links, try to scrape with Firecrawl if available
        if (std.mem.startsWith(u8, url, "http")) {
            const response = self.firecrawl_client.scrape(url, .{
                .only_main_content = true,
                .include_links = false,
            }) catch |err| {
                std.log.debug("Failed to scrape linked content {s}: {}", .{ url, err });
                return null;
            };
            defer response.deinit(self.allocator);
            
            if (response.success and response.data != null and response.data.?.markdown != null) {
                const content = response.data.?.markdown.?;
                // Return first 500 characters as summary
                if (content.len > 500) {
                    return try std.fmt.allocPrint(self.allocator, "{s}...", .{content[0..500]});
                } else {
                    return try self.allocator.dupe(u8, content);
                }
            }
        }
        
        return null;
    }
    
    /// Calculate relevance score for Reddit posts
    fn calculateRedditRelevance(self: *RedditClient, reddit_post: reddit_api.RedditPost) f32 {
        _ = self;
        var relevance: f32 = 0.3; // Base score
        
        // Score boost from upvotes (logarithmic)
        if (reddit_post.score > 0) {
            const log_score = @log(@as(f32, @floatFromInt(reddit_post.score)));
            relevance += @min(log_score / 10.0, 0.3);
        }
        
        // Score boost from comments
        if (reddit_post.num_comments > 0) {
            const comment_boost = @as(f32, @floatFromInt(reddit_post.num_comments)) / 100.0;
            relevance += @min(comment_boost * 0.2, 0.2);
        }
        
        // Upvote ratio boost
        relevance += (reddit_post.upvote_ratio - 0.5) * 0.2;
        
        return @min(relevance, 1.0);
    }
    
    /// Check if Reddit post is AI-related
    fn isAIRelatedPost(self: *RedditClient, news_item: types.NewsItem) bool {
        const ai_keywords = [_][]const u8{
            "ai", "artificial intelligence", "machine learning", "ml", "deep learning",
            "neural network", "gpt", "llm", "large language model", "claude", "openai",
            "anthropic", "transformer", "bert", "chatgpt", "automation", "robotics"
        };
        
        const combined_text = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ news_item.title, news_item.summary }) catch return false;
        defer self.allocator.free(combined_text);
        
        return utils.TextUtils.containsKeywords(self.allocator, combined_text, &ai_keywords);
    }
    
    /// Parse Reddit markdown content to extract post information
    fn parseRedditMarkdown(self: *RedditClient, markdown: []const u8, source: config.RedditSource) ![]types.NewsItem {
        var posts = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            // Clean up if we fail partway through
            for (posts.items) |post| {
                post.deinit(self.allocator);
            }
            posts.deinit();
        }
        
        var lines = std.mem.splitScalar(u8, markdown, '\n');
        var current_post: ?PartialPost = null;
        var post_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Look for post titles (usually start with ##, ###, or have specific patterns)
            if (self.isPostTitle(trimmed)) {
                // Save previous post if exists
                if (current_post) |post| {
                    if (try self.shouldIncludePost(post, source)) {
                        const news_item = try self.convertToNewsItem(post, source);
                        try posts.append(news_item);
                        post_count += 1;
                        
                        if (post_count >= source.max_posts) break;
                    }
                    current_post.?.deinit(self.allocator);
                }
                
                // Start new post
                current_post = try self.parsePostHeader(trimmed);
            } else if (current_post != null) {
                // Add content to current post
                try self.addContentToPost(&current_post.?, trimmed);
            }
        }
        
        // Handle last post
        if (current_post) |post| {
            if (try self.shouldIncludePost(post, source)) {
                const news_item = try self.convertToNewsItem(post, source);
                try posts.append(news_item);
            }
            current_post.?.deinit(self.allocator);
        }
        
        const result = try posts.toOwnedSlice();
        posts = std.ArrayList(types.NewsItem).init(self.allocator); // Prevent cleanup
        return result;
    }
    
    fn isPostTitle(self: *RedditClient, line: []const u8) bool {
        _ = self;
        
        // Look for common Reddit post patterns
        if (std.mem.startsWith(u8, line, "##")) return true;
        if (std.mem.startsWith(u8, line, "###")) return true;
        if (std.mem.indexOf(u8, line, "submitted") != null and std.mem.indexOf(u8, line, "points") != null) return true;
        if (std.mem.indexOf(u8, line, "upvote") != null or std.mem.indexOf(u8, line, "downvote") != null) return true;
        
        // Look for link patterns that indicate post titles
        if (std.mem.startsWith(u8, line, "[") and std.mem.indexOf(u8, line, "](") != null) {
            // Check if it looks like a substantial title (not just navigation)
            if (line.len > 20 and !std.mem.containsAtLeast(u8, line, 1, "reddit.com")) {
                return true;
            }
        }
        
        return false;
    }
    
    fn parsePostHeader(self: *RedditClient, line: []const u8) !PartialPost {
        var post = PartialPost{
            .title = try self.allocator.dupe(u8, ""),
            .url = try self.allocator.dupe(u8, ""),
            .author = try self.allocator.dupe(u8, ""),
            .upvotes = 0,
            .comment_count = 0,
            .content = std.ArrayList(u8).init(self.allocator),
            .allocator = self.allocator,
        };
        
        // Extract title from markdown link format [title](url)
        if (std.mem.indexOf(u8, line, "[") != null and std.mem.indexOf(u8, line, "](") != null) {
            const title_start = std.mem.indexOf(u8, line, "[").? + 1;
            const title_end = std.mem.indexOf(u8, line, "](").?;
            const url_start = title_end + 2;
            const url_end = std.mem.indexOf(u8, line[url_start..], ")");
            
            if (title_end > title_start) {
                self.allocator.free(post.title);
                post.title = try self.allocator.dupe(u8, line[title_start..title_end]);
            }
            
            if (url_end != null and url_start < line.len) {
                self.allocator.free(post.url);
                const url_slice = line[url_start..url_start + url_end.?];
                post.url = try self.allocator.dupe(u8, url_slice);
            }
        } else {
            // Fallback: use the whole line as title, clean up markdown
            const cleaned_title = std.mem.trim(u8, line, "# \t");
            self.allocator.free(post.title);
            post.title = try self.allocator.dupe(u8, cleaned_title);
        }
        
        // Extract vote and comment counts if present
        post.upvotes = utils.TextUtils.extractNumberNearKeyword(line, "point") orelse 
                      utils.TextUtils.extractNumberNearKeyword(line, "upvote") orelse 1;
        post.comment_count = utils.TextUtils.extractNumberNearKeyword(line, "comment") orelse 0;
        
        return post;
    }
    
    fn addContentToPost(self: *RedditClient, post: *PartialPost, line: []const u8) !void {
        _ = self;
        
        // Skip empty lines and navigation elements
        if (line.len == 0) return;
        if (std.mem.indexOf(u8, line, "reddit.com") != null) return;
        if (std.mem.indexOf(u8, line, "permalink") != null) return;
        
        // Add line to content with newline
        try post.content.appendSlice(line);
        try post.content.append('\n');
    }
    
    
    fn shouldIncludePost(self: *RedditClient, post: PartialPost, source: config.RedditSource) !bool {
        
        // Filter by minimum upvotes
        if (post.upvotes < source.min_upvotes) return false;
        
        // Filter by title length (avoid very short titles)
        if (post.title.len < 10) return false;
        
        // Filter AI-related content (basic keyword matching)
        const ai_keywords = [_][]const u8{
            "AI", "ML", "LLM", "GPT", "Claude", "artificial intelligence",
            "machine learning", "neural network", "deep learning", "model",
            "training", "inference", "transformer", "attention", "embedding",
            "fine-tuning", "RAG", "retrieval", "generation", "chatbot",
            "language model", "computer vision", "NLP", "reinforcement learning"
        };
        
        const combined_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ post.title, post.content.items });
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
    
    fn convertToNewsItem(self: *RedditClient, post: PartialPost, source: config.RedditSource) !types.NewsItem {
        const reddit_metadata = types.RedditMetadata{
            .upvotes = @as(i32, @intCast(post.upvotes)),
            .comment_count = post.comment_count,
            .subreddit = try self.allocator.dupe(u8, source.subreddit),
            .author = try self.allocator.dupe(u8, post.author),
            .post_id = try self.extractPostId(post.url),
            .created_utc = @as(f64, @floatFromInt(types.getCurrentTimestamp())),
            .permalink = try std.fmt.allocPrint(self.allocator, "/r/{s}/comments/{s}/", .{ source.subreddit, post.title }),
            .flair = null,
            .is_self_post = false,
            .upvote_ratio = 0.8, // Default estimate
            .selftext = null, // TODO: Extract selftext when available
            .top_comments = null, // TODO: Extract comments when available
        };
        
        // Generate summary from content (first 200 chars)
        const content = post.content.items;
        const summary_len = @min(content.len, 200);
        var summary = try self.allocator.alloc(u8, summary_len + 3);
        @memcpy(summary[0..summary_len], content[0..summary_len]);
        if (content.len > 200) {
            @memcpy(summary[summary_len..], "...");
        } else {
            summary = summary[0..summary_len];
        }
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, post.title),
            .summary = summary,
            .url = try self.allocator.dupe(u8, post.url),
            .source = try std.fmt.allocPrint(self.allocator, "r/{s}", .{source.subreddit}),
            .source_type = .reddit,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = @as(f32, @floatFromInt(post.upvotes)) / 100.0, // Simple scoring
            .reddit_metadata = reddit_metadata,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    fn extractPostId(self: *RedditClient, url: []const u8) ![]u8 {
        // Extract Reddit post ID from URL
        if (std.mem.indexOf(u8, url, "/comments/")) |pos| {
            const id_start = pos + "/comments/".len;
            const id_end = std.mem.indexOf(u8, url[id_start..], "/") orelse (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        }
        
        // Fallback: generate a simple ID from URL hash
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(url);
        const hash = hasher.final();
        return std.fmt.allocPrint(self.allocator, "{x}", .{hash});
    }
};

const PartialPost = struct {
    title: []u8,
    url: []u8,
    author: []u8,
    upvotes: u32,
    comment_count: u32,
    content: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    
    fn deinit(self: PartialPost, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.author);
        self.content.deinit();
    }
};

/// Enhanced Reddit extraction using API instead of web scraping
pub fn extractAllRedditPosts(allocator: std.mem.Allocator, api_keys: config.ApiKeys) ![]types.NewsItem {
    // Initialize HTTP client for Reddit API
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    // Initialize Reddit API client
    var reddit_client = reddit_api.RedditApiClient.init(
        allocator,
        &http_client,
        api_keys.reddit_client_id,
        api_keys.reddit_client_secret,
        api_keys.reddit_user_agent,
    );
    defer reddit_client.deinit();
    
    var all_posts = std.ArrayList(types.NewsItem).init(allocator);
    defer {
        // Clean up on error
        for (all_posts.items) |item| {
            item.deinit(allocator);
        }
        all_posts.deinit();
    }
    
    for (config.Config.reddit_sources) |source| {
        std.log.info("📱 Extracting posts from r/{s} via Reddit API...", .{source.subreddit});
        
        // Get posts from Reddit API
        const reddit_posts = reddit_client.getSubredditPosts(
            source.subreddit,
            source.sort,
            source.max_posts,
        ) catch |err| {
            std.log.err("Failed to extract from r/{s}: {}", .{ source.subreddit, err });
            continue;
        };
        defer {
            for (reddit_posts) |post| {
                post.deinit(allocator);
            }
            allocator.free(reddit_posts);
        }
        
        // Convert Reddit posts to NewsItems
        for (reddit_posts) |reddit_post| {
            // Apply filters
            if (reddit_post.score < source.min_upvotes) continue;
            if (reddit_post.over_18) continue; // Skip NSFW content
            if (!isAIRelated(reddit_post.title, reddit_post.selftext orelse "")) continue;
            
            // Get comments if requested
            var comments: []reddit_api.RedditComment = &[_]reddit_api.RedditComment{};
            if (source.include_comments) {
                comments = reddit_client.getPostComments(
                    source.subreddit,
                    reddit_post.id,
                    source.max_comments,
                ) catch |err| blk: {
                    std.log.warn("Failed to get comments for post {s}: {}", .{ reddit_post.id, err });
                    break :blk &[_]reddit_api.RedditComment{};
                };
            }
            defer {
                for (comments) |comment| {
                    comment.deinit(allocator);
                }
                if (comments.len > 0) allocator.free(comments);
            }
            
            // Convert to NewsItem
            const news_item = try convertRedditPostToNewsItem(allocator, reddit_post, comments, source);
            try all_posts.append(news_item);
        }
        
        std.log.info("✅ Extracted {d} relevant posts from r/{s}", .{ all_posts.items.len, source.subreddit });
    }
    
    const result = try all_posts.toOwnedSlice();
    all_posts = std.ArrayList(types.NewsItem).init(allocator); // Prevent cleanup
    return result;
}

/// Convert Reddit API post to our NewsItem format
fn convertRedditPostToNewsItem(
    allocator: std.mem.Allocator,
    reddit_post: reddit_api.RedditPost,
    comments: []reddit_api.RedditComment,
    source: config.RedditSource,
) !types.NewsItem {
    // Create enhanced Reddit metadata
    const reddit_metadata = types.RedditMetadata{
        .upvotes = @as(u32, @intCast(@max(0, reddit_post.score))),
        .comment_count = reddit_post.num_comments,
        .subreddit = try allocator.dupe(u8, reddit_post.subreddit),
        .author = try allocator.dupe(u8, reddit_post.author),
        .post_id = try allocator.dupe(u8, reddit_post.id),
    };
    
    // Generate comprehensive summary
    var summary_parts = std.ArrayList([]const u8).init(allocator);
    defer summary_parts.deinit();
    
    // Add post text if available
    if (reddit_post.selftext) |selftext| {
        if (selftext.len > 0) {
            const trimmed_text = std.mem.trim(u8, selftext, " \t\n\r");
            if (trimmed_text.len > 0) {
                const summary_text = if (trimmed_text.len > 300) 
                    try std.fmt.allocPrint(allocator, "{s}...", .{trimmed_text[0..300]})
                else 
                    try allocator.dupe(u8, trimmed_text);
                try summary_parts.append(summary_text);
            }
        }
    }
    
    // Add top comments to summary
    if (comments.len > 0) {
        try summary_parts.append(try allocator.dupe(u8, "\n\n**Top Comments:**"));
        for (comments[0..@min(3, comments.len)]) |comment| {
            if (comment.body.len > 0 and comment.score > 5) {
                const comment_text = if (comment.body.len > 150)
                    try std.fmt.allocPrint(allocator, "\n- {s}... (Score: {d})", .{ comment.body[0..150], comment.score })
                else
                    try std.fmt.allocPrint(allocator, "\n- {s} (Score: {d})", .{ comment.body, comment.score });
                try summary_parts.append(comment_text);
            }
        }
    }
    
    // Combine summary parts
    var summary_buffer = std.ArrayList(u8).init(allocator);
    defer summary_buffer.deinit();
    
    for (summary_parts.items) |part| {
        try summary_buffer.appendSlice(part);
        allocator.free(part);
    }
    
    const final_summary = if (summary_buffer.items.len > 0)
        try summary_buffer.toOwnedSlice()
    else
        try allocator.dupe(u8, reddit_post.title);
    
    // Calculate enhanced relevance score
    const relevance_score = calculateEnhancedRelevanceScore(
        reddit_post.title,
        reddit_post.selftext orelse "",
        reddit_post.score,
        reddit_post.num_comments,
        comments,
    );
    
    // Determine post URL (use Reddit URL if it's a self post)
    const post_url = if (reddit_post.is_self or reddit_post.url == null)
        try std.fmt.allocPrint(allocator, "https://reddit.com{s}", .{reddit_post.permalink})
    else
        try allocator.dupe(u8, reddit_post.url.?);
    
    return types.NewsItem{
        .title = try allocator.dupe(u8, reddit_post.title),
        .summary = final_summary,
        .url = post_url,
        .source = try std.fmt.allocPrint(allocator, "r/{s}", .{source.subreddit}),
        .source_type = .reddit,
        .timestamp = @as(i64, @intFromFloat(reddit_post.created_utc)),
        .relevance_score = relevance_score,
        .reddit_metadata = reddit_metadata,
        .youtube_metadata = null,
        .huggingface_metadata = null,
        .blog_metadata = null,
        .github_metadata = null,
    };
}

/// Enhanced AI relevance detection
fn isAIRelated(title: []const u8, content: []const u8) bool {
    const ai_keywords = [_][]const u8{
        "AI", "artificial intelligence", "machine learning", "ML", "neural", "deep learning",
        "GPT", "LLM", "transformer", "ChatGPT", "Claude", "OpenAI", "Anthropic", "ollama",
        "computer vision", "NLP", "natural language", "algorithm", "model", "training",
        "inference", "embedding", "vector", "AGI", "automation", "robot", "autonomous",
        "data science", "analytics", "prediction", "classification", "regression",
        "hugging face", "pytorch", "tensorflow", "keras", "scikit", "pandas", "numpy",
        "stable diffusion", "midjourney", "DALL-E", "diffusion", "generative",
        "fine-tuning", "RAG", "retrieval", "prompt", "tokens", "attention", "BERT",
        "reinforcement learning", "Q-learning", "neural network", "backpropagation"
    };
    
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();
    
    const combined_text = std.fmt.allocPrint(temp_allocator, "{s} {s}", .{ title, content }) catch return false;
    const lower_text = std.ascii.allocLowerString(temp_allocator, combined_text) catch return false;
    
    for (ai_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
        
        if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
            return true;
        }
    }
    
    return false;
}

/// Calculate enhanced relevance score using multiple factors
fn calculateEnhancedRelevanceScore(
    title: []const u8,
    content: []const u8,
    score: i32,
    num_comments: u32,
    comments: []reddit_api.RedditComment,
) f32 {
    var relevance: f32 = 0.3; // Base score
    
    // Keyword-based scoring
    const high_value_keywords = [_][]const u8{ "GPT", "Claude", "OpenAI", "Anthropic", "breakthrough", "release" };
    const medium_value_keywords = [_][]const u8{ "AI", "ML", "neural", "model", "algorithm", "learning" };
    
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();
    
    const combined_text = std.fmt.allocPrint(temp_allocator, "{s} {s}", .{ title, content }) catch return relevance;
    const lower_text = std.ascii.allocLowerString(temp_allocator, combined_text) catch return relevance;
    
    // High-value keywords boost
    for (high_value_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
        
        if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
            relevance += 0.4;
        }
    }
    
    // Medium-value keywords boost
    for (medium_value_keywords) |keyword| {
        const lower_keyword = std.ascii.allocLowerString(temp_allocator, keyword) catch continue;
        
        if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
            relevance += 0.2;
        }
    }
    
    // Engagement-based scoring
    const upvote_score = @as(f32, @floatFromInt(@max(0, score))) / 100.0;
    const comment_score = @as(f32, @floatFromInt(num_comments)) / 50.0;
    
    relevance += @min(upvote_score * 0.3, 0.3); // Max 0.3 boost from upvotes
    relevance += @min(comment_score * 0.2, 0.2); // Max 0.2 boost from comments
    
    // Comment quality boost
    var quality_comments: u32 = 0;
    for (comments) |comment| {
        if (comment.score > 10 and comment.body.len > 50) {
            quality_comments += 1;
        }
    }
    
    if (quality_comments > 0) {
        relevance += @min(@as(f32, @floatFromInt(quality_comments)) * 0.1, 0.2);
    }
    
    return @min(relevance, 1.0);
}

// Test function
test "Reddit client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var firecrawl_client = try firecrawl.FirecrawlClient.init(allocator, "test-key");
    defer firecrawl_client.deinit();
    
    _ = RedditClient.init(allocator, &firecrawl_client);
    
    // Test number extraction using utility
    const upvotes = utils.TextUtils.extractNumberNearKeyword("submitted 2 hours ago by user123 - 45 points", "point");
    try std.testing.expect(upvotes != null);
    try std.testing.expect(upvotes.? == 45);
}

/// Create a standardized Reddit URL for caching purposes
pub fn createRedditUrl(allocator: std.mem.Allocator, subreddit: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "https://reddit.com/r/{s}", .{subreddit});
}