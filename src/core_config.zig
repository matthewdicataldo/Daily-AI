const std = @import("std");

// Comptime configuration - edit these arrays to add/remove sources
pub const Config = struct {
    // Reddit subreddits to monitor (enhanced for deep research)
    pub const reddit_sources = [_]RedditSource{
        .{ .subreddit = "LocalLLaMA", .max_posts = 25 },  // Increased from 16
        .{ .subreddit = "MachineLearning", .max_posts = 20 },  // Increased from 10
        .{ .subreddit = "artificial", .max_posts = 15 },  // Increased from 10
        .{ .subreddit = "singularity", .max_posts = 15 },  // Increased from 5
        .{ .subreddit = "ChatGPT", .max_posts = 10 },  // New source
        .{ .subreddit = "OpenAI", .max_posts = 8 },  // New source
        .{ .subreddit = "ArtificialIntelligence", .max_posts = 12 },  // New source
    };
    
    // YouTube channels to monitor (enhanced for deep research)
    pub const youtube_sources = [_]YouTubeSource{
        .{ .handle = "@NateBJones", .max_videos = 3, .include_transcript = true },  // Increased from 2
        .{ .handle = "@GosuCoder", .max_videos = 3, .include_transcript = true },  // Increased from 2
        .{ .handle = "@AICodeKing", .max_videos = 3, .include_transcript = true },  // Increased from 2
        .{ .handle = "@aiexplained-official", .max_videos = 5, .include_transcript = true },  // Increased from 4
        .{ .handle = "@TwoMinutePapers", .max_videos = 3, .include_transcript = true },  // Increased from 2
        .{ .handle = "@3Blue1Brown", .max_videos = 2, .include_transcript = true },  // Increased from 1
        .{ .handle = "@yannic-kilcher", .max_videos = 2, .include_transcript = true },  // New source
        .{ .handle = "@sentdex", .max_videos = 2, .include_transcript = true },  // New source
        .{ .handle = "@CodeEmporium", .max_videos = 2, .include_transcript = true },  // New source
    };
    
    // TikTok sources to monitor
    pub const tiktok_sources = [_]TikTokSource{
        .{ .handle = "cjs.ai.toolbox", .max_videos = 6 },
        .{ .handle = "ai_explained", .max_videos = 2 },
    };
    
    // Research paper sources (enhanced for deep research)
    pub const research_sources = [_]ResearchSource{
        .{ .url = "https://huggingface.co/papers", .max_papers = 10, .trending_only = true },  // Increased from 6
        .{ .url = "https://arxiv.org/list/cs.AI/recent", .max_papers = 8, .trending_only = false },  // Increased from 5
        .{ .url = "https://arxiv.org/list/cs.CL/recent", .max_papers = 6, .trending_only = false },  // New source - Computational Linguistics
        .{ .url = "https://arxiv.org/list/cs.LG/recent", .max_papers = 6, .trending_only = false },  // New source - Machine Learning
        .{ .url = "https://arxiv.org/list/stat.ML/recent", .max_papers = 4, .trending_only = false },  // New source - ML Statistics
    };
    
    // Blog sources
    pub const blog_sources = [_]BlogSource{
        .{ .url = "https://openai.com/blog", .name = "OpenAI Blog" },
        .{ .url = "https://www.anthropic.com/news", .name = "Anthropic News" },
        .{ .url = "https://natesnewsletter.substack.com/", .name = "Nate's Newsletter" },
        .{ .url = "https://blog.google/technology/ai/", .name = "Google AI Blog" },
        .{ .url = "https://ai.meta.com/blog/", .name = "Meta AI Blog" },
        .{ .url = "https://www.deepmind.com/blog", .name = "DeepMind Blog" },
    };
    
    // News sources (enhanced for deep research)
    pub const news_sources = [_]NewsSource{
        .{ .name = "Hacker News", .url = "https://news.ycombinator.com", .max_items = 60 },  // Increased from 40
    };
    
    // RSS News sources (enhanced for deep research)
    pub const rss_sources = [_]RssSource{
        .{ .name = "Google AI News", .url = "https://news.google.com/rss/search?q=artificial+intelligence&hl=en&gl=US&ceid=US:en", .max_articles = 30 },  // Increased from 20
        .{ .name = "TechCrunch AI", .url = "https://techcrunch.com/category/artificial-intelligence/feed/", .max_articles = 25 },  // Increased from 15
        .{ .name = "MIT Technology Review AI", .url = "https://www.technologyreview.com/topic/artificial-intelligence/feed/", .max_articles = 15 },  // Increased from 10
        .{ .name = "VentureBeat AI", .url = "https://venturebeat.com/ai/feed/", .max_articles = 20 },  // Increased from 15
        .{ .name = "Ars Technica AI", .url = "https://feeds.arstechnica.com/arstechnica/technology-lab", .max_articles = 15 },  // Increased from 10
        .{ .name = "AI News", .url = "https://www.artificialintelligence-news.com/feed/", .max_articles = 15 },  // New source
        .{ .name = "The Information AI", .url = "https://www.theinformation.com/topics/artificial-intelligence", .max_articles = 10 },  // New source
    };
    
    // Processing settings (enhanced for deep research)
    pub const processing = ProcessingConfig{
        .max_concurrent_scrapes = 8,  // Increased from 5 for faster processing
        .claude_max_turns = 15,  // Increased from 10 for deeper analysis
        .relevance_threshold = 0.6,  // Lowered from 0.7 to capture more content
        .max_items_per_blog = 30,  // Increased from 20 for comprehensive coverage
    };
    
    // Output settings
    pub const output = OutputConfig{
        .format = .markdown,
        .file_pattern = "ai-news-{date}.md",
        .include_timestamps = true,
        .include_source_metrics = true,
    };
    
    // Helper function to get environment variable from system or .env file
    fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        // First try system environment
        if (std.process.getEnvVarOwned(allocator, key)) |value| {
            return value;
        } else |_| {
            // Fallback to .env file
            return getEnvVarFromDotEnv(allocator, key);
        }
    }
    
    // Helper function to get environment variable from .env file
    fn getEnvVarFromDotEnv(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const file = std.fs.cwd().openFile(".env", .{}) catch |err| switch (err) {
            error.FileNotFound => return error.EnvironmentVariableNotFound,
            else => return err,
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB limit
        defer allocator.free(content);
        
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip empty lines and comments
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
                continue;
            }
            
            // Look for KEY=VALUE format
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const file_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, file_key, key)) {
                    var value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");
                    
                    // Remove quotes if present
                    if (value.len >= 2) {
                        if ((std.mem.startsWith(u8, value, "\"") and std.mem.endsWith(u8, value, "\"")) or
                            (std.mem.startsWith(u8, value, "'") and std.mem.endsWith(u8, value, "'"))) {
                            value = value[1..value.len - 1];
                        }
                    }
                    
                    return try allocator.dupe(u8, value);
                }
            }
        }
        
        return error.EnvironmentVariableNotFound;
    }

    // Runtime API key loading (called at program start)
    pub fn loadApiKeys(allocator: std.mem.Allocator) !ApiKeys {
        return ApiKeys{
            .firecrawl_api_key = try getEnvVar(allocator, "FIRECRAWL_API_KEY"),
            .claude_model = getEnvVar(allocator, "CLAUDE_MODEL") catch try allocator.dupe(u8, "sonnet"),
            .output_dir = getEnvVar(allocator, "OUTPUT_DIR") catch try allocator.dupe(u8, "./output"),
            .verbose = blk: {
                const verbose_str = getEnvVar(allocator, "VERBOSE") catch break :blk false;
                defer allocator.free(verbose_str);
                break :blk std.mem.eql(u8, verbose_str, "true");
            },
            .reddit_client_id = try getEnvVar(allocator, "REDDIT_CLIENT_ID"),
            .reddit_client_secret = try getEnvVar(allocator, "REDDIT_CLIENT_SECRET"),
            .reddit_user_agent = getEnvVar(allocator, "REDDIT_USER_AGENT") catch try allocator.dupe(u8, "daily-ai-news-generator:v1.0 (by /u/your_username)"),
        };
    }
};

// Source type definitions
pub const RedditSource = struct {
    subreddit: []const u8,
    max_posts: u32 = 20,
    min_upvotes: u32 = 10,
    max_age_hours: u32 = 24,
    sort: RedditSort = .hot,
    include_comments: bool = true,
    max_comments: u32 = 10,
};

pub const RedditSort = enum {
    hot,
    new,
    top,
    rising,
};

pub const YouTubeSource = struct {
    handle: []const u8,
    max_videos: u32 = 1,
    include_transcript: bool = true,
    include_comments: bool = true,
    max_comments: u32 = 50,
    max_age_days: u32 = 7,
};

pub const TikTokSource = struct {
    handle: []const u8,
    max_videos: u32 = 3,
    max_age_days: u32 = 7,
};

pub const ResearchSource = struct {
    url: []const u8,
    max_papers: u32 = 10,
    trending_only: bool = true,
    min_downloads: u32 = 0,
};

pub const BlogSource = struct {
    url: []const u8,
    name: []const u8,
    max_articles: u32 = 5,
    max_age_days: u32 = 30,
};

pub const NewsSource = struct {
    name: []const u8,
    url: []const u8,
    max_items: u32 = 30,
    max_age_hours: u32 = 24,
};

pub const RssSource = struct {
    name: []const u8,
    url: []const u8,
    max_articles: u32 = 20,
    max_age_days: u32 = 7,
    include_description: bool = true,
    filter_ai_keywords: bool = true,
};

pub const ProcessingConfig = struct {
    max_concurrent_scrapes: u32,
    claude_max_turns: u32,
    relevance_threshold: f32,
    max_items_per_blog: u32,
};

pub const OutputConfig = struct {
    format: enum { markdown, json, html },
    file_pattern: []const u8,
    include_timestamps: bool,
    include_source_metrics: bool,
};

pub const ApiKeys = struct {
    firecrawl_api_key: []const u8,
    claude_model: []const u8,
    output_dir: []const u8,
    verbose: bool,
    reddit_client_id: []const u8,
    reddit_client_secret: []const u8,
    reddit_user_agent: []const u8,
    
    pub fn deinit(self: ApiKeys, allocator: std.mem.Allocator) void {
        allocator.free(self.firecrawl_api_key);
        allocator.free(self.claude_model);
        allocator.free(self.output_dir);
        allocator.free(self.reddit_client_id);
        allocator.free(self.reddit_client_secret);
        allocator.free(self.reddit_user_agent);
    }
};

// Compile-time validation
comptime {
    // Validate that we have at least one source of each type
    if (Config.reddit_sources.len == 0 and 
        Config.youtube_sources.len == 0 and 
        Config.research_sources.len == 0 and 
        Config.blog_sources.len == 0) {
        @compileError("At least one source must be configured");
    }
    
    // Validate subreddit names don't contain invalid characters
    for (Config.reddit_sources) |source| {
        if (std.mem.indexOf(u8, source.subreddit, "/") != null) {
            @compileError("Reddit subreddit names should not contain '/' characters");
        }
    }
    
    // Validate YouTube handles start with @
    for (Config.youtube_sources) |source| {
        if (!std.mem.startsWith(u8, source.handle, "@")) {
            @compileError("YouTube handles must start with '@'");
        }
    }
    
    // Validate processing thresholds are reasonable
    if (Config.processing.relevance_threshold < 0.0 or Config.processing.relevance_threshold > 1.0) {
        @compileError("Relevance threshold must be between 0.0 and 1.0");
    }
}