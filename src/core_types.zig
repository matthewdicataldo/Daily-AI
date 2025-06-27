const std = @import("std");
const memory_pools = @import("cache_memory_pools.zig");

pub const SourceType = enum {
    reddit,
    youtube,
    tiktok,
    research_hub,
    blog,
    web_crawl,
    github_repo,
    rss,
    
    pub const SourceInfo = struct {
        name: []const u8,
        cli_flag: []const u8,
        description: []const u8,
    };
    
    pub fn getInfo(self: SourceType) SourceInfo {
        return switch (self) {
            .reddit => .{ .name = "reddit", .cli_flag = "reddit", .description = "Reddit sources" },
            .youtube => .{ .name = "youtube", .cli_flag = "youtube", .description = "YouTube sources" },
            .tiktok => .{ .name = "tiktok", .cli_flag = "tiktok", .description = "TikTok sources" },
            .research_hub => .{ .name = "research", .cli_flag = "research", .description = "research paper sources" },
            .blog => .{ .name = "blogs", .cli_flag = "blogs", .description = "blog sources" },
            .web_crawl => .{ .name = "news", .cli_flag = "news", .description = "news sources (Hacker News)" },
            .github_repo => .{ .name = "github", .cli_flag = "github", .description = "GitHub repository sources" },
            .rss => .{ .name = "rss", .cli_flag = "rss", .description = "RSS news feeds" },
        };
    }
    
    pub fn getAllSourceTypes() []const SourceType {
        return &[_]SourceType{ .reddit, .youtube, .tiktok, .research_hub, .blog, .web_crawl, .github_repo, .rss };
    }
};

/// String reference within a string pool (data-oriented design)
pub const StringRef = struct {
    offset: u32,
    length: u32,
    
    pub fn slice(self: StringRef, pool: []const u8) []const u8 {
        return pool[self.offset..self.offset + self.length];
    }
    
    pub fn isEmpty(self: StringRef) bool {
        return self.length == 0;
    }
};

/// Data-oriented news item storage using Structure of Arrays (SoA)
/// This replaces the traditional Array of Structures (AoS) pattern for better cache performance
/// Now uses specialized memory pools for optimal performance
pub const NewsItemStorage = struct {
    // Hot data - frequently accessed together (better cache locality)
    relevance_scores: []f32,
    timestamps: []i64,
    source_types: []SourceType,
    
    // String references into the optimized string pool
    title_refs: []StringRef,
    summary_refs: []StringRef,
    url_refs: []StringRef,
    source_refs: []StringRef,
    
    // Metadata indices (optional, points to separate metadata arrays)
    reddit_indices: []?u32,      // Index into reddit_metadata array
    youtube_indices: []?u32,     // Index into youtube_metadata array
    huggingface_indices: []?u32, // Index into huggingface_metadata array
    blog_indices: []?u32,        // Index into blog_metadata array
    github_indices: []?u32,      // Index into github_metadata array
    
    // Metadata arrays (separate for each type) - managed by pools
    reddit_metadata: []RedditMetadata,
    youtube_metadata: []YouTubeMetadata,
    huggingface_metadata: []HuggingFaceMetadata,
    blog_metadata: []BlogMetadata,
    github_metadata: []GitHubRepoMetadata,
    
    // Counters
    count: u32,
    capacity: u32,
    
    // Memory management
    pools: *memory_pools.NewsAggregatorPools,
    allocator: std.mem.Allocator, // Fallback allocator
    
    const Self = @This();
    
    /// Initialize empty storage with specified capacity and memory pools
    pub fn init(allocator: std.mem.Allocator, pools: *memory_pools.NewsAggregatorPools, capacity: u32) !Self {
        return Self{
            .relevance_scores = try allocator.alloc(f32, capacity),
            .timestamps = try allocator.alloc(i64, capacity),
            .source_types = try allocator.alloc(SourceType, capacity),
            .title_refs = try allocator.alloc(StringRef, capacity),
            .summary_refs = try allocator.alloc(StringRef, capacity),
            .url_refs = try allocator.alloc(StringRef, capacity),
            .source_refs = try allocator.alloc(StringRef, capacity),
            .reddit_indices = try allocator.alloc(?u32, capacity),
            .youtube_indices = try allocator.alloc(?u32, capacity),
            .huggingface_indices = try allocator.alloc(?u32, capacity),
            .blog_indices = try allocator.alloc(?u32, capacity),
            .github_indices = try allocator.alloc(?u32, capacity),
            .reddit_metadata = try allocator.alloc(RedditMetadata, capacity / 4), // Estimate 25% have reddit metadata
            .youtube_metadata = try allocator.alloc(YouTubeMetadata, capacity / 4),
            .huggingface_metadata = try allocator.alloc(HuggingFaceMetadata, capacity / 4),
            .blog_metadata = try allocator.alloc(BlogMetadata, capacity / 4),
            .github_metadata = try allocator.alloc(GitHubRepoMetadata, capacity / 4),
            .count = 0,
            .capacity = capacity,
            .pools = pools,
            .allocator = allocator,
        };
    }
    
    /// Clean up all allocated memory
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.relevance_scores);
        self.allocator.free(self.timestamps);
        self.allocator.free(self.source_types);
        self.allocator.free(self.title_refs);
        self.allocator.free(self.summary_refs);
        self.allocator.free(self.url_refs);
        self.allocator.free(self.source_refs);
        self.allocator.free(self.reddit_indices);
        self.allocator.free(self.youtube_indices);
        self.allocator.free(self.huggingface_indices);
        self.allocator.free(self.blog_indices);
        self.allocator.free(self.github_indices);
        
        // Clean up metadata arrays - only deinit if they were actually used
        // For now, we're not using metadata in SoA, so just free the arrays
        self.allocator.free(self.reddit_metadata);
        self.allocator.free(self.youtube_metadata);
        self.allocator.free(self.huggingface_metadata);
        self.allocator.free(self.blog_metadata);
        self.allocator.free(self.github_metadata);
    }
    
    /// Add string to optimized pool and return reference
    fn addStringToPool(self: *Self, str: []const u8) !StringRef {
        return try self.pools.allocString(str);
    }
    
    /// Add a news item to the storage
    pub fn addItem(self: *Self, item: NewsItem) !void {
        if (self.count >= self.capacity) {
            return error.StorageFull;
        }
        
        const index = self.count;
        
        // Store hot data
        self.relevance_scores[index] = item.relevance_score;
        self.timestamps[index] = item.timestamp;
        self.source_types[index] = item.source_type;
        
        // Store string references
        self.title_refs[index] = try self.addStringToPool(item.title);
        self.summary_refs[index] = try self.addStringToPool(item.summary);
        self.url_refs[index] = try self.addStringToPool(item.url);
        self.source_refs[index] = try self.addStringToPool(item.source);
        
        // Handle metadata (simplified for now - just set to null)
        self.reddit_indices[index] = null;
        self.youtube_indices[index] = null;
        self.huggingface_indices[index] = null;
        self.blog_indices[index] = null;
        self.github_indices[index] = null;
        
        self.count += 1;
    }
    
    /// Get a NewsItem by index (creates temporary NewsItem)
    pub fn getItem(self: *Self, index: u32) !NewsItem {
        if (index >= self.count) return error.IndexOutOfBounds;
        
        return NewsItem{
            .title = try self.allocator.dupe(u8, self.getTitle(index)),
            .summary = try self.allocator.dupe(u8, self.getSummary(index)),
            .url = try self.allocator.dupe(u8, self.getUrl(index)),
            .source = try self.allocator.dupe(u8, self.getSource(index)),
            .source_type = self.source_types[index],
            .timestamp = self.timestamps[index],
            .relevance_score = self.relevance_scores[index],
            .reddit_metadata = null, // TODO: Implement metadata retrieval
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Get title string by index without allocation
    pub fn getTitle(self: Self, index: u32) []const u8 {
        return self.pools.string_pool.getString(self.title_refs[index]);
    }
    
    /// Get summary string by index without allocation
    pub fn getSummary(self: Self, index: u32) []const u8 {
        return self.pools.string_pool.getString(self.summary_refs[index]);
    }
    
    /// Get URL string by index without allocation
    pub fn getUrl(self: Self, index: u32) []const u8 {
        return self.pools.string_pool.getString(self.url_refs[index]);
    }
    
    /// Get source string by index without allocation
    pub fn getSource(self: Self, index: u32) []const u8 {
        return self.pools.string_pool.getString(self.source_refs[index]);
    }
    
    /// Convert storage back to array of NewsItems (for compatibility)
    pub fn toNewsItems(self: *Self) ![]NewsItem {
        var items = try self.allocator.alloc(NewsItem, self.count);
        
        for (0..self.count) |i| {
            items[i] = try self.getItem(@intCast(i));
        }
        
        return items;
    }
    
    /// Create storage from existing NewsItems array
    pub fn fromNewsItems(allocator: std.mem.Allocator, pools: *memory_pools.NewsAggregatorPools, items: []const NewsItem) !Self {
        var storage = try Self.init(allocator, pools, @intCast(items.len));
        
        for (items) |item| {
            try storage.addItem(item);
        }
        
        return storage;
    }
    
    /// Get performance statistics for this storage instance
    pub fn getPerformanceStats(self: Self) StorageStats {
        const pool_stats = self.pools.getStats();
        return StorageStats{
            .item_count = self.count,
            .capacity_utilization = @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.capacity)),
            .string_pool_utilization = pool_stats.string_pool.utilization,
            .total_string_bytes = pool_stats.string_pool.used,
            .metadata_pool_utilization = pool_stats.reddit_pool_utilization,
        };
    }
};

/// Legacy NewsItem structure - kept for compatibility during transition
pub const NewsItem = struct {
    title: []const u8,
    summary: []const u8,
    url: []const u8,
    source: []const u8,
    source_type: SourceType,
    timestamp: i64,
    relevance_score: f32,
    reddit_metadata: ?RedditMetadata,
    youtube_metadata: ?YouTubeMetadata,
    huggingface_metadata: ?HuggingFaceMetadata,
    blog_metadata: ?BlogMetadata,
    github_metadata: ?GitHubRepoMetadata,
    
    pub fn deinit(self: NewsItem, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.url);
        allocator.free(self.source);
        
        if (self.reddit_metadata) |reddit| {
            reddit.deinit(allocator);
        }
        if (self.youtube_metadata) |youtube| {
            youtube.deinit(allocator);
        }
        if (self.huggingface_metadata) |hf| {
            hf.deinit(allocator);
        }
        if (self.blog_metadata) |blog| {
            blog.deinit(allocator);
        }
        if (self.github_metadata) |github| {
            github.deinit(allocator);
        }
    }
    
    /// Clone a NewsItem (deep copy)
    pub fn clone(self: NewsItem, allocator: std.mem.Allocator) !NewsItem {
        var cloned = NewsItem{
            .title = try allocator.dupe(u8, self.title),
            .summary = try allocator.dupe(u8, self.summary),
            .url = try allocator.dupe(u8, self.url),
            .source = try allocator.dupe(u8, self.source),
            .source_type = self.source_type,
            .timestamp = self.timestamp,
            .relevance_score = self.relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
        
        // Clone metadata if present
        if (self.reddit_metadata) |reddit| {
            cloned.reddit_metadata = try reddit.clone(allocator);
        }
        if (self.youtube_metadata) |youtube| {
            cloned.youtube_metadata = try youtube.clone(allocator);
        }
        if (self.huggingface_metadata) |hf| {
            cloned.huggingface_metadata = try hf.clone(allocator);
        }
        if (self.blog_metadata) |blog| {
            cloned.blog_metadata = try blog.clone(allocator);
        }
        if (self.github_metadata) |github| {
            cloned.github_metadata = try github.clone(allocator);
        }
        
        return cloned;
    }
};

pub const RedditMetadata = struct {
    upvotes: i32,
    comment_count: u32,
    subreddit: []const u8,
    author: []const u8,
    post_id: []const u8,
    created_utc: f64,
    permalink: []const u8,
    flair: ?[]const u8,
    is_self_post: bool,
    upvote_ratio: f32,
    selftext: ?[]const u8,
    top_comments: ?[]RedditComment,
    
    pub const RedditComment = struct {
        author: []const u8,
        text: []const u8,
        score: i32,
        
        pub fn deinit(self: RedditComment, allocator: std.mem.Allocator) void {
            allocator.free(self.author);
            allocator.free(self.text);
        }
    };
    
    pub fn deinit(self: RedditMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.subreddit);
        allocator.free(self.author);
        allocator.free(self.post_id);
        allocator.free(self.permalink);
        if (self.flair) |flair| allocator.free(flair);
        if (self.selftext) |selftext| allocator.free(selftext);
        if (self.top_comments) |comments| {
            for (comments) |comment| {
                comment.deinit(allocator);
            }
            allocator.free(comments);
        }
    }
    
    pub fn clone(self: RedditMetadata, allocator: std.mem.Allocator) !RedditMetadata {
        var cloned = RedditMetadata{
            .upvotes = self.upvotes,
            .comment_count = self.comment_count,
            .subreddit = try allocator.dupe(u8, self.subreddit),
            .author = try allocator.dupe(u8, self.author),
            .post_id = try allocator.dupe(u8, self.post_id),
            .created_utc = self.created_utc,
            .permalink = try allocator.dupe(u8, self.permalink),
            .flair = if (self.flair) |flair| try allocator.dupe(u8, flair) else null,
            .is_self_post = self.is_self_post,
            .upvote_ratio = self.upvote_ratio,
            .selftext = if (self.selftext) |text| try allocator.dupe(u8, text) else null,
            .top_comments = null,
        };
        
        if (self.top_comments) |comments| {
            var cloned_comments = try allocator.alloc(RedditComment, comments.len);
            for (comments, 0..) |comment, i| {
                cloned_comments[i] = RedditComment{
                    .author = try allocator.dupe(u8, comment.author),
                    .text = try allocator.dupe(u8, comment.text),
                    .score = comment.score,
                };
            }
            cloned.top_comments = cloned_comments;
        }
        
        return cloned;
    }
};

pub const YouTubeMetadata = struct {
    video_id: []const u8,
    channel_name: []const u8,
    duration: []const u8,
    view_count: u64,
    like_count: u32,
    comment_count: u32,
    upload_date: []const u8,
    has_transcript: bool,
    transcript: ?[]const u8,
    top_comments: ?[]Comment,
    
    pub const Comment = struct {
        author: []const u8,
        text: []const u8,
        likes: u32,
        
        pub fn deinit(self: Comment, allocator: std.mem.Allocator) void {
            allocator.free(self.author);
            allocator.free(self.text);
        }
    };
    
    pub fn deinit(self: YouTubeMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.video_id);
        allocator.free(self.channel_name);
        allocator.free(self.duration);
        allocator.free(self.upload_date);
        
        if (self.transcript) |transcript| {
            allocator.free(transcript);
        }
        
        if (self.top_comments) |comments| {
            for (comments) |comment| {
                comment.deinit(allocator);
            }
            allocator.free(comments);
        }
    }
    
    pub fn clone(self: YouTubeMetadata, allocator: std.mem.Allocator) !YouTubeMetadata {
        var cloned = YouTubeMetadata{
            .video_id = try allocator.dupe(u8, self.video_id),
            .channel_name = try allocator.dupe(u8, self.channel_name),
            .duration = try allocator.dupe(u8, self.duration),
            .view_count = self.view_count,
            .like_count = self.like_count,
            .comment_count = self.comment_count,
            .upload_date = try allocator.dupe(u8, self.upload_date),
            .has_transcript = self.has_transcript,
            .transcript = if (self.transcript) |t| try allocator.dupe(u8, t) else null,
            .top_comments = null,
        };
        
        if (self.top_comments) |comments| {
            var cloned_comments = try allocator.alloc(Comment, comments.len);
            for (comments, 0..) |comment, i| {
                cloned_comments[i] = Comment{
                    .author = try allocator.dupe(u8, comment.author),
                    .text = try allocator.dupe(u8, comment.text),
                    .likes = comment.likes,
                };
            }
            cloned.top_comments = cloned_comments;
        }
        
        return cloned;
    }
};

pub const HuggingFaceMetadata = struct {
    paper_id: []const u8,
    authors: [][]const u8,
    abstract: []const u8,
    publication_date: []const u8,
    likes: u32,
    downloads: u32,
    trending_score: f32,
    arxiv_id: ?[]const u8,
    github_repo: ?[]const u8,
    
    pub fn deinit(self: HuggingFaceMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.paper_id);
        
        for (self.authors) |author| {
            allocator.free(author);
        }
        allocator.free(self.authors);
        
        allocator.free(self.abstract);
        allocator.free(self.publication_date);
        
        if (self.arxiv_id) |arxiv| {
            allocator.free(arxiv);
        }
        if (self.github_repo) |repo| {
            allocator.free(repo);
        }
    }
    
    pub fn clone(self: HuggingFaceMetadata, allocator: std.mem.Allocator) !HuggingFaceMetadata {
        var cloned_authors = try allocator.alloc([]const u8, self.authors.len);
        for (self.authors, 0..) |author, i| {
            cloned_authors[i] = try allocator.dupe(u8, author);
        }
        
        return HuggingFaceMetadata{
            .paper_id = try allocator.dupe(u8, self.paper_id),
            .authors = cloned_authors,
            .abstract = try allocator.dupe(u8, self.abstract),
            .publication_date = try allocator.dupe(u8, self.publication_date),
            .likes = self.likes,
            .downloads = self.downloads,
            .trending_score = self.trending_score,
            .arxiv_id = if (self.arxiv_id) |id| try allocator.dupe(u8, id) else null,
            .github_repo = if (self.github_repo) |repo| try allocator.dupe(u8, repo) else null,
        };
    }
};

pub const BlogMetadata = struct {
    author: ?[]const u8,
    publication_date: []const u8,
    read_time_minutes: ?u32,
    tags: ?[][]const u8,
    
    pub fn deinit(self: BlogMetadata, allocator: std.mem.Allocator) void {
        if (self.author) |author| {
            allocator.free(author);
        }
        allocator.free(self.publication_date);
        
        if (self.tags) |tags| {
            for (tags) |tag| {
                allocator.free(tag);
            }
            allocator.free(tags);
        }
    }
    
    pub fn clone(self: BlogMetadata, allocator: std.mem.Allocator) !BlogMetadata {
        var cloned = BlogMetadata{
            .author = if (self.author) |author| try allocator.dupe(u8, author) else null,
            .publication_date = try allocator.dupe(u8, self.publication_date),
            .read_time_minutes = self.read_time_minutes,
            .tags = null,
        };
        
        if (self.tags) |tags| {
            var cloned_tags = try allocator.alloc([]const u8, tags.len);
            for (tags, 0..) |tag, i| {
                cloned_tags[i] = try allocator.dupe(u8, tag);
            }
            cloned.tags = cloned_tags;
        }
        
        return cloned;
    }
};

pub const GitHubRepoMetadata = struct {
    repo_name: []const u8,
    owner: []const u8,
    description: ?[]const u8,
    primary_language: ?[]const u8,
    languages: ?[]LanguageInfo,
    file_count: u32,
    total_lines: u32,
    star_count: ?u32,
    fork_count: ?u32,
    created_at: ?[]const u8,
    updated_at: ?[]const u8,
    topics: ?[][]const u8,
    readme_summary: ?[]const u8,
    key_files: ?[]FileInfo,
    architecture_insights: ?[]const u8,
    
    pub const LanguageInfo = struct {
        name: []const u8,
        percentage: f32,
        lines_of_code: u32,
        
        pub fn deinit(self: LanguageInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };
    
    pub const FileInfo = struct {
        path: []const u8,
        size: u32,
        importance: enum { critical, important, supporting },
        description: ?[]const u8,
        
        pub fn deinit(self: FileInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            if (self.description) |desc| {
                allocator.free(desc);
            }
        }
    };
    
    pub fn deinit(self: GitHubRepoMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_name);
        allocator.free(self.owner);
        
        if (self.description) |desc| {
            allocator.free(desc);
        }
        if (self.primary_language) |lang| {
            allocator.free(lang);
        }
        if (self.languages) |langs| {
            for (langs) |lang| {
                lang.deinit(allocator);
            }
            allocator.free(langs);
        }
        if (self.created_at) |created| {
            allocator.free(created);
        }
        if (self.updated_at) |updated| {
            allocator.free(updated);
        }
        if (self.topics) |topics| {
            for (topics) |topic| {
                allocator.free(topic);
            }
            allocator.free(topics);
        }
        if (self.readme_summary) |readme| {
            allocator.free(readme);
        }
        if (self.key_files) |files| {
            for (files) |file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        if (self.architecture_insights) |insights| {
            allocator.free(insights);
        }
    }
    
    pub fn clone(self: GitHubRepoMetadata, allocator: std.mem.Allocator) !GitHubRepoMetadata {
        var cloned = GitHubRepoMetadata{
            .repo_name = try allocator.dupe(u8, self.repo_name),
            .owner = try allocator.dupe(u8, self.owner),
            .description = if (self.description) |desc| try allocator.dupe(u8, desc) else null,
            .primary_language = if (self.primary_language) |lang| try allocator.dupe(u8, lang) else null,
            .languages = null,
            .file_count = self.file_count,
            .total_lines = self.total_lines,
            .star_count = self.star_count,
            .fork_count = self.fork_count,
            .created_at = if (self.created_at) |created| try allocator.dupe(u8, created) else null,
            .updated_at = if (self.updated_at) |updated| try allocator.dupe(u8, updated) else null,
            .topics = null,
            .readme_summary = if (self.readme_summary) |readme| try allocator.dupe(u8, readme) else null,
            .key_files = null,
            .architecture_insights = if (self.architecture_insights) |insights| try allocator.dupe(u8, insights) else null,
        };
        
        if (self.languages) |langs| {
            var cloned_langs = try allocator.alloc(LanguageInfo, langs.len);
            for (langs, 0..) |lang, i| {
                cloned_langs[i] = LanguageInfo{
                    .name = try allocator.dupe(u8, lang.name),
                    .percentage = lang.percentage,
                    .lines_of_code = lang.lines_of_code,
                };
            }
            cloned.languages = cloned_langs;
        }
        
        if (self.topics) |topics| {
            var cloned_topics = try allocator.alloc([]const u8, topics.len);
            for (topics, 0..) |topic, i| {
                cloned_topics[i] = try allocator.dupe(u8, topic);
            }
            cloned.topics = cloned_topics;
        }
        
        if (self.key_files) |files| {
            var cloned_files = try allocator.alloc(FileInfo, files.len);
            for (files, 0..) |file, i| {
                cloned_files[i] = FileInfo{
                    .path = try allocator.dupe(u8, file.path),
                    .size = file.size,
                    .importance = file.importance,
                    .description = if (file.description) |desc| try allocator.dupe(u8, desc) else null,
                };
            }
            cloned.key_files = cloned_files;
        }
        
        return cloned;
    }
};

pub const BlogPost = struct {
    title: []const u8,
    date: []const u8,
    items: []NewsItem,
    metadata: BlogPostMetadata,
    
    pub const BlogPostMetadata = struct {
        sources_count: u32,
        items_processed: u32,
        generation_time: i64,
        total_word_count: u32,
        categories: []Category,
        
        pub const Category = struct {
            name: []const u8,
            item_count: u32,
            
            pub fn deinit(self: Category, allocator: std.mem.Allocator) void {
                allocator.free(self.name);
            }
        };
        
        pub fn deinit(self: BlogPostMetadata, allocator: std.mem.Allocator) void {
            for (self.categories) |category| {
                category.deinit(allocator);
            }
            allocator.free(self.categories);
        }
    };
    
    pub fn deinit(self: BlogPost, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.date);
        
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        
        self.metadata.deinit(allocator);
    }
};

// Firecrawl API response structures
pub const FirecrawlResponse = struct {
    success: bool,
    data: ?FirecrawlData,
    @"error": ?[]const u8,
    
    pub const FirecrawlData = struct {
        markdown: ?[]const u8,
        html: ?[]const u8,
        metadata: ?FirecrawlMetadata,
        links: ?[]FirecrawlLink,
        
        pub const FirecrawlMetadata = struct {
            title: ?[]const u8,
            description: ?[]const u8,
            language: ?[]const u8,
            sourceURL: ?[]const u8,
            statusCode: ?u16,
            
            pub fn deinit(self: FirecrawlMetadata, allocator: std.mem.Allocator) void {
                if (self.title) |title| allocator.free(title);
                if (self.description) |desc| allocator.free(desc);
                if (self.language) |lang| allocator.free(lang);
                if (self.sourceURL) |url| allocator.free(url);
            }
        };
        
        pub const FirecrawlLink = struct {
            text: ?[]const u8,
            href: ?[]const u8,
            
            pub fn deinit(self: FirecrawlLink, allocator: std.mem.Allocator) void {
                if (self.text) |text| allocator.free(text);
                if (self.href) |href| allocator.free(href);
            }
        };
        
        
        pub fn deinit(self: FirecrawlData, allocator: std.mem.Allocator) void {
            if (self.markdown) |md| allocator.free(md);
            if (self.html) |html| allocator.free(html);
            if (self.metadata) |meta| meta.deinit(allocator);
            if (self.links) |links| {
                for (links) |link| {
                    link.deinit(allocator);
                }
                allocator.free(links);
            }
        }
    };
    
    pub fn deinit(self: FirecrawlResponse, allocator: std.mem.Allocator) void {
        if (self.data) |data| data.deinit(allocator);
        if (self.@"error") |err| allocator.free(err);
    }
};

// HTTP request/response structures for networking
pub const HttpRequest = struct {
    method: HttpMethod,
    url: []const u8,
    headers: []Header,
    body: ?[]const u8,
    
    pub const HttpMethod = enum {
        GET,
        POST,
        PUT,
        DELETE,
    };
    
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
    
    pub fn deinit(self: HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    headers: []HttpRequest.Header,
    body: []const u8,
    
    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        allocator.free(self.body);
    }
};

// Error types
pub const AppError = error{
    ConfigurationError,
    NetworkError,
    HttpError,
    ApiKeyMissing,
    FirecrawlError,
    ClaudeError,
    ParseError,
    FileSystemError,
    InvalidInput,
    RateLimitExceeded,
    OutOfMemory,
};

// Utility functions for common operations
pub fn timestampToString(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    // Convert timestamp to a basic date/time string
    const seconds = @as(u64, @intCast(timestamp));
    const epoch_day = @divFloor(seconds, 86400); // seconds per day
    const seconds_in_day = seconds % 86400;
    
    const hours = @divFloor(seconds_in_day, 3600);
    const minutes = @divFloor((seconds_in_day % 3600), 60);
    const secs = seconds_in_day % 60;
    
    // Proper date calculation from Unix timestamp
    var days = epoch_day;
    
    // Start from Unix epoch: January 1, 1970
    var year: u32 = 1970;
    var month: u32 = 1;
    var day: u32 = 1;
    
    // Calculate year (accounting for leap years)
    while (true) {
        const days_in_year: u32 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    
    // Days in each month
    const months = [_]u32{ 31, if (isLeapYear(year)) @as(u32, 29) else @as(u32, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    
    // Calculate month and day
    for (months, 0..) |days_in_month, m| {
        if (days < days_in_month) {
            month = @as(u32, @intCast(m + 1));
            day = @as(u32, @intCast(days + 1));
            break;
        }
        days -= days_in_month;
    }
    
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, month, day, hours, minutes, secs
    });
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

pub fn getCurrentTimestamp() i64 {
    return std.time.timestamp();
}

/// Content summary for integration system
pub const ContentSummary = struct {
    items: []NewsItem,
    total_count: u32,
    youtube_count: u32,
    tiktok_count: u32,
    research_count: u32,
    
    pub fn deinit(self: ContentSummary, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }
};

// Test helpers
pub fn createMockNewsItem(allocator: std.mem.Allocator) !NewsItem {
    return NewsItem{
        .title = try allocator.dupe(u8, "Test News Item"),
        .summary = try allocator.dupe(u8, "This is a test summary"),
        .url = try allocator.dupe(u8, "https://example.com/test"),
        .source = try allocator.dupe(u8, "Test Source"),
        .source_type = .blog,
        .timestamp = getCurrentTimestamp(),
        .relevance_score = 0.8,
        .reddit_metadata = null,
        .youtube_metadata = null,
        .huggingface_metadata = null,
        .blog_metadata = null,
        .github_metadata = null,
    };
}

/// Performance statistics for NewsItemStorage
pub const StorageStats = struct {
    item_count: u32,
    capacity_utilization: f32,
    string_pool_utilization: f32,
    total_string_bytes: usize,
    metadata_pool_utilization: f32,
};

/// Create mock NewsItemStorage for testing (requires pools)
pub fn createMockNewsItemStorage(allocator: std.mem.Allocator, pools: *memory_pools.NewsAggregatorPools) !NewsItemStorage {
    var storage = try NewsItemStorage.init(allocator, pools, 10);
    
    // Add a few test items
    const test_item = try createMockNewsItem(allocator);
    defer test_item.deinit(allocator);
    
    try storage.addItem(test_item);
    
    return storage;
}