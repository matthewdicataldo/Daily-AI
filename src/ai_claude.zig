const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const processor = @import("ai_processor.zig");

/// Compare function for sorting NewsItems by timestamp (descending - newest first)
fn compareByTimestamp(context: void, a: types.NewsItem, b: types.NewsItem) bool {
    _ = context;
    return a.timestamp > b.timestamp;
}

pub const ClaudeClient = struct {
    allocator: std.mem.Allocator,
    claude_model: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, claude_model: []const u8) ClaudeClient {
        return ClaudeClient{
            .allocator = allocator,
            .claude_model = claude_model,
        };
    }
    
    /// Analyze content using Claude Sonnet and generate NPR-style story (single call)
    pub fn analyzeContent(self: *ClaudeClient, content: processor.ProcessedContent) !AnalyzedContent {
        std.log.info("Starting Claude Sonnet analysis of processed content...", .{});
        
        // Single comprehensive analysis call with Sonnet
        const analysis_result = try self.performComprehensiveAnalysis(content);
        
        return analysis_result;
    }
    
    /// Analyze content using parallel Claude calls with intelligent batching for maximum performance
    pub fn analyzeContentParallel(self: *ClaudeClient, content: processor.ProcessedContent) !AnalyzedContent {
        std.log.info("Starting parallel Claude analysis with intelligent batching...", .{});
        
        // Create thread pool for parallel analysis
        var thread_pool: std.Thread.Pool = undefined;
        try thread_pool.init(std.Thread.Pool.Options{ .allocator = self.allocator, .n_jobs = null });
        defer thread_pool.deinit();
        
        // Prepare batched analysis tasks with intelligent sizing
        var analysis_tasks = std.ArrayList(AnalysisTask).init(self.allocator);
        defer analysis_tasks.deinit();
        
        // Create batched tasks for each category that has content
        try createBatchedTasks(self, &analysis_tasks, .research_papers, content.categorized_items.research_papers);
        try createBatchedTasks(self, &analysis_tasks, .video_highlights, content.categorized_items.video_highlights);
        try createBatchedTasks(self, &analysis_tasks, .community_highlights, content.categorized_items.community_highlights);
        try createBatchedTasks(self, &analysis_tasks, .model_releases, content.categorized_items.model_releases);
        try createBatchedTasks(self, &analysis_tasks, .industry_news, content.categorized_items.industry_news);
        try createBatchedTasks(self, &analysis_tasks, .tutorials_demos, content.categorized_items.tutorials_demos);
        
        // Launch parallel analysis tasks
        std.log.info("Launching {d} parallel Claude batch analysis tasks...", .{analysis_tasks.items.len});
        
        var wait_group = std.Thread.WaitGroup{};
        for (analysis_tasks.items) |*task| {
            thread_pool.spawnWg(&wait_group, analyzeContentCategoryWorker, .{ self, task });
        }
        
        // Wait for all analyses to complete
        thread_pool.waitAndWork(&wait_group);
        
        std.log.info("All parallel Claude analyses completed!", .{});
        
        // Collect results and handle any errors
        var research_papers = std.ArrayList(AnalyzedItem).init(self.allocator);
        var video_highlights = std.ArrayList(AnalyzedItem).init(self.allocator);
        var community_highlights = std.ArrayList(AnalyzedItem).init(self.allocator);
        var model_releases = std.ArrayList(AnalyzedItem).init(self.allocator);
        var industry_news = std.ArrayList(AnalyzedItem).init(self.allocator);
        var tutorials_demos = std.ArrayList(AnalyzedItem).init(self.allocator);
        
        for (analysis_tasks.items) |task| {
            if (task.error_info) |error_info| {
                std.log.warn("Analysis task for category {} failed: {s}", .{ task.category, error_info });
                // Continue with empty results for failed category
                continue;
            }
            
            if (task.result) |result| {
                switch (task.category) {
                    .research_papers => try research_papers.appendSlice(result),
                    .video_highlights => try video_highlights.appendSlice(result),
                    .community_highlights => try community_highlights.appendSlice(result),
                    .model_releases => try model_releases.appendSlice(result),
                    .industry_news => try industry_news.appendSlice(result),
                    .tutorials_demos => try tutorials_demos.appendSlice(result),
                }
            }
        }
        
        // Generate executive summary from all analyses (this can remain sequential)
        const executive_summary = try self.generateExecutiveSummary(content);
        
        return AnalyzedContent{
            .research_papers = try research_papers.toOwnedSlice(),
            .video_highlights = try video_highlights.toOwnedSlice(),
            .community_highlights = try community_highlights.toOwnedSlice(),
            .model_releases = try model_releases.toOwnedSlice(),
            .industry_news = try industry_news.toOwnedSlice(),
            .tutorials_demos = try tutorials_demos.toOwnedSlice(),
            .executive_summary = executive_summary,
            .analysis_timestamp = types.getCurrentTimestamp(),
            .original_stats = content.stats,
        };
    }
    
    /// Perform comprehensive analysis with Sonnet in a single call
    fn performComprehensiveAnalysis(self: *ClaudeClient, content: processor.ProcessedContent) !AnalyzedContent {
        std.log.info("Performing comprehensive analysis with Claude Sonnet...", .{});
        
        // Build comprehensive prompt that analyzes everything at once
        const prompt = try self.buildComprehensivePrompt(content);
        defer self.allocator.free(prompt);
        
        std.log.info("Built prompt, length: {d} characters", .{prompt.len});
        std.log.info("Prompt preview (first 1000 chars): {s}", .{prompt[0..@min(1000, prompt.len)]});
        std.log.info("Prompt ending (last 500 chars): {s}", .{prompt[@max(0, prompt.len -| 500)..]});
        
        // Execute Claude with sonnet model
        std.log.info("About to execute Claude...", .{});
        const claude_response = try self.executeClaudeWithModel(prompt, "sonnet");
        defer self.allocator.free(claude_response);
        
        std.log.info("Claude response received, length: {d} characters", .{claude_response.len});
        
        // Parse the comprehensive response
        return try self.parseComprehensiveResponse(claude_response, content);
    }
    
    /// Analyze video content with educational focus
    fn analyzeVideoContent(self: *ClaudeClient, videos: []types.NewsItem) ![]AnalyzedItem {
        if (videos.len == 0) return &[_]AnalyzedItem{};
        
        std.log.info("Analyzing {d} video highlights...", .{videos.len});
        
        const prompt = try self.buildVideoAnalysisPrompt(videos);
        defer self.allocator.free(prompt);
        
        const claude_response = try self.executeClaude(prompt);
        defer self.allocator.free(claude_response);
        
        return try self.parseClaudeResponse(claude_response, videos);
    }
    
    /// Analyze community discussions with sentiment focus
    fn analyzeCommunityContent(self: *ClaudeClient, discussions: []types.NewsItem) ![]AnalyzedItem {
        if (discussions.len == 0) return &[_]AnalyzedItem{};
        
        std.log.info("Analyzing {d} community discussions...", .{discussions.len});
        
        const prompt = try self.buildCommunityAnalysisPrompt(discussions);
        defer self.allocator.free(prompt);
        
        const claude_response = try self.executeClaude(prompt);
        defer self.allocator.free(claude_response);
        
        return try self.parseClaudeResponse(claude_response, discussions);
    }
    
    /// Analyze model releases with technical focus
    fn analyzeModelReleases(self: *ClaudeClient, releases: []types.NewsItem) ![]AnalyzedItem {
        if (releases.len == 0) return &[_]AnalyzedItem{};
        
        std.log.info("Analyzing {d} model releases...", .{releases.len});
        
        const prompt = try self.buildModelReleasePrompt(releases);
        defer self.allocator.free(prompt);
        
        const claude_response = try self.executeClaude(prompt);
        defer self.allocator.free(claude_response);
        
        return try self.parseClaudeResponse(claude_response, releases);
    }
    
    /// Analyze industry news with business focus
    fn analyzeIndustryNews(self: *ClaudeClient, news: []types.NewsItem) ![]AnalyzedItem {
        if (news.len == 0) return &[_]AnalyzedItem{};
        
        std.log.info("Analyzing {d} industry news items...", .{news.len});
        
        const prompt = try self.buildIndustryNewsPrompt(news);
        defer self.allocator.free(prompt);
        
        const claude_response = try self.executeClaude(prompt);
        defer self.allocator.free(claude_response);
        
        return try self.parseClaudeResponse(claude_response, news);
    }
    
    /// Analyze tutorials with practical focus
    fn analyzeTutorialContent(self: *ClaudeClient, tutorials: []types.NewsItem) ![]AnalyzedItem {
        if (tutorials.len == 0) return &[_]AnalyzedItem{};
        
        std.log.info("Analyzing {d} tutorials and demos...", .{tutorials.len});
        
        const prompt = try self.buildTutorialAnalysisPrompt(tutorials);
        defer self.allocator.free(prompt);
        
        const claude_response = try self.executeClaude(prompt);
        defer self.allocator.free(claude_response);
        
        return try self.parseClaudeResponse(claude_response, tutorials);
    }
    
    /// Build research paper analysis prompt
    fn buildResearchAnalysisPrompt(self: *ClaudeClient, papers: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI/ML research papers and provide enhanced summaries:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Key technical contributions and innovations\n");
        try prompt.appendSlice("- Practical applications and potential impact\n");
        try prompt.appendSlice("- Methodological advances or novel approaches\n");
        try prompt.appendSlice("- Significance within the broader AI research landscape\n\n");
        
        for (papers, 0..) |paper, i| {
            try prompt.writer().print("Paper {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{paper.title});
            try prompt.writer().print("Source: {s}\n", .{paper.source});
            try prompt.writer().print("Summary: {s}\n", .{paper.summary});
            
            if (paper.huggingface_metadata) |hf| {
                try prompt.writer().print("Authors: {s}\n", .{hf.authors[0]});
                if (hf.abstract.len > 0) {
                    try prompt.writer().print("Abstract: {s}\n", .{hf.abstract});
                }
            }
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each paper, provide:\n");
        try prompt.appendSlice("1. Enhanced 2-3 sentence summary highlighting key contributions\n");
        try prompt.appendSlice("2. Technical significance score (1-10)\n");
        try prompt.appendSlice("3. Practical applicability score (1-10)\n");
        try prompt.appendSlice("4. Key insights or implications\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Build video content analysis prompt
    fn buildVideoAnalysisPrompt(self: *ClaudeClient, videos: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI/tech video content and provide enhanced summaries:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Key insights and practical takeaways\n");
        try prompt.appendSlice("- Educational value and target audience\n");
        try prompt.appendSlice("- Technical concepts explained or demonstrated\n");
        try prompt.appendSlice("- Actionable information for viewers\n\n");
        
        for (videos, 0..) |video, i| {
            try prompt.writer().print("Video {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{video.title});
            try prompt.writer().print("Channel: {s}\n", .{video.source});
            try prompt.writer().print("Description: {s}\n", .{video.summary});
            
            if (video.youtube_metadata) |yt| {
                try prompt.writer().print("Views: {d}\n", .{yt.view_count});
                try prompt.writer().print("Duration: {s}\n", .{yt.duration});
            }
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each video, provide:\n");
        try prompt.appendSlice("1. Enhanced summary focusing on key learnings\n");
        try prompt.appendSlice("2. Educational value score (1-10)\n");
        try prompt.appendSlice("3. Technical depth score (1-10)\n");
        try prompt.appendSlice("4. Target audience and recommended viewers\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Build community discussion analysis prompt
    fn buildCommunityAnalysisPrompt(self: *ClaudeClient, discussions: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI community discussions and provide insights:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Community sentiment and key concerns\n");
        try prompt.appendSlice("- Emerging trends and discussions\n");
        try prompt.appendSlice("- Technical debates and community consensus\n");
        try prompt.appendSlice("- Practical implications for AI practitioners\n\n");
        
        for (discussions, 0..) |discussion, i| {
            try prompt.writer().print("Discussion {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{discussion.title});
            try prompt.writer().print("Subreddit: {s}\n", .{discussion.source});
            try prompt.writer().print("Content: {s}\n", .{discussion.summary});
            
            if (discussion.reddit_metadata) |reddit| {
                try prompt.writer().print("Upvotes: {d}\n", .{reddit.upvotes});
                try prompt.writer().print("Comments: {d}\n", .{reddit.comment_count});
            }
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each discussion, provide:\n");
        try prompt.appendSlice("1. Enhanced summary of key points and community sentiment\n");
        try prompt.appendSlice("2. Community interest score (1-10)\n");
        try prompt.appendSlice("3. Technical relevance score (1-10)\n");
        try prompt.appendSlice("4. Key insights for AI practitioners\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Build model release analysis prompt
    fn buildModelReleasePrompt(self: *ClaudeClient, releases: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI model releases and announcements:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Technical capabilities and improvements\n");
        try prompt.appendSlice("- Comparison with existing models\n");
        try prompt.appendSlice("- Practical applications and use cases\n");
        try prompt.appendSlice("- Market impact and significance\n\n");
        
        for (releases, 0..) |release, i| {
            try prompt.writer().print("Release {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{release.title});
            try prompt.writer().print("Source: {s}\n", .{release.source});
            try prompt.writer().print("Details: {s}\n", .{release.summary});
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each release, provide:\n");
        try prompt.appendSlice("1. Enhanced summary of capabilities and improvements\n");
        try prompt.appendSlice("2. Technical innovation score (1-10)\n");
        try prompt.appendSlice("3. Market impact score (1-10)\n");
        try prompt.appendSlice("4. Key use cases and target applications\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Build industry news analysis prompt
    fn buildIndustryNewsPrompt(self: *ClaudeClient, news: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI industry news and developments:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Business and strategic implications\n");
        try prompt.appendSlice("- Industry trends and market movements\n");
        try prompt.appendSlice("- Regulatory and policy developments\n");
        try prompt.appendSlice("- Impact on AI ecosystem and practitioners\n\n");
        
        for (news, 0..) |item, i| {
            try prompt.writer().print("News {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{item.title});
            try prompt.writer().print("Source: {s}\n", .{item.source});
            try prompt.writer().print("Content: {s}\n", .{item.summary});
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each news item, provide:\n");
        try prompt.appendSlice("1. Enhanced summary with business context\n");
        try prompt.appendSlice("2. Industry significance score (1-10)\n");
        try prompt.appendSlice("3. Strategic importance score (1-10)\n");
        try prompt.appendSlice("4. Implications for AI professionals and companies\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Build tutorial analysis prompt
    fn buildTutorialAnalysisPrompt(self: *ClaudeClient, tutorials: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        try prompt.appendSlice("Analyze the following AI tutorials and educational content:\n\n");
        try prompt.appendSlice("Focus on:\n");
        try prompt.appendSlice("- Learning objectives and skill development\n");
        try prompt.appendSlice("- Technical concepts and practical applications\n");
        try prompt.appendSlice("- Target skill level and prerequisites\n");
        try prompt.appendSlice("- Implementation guidance and actionable steps\n\n");
        
        for (tutorials, 0..) |tutorial, i| {
            try prompt.writer().print("Tutorial {d}:\n", .{i + 1});
            try prompt.writer().print("Title: {s}\n", .{tutorial.title});
            try prompt.writer().print("Source: {s}\n", .{tutorial.source});
            try prompt.writer().print("Description: {s}\n", .{tutorial.summary});
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice("For each tutorial, provide:\n");
        try prompt.appendSlice("1. Enhanced summary of learning outcomes\n");
        try prompt.appendSlice("2. Educational value score (1-10)\n");
        try prompt.appendSlice("3. Practical applicability score (1-10)\n");
        try prompt.appendSlice("4. Recommended audience and skill level\n\n");
        
        return try prompt.toOwnedSlice();
    }
    
    /// Execute Claude Code CLI with the given prompt
    pub fn executeClaude(self: *ClaudeClient, prompt: []const u8) ![]const u8 {
        std.log.info("Executing Claude with model: {s}, prompt length: {d}", .{self.claude_model, prompt.len});
        
        // Write prompt to temporary file to avoid command line parameter issues
        const temp_file_path = "/tmp/claude_prompt.txt";
        const temp_file = std.fs.cwd().createFile(temp_file_path, .{}) catch |err| {
            std.log.err("Failed to create temp file: {}", .{err});
            return types.AppError.ClaudeError;
        };
        defer temp_file.close();
        defer std.fs.cwd().deleteFile(temp_file_path) catch {};
        
        temp_file.writeAll(prompt) catch |err| {
            std.log.err("Failed to write to temp file: {}", .{err});
            return types.AppError.ClaudeError;
        };
        
        // Execute Claude with file input - use simple text mode 
        var child = std.process.Child.init(&[_][]const u8{ 
            "claude", 
            temp_file_path,
            "--model",
            self.claude_model,
            "--output-format", 
            "text",
            "--input-format",
            "text",
            "--dangerously-skip-permissions",
            "--disallowedTools",
            "*"
        }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        child.spawn() catch |err| {
            std.log.err("Failed to spawn Claude process: {}", .{err});
            return types.AppError.ClaudeError;
        };
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB limit
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);
        
        const exit_code = try child.wait();
        
        if (exit_code != .Exited or exit_code.Exited != 0) {
            std.log.err("Claude command failed with exit code: {}", .{exit_code});
            std.log.err("Stderr: {s}", .{stderr});
            return types.AppError.ClaudeError;
        }
        
        // Return text response directly 
        return stdout;
    }
    
    /// Execute Claude with a specific model
    fn executeClaudeWithModel(self: *ClaudeClient, prompt: []const u8, model: []const u8) ![]const u8 {
        std.log.info("Executing Claude with model: {s}, prompt length: {d}", .{model, prompt.len});
        
        // Write prompt to temporary file to avoid command line parameter issues
        const temp_file_path = "/tmp/claude_prompt_model.txt";
        const temp_file = std.fs.cwd().createFile(temp_file_path, .{}) catch |err| {
            std.log.err("Failed to create temp file: {}", .{err});
            return types.AppError.ClaudeError;
        };
        defer temp_file.close();
        defer std.fs.cwd().deleteFile(temp_file_path) catch {};
        
        temp_file.writeAll(prompt) catch |err| {
            std.log.err("Failed to write to temp file: {}", .{err});
            return types.AppError.ClaudeError;
        };
        
        // Execute Claude with file input - use simple text mode
        var child = std.process.Child.init(&[_][]const u8{ 
            "claude", 
            temp_file_path,
            "--model",
            model,
            "--output-format", 
            "text",
            "--input-format",
            "text",
            "--dangerously-skip-permissions",
            "--disallowedTools",
            "*"
        }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        child.spawn() catch |err| {
            std.log.err("Failed to spawn Claude process: {}", .{err});
            return types.AppError.ClaudeError;
        };
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB limit
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);
        
        const exit_code = try child.wait();
        
        if (exit_code != .Exited or exit_code.Exited != 0) {
            std.log.err("Claude command failed with exit code: {}", .{exit_code});
            std.log.err("Stderr: {s}", .{stderr});
            return types.AppError.ClaudeError;
        }
        
        // Return text response directly
        return stdout;
    }
    
    /// Build comprehensive prompt for single analysis call
    fn buildComprehensivePrompt(self: *ClaudeClient, content: processor.ProcessedContent) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        
        // Get today's date dynamically
        const now = types.getCurrentTimestamp();
        const date_str = try types.timestampToString(self.allocator, now);
        defer self.allocator.free(date_str);
        const date_part = date_str[0..10]; // Extract YYYY-MM-DD part
        
        try prompt.appendSlice(
            \\<instructions>
            \\You are a tech journalist writing for a professional AI publication. Analyze the provided sources and create a comprehensive AI news blog post.
            \\
            \\IMPORTANT OUTPUT FORMAT:
            \\1. First, use <thinking> tags to analyze the sources, identify key themes, and plan your blog structure
            \\2. Then, use <blog> tags to output ONLY the final markdown blog post with no commentary
            \\
            \\Your response should be structured exactly like this:
            \\<thinking>
            \\[Your analysis of sources, theme identification, and structural planning goes here]
            \\</thinking>
            \\
            \\<blog>
            \\[The complete markdown blog post starting with # AI News - 
        );
        try prompt.appendSlice(date_part);
        try prompt.appendSlice(
            \\]
            \\</blog>
            \\
            \\Blog requirements for the <blog> section:
            \\- Title with today's date (
        );
        try prompt.appendSlice(date_part);
        try prompt.appendSlice(
            \\)
            \\- Executive summary of key trends
            \\- Organized thematic sections
            \\- Analysis and context for significant items
            \\- Professional style for tech practitioners
            \\- Forward-looking conclusion
            \\- Citations section at the end with numbered references
            \\- Include cleaned-up quotes from comments/transcripts using [sic] when needed
            \\- All sources must be linked with their URLs
            \\
            \\Sources to analyze:
            \\</instructions>
            \\
        );
        
        // Collect all items from all categories into a single array
        var all_items = std.ArrayList(types.NewsItem).init(self.allocator);
        defer all_items.deinit();
        
        try all_items.appendSlice(content.categorized_items.research_papers);
        try all_items.appendSlice(content.categorized_items.community_highlights);
        try all_items.appendSlice(content.categorized_items.model_releases);
        try all_items.appendSlice(content.categorized_items.industry_news);
        try all_items.appendSlice(content.categorized_items.video_highlights);
        try all_items.appendSlice(content.categorized_items.tutorials_demos);
        
        // Sort by timestamp descending (most recent first)
        std.mem.sort(types.NewsItem, all_items.items, {}, compareByTimestamp);
        
        for (all_items.items, 0..) |item, i| {
            const timestamp_str = types.timestampToString(self.allocator, item.timestamp) catch "Unknown time";
            defer self.allocator.free(timestamp_str);
            
            const category = switch (item.source_type) {
                .reddit => "COMMUNITY",
                .youtube, .tiktok => "VIDEO",
                .research_hub => "RESEARCH",
                .blog => "BLOG", 
                .web_crawl => "NEWS",
                .github_repo => "CODE",
                .rss => "RSS_NEWS",
            };
            
            try prompt.writer().print("{d}. [{s}] [{s}] {s}\n", .{ i + 1, timestamp_str, category, item.title });
            try prompt.writer().print("   Source: {s}\n", .{item.source});
            try prompt.writer().print("   Summary: {s}\n", .{item.summary});
            try prompt.writer().print("   URL: {s}\n", .{item.url});
            try prompt.writer().print("   Relevance Score: {d:.2}\n", .{item.relevance_score});
            
            // Include detailed metadata for videos
            if (item.youtube_metadata) |yt| {
                try prompt.writer().print("   Channel: {s}\n", .{yt.channel_name});
                try prompt.writer().print("   Duration: {s}\n", .{yt.duration});
                try prompt.writer().print("   Views: {d}\n", .{yt.view_count});
                if (yt.transcript) |transcript| {
                    // Truncate very long transcripts but include more detail
                    const transcript_preview = if (transcript.len > 1000) transcript[0..1000] else transcript;
                    try prompt.writer().print("   Transcript: {s}...\n", .{transcript_preview});
                }
                if (yt.top_comments) |comments| {
                    try prompt.writer().print("   Top Comments ({d} total):\n", .{comments.len});
                    for (comments[0..@min(5, comments.len)]) |comment| {
                        try prompt.writer().print("     - @{s} ({d} likes): {s}\n", .{comment.author, comment.likes, comment.text});
                    }
                }
            }
            
            // Include detailed Reddit metadata
            if (item.reddit_metadata) |reddit| {
                try prompt.writer().print("   Subreddit: r/{s}\n", .{reddit.subreddit});
                try prompt.writer().print("   Author: u/{s}\n", .{reddit.author});
                try prompt.writer().print("   Upvotes: {d} ({d:.1}% upvoted)\n", .{reddit.upvotes, reddit.upvote_ratio * 100});
                try prompt.writer().print("   Comments: {d}\n", .{reddit.comment_count});
                if (reddit.flair) |flair| {
                    try prompt.writer().print("   Flair: {s}\n", .{flair});
                }
                if (reddit.selftext) |selftext| {
                    const selftext_preview = if (selftext.len > 500) selftext[0..500] else selftext;
                    try prompt.writer().print("   Post Content: {s}...\n", .{selftext_preview});
                }
                if (reddit.top_comments) |comments| {
                    try prompt.writer().print("   Top Comments ({d} total):\n", .{comments.len});
                    for (comments[0..@min(5, comments.len)]) |comment| {
                        try prompt.writer().print("     - u/{s} (score: {d}): {s}\n", .{comment.author, comment.score, comment.text});
                    }
                }
            }
            
            try prompt.appendSlice("\n");
        }
        
        try prompt.appendSlice(
            \\
            \\FINAL INSTRUCTIONS: 
            \\
            \\Now analyze these sources and provide your response using the exact XML structure specified above:
            \\
            \\1. Start with <thinking> tags containing your analysis and planning
            \\2. Follow with <blog> tags containing ONLY the clean markdown blog post
            \\3. The blog section should start with # AI News - 2025-06-27
            \\4. Include direct quotes from transcripts and comments using proper formatting
            \\5. Use [sic] notation when correcting obvious errors in quotes
            \\6. Add a "## Citations" section at the end with numbered references including full URLs
            \\7. Link all sources using markdown format: [Source Name](URL)
            \\8. When quoting, attribute properly with full metadata
            \\9. Include community engagement metrics in your analysis
            \\10. Ensure the <blog> section contains NO commentary about the task itself
            \\
            \\Begin your response now with <thinking> tags:
        );
        
        return try prompt.toOwnedSlice();
    }
    
    /// Parse comprehensive response from Claude (extracts content from <blog> tags)
    fn parseComprehensiveResponse(self: *ClaudeClient, response: []const u8, content: processor.ProcessedContent) !AnalyzedContent {
        std.log.info("Claude response received, length: {d} characters", .{response.len});
        std.log.info("Claude response preview: {s}", .{response[0..@min(500, response.len)]});
        
        // Extract content from <blog> tags
        const blog_content = self.extractBlogContent(response) catch |err| {
            std.log.warn("Failed to extract blog content from XML tags: {}, using full response", .{err});
            // Fallback to full response if parsing fails
            return AnalyzedContent{
                .research_papers = &[_]AnalyzedItem{},
                .video_highlights = &[_]AnalyzedItem{},
                .community_highlights = &[_]AnalyzedItem{},
                .model_releases = &[_]AnalyzedItem{},
                .industry_news = &[_]AnalyzedItem{},
                .tutorials_demos = &[_]AnalyzedItem{},
                .executive_summary = try self.allocator.dupe(u8, response),
                .analysis_timestamp = types.getCurrentTimestamp(),
                .original_stats = content.stats,
            };
        };
        
        std.log.info("Successfully extracted clean blog content, length: {d} characters", .{blog_content.len});
        
        return AnalyzedContent{
            .research_papers = &[_]AnalyzedItem{},
            .video_highlights = &[_]AnalyzedItem{},
            .community_highlights = &[_]AnalyzedItem{},
            .model_releases = &[_]AnalyzedItem{},
            .industry_news = &[_]AnalyzedItem{},
            .tutorials_demos = &[_]AnalyzedItem{},
            .executive_summary = blog_content,
            .analysis_timestamp = types.getCurrentTimestamp(),
            .original_stats = content.stats,
        };
    }
    
    /// Extract content from <blog> tags, removing Claude's meta-commentary
    fn extractBlogContent(self: *ClaudeClient, response: []const u8) ![]const u8 {
        std.log.info("Attempting to extract blog content from response, total length: {d}", .{response.len});
        std.log.info("Response preview (first 500 chars): {s}", .{response[0..@min(500, response.len)]});
        
        // Find the opening <blog> tag
        const blog_start_tag = "<blog>";
        const blog_end_tag = "</blog>";
        
        const start_pos = std.mem.indexOf(u8, response, blog_start_tag) orelse {
            std.log.warn("No <blog> opening tag found in response - Claude did not follow XML format", .{});
            std.log.info("Looking for alternative patterns in response...", .{});
            
            // Try to find if there's a markdown title that we can use as fallback
            if (std.mem.indexOf(u8, response, "# AI News")) |title_pos| {
                std.log.info("Found markdown title at position {d}, using fallback extraction", .{title_pos});
                const fallback_content = std.mem.trim(u8, response[title_pos..], " \t\n\r");
                return try self.allocator.dupe(u8, fallback_content);
            }
            
            std.log.warn("No suitable content pattern found, using full response as fallback", .{});
            return types.AppError.ClaudeError;
        };
        
        std.log.info("Found <blog> opening tag at position: {d}", .{start_pos});
        const content_start = start_pos + blog_start_tag.len;
        
        // Find the closing </blog> tag
        const end_pos = std.mem.indexOf(u8, response[content_start..], blog_end_tag) orelse {
            std.log.warn("No </blog> closing tag found in response - partial XML format", .{});
            std.log.info("Using content from <blog> tag to end of response as fallback", .{});
            const fallback_content = std.mem.trim(u8, response[content_start..], " \t\n\r");
            return try self.allocator.dupe(u8, fallback_content);
        };
        
        std.log.info("Found </blog> closing tag at relative position: {d}", .{end_pos});
        const content_end = content_start + end_pos;
        
        // Extract and trim the blog content
        const raw_blog_content = response[content_start..content_end];
        
        // Trim whitespace from the beginning and end
        const trimmed_content = std.mem.trim(u8, raw_blog_content, " \t\n\r");
        
        std.log.info("Successfully extracted blog content from XML tags, length: {d} characters", .{trimmed_content.len});
        std.log.info("Clean blog content preview: {s}", .{trimmed_content[0..@min(200, trimmed_content.len)]});
        
        return try self.allocator.dupe(u8, trimmed_content);
    }
    
    /// Parse Claude JSON response into analyzed items
    fn parseClaudeResponse(self: *ClaudeClient, response: []const u8, original_items: []types.NewsItem) ![]AnalyzedItem {
        std.log.debug("Parsing Claude response, length: {d} chars", .{response.len});
        
        // Try to parse as JSON first
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, response, .{}) catch |err| {
            std.log.warn("Failed to parse Claude response as JSON: {}, creating fallback items", .{err});
            return try self.createFallbackAnalyzedItems(original_items);
        };
        
        if (parsed.value != .array) {
            std.log.warn("Expected JSON array from Claude, got {}, creating fallback", .{parsed.value});
            return try self.createFallbackAnalyzedItems(original_items);
        }
        
        const array = parsed.value.array;
        var analyzed_items = try self.allocator.alloc(AnalyzedItem, array.items.len);
        errdefer {
            for (analyzed_items[0..]) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(analyzed_items);
        }
        
        for (array.items, 0..) |item_val, i| {
            if (item_val != .object) {
                // Use fallback for invalid items
                analyzed_items[i] = try self.createFallbackAnalyzedItem(if (i < original_items.len) original_items[i] else original_items[0]);
                continue;
            }
            
            analyzed_items[i] = try self.parseAnalyzedItemFromJson(item_val.object, if (i < original_items.len) original_items[i] else original_items[0]);
        }
        
        std.log.info("Successfully parsed {d} analyzed items from Claude response", .{analyzed_items.len});
        return analyzed_items;
    }
    
    /// Parse a single AnalyzedItem from JSON object
    fn parseAnalyzedItemFromJson(self: *ClaudeClient, obj: std.json.ObjectMap, original_item: types.NewsItem) !AnalyzedItem {
        // Extract enhanced summary
        const enhanced_summary = if (obj.get("enhanced_summary")) |val|
            if (val == .string) try self.allocator.dupe(u8, val.string) else try self.allocator.dupe(u8, original_item.summary)
        else
            try self.allocator.dupe(u8, original_item.summary);
        
        // Extract scores
        const technical_score = if (obj.get("technical_score")) |val| blk: {
            switch (val) {
                .float => break :blk @as(f32, @floatCast(val.float)),
                .integer => break :blk @as(f32, @floatFromInt(val.integer)),
                else => break :blk 7.0,
            }
        } else 7.0;
        
        const relevance_score = if (obj.get("relevance_score")) |val| blk: {
            switch (val) {
                .float => break :blk @as(f32, @floatCast(val.float)),
                .integer => break :blk @as(f32, @floatFromInt(val.integer)),
                else => break :blk original_item.relevance_score,
            }
        } else original_item.relevance_score;
        
        // Extract insights and audience
        const key_insights = if (obj.get("key_insights")) |val|
            if (val == .string) try self.allocator.dupe(u8, val.string) else try self.allocator.dupe(u8, "Analysis provided by Claude AI")
        else
            try self.allocator.dupe(u8, "Analysis provided by Claude AI");
        
        const target_audience = if (obj.get("target_audience")) |val|
            if (val == .string) try self.allocator.dupe(u8, val.string) else try self.allocator.dupe(u8, "AI practitioners and researchers")
        else
            try self.allocator.dupe(u8, "AI practitioners and researchers");
        
        // Clone the original item
        const cloned_item = try original_item.clone(self.allocator);
        
        return AnalyzedItem{
            .original_item = cloned_item,
            .enhanced_summary = enhanced_summary,
            .technical_score = technical_score,
            .relevance_score = relevance_score,
            .key_insights = key_insights,
            .target_audience = target_audience,
        };
    }
    
    /// Create fallback analyzed items when Claude parsing fails
    fn createFallbackAnalyzedItems(self: *ClaudeClient, original_items: []types.NewsItem) ![]AnalyzedItem {
        var analyzed_items = try self.allocator.alloc(AnalyzedItem, original_items.len);
        errdefer {
            for (analyzed_items[0..]) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(analyzed_items);
        }
        
        for (original_items, 0..) |original_item, i| {
            analyzed_items[i] = try self.createFallbackAnalyzedItem(original_item);
        }
        
        return analyzed_items;
    }
    
    /// Create a single fallback analyzed item
    fn createFallbackAnalyzedItem(self: *ClaudeClient, original_item: types.NewsItem) !AnalyzedItem {
        const cloned_item = try original_item.clone(self.allocator);
        
        return AnalyzedItem{
            .original_item = cloned_item,
            .enhanced_summary = try self.allocator.dupe(u8, original_item.summary),
            .technical_score = 7.0,
            .relevance_score = original_item.relevance_score,
            .key_insights = try self.allocator.dupe(u8, "Content analysis from multiple AI sources"),
            .target_audience = try self.allocator.dupe(u8, "AI practitioners and enthusiasts"),
        };
    }
    
    /// Generate executive summary from processed content (fallback/simple method)
    fn generateExecutiveSummary(self: *ClaudeClient, content: processor.ProcessedContent) ![]const u8 {
        const claude_response = try self.executeClaude(try std.fmt.allocPrint(self.allocator,
            \\Write a brief executive summary of today's AI developments based on {d} items from sources including Reddit discussions, research papers, YouTube videos, and industry news.
            \\Focus on the most significant trends and developments.
            \\
            \\Keep it to 2-3 sentences maximum.
            \\
        , .{content.stats.final_item_count}));
        defer self.allocator.free(claude_response);
        
        // For now, return a simple extracted summary
        // TODO: Parse JSON response properly
        return std.fmt.allocPrint(self.allocator,
            \\Today's AI news features {d} carefully curated items spanning research breakthroughs, industry developments, and community insights. 
            \\Notable highlights include cutting-edge research papers, significant model releases, and valuable educational content for AI practitioners.
            \\The coverage represents a comprehensive view of current AI ecosystem activity across academic, commercial, and community spheres.
        , .{content.stats.final_item_count});
    }
};

/// Content analyzed by Claude with enhanced summaries and insights
pub const AnalyzedContent = struct {
    research_papers: []AnalyzedItem,
    video_highlights: []AnalyzedItem,
    community_highlights: []AnalyzedItem,
    model_releases: []AnalyzedItem,
    industry_news: []AnalyzedItem,
    tutorials_demos: []AnalyzedItem,
    executive_summary: []const u8,
    analysis_timestamp: i64,
    original_stats: processor.ProcessingStats,
    
    pub fn deinit(self: AnalyzedContent, allocator: std.mem.Allocator) void {
        self.freeAnalyzedItems(allocator, self.research_papers);
        self.freeAnalyzedItems(allocator, self.video_highlights);
        self.freeAnalyzedItems(allocator, self.community_highlights);
        self.freeAnalyzedItems(allocator, self.model_releases);
        self.freeAnalyzedItems(allocator, self.industry_news);
        self.freeAnalyzedItems(allocator, self.tutorials_demos);
        allocator.free(self.executive_summary);
    }
    
    fn freeAnalyzedItems(self: AnalyzedContent, allocator: std.mem.Allocator, items: []AnalyzedItem) void {
        _ = self;
        for (items) |item| {
            item.deinit(allocator);
        }
        allocator.free(items);
    }
};

/// Individual item analyzed by Claude
pub const AnalyzedItem = struct {
    original_item: types.NewsItem,
    enhanced_summary: []const u8,
    technical_score: f32,
    relevance_score: f32,
    key_insights: []const u8,
    target_audience: []const u8,
    
    pub fn deinit(self: AnalyzedItem, allocator: std.mem.Allocator) void {
        allocator.free(self.enhanced_summary);
        allocator.free(self.key_insights);
        allocator.free(self.target_audience);
    }
};

/// Content category for parallel analysis
pub const ContentCategory = enum {
    research_papers,
    video_highlights,
    community_highlights,
    model_releases,
    industry_news,
    tutorials_demos,
};

/// Analysis task for parallel processing
pub const AnalysisTask = struct {
    category: ContentCategory,
    items: []types.NewsItem,
    batch_id: u32,
    result: ?[]AnalyzedItem,
    error_info: ?[]const u8,
};

/// Batching configuration for different content types
const BatchConfig = struct {
    max_items_per_batch: u32,
    max_tokens_per_batch: u32,
    avg_tokens_per_item: u32,
    
    const RESEARCH_PAPERS = BatchConfig{ .max_items_per_batch = 3, .max_tokens_per_batch = 8000, .avg_tokens_per_item = 2000 };
    const VIDEO_HIGHLIGHTS = BatchConfig{ .max_items_per_batch = 5, .max_tokens_per_batch = 6000, .avg_tokens_per_item = 800 };
    const COMMUNITY_HIGHLIGHTS = BatchConfig{ .max_items_per_batch = 8, .max_tokens_per_batch = 7000, .avg_tokens_per_item = 600 };
    const MODEL_RELEASES = BatchConfig{ .max_items_per_batch = 4, .max_tokens_per_batch = 7000, .avg_tokens_per_item = 1200 };
    const INDUSTRY_NEWS = BatchConfig{ .max_items_per_batch = 6, .max_tokens_per_batch = 7000, .avg_tokens_per_item = 800 };
    const TUTORIALS_DEMOS = BatchConfig{ .max_items_per_batch = 5, .max_tokens_per_batch = 6000, .avg_tokens_per_item = 800 };
    
    fn getForCategory(category: ContentCategory) BatchConfig {
        return switch (category) {
            .research_papers => RESEARCH_PAPERS,
            .video_highlights => VIDEO_HIGHLIGHTS,
            .community_highlights => COMMUNITY_HIGHLIGHTS,
            .model_releases => MODEL_RELEASES,
            .industry_news => INDUSTRY_NEWS,
            .tutorials_demos => TUTORIALS_DEMOS,
        };
    }
};

/// Worker function for parallel content analysis with batching
fn analyzeContentCategoryWorker(claude_client: *ClaudeClient, task: *AnalysisTask) void {
    const start_time = std.time.milliTimestamp();
    
    const result = switch (task.category) {
        .research_papers => analyzeResearchPapers(claude_client, task.items),
        .video_highlights => claude_client.analyzeVideoContent(task.items),
        .community_highlights => claude_client.analyzeCommunityContent(task.items),
        .model_releases => claude_client.analyzeModelReleases(task.items),
        .industry_news => claude_client.analyzeIndustryNews(task.items),
        .tutorials_demos => claude_client.analyzeTutorialContent(task.items),
    };
    
    const elapsed_ms = std.time.milliTimestamp() - start_time;
    
    if (result) |analyzed_items| {
        task.result = analyzed_items;
        std.log.info("✅ Completed batch {d} for {} category ({d} items) in {d}ms", .{ task.batch_id, task.category, analyzed_items.len, elapsed_ms });
    } else |err| {
        const error_msg = std.fmt.allocPrint(claude_client.allocator, "Batch {d} analysis failed: {}", .{ task.batch_id, err }) catch "Unknown error";
        task.error_info = error_msg;
        std.log.err("❌ Batch {d} analysis failed for {} category: {}", .{ task.batch_id, task.category, err });
    }
}

/// Analyze research papers category
fn analyzeResearchPapers(self: *ClaudeClient, papers: []types.NewsItem) ![]AnalyzedItem {
    if (papers.len == 0) return &[_]AnalyzedItem{};
    
    std.log.info("Analyzing {d} research papers...", .{papers.len});
    
    const prompt = try self.buildResearchAnalysisPrompt(papers);
    defer self.allocator.free(prompt);
    
    const claude_response = try self.executeClaude(prompt);
    defer self.allocator.free(claude_response);
    
    return try self.parseClaudeResponse(claude_response, papers);
}

/// Create intelligently batched tasks for a content category
fn createBatchedTasks(self: *ClaudeClient, tasks: *std.ArrayList(AnalysisTask), category: ContentCategory, items: []types.NewsItem) !void {
    if (items.len == 0) return;
    
    const batch_config = BatchConfig.getForCategory(category);
    var batch_id: u32 = 0;
    var current_batch_size: u32 = 0;
    var current_batch_tokens: u32 = 0;
    var batch_start: usize = 0;
    
    std.log.info("Creating intelligent batches for {} category ({d} items)", .{ category, items.len });
    
    for (items, 0..) |item, i| {
        // Estimate tokens for this item (title + summary + metadata)
        const estimated_tokens = estimateTokens(self, item);
        
        // Check if adding this item would exceed limits
        const would_exceed_items = current_batch_size >= batch_config.max_items_per_batch;
        const would_exceed_tokens = current_batch_tokens + estimated_tokens > batch_config.max_tokens_per_batch;
        
        if ((would_exceed_items or would_exceed_tokens) and current_batch_size > 0) {
            // Finalize current batch
            try tasks.append(AnalysisTask{
                .category = category,
                .items = items[batch_start..i],
                .batch_id = batch_id,
                .result = null,
                .error_info = null,
            });
            
            std.log.debug("Created batch {d} for {}: {d} items, ~{d} tokens", .{ batch_id, category, current_batch_size, current_batch_tokens });
            
            // Start new batch
            batch_id += 1;
            batch_start = i;
            current_batch_size = 0;
            current_batch_tokens = 0;
        }
        
        // Add item to current batch
        current_batch_size += 1;
        current_batch_tokens += estimated_tokens;
    }
    
    // Finalize last batch if it has items
    if (current_batch_size > 0) {
        try tasks.append(AnalysisTask{
            .category = category,
            .items = items[batch_start..],
            .batch_id = batch_id,
            .result = null,
            .error_info = null,
        });
        
        std.log.debug("Created final batch {d} for {}: {d} items, ~{d} tokens", .{ batch_id, category, current_batch_size, current_batch_tokens });
    }
    
    std.log.info("Created {d} batches for {} category", .{ batch_id + 1, category });
}

/// Estimate token count for a news item (rough approximation)
fn estimateTokens(self: *ClaudeClient, item: types.NewsItem) u32 {
    _ = self;
    
    // Rough estimation: 1 token ~= 4 characters for English text
    var char_count: u32 = @intCast(item.title.len + item.summary.len);
    
    // Add metadata character counts
    if (item.reddit_metadata) |reddit| {
        char_count += @intCast(reddit.subreddit.len + reddit.author.len);
    }
    if (item.youtube_metadata) |youtube| {
        char_count += @intCast(youtube.channel_name.len + youtube.duration.len);
        if (youtube.transcript) |transcript| {
            char_count += @intCast(@min(transcript.len, 1000)); // Cap transcript at 1000 chars for estimation
        }
    }
    if (item.huggingface_metadata) |hf| {
        char_count += @intCast(hf.abstract.len);
        for (hf.authors) |author| {
            char_count += @intCast(author.len);
        }
    }
    
    // Convert chars to tokens (rough estimate)
    const estimated_tokens = char_count / 4;
    
    // Add base prompt overhead (varies by category)
    return estimated_tokens + 200; // ~200 tokens for prompt overhead
}

// Test function
test "Claude client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const claude_client = ClaudeClient.init(allocator, "sonnet");
    
    try std.testing.expect(std.mem.eql(u8, claude_client.claude_model, "sonnet"));
}