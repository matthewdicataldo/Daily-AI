const std = @import("std");
const http = @import("common_http.zig");
const firecrawl = @import("external_firecrawl.zig");
const types = @import("core_types.zig");
const claude = @import("ai_claude.zig");

/// Web crawler configuration
pub const CrawlerConfig = struct {
    user_agent: []const u8 = "daily-ai-zig/1.0",
    max_concurrent_requests: u32 = 5,
    request_timeout_ms: u32 = 30000,
    max_page_size_mb: u32 = 10,
    enable_javascript: bool = true,
    enable_stealth_mode: bool = false,
    max_crawl_depth: u32 = 3,
    respect_robots_txt: bool = true,
    
    // Crawl4AI integration settings
    crawl4ai_endpoint: ?[]const u8 = null,
    crawl4ai_api_key: ?[]const u8 = null,
    
    // Content extraction settings
    extract_markdown: bool = true,
    extract_structured_data: bool = true,
    remove_noise: bool = true,
    
    // LLM-powered extraction
    enable_llm_extraction: bool = false,
    extraction_schema: ?[]const u8 = null,
};

/// Crawl result with multiple content formats
pub const CrawlResult = struct {
    url: []const u8,
    title: ?[]const u8,
    content: []const u8,
    markdown: ?[]const u8,
    structured_data: ?[]StructuredData,
    metadata: CrawlMetadata,
    
    pub fn deinit(self: CrawlResult, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.title) |title| allocator.free(title);
        allocator.free(self.content);
        if (self.markdown) |md| allocator.free(md);
        if (self.structured_data) |data| {
            for (data) |*item| item.deinit(allocator);
            allocator.free(data);
        }
        self.metadata.deinit(allocator);
    }
};

/// Structured data extracted from web pages
pub const StructuredData = struct {
    type: []const u8,  // e.g., "article", "product", "event"
    properties: std.StringHashMap([]const u8),
    
    pub fn deinit(self: *StructuredData, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        var iterator = self.properties.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();
    }
};

/// Metadata about the crawl operation
pub const CrawlMetadata = struct {
    status_code: u16,
    content_type: ?[]const u8,
    content_length: usize,
    crawl_time_ms: u64,
    extraction_method: []const u8,
    success: bool,
    error_message: ?[]const u8,
    
    pub fn deinit(self: CrawlMetadata, allocator: std.mem.Allocator) void {
        if (self.content_type) |ct| allocator.free(ct);
        allocator.free(self.extraction_method);
        if (self.error_message) |err| allocator.free(err);
    }
};

/// Thread-safe context for batch crawling
const BatchCrawlContext = struct {
    crawler: *WebCrawler,
    urls: [][]const u8,
    results: []?CrawlResult,
    mutex: std.Thread.Mutex,
    completed_count: usize,
};

/// Data passed to worker threads
const ThreadCrawlData = struct {
    context: *BatchCrawlContext,
    url_index: usize,
    url: []const u8,
};

/// Worker thread function for concurrent crawling
fn crawlWorkerThread(data: *ThreadCrawlData) void {
    defer data.context.crawler.allocator.destroy(data);
    
    const result = data.context.crawler.crawlURL(data.url) catch |err| {
        std.log.warn("Thread crawl failed for {s}: {}", .{ data.url, err });
        return; // Leave result as null to indicate failure
    };
    
    // Thread-safe result storage
    data.context.mutex.lock();
    defer data.context.mutex.unlock();
    
    data.context.results[data.url_index] = result;
    data.context.completed_count += 1;
    
    std.log.debug("🧵 Thread completed crawl {d}/{d}: {s}", .{ 
        data.context.completed_count, data.context.urls.len, data.url 
    });
}

/// Advanced web crawler with multiple backends
pub const WebCrawler = struct {
    allocator: std.mem.Allocator,
    config: CrawlerConfig,
    http_client: *http.HttpClient,
    firecrawl_client: ?*firecrawl.FirecrawlClient,
    claude_client: ?*claude.ClaudeClient,
    
    // Crawl statistics
    total_crawls: u32,
    successful_crawls: u32,
    failed_crawls: u32,
    total_bytes_crawled: u64,
    average_crawl_time_ms: f64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: CrawlerConfig, http_client: *http.HttpClient) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .http_client = http_client,
            .firecrawl_client = null,
            .claude_client = null,
            .total_crawls = 0,
            .successful_crawls = 0,
            .failed_crawls = 0,
            .total_bytes_crawled = 0,
            .average_crawl_time_ms = 0.0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        std.log.info("🕸️ Crawler Stats: {d} total crawls, {d} successful, {d:.1} MB crawled", .{
            self.total_crawls, self.successful_crawls, @as(f64, @floatFromInt(self.total_bytes_crawled)) / (1024.0 * 1024.0)
        });
    }
    
    /// Set Firecrawl client for enhanced crawling
    pub fn setFirecrawlClient(self: *Self, firecrawl_client: *firecrawl.FirecrawlClient) void {
        self.firecrawl_client = firecrawl_client;
    }
    
    /// Set Claude client for AI-powered extraction
    pub fn setClaudeClient(self: *Self, claude_client: *claude.ClaudeClient) void {
        self.claude_client = claude_client;
    }
    
    /// Crawl a single URL with full content extraction
    pub fn crawlURL(self: *Self, url: []const u8) !CrawlResult {
        const start_time = std.time.milliTimestamp();
        self.total_crawls += 1;
        
        std.log.info("🕷️ Crawling: {s}", .{url});
        
        // Try Firecrawl first if available
        if (self.firecrawl_client) |firecrawl_client| {
            const result = self.crawlWithFirecrawl(firecrawl_client, url) catch |err| {
                std.log.warn("Firecrawl failed for {s}: {}, falling back to direct crawl", .{ url, err });
                return try self.crawlWithDirect(url, start_time);
            };
            
            self.successful_crawls += 1;
            return result;
        }
        
        // Try Crawl4AI if configured
        if (self.config.crawl4ai_endpoint) |_| {
            const result = self.crawlWithCrawl4AI(url) catch |err| {
                std.log.warn("Crawl4AI failed for {s}: {}, falling back to direct crawl", .{ url, err });
                return try self.crawlWithDirect(url, start_time);
            };
            
            self.successful_crawls += 1;
            return result;
        }
        
        // Fall back to direct HTTP crawling
        return try self.crawlWithDirect(url, start_time);
    }
    
    /// Search the web using multiple strategies
    pub fn search(self: *Self, query: []const u8) ![]types.NewsItem {
        std.log.info("🌐 Web search: {s}", .{query});
        
        var search_results = std.ArrayList(types.NewsItem).init(self.allocator);
        defer search_results.deinit();
        
        // Generate search URLs for different engines
        const search_urls = try self.generateSearchURLs(query);
        defer {
            for (search_urls) |url| {
                self.allocator.free(url);
            }
            self.allocator.free(search_urls);
        }
        
        // Crawl search results
        for (search_urls) |search_url| {
            const crawl_result = self.crawlURL(search_url) catch |err| {
                std.log.warn("Failed to crawl search URL {s}: {}", .{ search_url, err });
                continue;
            };
            defer crawl_result.deinit(self.allocator);
            
            // Extract search results from the page
            const extracted_results = try self.extractSearchResults(crawl_result, query);
            defer {
                for (extracted_results) |result| {
                    result.deinit(self.allocator);
                }
                self.allocator.free(extracted_results);
            }
            
            for (extracted_results) |result| {
                try search_results.append(try result.clone(self.allocator));
            }
        }
        
        std.log.info("🔍 Web search completed: {d} results for '{s}'", .{ search_results.items.len, query });
        return try search_results.toOwnedSlice();
    }
    
    /// Batch crawl multiple URLs with concurrency control
    pub fn batchCrawl(self: *Self, urls: [][]const u8) ![]CrawlResult {
        var results = try self.allocator.alloc(CrawlResult, urls.len);
        var successful_count: usize = 0;
        
        // Initialize result array with placeholder values
        for (results) |*result| {
            result.* = undefined;
        }
        
        // Determine batch size based on configured max concurrent requests
        const batch_size = @min(self.config.max_concurrent_requests, urls.len);
        var current_batch: usize = 0;
        
        while (current_batch < urls.len) {
            const batch_end = @min(current_batch + batch_size, urls.len);
            const current_batch_urls = urls[current_batch..batch_end];
            
            std.log.info("🔄 Processing batch {d}-{d} of {d} URLs", .{ current_batch + 1, batch_end, urls.len });
            
            // Process current batch concurrently using thread pool
            var batch_threads = std.ArrayList(std.Thread).init(self.allocator);
            defer batch_threads.deinit();
            
            var batch_results = std.ArrayList(CrawlResult).init(self.allocator);
            defer batch_results.deinit();
            
            // Create thread-safe context for batch processing
            var batch_context = BatchCrawlContext{
                .crawler = self,
                .urls = current_batch_urls,
                .results = try self.allocator.alloc(?CrawlResult, current_batch_urls.len),
                .mutex = std.Thread.Mutex{},
                .completed_count = 0,
            };
            defer self.allocator.free(batch_context.results);
            
            // Initialize results array
            for (batch_context.results) |*result| {
                result.* = null;
            }
            
            // Launch worker threads for batch
            for (current_batch_urls, 0..) |url, i| {
                const thread_data = try self.allocator.create(ThreadCrawlData);
                thread_data.* = ThreadCrawlData{
                    .context = &batch_context,
                    .url_index = i,
                    .url = url,
                };
                
                const thread = try std.Thread.spawn(.{}, crawlWorkerThread, .{thread_data});
                try batch_threads.append(thread);
            }
            
            // Wait for all threads to complete
            for (batch_threads.items) |thread| {
                thread.join();
            }
            
            // Collect results from batch
            for (batch_context.results, 0..) |maybe_result, i| {
                const result_index = current_batch + i;
                if (maybe_result) |result| {
                    results[result_index] = result;
                    if (result.metadata.success) {
                        successful_count += 1;
                    }
                } else {
                    // Create error result for failed crawl
                    results[result_index] = CrawlResult{
                        .url = try self.allocator.dupe(u8, current_batch_urls[i]),
                        .title = null,
                        .content = try self.allocator.dupe(u8, ""),
                        .markdown = null,
                        .structured_data = null,
                        .metadata = CrawlMetadata{
                            .status_code = 0,
                            .content_type = null,
                            .content_length = 0,
                            .crawl_time_ms = 0,
                            .extraction_method = try self.allocator.dupe(u8, "error"),
                            .success = false,
                            .error_message = try self.allocator.dupe(u8, "Thread crawl failed"),
                        },
                    };
                }
            }
            
            current_batch = batch_end;
            
            // Add delay between batches to respect rate limits
            if (current_batch < urls.len) {
                std.time.sleep(1000 * 1000 * 1000); // 1 second delay
            }
        }
        
        std.log.info("📊 Batch crawl completed: {d}/{d} successful", .{ successful_count, urls.len });
        return results;
    }
    
    /// Extract content using LLM-powered extraction
    pub fn extractWithLLM(self: *Self, content: []const u8, extraction_schema: []const u8) ![]StructuredData {
        if (self.claude_client == null) {
            return &[_]StructuredData{};
        }
        
        const extraction_prompt = try std.fmt.allocPrint(self.allocator,
            \\Extract structured data from the following content using this schema:
            \\
            \\Schema: {s}
            \\
            \\Content:
            \\{s}
            \\
            \\Respond with JSON array of extracted structured data objects.
        , .{ extraction_schema, content[0..@min(content.len, 2000)] }); // Limit content size for prompt
        defer self.allocator.free(extraction_prompt);
        
        const llm_response = try self.claude_client.?.executeClaude(extraction_prompt);
        defer self.allocator.free(llm_response);
        
        return try self.parseStructuredDataFromLLM(llm_response);
    }
    
    // Private implementation methods
    fn crawlWithFirecrawl(self: *Self, firecrawl_client: *firecrawl.FirecrawlClient, url: []const u8) !CrawlResult {
        const start_time = std.time.milliTimestamp();
        
        const scrape_options = firecrawl.ScrapeOptions{
            .only_main_content = true,
            .include_links = true,
            .include_raw_html = false,
            .wait_for = 3000,
        };
        
        const response = try firecrawl_client.scrape(url, scrape_options);
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            self.failed_crawls += 1;
            return error.CrawlFailed;
        }
        
        const end_time = std.time.milliTimestamp();
        const crawl_time = @as(u64, @intCast(end_time - start_time));
        
        const content = response.data.?.markdown orelse response.data.?.html orelse "";
        self.total_bytes_crawled += content.len;
        self.updateAverageCrawlTime(crawl_time);
        
        return CrawlResult{
            .url = try self.allocator.dupe(u8, url),
            .title = if (response.data.?.metadata) |meta| 
                if (meta.title) |title| try self.allocator.dupe(u8, title) else null 
            else null,
            .content = try self.allocator.dupe(u8, content),
            .markdown = if (response.data.?.markdown) |md| try self.allocator.dupe(u8, md) else null,
            .structured_data = null, // TODO: Extract from Firecrawl response
            .metadata = CrawlMetadata{
                .status_code = 200,
                .content_type = try self.allocator.dupe(u8, "text/html"),
                .content_length = content.len,
                .crawl_time_ms = crawl_time,
                .extraction_method = try self.allocator.dupe(u8, "firecrawl"),
                .success = true,
                .error_message = null,
            },
        };
    }
    
    fn crawlWithCrawl4AI(self: *Self, url: []const u8) !CrawlResult {
        const start_time = std.time.milliTimestamp();
        
        // Build Crawl4AI request
        const crawl4ai_url = try std.fmt.allocPrint(self.allocator, "{s}/crawl", .{self.config.crawl4ai_endpoint.?});
        defer self.allocator.free(crawl4ai_url);
        
        const request_body = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "url": "{s}",
            \\  "markdown": true,
            \\  "structured_data": true,
            \\  "stealth_mode": {s},
            \\  "wait_for": 3000
            \\}}
        , .{ url, if (self.config.enable_stealth_mode) "true" else "false" });
        defer self.allocator.free(request_body);
        
        var headers = std.ArrayList(types.HttpRequest.Header).init(self.allocator);
        defer headers.deinit();
        
        try headers.append(types.HttpRequest.Header{
            .name = try self.allocator.dupe(u8, "Content-Type"),
            .value = try self.allocator.dupe(u8, "application/json"),
        });
        
        if (self.config.crawl4ai_api_key) |api_key| {
            try headers.append(types.HttpRequest.Header{
                .name = try self.allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key}),
            });
        }
        
        const response = try self.http_client.post(crawl4ai_url, headers.items, request_body);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            self.failed_crawls += 1;
            return error.CrawlFailed;
        }
        
        const end_time = std.time.milliTimestamp();
        const crawl_time = @as(u64, @intCast(end_time - start_time));
        
        // Parse Crawl4AI response (simplified)
        const content = response.body; // Would need proper JSON parsing
        self.total_bytes_crawled += content.len;
        self.updateAverageCrawlTime(crawl_time);
        
        return CrawlResult{
            .url = try self.allocator.dupe(u8, url),
            .title = null, // Would extract from JSON response
            .content = try self.allocator.dupe(u8, content),
            .markdown = try self.allocator.dupe(u8, content), // Simplified
            .structured_data = null, // Would extract from JSON response
            .metadata = CrawlMetadata{
                .status_code = response.status_code,
                .content_type = try self.allocator.dupe(u8, "application/json"),
                .content_length = content.len,
                .crawl_time_ms = crawl_time,
                .extraction_method = try self.allocator.dupe(u8, "crawl4ai"),
                .success = true,
                .error_message = null,
            },
        };
    }
    
    fn crawlWithDirect(self: *Self, url: []const u8, start_time: i64) !CrawlResult {
        // Build headers
        var headers = std.ArrayList(types.HttpRequest.Header).init(self.allocator);
        defer headers.deinit();
        
        try headers.append(types.HttpRequest.Header{
            .name = try self.allocator.dupe(u8, "User-Agent"),
            .value = try self.allocator.dupe(u8, self.config.user_agent),
        });
        
        const response = try self.http_client.get(url, headers.items);
        defer response.deinit(self.allocator);
        
        const end_time = std.time.milliTimestamp();
        const crawl_time = @as(u64, @intCast(end_time - start_time));
        
        if (response.status_code >= 400) {
            self.failed_crawls += 1;
            return error.CrawlFailed;
        }
        
        const content = response.body;
        self.total_bytes_crawled += content.len;
        self.updateAverageCrawlTime(crawl_time);
        self.successful_crawls += 1;
        
        // Extract title from HTML (simplified)
        const title = self.extractTitleFromHTML(content) catch null;
        
        // Convert to markdown (simplified)
        const markdown = try self.convertHTMLToMarkdown(content);
        
        return CrawlResult{
            .url = try self.allocator.dupe(u8, url),
            .title = title,
            .content = try self.allocator.dupe(u8, content),
            .markdown = markdown,
            .structured_data = null,
            .metadata = CrawlMetadata{
                .status_code = response.status_code,
                .content_type = try self.allocator.dupe(u8, "text/html"),
                .content_length = content.len,
                .crawl_time_ms = crawl_time,
                .extraction_method = try self.allocator.dupe(u8, "direct_http"),
                .success = true,
                .error_message = null,
            },
        };
    }
    
    fn generateSearchURLs(self: *Self, query: []const u8) ![][]const u8 {
        // URL encode the query
        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);
        
        var urls = std.ArrayList([]const u8).init(self.allocator);
        
        // Add different search engines
        try urls.append(try std.fmt.allocPrint(self.allocator, "https://duckduckgo.com/html/?q={s}", .{encoded_query}));
        try urls.append(try std.fmt.allocPrint(self.allocator, "https://www.bing.com/search?q={s}", .{encoded_query}));
        
        return try urls.toOwnedSlice();
    }
    
    fn extractSearchResults(self: *Self, crawl_result: CrawlResult, query: []const u8) ![]types.NewsItem {
        var results = std.ArrayList(types.NewsItem).init(self.allocator);
        defer results.deinit();
        
        // Determine search engine type from URL
        const search_engine = self.detectSearchEngine(crawl_result.url);
        
        // Parse content based on search engine
        switch (search_engine) {
            .duckduckgo => try self.extractDuckDuckGoResults(&results, crawl_result.content, query),
            .bing => try self.extractBingResults(&results, crawl_result.content, query),
            .unknown => try self.extractGenericSearchResults(&results, crawl_result.content, query),
        }
        
        std.log.info("🔍 Extracted {d} search results from {s}", .{ results.items.len, crawl_result.url });
        return try results.toOwnedSlice();
    }
    
    const SearchEngine = enum {
        duckduckgo,
        bing,
        unknown,
    };
    
    fn detectSearchEngine(self: *Self, url: []const u8) SearchEngine {
        _ = self;
        
        if (std.mem.indexOf(u8, url, "duckduckgo.com") != null) {
            return .duckduckgo;
        } else if (std.mem.indexOf(u8, url, "bing.com") != null) {
            return .bing;
        } else {
            return .unknown;
        }
    }
    
    fn extractDuckDuckGoResults(self: *Self, results: *std.ArrayList(types.NewsItem), html: []const u8, query: []const u8) !void {
        // DuckDuckGo result extraction
        var pos: usize = 0;
        
        while (std.mem.indexOfPos(u8, html, pos, "result__a")) |start| {
            pos = start + 9;
            
            // Extract URL
            const href_start = std.mem.indexOfPos(u8, html, start, "href=\"") orelse continue;
            const url_start = href_start + 6;
            const url_end = std.mem.indexOfScalarPos(u8, html, url_start, '"') orelse continue;
            const url = html[url_start..url_end];
            
            // Extract title
            const title_start = std.mem.indexOfPos(u8, html, url_end, ">") orelse continue;
            const title_content_start = title_start + 1;
            const title_end = std.mem.indexOfPos(u8, html, title_content_start, "</a>") orelse continue;
            const title = std.mem.trim(u8, html[title_content_start..title_end], " \t\n\r");
            
            // Extract snippet (simplified)
            const snippet_start = std.mem.indexOfPos(u8, html, title_end, "result__snippet") orelse {
                // Create result without snippet
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet_content_start = std.mem.indexOfPos(u8, html, snippet_start, ">") orelse {
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet_content_start_adj = snippet_content_start + 1;
            const snippet_end = std.mem.indexOfPos(u8, html, snippet_content_start_adj, "</") orelse {
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet = std.mem.trim(u8, html[snippet_content_start_adj..snippet_end], " \t\n\r");
            
            try self.addSearchResult(results, title, snippet, url, query);
        }
    }
    
    fn extractBingResults(self: *Self, results: *std.ArrayList(types.NewsItem), html: []const u8, query: []const u8) !void {
        // Bing result extraction
        var pos: usize = 0;
        
        while (std.mem.indexOfPos(u8, html, pos, "b_algo")) |start| {
            pos = start + 6;
            
            // Extract title and URL from h2 tag
            const h2_start = std.mem.indexOfPos(u8, html, start, "<h2>") orelse continue;
            const a_start = std.mem.indexOfPos(u8, html, h2_start, "<a href=\"") orelse continue;
            const url_start = a_start + 9;
            const url_end = std.mem.indexOfScalarPos(u8, html, url_start, '"') orelse continue;
            const url = html[url_start..url_end];
            
            const title_start = std.mem.indexOfPos(u8, html, url_end, ">") orelse continue;
            const title_content_start = title_start + 1;
            const title_end = std.mem.indexOfPos(u8, html, title_content_start, "</a>") orelse continue;
            const title = std.mem.trim(u8, html[title_content_start..title_end], " \t\n\r");
            
            // Extract snippet
            const snippet_start = std.mem.indexOfPos(u8, html, title_end, "b_caption") orelse {
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet_content_start = std.mem.indexOfPos(u8, html, snippet_start, ">") orelse {
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet_content_start_adj = snippet_content_start + 1;
            const snippet_end = std.mem.indexOfPos(u8, html, snippet_content_start_adj, "</") orelse {
                try self.addSearchResult(results, title, "", url, query);
                continue;
            };
            const snippet = std.mem.trim(u8, html[snippet_content_start_adj..snippet_end], " \t\n\r");
            
            try self.addSearchResult(results, title, snippet, url, query);
        }
    }
    
    fn extractGenericSearchResults(self: *Self, results: *std.ArrayList(types.NewsItem), html: []const u8, query: []const u8) !void {
        // Generic search result extraction using common patterns
        var pos: usize = 0;
        
        // Look for common link patterns
        while (std.mem.indexOfPos(u8, html, pos, "<a href=\"http")) |start| {
            pos = start + 9;
            
            const url_start = start + 9;
            const url_end = std.mem.indexOfScalarPos(u8, html, url_start, '"') orelse continue;
            const url = html[url_start..url_end];
            
            // Skip if URL looks like an ad or internal link
            if (std.mem.indexOf(u8, url, "google.com") != null or
                std.mem.indexOf(u8, url, "bing.com") != null or
                std.mem.indexOf(u8, url, "ad") != null) {
                continue;
            }
            
            const title_start = std.mem.indexOfPos(u8, html, url_end, ">") orelse continue;
            const title_content_start = title_start + 1;
            const title_end = std.mem.indexOfPos(u8, html, title_content_start, "</a>") orelse continue;
            var title = std.mem.trim(u8, html[title_content_start..title_end], " \t\n\r");
            
            // Remove HTML tags from title
            title = try self.removeHtmlTags(title);
            
            // Create basic result
            try self.addSearchResult(results, title, "", url, query);
            
            // Limit to prevent too many results
            if (results.items.len >= 10) break;
        }
    }
    
    fn addSearchResult(self: *Self, results: *std.ArrayList(types.NewsItem), title: []const u8, summary: []const u8, url: []const u8, query: []const u8) !void {
        // Calculate relevance score based on query match
        const relevance_score = self.calculateSearchRelevance(title, summary, query);
        
        const news_item = types.NewsItem{
            .title = try self.allocator.dupe(u8, title),
            .summary = try self.allocator.dupe(u8, summary),
            .url = try self.allocator.dupe(u8, url),
            .source = try self.allocator.dupe(u8, "web_search"),
            .source_type = .web_crawl,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
        
        try results.append(news_item);
    }
    
    fn calculateSearchRelevance(self: *Self, title: []const u8, summary: []const u8, query: []const u8) f32 {
        var score: f32 = 0.5; // Base score
        
        // Check query terms in title (higher weight)
        const title_lower = std.ascii.allocLowerString(self.allocator, title) catch return score;
        defer self.allocator.free(title_lower);
        
        const query_lower = std.ascii.allocLowerString(self.allocator, query) catch return score;
        defer self.allocator.free(query_lower);
        
        // Simple keyword matching
        var query_iter = std.mem.splitScalar(u8, query_lower, ' ');
        var matches: f32 = 0;
        var total_terms: f32 = 0;
        
        while (query_iter.next()) |term| {
            total_terms += 1;
            if (std.mem.indexOf(u8, title_lower, term) != null) {
                matches += 2.0; // Title matches worth more
            } else if (std.mem.indexOf(u8, summary, term) != null) {
                matches += 1.0; // Summary matches worth less
            }
        }
        
        if (total_terms > 0) {
            score += (matches / total_terms) * 0.3;
        }
        
        return @min(1.0, @max(0.0, score));
    }
    
    fn removeHtmlTags(self: *Self, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        var in_tag = false;
        for (input) |char| {
            if (char == '<') {
                in_tag = true;
            } else if (char == '>') {
                in_tag = false;
            } else if (!in_tag) {
                try result.append(char);
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    fn extractTitleFromHTML(self: *Self, html: []const u8) ![]const u8 {
        // Simple title extraction
        const title_start = std.mem.indexOf(u8, html, "<title>") orelse return error.TitleNotFound;
        const title_end = std.mem.indexOf(u8, html[title_start + 7..], "</title>") orelse return error.TitleNotFound;
        
        const title_text = html[title_start + 7..title_start + 7 + title_end];
        return try self.allocator.dupe(u8, title_text);
    }
    
    fn convertHTMLToMarkdown(self: *Self, html: []const u8) ![]const u8 {
        // Simplified HTML to Markdown conversion
        // In a real implementation, this would use a proper HTML parser
        
        var markdown = std.ArrayList(u8).init(self.allocator);
        defer markdown.deinit();
        
        // Remove HTML tags (very simplified)
        var in_tag = false;
        for (html) |char| {
            if (char == '<') {
                in_tag = true;
            } else if (char == '>') {
                in_tag = false;
            } else if (!in_tag) {
                try markdown.append(char);
            }
        }
        
        return try markdown.toOwnedSlice();
    }
    
    fn urlEncode(self: *Self, input: []const u8) ![]const u8 {
        var encoded = std.ArrayList(u8).init(self.allocator);
        defer encoded.deinit();
        
        for (input) |char| {
            if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
                try encoded.append(char);
            } else {
                try encoded.writer().print("%{X:0>2}", .{char});
            }
        }
        
        return try encoded.toOwnedSlice();
    }
    
    fn parseStructuredDataFromLLM(self: *Self, llm_response: []const u8) ![]StructuredData {
        var structured_data = std.ArrayList(StructuredData).init(self.allocator);
        defer structured_data.deinit();
        
        // Parse JSON response from LLM
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, llm_response, .{}) catch |err| {
            std.log.warn("Failed to parse LLM response as JSON: {}", .{err});
            // Try to extract data from text format as fallback
            return try self.parseStructuredDataFromText(llm_response);
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        
        // Handle array of structured data objects
        if (root == .array) {
            for (root.array.items) |item| {
                if (item == .object) {
                    const structured_item = try self.parseStructuredDataObject(item.object);
                    try structured_data.append(structured_item);
                }
            }
        } 
        // Handle single object
        else if (root == .object) {
            const structured_item = try self.parseStructuredDataObject(root.object);
            try structured_data.append(structured_item);
        }
        
        return try structured_data.toOwnedSlice();
    }
    
    fn parseStructuredDataObject(self: *Self, obj: std.json.ObjectMap) !StructuredData {
        const data_type = if (obj.get("type")) |type_value|
            if (type_value == .string) try self.allocator.dupe(u8, type_value.string) else try self.allocator.dupe(u8, "unknown")
        else
            try self.allocator.dupe(u8, "unknown");
        
        var properties = std.StringHashMap([]const u8).init(self.allocator);
        
        // Extract properties from the object
        var iterator = obj.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "type")) {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value = switch (entry.value_ptr.*) {
                    .string => |str| try self.allocator.dupe(u8, str),
                    .integer => |int| try std.fmt.allocPrint(self.allocator, "{d}", .{int}),
                    .float => |float| try std.fmt.allocPrint(self.allocator, "{d}", .{float}),
                    .bool => |boolean| try self.allocator.dupe(u8, if (boolean) "true" else "false"),
                    else => try self.allocator.dupe(u8, ""),
                };
                try properties.put(key, value);
            }
        }
        
        return StructuredData{
            .type = data_type,
            .properties = properties,
        };
    }
    
    fn parseStructuredDataFromText(self: *Self, text: []const u8) ![]StructuredData {
        // Fallback text parsing for when JSON parsing fails
        var structured_data = std.ArrayList(StructuredData).init(self.allocator);
        defer structured_data.deinit();
        
        // Look for common structured data patterns in text
        var properties = std.StringHashMap([]const u8).init(self.allocator);
        
        // Extract title if present
        if (std.mem.indexOf(u8, text, "title:")) |title_pos| {
            const title_start = title_pos + 6;
            const title_end = std.mem.indexOfScalarPos(u8, text, title_start, '\n') orelse text.len;
            const title = std.mem.trim(u8, text[title_start..title_end], " \t");
            try properties.put(try self.allocator.dupe(u8, "title"), try self.allocator.dupe(u8, title));
        }
        
        // Extract description if present
        if (std.mem.indexOf(u8, text, "description:")) |desc_pos| {
            const desc_start = desc_pos + 12;
            const desc_end = std.mem.indexOfScalarPos(u8, text, desc_start, '\n') orelse text.len;
            const description = std.mem.trim(u8, text[desc_start..desc_end], " \t");
            try properties.put(try self.allocator.dupe(u8, "description"), try self.allocator.dupe(u8, description));
        }
        
        // If we found any properties, create a structured data object
        if (properties.count() > 0) {
            try structured_data.append(StructuredData{
                .type = try self.allocator.dupe(u8, "extracted_text"),
                .properties = properties,
            });
        }
        
        return try structured_data.toOwnedSlice();
    }
    
    fn updateAverageCrawlTime(self: *Self, crawl_time: u64) void {
        const new_average = (self.average_crawl_time_ms * @as(f64, @floatFromInt(self.total_crawls - 1)) + 
                           @as(f64, @floatFromInt(crawl_time))) / @as(f64, @floatFromInt(self.total_crawls));
        self.average_crawl_time_ms = new_average;
    }
};

/// Create web crawler with default configuration
pub fn createWebCrawler(allocator: std.mem.Allocator, http_client: *http.HttpClient) WebCrawler {
    const config = CrawlerConfig{};
    return WebCrawler.init(allocator, config, http_client);
}

/// Create web crawler with Crawl4AI integration
pub fn createCrawl4AICrawler(allocator: std.mem.Allocator, http_client: *http.HttpClient, 
                            crawl4ai_endpoint: []const u8, api_key: ?[]const u8) WebCrawler {
    const config = CrawlerConfig{
        .crawl4ai_endpoint = crawl4ai_endpoint,
        .crawl4ai_api_key = api_key,
        .enable_stealth_mode = true,
        .enable_llm_extraction = true,
    };
    return WebCrawler.init(allocator, config, http_client);
}

// Test function
test "Web crawler initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var crawler = createWebCrawler(allocator, &http_client);
    defer crawler.deinit();
    
    try std.testing.expect(crawler.total_crawls == 0);
    try std.testing.expect(crawler.config.max_concurrent_requests == 5);
}