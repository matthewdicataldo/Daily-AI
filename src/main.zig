const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("daily_ai_lib");

// Import from library to avoid module conflicts
const config = lib.config;
const types = lib.types;
const firecrawl = lib.firecrawl;
const http = lib.http;
const reddit = lib.reddit;
const youtube = lib.youtube;
const tiktok = lib.tiktok;
const huggingface = lib.huggingface;
const blog = lib.blog;
const hackernews = lib.hackernews;
const processor = lib.processor;
const claude = lib.claude;
// Note: Local LLM imports removed to simplify system, deep research requires LLM backend
const generator = lib.generator;
const cli = lib.cli;
const progress = lib.progress;
const cache = lib.cache;
const progress_stream = lib.progress_stream;

// RSS extraction
const rss = lib.rss;

// Parallel extraction types
const ExtractionResult = struct {
    items: []types.NewsItem,
    source_type: []const u8,
    error_occurred: bool,
};

const ExtractionContext = struct {
    allocator: std.mem.Allocator,
    api_keys: *const config.ApiKeys,
    firecrawl_client: *firecrawl.FirecrawlClient,
    cli_config: *const cli.CliConfig,
    content_cache: *cache.ContentCache,
    result_index: usize,
    results: *[6]?ExtractionResult,
};

/// Clean up old log files, keeping only the 5 most recent ones and all blog files
fn cleanupOldLogs(allocator: std.mem.Allocator) void {
    std.log.info("🧹 Cleaning up old log files...", .{});
    
    // Get list of .log files (excluding blog files)
    const cleanup_script = 
        \\find . -name "*.log" -type f -printf '%T@ %p\n' | sort -n | head -n -5 | cut -d' ' -f2- | xargs -r rm -f
    ;
    
    var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cleanup_script }, allocator);
    _ = process.spawnAndWait() catch |err| {
        std.log.warn("⚠️ Log cleanup failed: {}", .{err});
        return;
    };
    
    std.log.info("✅ Old logs cleaned up (kept 5 most recent)", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected! Check allocator usage.", .{});
        }
    }
    const base_allocator = gpa.allocator();
    
    // Create main arena allocator for entire blog generation process
    var main_arena = std.heap.ArenaAllocator.init(base_allocator);
    defer main_arena.deinit(); // This will free ALL arena memory at once
    const allocator = main_arena.allocator();
    
    // Clean up old logs at startup using base allocator (short-lived)
    cleanupOldLogs(base_allocator);
    
    // Initialize streaming progress system
    var stream = progress_stream.ProgressStream.init(allocator);
    defer stream.deinit();
    
    // Initialize progress tracker
    var tracker = progress.ProgressTracker.init(allocator, progress.ProgressPhases.TOTAL_STEPS);
    defer tracker.deinit();
    
    // Register all major operations for streaming
    try stream.registerOperation("cli_parse", "Parse CLI arguments");
    try stream.registerOperation("config_load", "Load configuration and API keys");
    try stream.registerOperation("client_init", "Initialize API clients");
    try stream.registerOperation("content_extract", "Extract content from all sources");
    try stream.registerOperation("content_process", "Process and filter content");
    try stream.registerOperation("claude_analyze", "Analyze content with Claude AI");
    try stream.registerOperation("blog_generate", "Generate markdown blog post");
    
    tracker.updatePhase("🚀 Starting AI News Generator", progress.ProgressPhases.INIT);
    
    // Parse command line arguments
    tracker.updatePhase("📋 Parsing command line arguments", progress.ProgressPhases.CLI_PARSE);
    try stream.updateOperation("cli_parse", 0.1, "Parsing command line arguments", 0, null);
    
    const cli_config = cli.parseArgs(allocator) catch |err| switch (err) {
        error.ShowHelpAndExit => {
            try cli.printUsage(allocator);
            return;
        },
        else => {
            try stream.failOperation("cli_parse", "Failed to parse command line arguments");
            return err;
        },
    };
    defer cli_config.deinit(allocator);
    
    try stream.updateOperation("cli_parse", 1.0, "CLI arguments parsed successfully", 1, 1);
    
    std.log.info("🚀 AI News Generator starting...", .{});
    
    if (cli_config.verbose) {
        std.log.info("📋 CLI Configuration:", .{});
        std.log.info("  📁 Output directory: {s}", .{cli_config.output_dir});
        std.log.info("  🤖 Claude model: {s}", .{cli_config.claude_model});
        std.log.info("  📺 YouTube enabled: {}", .{cli_config.sources.youtube});
        std.log.info("  📖 Reddit enabled: {}", .{cli_config.sources.reddit});
        std.log.info("  🔬 Research enabled: {}", .{cli_config.sources.research});
        std.log.info("  📰 Blogs enabled: {}", .{cli_config.sources.blogs});
        std.log.info("  📄 News enabled: {}", .{cli_config.sources.news});
    }
    
    // Load API keys from environment
    tracker.updatePhase("🔑 Loading API keys and configuration", progress.ProgressPhases.CONFIG_LOAD);
    try stream.updateOperation("config_load", 0.2, "Loading environment variables", 0, null);
    
    const api_keys = config.Config.loadApiKeys(allocator) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            try stream.failOperation("config_load", "Missing required environment variable FIRECRAWL_API_KEY");
            std.log.err("❌ Missing required environment variable FIRECRAWL_API_KEY", .{});
            std.log.err("Please copy .env.example to .env and set your API key", .{});
            return;
        },
        else => {
            try stream.failOperation("config_load", "Failed to load API keys");
            return err;
        },
    };
    defer api_keys.deinit(allocator);
    
    try stream.updateOperation("config_load", 1.0, "Configuration loaded successfully", 1, 1);
    
    // Show configuration
    std.log.info("⚙️ Configuration loaded:", .{});
    std.log.info("  📺 YouTube sources: {d}", .{config.Config.youtube_sources.len});
    std.log.info("  📖 Reddit sources: {d}", .{config.Config.reddit_sources.len});
    std.log.info("  🔬 Research sources: {d}", .{config.Config.research_sources.len});
    std.log.info("  📰 Blog sources: {d}", .{config.Config.blog_sources.len});
    std.log.info("  📄 News sources: {d}", .{config.Config.news_sources.len});
    std.log.info("  🤖 Claude model: {s}", .{cli_config.claude_model});
    std.log.info("  📁 Output directory: {s}", .{cli_config.output_dir});
    
    // Initialize clients
    tracker.updatePhase("🔧 Initializing API clients", progress.ProgressPhases.CLIENT_INIT);
    try stream.updateOperation("client_init", 0.1, "Initializing Firecrawl client", 0, 5);
    
    var firecrawl_client = firecrawl.FirecrawlClient.init(allocator, api_keys.firecrawl_api_key) catch |err| {
        try stream.failOperation("client_init", "Failed to initialize Firecrawl client");
        std.log.err("❌ Failed to initialize Firecrawl client: {}", .{err});
        return;
    };
    defer firecrawl_client.deinit();
    
    try stream.updateOperation("client_init", 0.3, "Initializing unified cache system", 1, 5);
    
    // Initialize cache system
    std.log.info("💾 Initializing cache system...", .{});
    
    // Initialize legacy content cache for compatibility
    var content_cache = cache.ContentCache.init(allocator, cache.CacheConfig{}) catch |err| blk: {
        std.log.warn("⚠️ Legacy cache init failed: {}, using unified cache only", .{err});
        break :blk cache.ContentCache.initDummy(allocator);
    };
    defer content_cache.deinit();
    
    try stream.updateOperation("client_init", 0.5, "Initializing content processor", 2, 6);
    var content_processor = processor.ContentProcessor.init(allocator);
    
    try stream.updateOperation("client_init", 0.65, "Initializing Claude client", 3, 6);
    var claude_client = claude.ClaudeClient.init(allocator, cli_config.claude_model);
    
    try stream.updateOperation("client_init", 0.8, "Claude client ready", 4, 5);
    
    try stream.updateOperation("client_init", 0.9, "Initializing blog generator", 4, 5);
    var blog_generator = generator.BlogGenerator.init(allocator, cli_config.output_dir);
    
    try stream.updateOperation("client_init", 1.0, "All clients initialized successfully", 5, 5);
    
    std.log.info("✅ All clients initialized successfully", .{});
    std.log.info("🤖 AI System Status:", .{});
    std.log.info("  Claude: ✅ Available (model: {s})", .{cli_config.claude_model});
    
    // === PHASE 1: CONTENT EXTRACTION ===
    std.log.info("", .{});
    std.log.info("📥 ==========================================", .{});
    std.log.info("📥           PHASE 1: CONTENT EXTRACTION", .{});
    std.log.info("📥 ==========================================", .{});
    std.log.info("", .{});
    const extraction_start = std.time.milliTimestamp();
    
    // Extract content from all sources with pre-sized allocation
    const estimated_total_items = blk: {
        var estimate: usize = 0;
        estimate += config.Config.reddit_sources.len * 20; // Avg 20 posts per subreddit
        estimate += config.Config.youtube_sources.len * 5; // Avg 5 videos per channel
        estimate += config.Config.research_sources.len * 10; // Avg 10 papers per source
        estimate += config.Config.blog_sources.len * 5; // Avg 5 articles per blog
        estimate += config.Config.news_sources.len * 30; // Avg 30 items per news source
        estimate += config.Config.rss_sources.len * 15; // Avg 15 articles per RSS source
        break :blk estimate;
    };
    
    var all_items = std.ArrayList(types.NewsItem).init(allocator);
    try all_items.ensureTotalCapacity(estimated_total_items);
    defer {
        // Clean up all NewsItem contents
        for (all_items.items) |item| {
            item.deinit(allocator);
        }
        // Clean up the ArrayList itself
        all_items.deinit();
    }
    
    // Parallel extraction of all sources
    tracker.updatePhase("🚀 Extracting from all sources in parallel", progress.ProgressPhases.REDDIT_EXTRACT);
    try stream.updateOperation("content_extract", 0.1, "Starting parallel content extraction", 0, null);
    
    // Create extraction results structure for parallel processing
    const MAX_EXTRACTORS = 6; // Reddit, YouTube, TikTok, Research, Blog, News, RSS
    var extraction_results = [_]?ExtractionResult{null} ** MAX_EXTRACTORS;
    
    // Create thread pool for parallel extraction
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(std.Thread.Pool.Options{ .allocator = allocator, .n_jobs = null });
    defer thread_pool.deinit();
    
    // Create extraction contexts for each source type
    var extraction_contexts = [_]ExtractionContext{
        ExtractionContext{ // Reddit - Index 0
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 0,
            .results = &extraction_results,
        },
        ExtractionContext{ // YouTube - Index 1
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 1,
            .results = &extraction_results,
        },
        ExtractionContext{ // TikTok - Index 2
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 2,
            .results = &extraction_results,
        },
        ExtractionContext{ // Research - Index 3
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 3,
            .results = &extraction_results,
        },
        ExtractionContext{ // News - Index 4
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 4,
            .results = &extraction_results,
        },
        ExtractionContext{ // RSS - Index 5
            .allocator = allocator,
            .api_keys = &api_keys,
            .firecrawl_client = &firecrawl_client,
            .cli_config = &cli_config,
            .content_cache = &content_cache,
            .result_index = 5,
            .results = &extraction_results,
        },
    };
    
    // Launch parallel extraction tasks
    var wait_group = std.Thread.WaitGroup{};
    
    std.log.info("🚀 Launching parallel content extraction across {d} source types...", .{MAX_EXTRACTORS});
    
    // Launch Reddit extraction
    if (config.Config.reddit_sources.len > 0 and cli_config.sources.isEnabled(.reddit)) {
        thread_pool.spawnWg(&wait_group, extractRedditParallel, .{&extraction_contexts[0]});
    }
    
    // Launch YouTube extraction  
    if (config.Config.youtube_sources.len > 0 and cli_config.sources.isEnabled(.youtube)) {
        thread_pool.spawnWg(&wait_group, extractYouTubeParallel, .{&extraction_contexts[1]});
    }
    
    // Launch TikTok extraction
    if (config.Config.tiktok_sources.len > 0 and cli_config.sources.isEnabled(.tiktok)) {
        thread_pool.spawnWg(&wait_group, extractTikTokParallel, .{&extraction_contexts[2]});
    }
    
    // Launch Research extraction
    if (config.Config.research_sources.len > 0 and cli_config.sources.isEnabled(.research_hub)) {
        thread_pool.spawnWg(&wait_group, extractResearchParallel, .{&extraction_contexts[3]});
    }
    
    // Launch News extraction
    if (config.Config.news_sources.len > 0 and cli_config.sources.isEnabled(.web_crawl)) {
        thread_pool.spawnWg(&wait_group, extractNewsParallel, .{&extraction_contexts[4]});
    }
    
    // Launch RSS extraction
    if (config.Config.rss_sources.len > 0 and cli_config.sources.rss) {
        thread_pool.spawnWg(&wait_group, extractRSSParallel, .{&extraction_contexts[5]});
    }
    
    // Wait for all extraction threads to complete
    thread_pool.waitAndWork(&wait_group);
    
    std.log.info("✅ All parallel extractions completed", .{});
    const extraction_end = std.time.milliTimestamp();
    std.log.info("⏱️ Parallel content extraction took: {d}ms", .{extraction_end - extraction_start});
    try stream.updateOperation("content_extract", 0.8, "Collecting parallel extraction results", MAX_EXTRACTORS, MAX_EXTRACTORS);
    
    // Collect results from all threads
    for (extraction_results) |maybe_result| {
        if (maybe_result) |result| {
            if (!result.error_occurred) {
                defer allocator.free(result.items);
                for (result.items) |item| {
                    try all_items.append(item);
                }
                std.log.info("✅ {s}: extracted {d} items", .{ result.source_type, result.items.len });
            } else {
                std.log.warn("⚠️ {s} extraction failed", .{result.source_type});
            }
        }
    }
    
    if (all_items.items.len == 0) {
        std.log.err("❌ No content extracted from any source. Check your configuration and API keys.", .{});
        return;
    }
    
    std.log.info("✅ Total extracted: {d} items", .{all_items.items.len});
    try stream.updateOperation("content_extract", 1.0, "Content extraction complete", @intCast(all_items.items.len), @intCast(all_items.items.len));
    
    // === PHASE 2: CONTENT PROCESSING ===
    tracker.updatePhase("🔄 Processing and filtering content", progress.ProgressPhases.CONTENT_PROCESS);
    std.log.info("", .{});
    std.log.info("🔄 ==========================================", .{});
    std.log.info("🔄          PHASE 2: CONTENT PROCESSING", .{});
    std.log.info("🔄 ==========================================", .{});
    std.log.info("", .{});
    const processing_start = std.time.milliTimestamp();
    try stream.updateOperation("content_process", 0.1, "Starting content processing pipeline", 0, @intCast(all_items.items.len));
    
    const processed_content = content_processor.processContentDataOriented(all_items.items) catch |err| {
        try stream.failOperation("content_process", "Content processing pipeline failed");
        std.log.err("❌ Content processing failed: {}", .{err});
        return;
    };
    defer processed_content.deinit(allocator);
    const processing_end = std.time.milliTimestamp();
    std.log.info("⏱️ Content processing took: {d}ms", .{processing_end - processing_start});
    
    try stream.updateOperation("content_process", 1.0, "Content processing complete", processed_content.stats.final_item_count, processed_content.stats.final_item_count);
    std.log.info("✅ Processing complete: {d} items after deduplication and filtering", .{processed_content.stats.final_item_count});
    
    
    // === PHASE 3: CLAUDE AI ANALYSIS ===
    tracker.updatePhase("🤖 Analyzing content with Claude AI", progress.ProgressPhases.CLAUDE_ANALYSIS);
    std.log.info("", .{});
    std.log.info("🤖 ==========================================", .{});
    std.log.info("🤖         PHASE 3: CLAUDE AI ANALYSIS", .{});
    std.log.info("🤖 ==========================================", .{});
    std.log.info("", .{});
    const ai_start = std.time.milliTimestamp();
    try stream.updateOperation("claude_analyze", 0.1, "Starting Claude analysis", 0, processed_content.stats.final_item_count);
    
    std.log.info("🤖 Using full Claude analysis with proper categorization", .{});
    try stream.updateOperation("claude_analyze", 0.3, "Running full Claude analysis", 0, null);
    
    const analyzed_content = claude_client.analyzeContent(processed_content) catch |err| {
        try stream.failOperation("claude_analyze", "Claude analysis failed");
        std.log.warn("⚠️ Claude analysis failed: {}", .{err});
        std.log.err("❌ Cannot continue without analysis results", .{});
        return;
    };
    defer analyzed_content.deinit(allocator);
    const ai_end = std.time.milliTimestamp();
    std.log.info("⏱️ Claude AI analysis took: {d}ms", .{ai_end - ai_start});
    
    try stream.updateOperation("claude_analyze", 1.0, "Claude AI analysis complete", 1, 1);
    std.log.info("✅ Claude AI analysis complete", .{});
    
    // === PHASE 4: BLOG GENERATION ===
    tracker.updatePhase("📝 Generating markdown blog post", progress.ProgressPhases.BLOG_GENERATION);
    std.log.info("", .{});
    std.log.info("📝 ==========================================", .{});
    std.log.info("📝          PHASE 4: BLOG GENERATION", .{});
    std.log.info("📝 ==========================================", .{});
    std.log.info("", .{});
    const blog_start = std.time.milliTimestamp();
    try stream.updateOperation("blog_generate", 0.1, "Starting blog generation", 0, 1);
    
    const generated_blog = blog_generator.generateBlogPost(analyzed_content) catch |err| {
        try stream.failOperation("blog_generate", "Blog generation failed");
        std.log.err("❌ Blog generation failed: {}", .{err});
        return;
    };
    defer generated_blog.deinit(allocator);
    const blog_end = std.time.milliTimestamp();
    std.log.info("⏱️ Blog generation took: {d}ms", .{blog_end - blog_start});
    
    try stream.updateOperation("blog_generate", 1.0, "Blog generation complete", 1, 1);
    
    // === COMPLETION ===
    tracker.complete();
    try stream.complete();
    const total_time = blog_end - extraction_start;
    std.log.info("⏱️ Total execution time: {d}ms ({d}s)", .{ total_time, @divTrunc(total_time, 1000) });
    std.log.info("\n🎉 AI News Generation Complete!", .{});
    std.log.info("📄 Generated: {s}", .{generated_blog.metadata.filename});
    std.log.info("📊 Word count: {d}", .{generated_blog.metadata.word_count});
    std.log.info("🔢 Sections: {d}", .{generated_blog.metadata.section_count});
    std.log.info("📈 Items included: {d}", .{generated_blog.metadata.total_items_included});
    std.log.info("💾 Saved to: {s}", .{generated_blog.metadata.full_path});
    
    std.log.info("\n✨ Phase 3: Content Processing Pipeline - COMPLETE! ✅", .{});
}

// Parallel extraction functions
fn extractRedditParallel(context: *const ExtractionContext) void {
    const start_time = std.time.milliTimestamp();
    
    var all_reddit_items = std.ArrayList(types.NewsItem).init(context.allocator);
    defer {
        for (all_reddit_items.items) |item| {
            item.deinit(context.allocator);
        }
        all_reddit_items.deinit();
    }
    
    // Initialize cache-aware extractor for speed (removed anonymous struct approach)
    _ = cache.CachedExtractor.init(context.content_cache);
    
    // Create enhanced Reddit client with API support
    var reddit_client = reddit.RedditClient.initWithApi(context.allocator, context.firecrawl_client, context.api_keys) catch |err| {
        std.log.warn("Failed to initialize Reddit API client: {}, falling back to scraping", .{err});
        // Fallback to basic client
        var basic_client = reddit.RedditClient.init(context.allocator, context.firecrawl_client);
        defer basic_client.deinit();
        
        // Use basic extraction for each source with caching
        for (config.Config.reddit_sources) |source| {
            // Create source URL for caching
            const source_url = reddit.createRedditUrl(context.allocator, source.subreddit) catch |url_err| {
                std.log.err("❌ Failed to create URL for r/{s}: {}", .{ source.subreddit, url_err });
                continue;
            };
            defer context.allocator.free(source_url);
            
            // Check cache first
            if (context.content_cache.getCached(source_url, .reddit) catch null) |cached_items| {
                std.log.info("🎯 Cache hit for r/{s} - found {d} cached items", .{ source.subreddit, cached_items.len });
                for (cached_items, 0..) |item, i| {
                    std.log.info("  📋 [{d}] {s} (cached)", .{ i + 1, item.title[0..@min(item.title.len, 60)] });
                    all_reddit_items.append(item) catch {
                        item.deinit(context.allocator);
                        continue;
                    };
                }
                context.allocator.free(cached_items);
                continue;
            }
            
            // Cache miss - extract fresh content  
            std.log.info("💥 Cache miss for r/{s} - extracting fresh content (fallback mode)...", .{source.subreddit});
            const source_items = basic_client.extractSubredditPosts(source) catch |extract_err| {
                std.log.err("❌ Failed to extract from r/{s}: {}", .{ source.subreddit, extract_err });
                continue;
            };
            
            // Log extracted content details
            std.log.info("📊 Extracted {d} fresh items from r/{s} (fallback):", .{ source_items.len, source.subreddit });
            for (source_items, 0..) |item, i| {
                const preview = item.title[0..@min(item.title.len, 60)];
                const summary_preview = item.summary[0..@min(item.summary.len, 100)];
                std.log.info("  📝 [{d}] {s}", .{ i + 1, preview });
                std.log.info("      💬 {s}...", .{summary_preview});
                std.log.info("      🔗 {s}", .{item.url});
                std.log.info("      ⭐ Score: {d:.2}", .{item.relevance_score});
            }
            
            // Cache the results
            context.content_cache.cache(source_url, .reddit, source_items) catch |cache_err| {
                std.log.warn("⚠️ Failed to cache results for r/{s}: {}", .{ source.subreddit, cache_err });
            };
            
            // Add to combined results
            for (source_items) |item| {
                all_reddit_items.append(item) catch {
                    item.deinit(context.allocator);
                    continue;
                };
            }
            context.allocator.free(source_items);
        }
        
        const end_time = std.time.milliTimestamp();
        std.log.info("⏱️ Reddit extraction took: {d}ms", .{end_time - start_time});
        
        const result_items = all_reddit_items.toOwnedSlice() catch &[_]types.NewsItem{};
        
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = @constCast(result_items),
            .source_type = "Reddit",
            .error_occurred = false,
        };
        return;
    };
    defer reddit_client.deinit();
    
    std.log.info("📱 Using Reddit API for comprehensive extraction...", .{});
    
    // Extract from each Reddit source using enhanced API with caching
    for (config.Config.reddit_sources) |source| {
        // Create source URL for caching
        const source_url = reddit.createRedditUrl(context.allocator, source.subreddit) catch |url_err| {
            std.log.err("❌ Failed to create URL for r/{s}: {}", .{ source.subreddit, url_err });
            continue;
        };
        defer context.allocator.free(source_url);
        
        // Check cache first
        if (context.content_cache.getCached(source_url, .reddit) catch null) |cached_items| {
            std.log.info("", .{});
            std.log.info("🎯 ======================================", .{});
            std.log.info("🎯 Cache HIT for r/{s} - {d} cached items", .{ source.subreddit, cached_items.len });
            std.log.info("🎯 ======================================", .{});
            
            for (cached_items, 0..) |item, i| {
                const preview = item.title[0..@min(item.title.len, 60)];
                std.log.info("", .{});
                std.log.info("  📋 [{d}] {s} (cached)", .{ i + 1, preview });
                std.log.info("       ⚡ Using cached data for faster performance", .{});
                all_reddit_items.append(item) catch {
                    item.deinit(context.allocator);
                    continue;
                };
            }
            std.log.info("", .{});
            context.allocator.free(cached_items);
            continue;
        }
        
        // Cache miss - extract fresh content
        std.log.info("", .{});
        std.log.info("💥 ======================================", .{});
        std.log.info("💥 Cache MISS for r/{s} - extracting fresh content...", .{source.subreddit});
        std.log.info("💥 ======================================", .{});
        const source_items = reddit_client.extractSubredditPosts(source) catch |err| {
            std.log.err("❌ Failed to extract from r/{s}: {}", .{ source.subreddit, err });
            continue;
        };
        
        // Log extracted content details with beautiful formatting
        std.log.info("", .{});
        std.log.info("📊 ========================================", .{});
        std.log.info("📊 Extracted {d} fresh items from r/{s}", .{ source_items.len, source.subreddit });
        std.log.info("📊 ========================================", .{});
        
        for (source_items, 0..) |item, i| {
            const preview = item.title[0..@min(item.title.len, 60)];
            
            // Enhanced metadata display for Reddit posts
            if (item.reddit_metadata) |reddit_meta| {
                const upvote_percentage = reddit_meta.upvote_ratio * 100;
                const flair_display = if (reddit_meta.flair) |flair| flair else "No flair";
            
                std.log.info("", .{});
                std.log.info("  📝 [{d}] {s}", .{ i + 1, preview });
                std.log.info("       💬 **Author:** u/{s}", .{reddit_meta.author});
                std.log.info("       🔥 **Score:** {d} upvotes ({d:.0}% upvoted)", .{ reddit_meta.upvotes, upvote_percentage });
                std.log.info("       💬 **Comments:** {d}", .{reddit_meta.comment_count});
                std.log.info("       🏷️ **Flair:** {s}", .{flair_display});
                std.log.info("       🔗 {s}", .{item.url});
                std.log.info("       ⭐ Score: {d:.2}", .{item.relevance_score});
            } else {
                std.log.info("", .{});
                std.log.info("  📝 [{d}] {s}", .{ i + 1, preview });
                std.log.info("       🔗 {s}", .{item.url});
                std.log.info("       ⭐ Score: {d:.2}", .{item.relevance_score});
            }
        }
        
        std.log.info("", .{});
        
        // Cache the results
        context.content_cache.cache(source_url, .reddit, source_items) catch |cache_err| {
            std.log.warn("⚠️ Failed to cache results for r/{s}: {}", .{ source.subreddit, cache_err });
        };
        
        // Add to combined results
        for (source_items) |item| {
            all_reddit_items.append(item) catch {
                item.deinit(context.allocator);
                continue;
            };
        }
        context.allocator.free(source_items);
    }
    
    const end_time = std.time.milliTimestamp();
    std.log.info("⏱️ Reddit extraction took: {d}ms", .{end_time - start_time});
    
    const result_items = all_reddit_items.toOwnedSlice() catch &[_]types.NewsItem{};
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = @constCast(result_items),
        .source_type = "Reddit",
        .error_occurred = false,
    };
}

// Helper function for single Reddit source extraction using comprehensive API
fn extractSingleRedditSource(allocator: std.mem.Allocator, url: []const u8) ![]types.NewsItem {
    std.log.debug("Extracting from Reddit URL: {s}", .{url});
    
    // Validate URL format
    if (!std.mem.startsWith(u8, url, "https://")) {
        std.log.err("Invalid Reddit URL format: {s}", .{url});
        return error.InvalidInput;
    }
    
    // Extract subreddit name from URL
    const subreddit = extractSubredditFromUrl(url) catch {
        std.log.err("Failed to extract subreddit from URL: {s}", .{url});
        return &[_]types.NewsItem{};
    };
    defer allocator.free(subreddit);
    
    // Find the matching Reddit source configuration
    _ = blk: {
        for (config.Config.reddit_sources) |src| {
            if (std.mem.eql(u8, src.subreddit, subreddit)) {
                break :blk src;
            }
        }
        // Default source if not found
        break :blk config.RedditSource{
            .subreddit = subreddit,
            .max_posts = 20,
            .min_upvotes = 10,
        };
    };
    
    // Create enhanced Reddit client with API support
    var temp_http_client = try http.HttpClient.init(allocator);
    defer temp_http_client.deinit();
    
    // We need access to API keys, but this function doesn't have them
    // For now, fallback to basic extraction - we'll need to restructure this
    std.log.debug("Reddit API extraction not yet integrated in this context");
    const result = try allocator.alloc(types.NewsItem, 0);
    
    std.log.debug("Reddit extraction returned {d} items", .{result.len});
    return result;
}

fn extractSubredditFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Extract subreddit name from URLs like "https://old.reddit.com/r/LocalLLaMA/"
    if (std.mem.indexOf(u8, url, "/r/")) |r_pos| {
        const start = r_pos + 3; // Skip "/r/"
        if (start < url.len) {
            const end = std.mem.indexOf(u8, url[start..], "/") orelse (url.len - start);
            return allocator.dupe(u8, url[start..start + end]);
        }
    }
    return error.InvalidUrl;
}

fn extractYouTubeParallel(context: *const ExtractionContext) void {
    const start_time = std.time.milliTimestamp();
    const items = youtube.extractAllYouTubeVideos(context.allocator, null) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "YouTube",
            .error_occurred = true,
        };
        return;
    };
    
    const end_time = std.time.milliTimestamp();
    std.log.info("⏱️ YouTube extraction took: {d}ms", .{end_time - start_time});
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "YouTube",
        .error_occurred = false,
    };
}

fn extractResearchParallel(context: *const ExtractionContext) void {
    const items = huggingface.extractAllResearchPapers(context.allocator, context.firecrawl_client) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "Research",
            .error_occurred = true,
        };
        return;
    };
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "Research",
        .error_occurred = false,
    };
}

fn extractBlogParallel(context: *const ExtractionContext) void {
    const items = blog.extractAllBlogArticles(context.allocator, context.firecrawl_client) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "Blogs",
            .error_occurred = true,
        };
        return;
    };
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "Blogs",
        .error_occurred = false,
    };
}

fn extractNewsParallel(context: *const ExtractionContext) void {
    const items = hackernews.extractAllNewsItems(context.allocator, context.firecrawl_client) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "News",
            .error_occurred = true,
        };
        return;
    };
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "News",
        .error_occurred = false,
    };
}

fn extractTikTokParallel(context: *const ExtractionContext) void {
    const items = tiktok.extractAllTikTokVideos(context.allocator, null) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "TikTok",
            .error_occurred = true,
        };
        return;
    };
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "TikTok",
        .error_occurred = false,
    };
}

fn extractRSSParallel(context: *const ExtractionContext) void {
    const items = rss.extractRssContent(context.allocator, &config.Config.rss_sources) catch {
        // Safe array access with bounds checking
        if (context.result_index >= context.results.len) {
            std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
            return;
        }
        context.results[context.result_index] = ExtractionResult{
            .items = &[_]types.NewsItem{},
            .source_type = "RSS",
            .error_occurred = true,
        };
        return;
    };
    
    // Safe array access with bounds checking
    if (context.result_index >= context.results.len) {
        std.log.err("❌ CRITICAL: Invalid result_index {d} >= array length {d}", .{context.result_index, context.results.len});
        return;
    }
    context.results[context.result_index] = ExtractionResult{
        .items = items,
        .source_type = "RSS",
        .error_occurred = false,
    };
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

/// Create fallback analyzed content when AI analysis fails
fn createFallbackAnalyzedContent(allocator: std.mem.Allocator, processed_content: processor.ProcessedContent) claude.AnalyzedContent {
    return claude.AnalyzedContent{
        .research_papers = &[_]claude.AnalyzedItem{},
        .video_highlights = &[_]claude.AnalyzedItem{},
        .community_highlights = &[_]claude.AnalyzedItem{},
        .model_releases = &[_]claude.AnalyzedItem{},
        .industry_news = &[_]claude.AnalyzedItem{},
        .tutorials_demos = &[_]claude.AnalyzedItem{},
        .executive_summary = allocator.dupe(u8, "Executive summary unavailable due to AI analysis failure.") catch "Analysis failed",
        .analysis_timestamp = types.getCurrentTimestamp(),
        .original_stats = processed_content.stats,
    };
}

test "config validation" {
    // Test comptime configuration validation
    try std.testing.expect(config.Config.reddit_sources.len > 0);
    try std.testing.expect(config.Config.youtube_sources.len > 0);
    try std.testing.expect(config.Config.processing.relevance_threshold >= 0.0);
    try std.testing.expect(config.Config.processing.relevance_threshold <= 1.0);
}

test "types functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const mock_item = try types.createMockNewsItem(allocator);
    defer mock_item.deinit(allocator);
    
    try std.testing.expect(std.mem.eql(u8, mock_item.title, "Test News Item"));
    try std.testing.expect(mock_item.source_type == .blog);
}