const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const gitingest = @import("external_gitingest.zig");
const http = @import("common_http.zig");
const utils = @import("core_utils.zig");
const memory_pools = @import("cache_memory_pools.zig");
const hot_cold_storage = @import("cache_hot_cold.zig");
const skytable_adapter = @import("cache_skytable_adapter.zig");
const cache = @import("cache_main.zig");

// Comptime constant arrays for performance
const TUTORIAL_KEYWORDS = [_][]const u8{
    "tutorial", "how to", "guide", "walkthrough", "step by step",
    "learn", "teaching", "explanation", "demo", "example"
};

pub const ContentProcessor = struct {
    allocator: std.mem.Allocator,
    gitingest_client: ?*gitingest.GitIngestClient,
    
    // Data-oriented processing buffers for better performance
    working_storage: ?*types.NewsItemStorage,
    
    // Memory pools for optimized allocation
    pools: ?*memory_pools.NewsAggregatorPools,
    
    // Hot/cold storage adapter for Skytable integration
    cache_adapter: ?*skytable_adapter.SkytableHotColdAdapter,
    
    pub fn init(allocator: std.mem.Allocator) ContentProcessor {
        return ContentProcessor{
            .allocator = allocator,
            .gitingest_client = null,
            .working_storage = null,
            .pools = null,
            .cache_adapter = null,
        };
    }
    
    pub fn initWithGitIngest(allocator: std.mem.Allocator, http_client: *http.HttpClient) !ContentProcessor {
        const gitingest_client = try allocator.create(gitingest.GitIngestClient);
        gitingest_client.* = gitingest.GitIngestClient.init(allocator, http_client);
        
        return ContentProcessor{
            .allocator = allocator,
            .gitingest_client = gitingest_client,
            .working_storage = null,
            .pools = null,
            .cache_adapter = null,
        };
    }
    
    pub fn deinit(self: *ContentProcessor) void {
        if (self.gitingest_client) |client| {
            self.allocator.destroy(client);
        }
        if (self.working_storage) |storage| {
            storage.deinit();
            self.allocator.destroy(storage);
        }
        if (self.pools) |pools| {
            pools.deinit();
            self.allocator.destroy(pools);
        }
    }
    
    /// Data-oriented content processing using NewsItemStorage (new optimized path)
    pub fn processContentDataOriented(self: *ContentProcessor, all_items: []types.NewsItem) !ProcessedContent {
        const start_time = std.time.milliTimestamp();
        std.log.info("🚀 Processing {d} items using data-oriented approach...", .{all_items.len});
        
        // Initialize memory pools if not already created
        if (self.pools == null) {
            const pools = try self.allocator.create(memory_pools.NewsAggregatorPools);
            pools.* = try memory_pools.NewsAggregatorPools.init(self.allocator);
            self.pools = pools;
        }
        
        // Initialize working storage with capacity for all items
        const capacity = @max(@as(u32, @intCast(all_items.len)), 1000);
        const storage = try self.allocator.create(types.NewsItemStorage);
        storage.* = try types.NewsItemStorage.init(self.allocator, self.pools.?, capacity);
        self.working_storage = storage;
        
        // Convert items to data-oriented storage
        const convert_start = std.time.milliTimestamp();
        for (all_items) |item| {
            try storage.addItem(item);
        }
        const convert_time = std.time.milliTimestamp() - convert_start;
        std.log.debug("⏱️ Conversion to SoA took {d}ms", .{convert_time});
        
        // Sort by timestamp using data-oriented approach (operates on arrays directly)
        const sort_start = std.time.milliTimestamp();
        try self.sortByTimestampDataOriented(storage);
        const sort_time = std.time.milliTimestamp() - sort_start;
        std.log.debug("⏱️ Data-oriented sorting took {d}ms", .{sort_time});
        
        // Deduplicate using hash-based approach (O(n) instead of O(n²))
        const dedup_start = std.time.milliTimestamp();
        const unique_count = try self.deduplicateDataOriented(storage);
        const dedup_time = std.time.milliTimestamp() - dedup_start;
        std.log.info("After data-oriented deduplication: {d} unique items ({d}ms)", .{ unique_count, dedup_time });
        
        // Filter by relevance using SIMD-friendly operations
        const filter_start = std.time.milliTimestamp();
        const filtered_count = try self.filterByRelevanceDataOriented(storage);
        const filter_time = std.time.milliTimestamp() - filter_start;
        std.log.info("After relevance filtering: {d} relevant items ({d}ms)", .{ filtered_count, filter_time });
        
        // Categorize content using data-oriented approach
        const categorize_start = std.time.milliTimestamp();
        const categorized = try self.categorizeContentDataOriented(storage, filtered_count);
        const categorize_time = std.time.milliTimestamp() - categorize_start;
        std.log.debug("⏱️ Data-oriented categorization took {d}ms", .{categorize_time});
        
        const end_time = std.time.milliTimestamp();
        const total_processing_time = @as(u64, @intCast(end_time - start_time));
        
        // Get memory pool statistics
        const pool_stats = self.pools.?.getStats();
        const storage_stats = storage.getPerformanceStats();
        
        // Calculate processing statistics
        const stats = ProcessingStats{
            .total_items_processed = @intCast(all_items.len),
            .items_after_deduplication = unique_count,
            .items_after_filtering = filtered_count,
            .final_item_count = categorized.getTotalItemCount(),
            .processing_time_ms = total_processing_time,
            .sources_processed = self.countSourcesDataOriented(storage),
        };
        
        std.log.info("✅ Data-oriented processing completed in {d}ms (convert: {d}ms, sort: {d}ms, dedup: {d}ms, filter: {d}ms, categorize: {d}ms)", .{
            total_processing_time, convert_time, sort_time, dedup_time, filter_time, categorize_time
        });
        
        // Log memory pool performance
        std.log.info("📊 Memory Pool Stats:", .{});
        std.log.info("   String pool: {d}/{d} bytes ({d:.1}% full)", .{
            pool_stats.string_pool.used,
            pool_stats.string_pool.capacity,
            pool_stats.string_pool.utilization * 100
        });
        std.log.info("   Total pool allocations: {d}", .{pool_stats.total_pool_allocations});
        std.log.info("   Storage utilization: {d:.1}%", .{storage_stats.capacity_utilization * 100});
        
        return ProcessedContent{
            .categorized_items = categorized,
            .stats = stats,
            .timestamp = types.getCurrentTimestamp(),
        };
    }
    
    /// Legacy content processing (maintained for compatibility)
    pub fn processContent(self: *ContentProcessor, all_items: []types.NewsItem) !ProcessedContent {
        const start_time = std.time.milliTimestamp();
        std.log.info("Processing {d} total items from all sources...", .{all_items.len});
        
        // Create processing arena for temporary allocations
        var processing_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer processing_arena.deinit();
        const temp_allocator = processing_arena.allocator();
        
        // Enhance content with GitHub repository analysis if GitIngest client is available
        const enhanced_items = if (self.gitingest_client != null) 
            try self.enhanceWithGitHubAnalysis(all_items, temp_allocator)
        else 
            all_items;
        
        // Sort by timestamp (newest first) - in-place operation
        const sort_start = std.time.milliTimestamp();
        std.sort.insertion(types.NewsItem, @constCast(enhanced_items), {}, compareByTimestamp);
        const sort_time = std.time.milliTimestamp() - sort_start;
        std.log.debug("⏱️ Sorting took {d}ms", .{sort_time});
        
        // Deduplicate content using temporary allocator
        const dedup_start = std.time.milliTimestamp();
        const deduplicated = try self.deduplicateContentOptimized(enhanced_items, temp_allocator);
        defer {
            for (deduplicated) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(deduplicated);
        }
        const dedup_time = std.time.milliTimestamp() - dedup_start;
        std.log.info("After deduplication: {d} unique items ({d}ms)", .{ deduplicated.len, dedup_time });
        
        // Filter by relevance threshold using temporary allocator
        const filter_start = std.time.milliTimestamp();
        const filtered = try self.filterByRelevanceOptimized(deduplicated, temp_allocator);
        defer {
            for (filtered) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(filtered);
        }
        const filter_time = std.time.milliTimestamp() - filter_start;
        std.log.info("After relevance filtering: {d} relevant items ({d}ms)", .{ filtered.len, filter_time });
        
        // Categorize content (final allocation uses main allocator)
        const categorize_start = std.time.milliTimestamp();
        const categorized = try self.categorizeContent(filtered);
        const categorize_time = std.time.milliTimestamp() - categorize_start;
        std.log.debug("⏱️ Categorization took {d}ms", .{categorize_time});
        
        const end_time = std.time.milliTimestamp();
        const total_processing_time = @as(u64, @intCast(end_time - start_time));
        
        // Calculate processing statistics with timing data
        const stats = ProcessingStats{
            .total_items_processed = @intCast(enhanced_items.len),
            .items_after_deduplication = @intCast(deduplicated.len),
            .items_after_filtering = @intCast(filtered.len),
            .final_item_count = categorized.getTotalItemCount(),
            .processing_time_ms = total_processing_time,
            .sources_processed = self.countSources(enhanced_items),
        };
        
        std.log.info("✅ Content processing completed in {d}ms (sort: {d}ms, dedup: {d}ms, filter: {d}ms, categorize: {d}ms)", .{
            total_processing_time, sort_time, dedup_time, filter_time, categorize_time
        });
        
        return ProcessedContent{
            .categorized_items = categorized,
            .stats = stats,
            .timestamp = types.getCurrentTimestamp(),
        };
    }
    
    /// Remove duplicate content using efficient HashMap-based approach - O(n) instead of O(n²)
    fn deduplicateContent(self: *ContentProcessor, items: []types.NewsItem) ![]types.NewsItem {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        return self.deduplicateContentHashMap(items, temp_allocator);
    }
    
    /// Efficient O(n) HashMap-based deduplication
    fn deduplicateContentHashMap(self: *ContentProcessor, items: []types.NewsItem, temp_allocator: std.mem.Allocator) ![]types.NewsItem {
        var unique_items = std.ArrayList(types.NewsItem).init(self.allocator);
        try unique_items.ensureTotalCapacity(items.len);
        
        // HashMap for exact URL matches - O(1) lookup
        var seen_urls = std.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(temp_allocator);
        try seen_urls.ensureTotalCapacity(@intCast(items.len));
        
        // HashMap for normalized titles - O(1) lookup for similar titles  
        var seen_titles = std.HashMap([]const u8, usize, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(temp_allocator);
        try seen_titles.ensureTotalCapacity(@intCast(items.len));
        
        for (items) |item| {
            var is_duplicate = false;
            
            // Step 1: Fast exact URL deduplication - O(1)
            if (seen_urls.contains(item.url)) {
                is_duplicate = true;
            } else {
                // Step 2: Normalized title deduplication - O(1) instead of O(n)
                const normalized_title = try self.normalizeTitle(item.title, temp_allocator);
                
                if (seen_titles.get(normalized_title)) |existing_index| {
                    // Found potential duplicate by title, do final similarity check
                    const existing_item = unique_items.items[existing_index];
                    if (self.areItemsDuplicate(item, existing_item)) {
                        is_duplicate = true;
                    }
                }
                
                if (!is_duplicate) {
                    // Add to unique items
                    const copied_item = try self.copyNewsItem(item);
                    const item_index = unique_items.items.len;
                    try unique_items.append(copied_item);
                    
                    // Register in HashMaps for future O(1) lookups
                    try seen_urls.put(try temp_allocator.dupe(u8, item.url), {});
                    try seen_titles.put(try temp_allocator.dupe(u8, normalized_title), item_index);
                }
            }
        }
        
        return try unique_items.toOwnedSlice();
    }
    
    /// Normalize title for efficient similarity comparison
    fn normalizeTitle(self: *ContentProcessor, title: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        
        // Convert to lowercase and remove common words/punctuation for better matching
        var normalized = std.ArrayList(u8).init(allocator);
        
        // Simple normalization: lowercase, remove punctuation, compress whitespace
        var prev_was_space = true; // Start true to avoid leading space
        
        for (title) |char| {
            if (std.ascii.isAlphanumeric(char)) {
                try normalized.append(std.ascii.toLower(char));
                prev_was_space = false;
            } else if (!prev_was_space and char == ' ') {
                try normalized.append(' ');
                prev_was_space = true;
            }
        }
        
        // Remove trailing space if any
        if (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
            _ = normalized.pop();
        }
        
        return try normalized.toOwnedSlice();
    }
    
    /// Optimized deduplication using temporary allocator for intermediate operations
    fn deduplicateContentOptimized(self: *ContentProcessor, items: []types.NewsItem, temp_allocator: std.mem.Allocator) ![]types.NewsItem {
        var unique_items = std.ArrayList(types.NewsItem).init(self.allocator);
        // Only pre-allocate for reasonable sizes to avoid OOM
        if (items.len < 1000) {
            try unique_items.ensureTotalCapacity(items.len);
        }
        
        // Use temporary allocator for URL and title comparison sets
        var seen_urls = std.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(temp_allocator);
        try seen_urls.ensureTotalCapacity(@intCast(items.len));
        
        for (items) |item| {
            var is_duplicate = false;
            
            // Fast URL-based deduplication first
            if (seen_urls.contains(item.url)) {
                is_duplicate = true;
            } else {
                // Only do expensive similarity check if URL is unique
                for (unique_items.items) |existing| {
                    if (self.areItemsDuplicate(item, existing)) {
                        is_duplicate = true;
                        break;
                    }
                }
                
                if (!is_duplicate) {
                    try seen_urls.put(item.url, {});
                }
            }
            
            if (!is_duplicate) {
                // Use generic cloning utility
                const copied_item = try utils.CloneUtils.cloneNewsItem(self.allocator, item);
                try unique_items.append(copied_item);
            }
        }
        
        return try unique_items.toOwnedSlice();
    }
    
    /// Data-oriented deduplication using hash-based approach - O(n) performance
    fn deduplicateDataOriented(self: *ContentProcessor, storage: *types.NewsItemStorage) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        // Hash table for O(1) duplicate detection
        var seen_hashes = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(temp_allocator);
        try seen_hashes.ensureTotalCapacity(storage.count);
        
        var write_index: u32 = 0;
        
        // Process each item
        for (0..storage.count) |read_index| {
            // Calculate hash for title + URL for duplicate detection
            const title = storage.getTitle(@intCast(read_index));
            const url = storage.getUrl(@intCast(read_index));
            
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(title);
            hasher.update(url);
            const content_hash = hasher.final();
            
            // Check if we've seen this hash before
            if (seen_hashes.get(content_hash)) |_| {
                // Duplicate found, skip this item
                continue;
            }
            
            // New unique item - add to seen set and move to write position
            try seen_hashes.put(content_hash, write_index);
            
            if (write_index != read_index) {
                // Move item from read_index to write_index (compacting the arrays)
                storage.relevance_scores[write_index] = storage.relevance_scores[read_index];
                storage.timestamps[write_index] = storage.timestamps[read_index];
                storage.source_types[write_index] = storage.source_types[read_index];
                storage.title_refs[write_index] = storage.title_refs[read_index];
                storage.summary_refs[write_index] = storage.summary_refs[read_index];
                storage.url_refs[write_index] = storage.url_refs[read_index];
                storage.source_refs[write_index] = storage.source_refs[read_index];
                storage.reddit_indices[write_index] = storage.reddit_indices[read_index];
                storage.youtube_indices[write_index] = storage.youtube_indices[read_index];
                storage.huggingface_indices[write_index] = storage.huggingface_indices[read_index];
                storage.blog_indices[write_index] = storage.blog_indices[read_index];
                storage.github_indices[write_index] = storage.github_indices[read_index];
            }
            
            write_index += 1;
        }
        
        // Update count to reflect deduplicated items
        storage.count = write_index;
        return write_index;
    }
    
    /// Check if two items are duplicates based on multiple criteria
    fn areItemsDuplicate(self: *ContentProcessor, item1: types.NewsItem, item2: types.NewsItem) bool {
        _ = self;
        
        // Exact URL match
        if (std.mem.eql(u8, item1.url, item2.url)) {
            return true;
        }
        
        // Similar titles using utility function
        const similarity = utils.TextUtils.calculateSimilarity(item1.title, item2.title);
        if (similarity > 0.85) {
            return true;
        }
        
        // Same source and very similar titles
        if (std.mem.eql(u8, item1.source, item2.source) and similarity > 0.70) {
            return true;
        }
        
        return false;
    }
    
    /// Filter items by relevance score threshold
    fn filterByRelevance(self: *ContentProcessor, items: []types.NewsItem) ![]types.NewsItem {
        var filtered = std.ArrayList(types.NewsItem).init(self.allocator);
        
        for (items) |item| {
            if (item.relevance_score >= config.Config.processing.relevance_threshold) {
                const copied_item = try self.copyNewsItem(item);
                try filtered.append(copied_item);
            }
        }
        
        return try filtered.toOwnedSlice();
    }
    
    /// Optimized relevance filtering with batch processing and pre-allocation
    fn filterByRelevanceOptimized(self: *ContentProcessor, items: []types.NewsItem, temp_allocator: std.mem.Allocator) ![]types.NewsItem {
        _ = temp_allocator; // May use for future optimizations
        
        // Pre-calculate how many items likely pass the threshold
        var estimated_filtered: usize = 0;
        for (items) |item| {
            if (item.relevance_score >= config.Config.processing.relevance_threshold) {
                estimated_filtered += 1;
            }
        }
        
        var filtered = std.ArrayList(types.NewsItem).init(self.allocator);
        // Only pre-allocate for reasonable sizes to avoid OOM
        if (estimated_filtered < 1000) {
            try filtered.ensureTotalCapacity(estimated_filtered);
        }
        
        // Second pass: actually filter and copy
        for (items) |item| {
            if (item.relevance_score >= config.Config.processing.relevance_threshold) {
                const copied_item = try utils.CloneUtils.cloneNewsItem(self.allocator, item);
                try filtered.append(copied_item);
            }
        }
        
        return try filtered.toOwnedSlice();
    }
    
    /// Categorize content into different types
    fn categorizeContent(self: *ContentProcessor, items: []types.NewsItem) !CategorizedContent {
        var research_papers = std.ArrayList(types.NewsItem).init(self.allocator);
        var video_highlights = std.ArrayList(types.NewsItem).init(self.allocator);
        var community_highlights = std.ArrayList(types.NewsItem).init(self.allocator);
        var model_releases = std.ArrayList(types.NewsItem).init(self.allocator);
        var industry_news = std.ArrayList(types.NewsItem).init(self.allocator);
        var tutorials_demos = std.ArrayList(types.NewsItem).init(self.allocator);
        
        for (items) |item| {
            const copied_item = try utils.CloneUtils.cloneNewsItem(self.allocator, item);
            
            switch (item.source_type) {
                .research_hub => try research_papers.append(copied_item),
                .youtube => {
                    if (self.isTutorialContent(item)) {
                        try tutorials_demos.append(copied_item);
                    } else {
                        try video_highlights.append(copied_item);
                    }
                },
                .tiktok => {
                    // TikTok content treated similar to YouTube videos
                    if (self.isTutorialContent(item)) {
                        try tutorials_demos.append(copied_item);
                    } else {
                        try video_highlights.append(copied_item);
                    }
                },
                .reddit => try community_highlights.append(copied_item),
                .blog => {
                    if (self.isModelRelease(item)) {
                        try model_releases.append(copied_item);
                    } else {
                        try industry_news.append(copied_item);
                    }
                },
                .web_crawl => {
                    // Web crawl content categorized based on content type
                    if (self.isModelRelease(item)) {
                        try model_releases.append(copied_item);
                    } else {
                        try industry_news.append(copied_item);
                    }
                },
                .github_repo => {
                    // GitHub repositories categorized based on content analysis
                    if (self.isTutorialContent(item)) {
                        try tutorials_demos.append(copied_item);
                    } else if (self.isModelRelease(item)) {
                        try model_releases.append(copied_item);
                    } else {
                        try industry_news.append(copied_item);
                    }
                },
                .rss => {
                    // RSS news feeds categorized based on content type
                    if (self.isModelRelease(item)) {
                        try model_releases.append(copied_item);
                    } else {
                        try industry_news.append(copied_item);
                    }
                },
            }
        }
        
        // Sort each category by relevance score (highest first)
        self.sortByRelevance(research_papers.items);
        self.sortByRelevance(video_highlights.items);
        self.sortByRelevance(community_highlights.items);
        self.sortByRelevance(model_releases.items);
        self.sortByRelevance(industry_news.items);
        self.sortByRelevance(tutorials_demos.items);
        
        return CategorizedContent{
            .research_papers = try research_papers.toOwnedSlice(),
            .video_highlights = try video_highlights.toOwnedSlice(),
            .community_highlights = try community_highlights.toOwnedSlice(),
            .model_releases = try model_releases.toOwnedSlice(),
            .industry_news = try industry_news.toOwnedSlice(),
            .tutorials_demos = try tutorials_demos.toOwnedSlice(),
        };
    }
    
    /// Check if content is tutorial/educational material
    fn isTutorialContent(self: *ContentProcessor, item: types.NewsItem) bool {
        const combined_text = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ item.title, item.summary }) catch return false;
        defer self.allocator.free(combined_text);
        
        return utils.TextUtils.containsKeywords(self.allocator, combined_text, &TUTORIAL_KEYWORDS);
    }
    
    /// Check if content is about model releases
    fn isModelRelease(self: *ContentProcessor, item: types.NewsItem) bool {
        const model_keywords = [_][]const u8{
            "release", "announced", "introducing", "new model", "gpt", "claude",
            "llama", "gemini", "api", "model", "launch", "available"
        };
        
        const combined_text = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ item.title, item.summary }) catch return false;
        defer self.allocator.free(combined_text);
        
        return utils.TextUtils.containsKeywords(self.allocator, combined_text, &model_keywords);
    }
    
    /// Enhance content items with GitHub repository analysis
    fn enhanceWithGitHubAnalysis(self: *ContentProcessor, items: []types.NewsItem, temp_allocator: std.mem.Allocator) ![]types.NewsItem {
        if (self.gitingest_client == null) return items;
        
        const client = self.gitingest_client.?;
        var enhanced_items = std.ArrayList(types.NewsItem).init(self.allocator);
        try enhanced_items.ensureTotalCapacity(items.len);
        
        std.log.info("Analyzing content for GitHub repositories...", .{});
        var repo_analysis_count: u32 = 0;
        
        for (items) |item| {
            var enhanced_item = try utils.CloneUtils.cloneNewsItem(self.allocator, item);
            
            // Extract GitHub URLs from title and summary
            const combined_content = try std.fmt.allocPrint(temp_allocator, "{s} {s}", .{ item.title, item.summary });
            const github_urls = client.extractGitHubUrls(combined_content) catch |err| {
                std.log.warn("Failed to extract GitHub URLs from item '{s}': {}", .{ item.title, err });
                try enhanced_items.append(enhanced_item);
                continue;
            };
            defer {
                for (github_urls) |url| {
                    self.allocator.free(url);
                }
                self.allocator.free(github_urls);
            }
            
            if (github_urls.len > 0) {
                // Analyze the first GitHub repository found
                const first_repo_url = github_urls[0];
                std.log.debug("📂 Found GitHub repo in '{s}': {s}", .{ item.title, first_repo_url });
                
                if (client.analyzeRepository(first_repo_url)) |mut_repo_analysis| {
                    var repo_analysis = mut_repo_analysis;
                    defer repo_analysis.deinit(self.allocator);
                    
                    // Generate code insights
                    const code_insights = blk: {
                        break :blk repo_analysis.generateCodeInsights(self.allocator, "Focus on AI/ML relevance and technical innovation.") catch |err| {
                            std.log.warn("Failed to generate code insights: {}", .{err});
                            break :blk null;
                        };
                    };
                    defer if (code_insights) |insights| self.allocator.free(insights);
                    
                    // Store insights in the analysis
                    if (code_insights) |insights| {
                        repo_analysis.architecture_insights = try self.allocator.dupe(u8, insights);
                    }
                    
                    // Convert to GitHubRepoMetadata and attach to item
                    const github_metadata = repo_analysis.toGitHubMetadata(self.allocator) catch |err| {
                        std.log.warn("Failed to convert repository analysis to metadata: {}", .{err});
                        try enhanced_items.append(enhanced_item);
                        continue;
                    };
                    
                    // Create a new GitHub-focused news item or enhance existing item
                    if (enhanced_item.source_type == .github_repo) {
                        // Already a GitHub repo item, just update metadata
                        enhanced_item.github_metadata = github_metadata;
                    } else {
                        // Create additional GitHub repo item
                        const github_item = types.NewsItem{
                            .title = try std.fmt.allocPrint(self.allocator, "📦 Repository: {s}/{s}", .{ github_metadata.owner, github_metadata.repo_name }),
                            .summary = if (github_metadata.readme_summary) |summary| 
                                try self.allocator.dupe(u8, summary)
                            else if (github_metadata.description) |desc|
                                try self.allocator.dupe(u8, desc)
                            else
                                try std.fmt.allocPrint(self.allocator, "{s} repository with {d} files and {d} lines of code", .{ 
                                    github_metadata.primary_language orelse "Multi-language", 
                                    github_metadata.file_count, 
                                    github_metadata.total_lines 
                                }),
                            .url = try self.allocator.dupe(u8, first_repo_url),
                            .source = try std.fmt.allocPrint(self.allocator, "GitHub ({s})", .{github_metadata.owner}),
                            .source_type = .github_repo,
                            .timestamp = item.timestamp,
                            .relevance_score = item.relevance_score * 0.8, // Slightly lower relevance for derived content
                            .reddit_metadata = null,
                            .youtube_metadata = null,
                            .huggingface_metadata = null,
                            .blog_metadata = null,
                            .github_metadata = github_metadata,
                        };
                        
                        try enhanced_items.append(github_item);
                        repo_analysis_count += 1;
                    }
                    
                    // Update original item with repository reference in summary
                    const enhanced_summary = try std.fmt.allocPrint(self.allocator, "{s}\n\n🔗 Related repository: {s} ({s}, {d} files)", .{
                        enhanced_item.summary,
                        first_repo_url,
                        github_metadata.primary_language orelse "Multi-language",
                        github_metadata.file_count
                    });
                    self.allocator.free(enhanced_item.summary);
                    enhanced_item.summary = enhanced_summary;
                } else |err| {
                    std.log.debug("Failed to analyze repository {s}: {}", .{ first_repo_url, err });
                }
            }
            
            try enhanced_items.append(enhanced_item);
        }
        
        if (repo_analysis_count > 0) {
            std.log.info("📊 Enhanced content with {d} GitHub repository analyses", .{repo_analysis_count});
        }
        
        return try enhanced_items.toOwnedSlice();
    }
    
    /// Sort items by relevance score (highest first)
    fn sortByRelevance(self: *ContentProcessor, items: []types.NewsItem) void {
        _ = self;
        std.sort.insertion(types.NewsItem, items, {}, compareByRelevance);
    }
    
    
    /// Count unique sources in the item list
    fn countSources(self: *ContentProcessor, items: []types.NewsItem) u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var sources = std.StringHashMap(void).init(temp_allocator);
        
        for (items) |item| {
            sources.put(item.source, {}) catch continue;
        }
        
        return @intCast(sources.count());
    }
    
    /// Sort by timestamp using data-oriented approach (operates on arrays directly)
    fn sortByTimestampDataOriented(self: *ContentProcessor, storage: *types.NewsItemStorage) !void {
        // Create index array for indirect sorting (avoids moving large data)
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var indices = try temp_allocator.alloc(u32, storage.count);
        for (0..storage.count) |i| {
            indices[i] = @intCast(i);
        }
        
        // Sort indices based on timestamps (newest first)
        const Context = struct {
            timestamps: []i64,
            
            pub fn lessThan(ctx: @This(), a_index: u32, b_index: u32) bool {
                return ctx.timestamps[a_index] > ctx.timestamps[b_index]; // Newest first
            }
        };
        
        const context = Context{ .timestamps = storage.timestamps[0..storage.count] };
        std.sort.insertion(u32, indices, context, Context.lessThan);
        
        // Apply the sorted order to all arrays
        try self.applySortOrder(storage, indices);
    }
    
    /// Apply sorted index order to all arrays in storage
    fn applySortOrder(self: *ContentProcessor, storage: *types.NewsItemStorage, indices: []const u32) !void {
        // Create temporary arrays to hold sorted data
        const temp_relevance = try self.allocator.alloc(f32, storage.count);
        defer self.allocator.free(temp_relevance);
        
        const temp_timestamps = try self.allocator.alloc(i64, storage.count);
        defer self.allocator.free(temp_timestamps);
        
        const temp_source_types = try self.allocator.alloc(types.SourceType, storage.count);
        defer self.allocator.free(temp_source_types);
        
        const temp_title_refs = try self.allocator.alloc(types.StringRef, storage.count);
        defer self.allocator.free(temp_title_refs);
        
        const temp_summary_refs = try self.allocator.alloc(types.StringRef, storage.count);
        defer self.allocator.free(temp_summary_refs);
        
        const temp_url_refs = try self.allocator.alloc(types.StringRef, storage.count);
        defer self.allocator.free(temp_url_refs);
        
        const temp_source_refs = try self.allocator.alloc(types.StringRef, storage.count);
        defer self.allocator.free(temp_source_refs);
        
        // Copy data in sorted order
        for (indices, 0..) |old_index, new_index| {
            temp_relevance[new_index] = storage.relevance_scores[old_index];
            temp_timestamps[new_index] = storage.timestamps[old_index];
            temp_source_types[new_index] = storage.source_types[old_index];
            temp_title_refs[new_index] = storage.title_refs[old_index];
            temp_summary_refs[new_index] = storage.summary_refs[old_index];
            temp_url_refs[new_index] = storage.url_refs[old_index];
            temp_source_refs[new_index] = storage.source_refs[old_index];
        }
        
        // Copy back to original arrays
        @memcpy(storage.relevance_scores[0..storage.count], temp_relevance);
        @memcpy(storage.timestamps[0..storage.count], temp_timestamps);
        @memcpy(storage.source_types[0..storage.count], temp_source_types);
        @memcpy(storage.title_refs[0..storage.count], temp_title_refs);
        @memcpy(storage.summary_refs[0..storage.count], temp_summary_refs);
        @memcpy(storage.url_refs[0..storage.count], temp_url_refs);
        @memcpy(storage.source_refs[0..storage.count], temp_source_refs);
    }
    
    /// Filter by relevance using data-oriented approach
    fn filterByRelevanceDataOriented(self: *ContentProcessor, storage: *types.NewsItemStorage) !u32 {
        _ = self;
        
        const threshold = config.Config.processing.relevance_threshold;
        var write_index: u32 = 0;
        
        // Single pass through relevance scores
        for (0..storage.count) |read_index| {
            if (storage.relevance_scores[read_index] >= threshold) {
                if (write_index != read_index) {
                    // Move item to write position (compacting)
                    storage.relevance_scores[write_index] = storage.relevance_scores[read_index];
                    storage.timestamps[write_index] = storage.timestamps[read_index];
                    storage.source_types[write_index] = storage.source_types[read_index];
                    storage.title_refs[write_index] = storage.title_refs[read_index];
                    storage.summary_refs[write_index] = storage.summary_refs[read_index];
                    storage.url_refs[write_index] = storage.url_refs[read_index];
                    storage.source_refs[write_index] = storage.source_refs[read_index];
                    storage.reddit_indices[write_index] = storage.reddit_indices[read_index];
                    storage.youtube_indices[write_index] = storage.youtube_indices[read_index];
                    storage.huggingface_indices[write_index] = storage.huggingface_indices[read_index];
                    storage.blog_indices[write_index] = storage.blog_indices[read_index];
                    storage.github_indices[write_index] = storage.github_indices[read_index];
                }
                write_index += 1;
            }
        }
        
        storage.count = write_index;
        return write_index;
    }
    
    /// Categorize content using data-oriented approach
    fn categorizeContentDataOriented(self: *ContentProcessor, storage: *types.NewsItemStorage, item_count: u32) !CategorizedContent {
        // Convert back to NewsItems for categorization (temporary compatibility)
        var items = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            for (items.items) |item| {
                item.deinit(self.allocator);
            }
            items.deinit();
        }
        
        for (0..item_count) |i| {
            const item = try storage.getItem(@intCast(i));
            try items.append(item);
        }
        
        // Use existing categorization logic
        return try self.categorizeContent(items.items);
    }
    
    /// Get detailed memory pool statistics
    pub fn getPoolStats(self: *ContentProcessor) ?memory_pools.PoolStats {
        if (self.pools) |pools| {
            return pools.getStats();
        }
        return null;
    }
    
    /// Check pool health and log warnings if needed
    pub fn checkAndLogPoolHealth(self: *ContentProcessor) void {
        if (self.pools) |pools| {
            const health = pools.checkPoolHealth();
            defer health.deinit(self.allocator);
            
            switch (health.overall_status) {
                .healthy => {},
                .warning => {
                    std.log.warn("⚠️ Memory pool utilization high:", .{});
                    for (health.issues) |issue| {
                        std.log.warn("   {s} pool: {d:.1}% full", .{ issue.pool_name, issue.utilization * 100 });
                    }
                },
                .critical => {
                    std.log.err("🚨 CRITICAL: Memory pools near capacity!", .{});
                    for (health.issues) |issue| {
                        if (issue.severity == .critical) {
                            std.log.err("   {s} pool: {d:.1}% full (CRITICAL)", .{ issue.pool_name, issue.utilization * 100 });
                        }
                    }
                },
            }
        }
    }
    
    /// Count unique sources using data-oriented approach
    fn countSourcesDataOriented(self: *ContentProcessor, storage: *types.NewsItemStorage) u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var sources = std.StringHashMap(void).init(temp_allocator);
        
        for (0..storage.count) |i| {
            const source = storage.getSource(@intCast(i));
            sources.put(source, {}) catch continue;
        }
        
        return @intCast(sources.count());
    }
};

/// Compare function for sorting by timestamp (newest first)
fn compareByTimestamp(_: void, a: types.NewsItem, b: types.NewsItem) bool {
    return a.timestamp > b.timestamp;
}

/// Compare function for sorting by relevance (highest first)
fn compareByRelevance(_: void, a: types.NewsItem, b: types.NewsItem) bool {
    return a.relevance_score > b.relevance_score;
}


/// Processed content structure
pub const ProcessedContent = struct {
    categorized_items: CategorizedContent,
    stats: ProcessingStats,
    timestamp: i64,
    
    pub fn deinit(self: ProcessedContent, allocator: std.mem.Allocator) void {
        self.categorized_items.deinit(allocator);
    }
};

/// Content organized by categories
pub const CategorizedContent = struct {
    research_papers: []types.NewsItem,
    video_highlights: []types.NewsItem,
    community_highlights: []types.NewsItem,
    model_releases: []types.NewsItem,
    industry_news: []types.NewsItem,
    tutorials_demos: []types.NewsItem,
    
    pub fn getTotalItemCount(self: CategorizedContent) u32 {
        return @as(u32, @intCast(
            self.research_papers.len +
            self.video_highlights.len +
            self.community_highlights.len +
            self.model_releases.len +
            self.industry_news.len +
            self.tutorials_demos.len
        ));
    }
    
    pub fn deinit(self: CategorizedContent, allocator: std.mem.Allocator) void {
        for (self.research_papers) |item| item.deinit(allocator);
        allocator.free(self.research_papers);
        
        for (self.video_highlights) |item| item.deinit(allocator);
        allocator.free(self.video_highlights);
        
        for (self.community_highlights) |item| item.deinit(allocator);
        allocator.free(self.community_highlights);
        
        for (self.model_releases) |item| item.deinit(allocator);
        allocator.free(self.model_releases);
        
        for (self.industry_news) |item| item.deinit(allocator);
        allocator.free(self.industry_news);
        
        for (self.tutorials_demos) |item| item.deinit(allocator);
        allocator.free(self.tutorials_demos);
    }
};

/// Processing statistics
pub const ProcessingStats = struct {
    total_items_processed: u32,
    items_after_deduplication: u32,
    items_after_filtering: u32,
    final_item_count: u32,
    processing_time_ms: u64,
    sources_processed: u32,
};

// Test function
test "content processor deduplication" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    _ = ContentProcessor.init(allocator);
    
    // Test title similarity with case differences using utility functions
    const similarity1 = utils.TextUtils.calculateSimilarity("OpenAI Releases GPT-4", "OpenAI releases GPT-4");
    try std.testing.expect(similarity1 > 0.9);
    
    // Test similar titles with additional word
    const similarity2 = utils.TextUtils.calculateSimilarity("OpenAI Releases GPT-4", "OpenAI releases GPT-4 model");
    try std.testing.expect(similarity2 > 0.7);
    
    // Test exact match
    const exact_similarity = utils.TextUtils.calculateSimilarity("Same Title", "Same Title");
    try std.testing.expect(exact_similarity == 1.0);
    
    // Test completely different titles
    const diff_similarity = utils.TextUtils.calculateSimilarity("AI News Today", "Stock Market Update");
    try std.testing.expect(diff_similarity < 0.5);
}