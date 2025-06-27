const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const claude = @import("ai_claude.zig");

pub const BlogGenerator = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8) BlogGenerator {
        return BlogGenerator{
            .allocator = allocator,
            .output_dir = output_dir,
        };
    }
    
    /// Generate complete blog post from analyzed content
    pub fn generateBlogPost(self: *BlogGenerator, analyzed_content: claude.AnalyzedContent) !GeneratedBlog {
        std.log.info("Generating blog post from analyzed content...", .{});
        
        // Ensure output directory exists
        try self.ensureOutputDirectory();
        
        // Generate filename with current date
        const filename = try self.generateFilename();
        defer self.allocator.free(filename);
        
        // Build the blog post content directly from Claude analysis
        const blog_content = try self.buildBlogContent(analyzed_content);
        
        // Write to file
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output_dir, filename });
        defer self.allocator.free(full_path);
        
        try self.writeBlogToFile(full_path, blog_content);
        
        // Generate metadata
        const metadata = GenerationMetadata{
            .filename = try self.allocator.dupe(u8, filename),
            .full_path = try self.allocator.dupe(u8, full_path),
            .word_count = self.countWords(blog_content),
            .character_count = @intCast(blog_content.len),
            .section_count = 2, // Simplified for NPR style
            .generation_time = types.getCurrentTimestamp(),
            .total_items_included = self.countTotalItems(analyzed_content),
        };
        
        return GeneratedBlog{
            .content = blog_content,
            .metadata = metadata,
        };
    }
    
    /// Build complete blog content from analyzed data
    fn buildBlogContent(self: *BlogGenerator, analyzed_content: claude.AnalyzedContent) ![]const u8 {
        // Claude now returns complete markdown blog content in executive_summary
        // Simply return it directly
        return try self.allocator.dupe(u8, analyzed_content.executive_summary);
    }
    
    /// Add simple NPR-style header
    fn addSimpleHeader(self: *BlogGenerator, blog: *std.ArrayList(u8), analyzed_content: claude.AnalyzedContent) !void {
        _ = analyzed_content;
        const date_str = try types.timestampToString(self.allocator, types.getCurrentTimestamp());
        defer self.allocator.free(date_str);
        
        try blog.writer().print(
            \\# AI News: {s}
            \\
            \\
        , .{date_str[0..10]}); // Just the date part YYYY-MM-DD
    }
    
    /// Add lead insight in NPR style - the big story
    fn addLeadInsight(self: *BlogGenerator, blog: *std.ArrayList(u8), summary: []const u8) !void {
        _ = self;
        
        try blog.writer().print(
            \\{s}
            \\
            \\
        , .{summary});
    }
    
    /// Add story body in NPR style - supporting details in narrative form
    fn addStoryBody(self: *BlogGenerator, blog: *std.ArrayList(u8), analyzed_content: claude.AnalyzedContent) !void {
        _ = self;
        
        // Weave together the most important details in narrative form
        var has_content = false;
        
        // Research developments
        if (analyzed_content.research_papers.len > 0) {
            for (analyzed_content.research_papers[0..@min(3, analyzed_content.research_papers.len)]) |paper| {
                try blog.writer().print("{s}\n\n", .{paper.enhanced_summary});
                
                if (paper.original_item.huggingface_metadata) |hf| {
                    if (hf.authors.len > 0) {
                        try blog.writer().print("The research from {s}", .{hf.authors[0]});
                        if (hf.authors.len > 1) {
                            try blog.writer().print(" and colleagues", .{});
                        }
                        try blog.writer().print(" [builds on recent advances]({s}).\n\n", .{paper.original_item.url});
                    }
                }
                has_content = true;
            }
        }
        
        // Community insights
        if (analyzed_content.community_highlights.len > 0) {
            for (analyzed_content.community_highlights[0..@min(2, analyzed_content.community_highlights.len)]) |discussion| {
                try blog.writer().print("{s}\n\n", .{discussion.enhanced_summary});
                
                if (discussion.original_item.reddit_metadata) |reddit| {
                    try blog.writer().print("This perspective from the {s} community [sparked significant discussion]({s}).\n\n", .{ reddit.subreddit, discussion.original_item.url });
                }
                has_content = true;
            }
        }
        
        // Industry developments
        if (analyzed_content.model_releases.len > 0 or analyzed_content.industry_news.len > 0) {
            const items = if (analyzed_content.model_releases.len > 0) analyzed_content.model_releases else analyzed_content.industry_news;
            for (items[0..@min(2, items.len)]) |item| {
                try blog.writer().print("{s}\n\n", .{item.enhanced_summary});
                try blog.writer().print("Read more: [{s}]({s})\n\n", .{ item.original_item.source, item.original_item.url });
                has_content = true;
            }
        }
        
        // Video insights
        if (analyzed_content.video_highlights.len > 0) {
            for (analyzed_content.video_highlights[0..@min(2, analyzed_content.video_highlights.len)]) |video| {
                try blog.writer().print("{s}\n\n", .{video.enhanced_summary});
                
                if (video.original_item.youtube_metadata) |yt| {
                    try blog.writer().print("Watch the full analysis from {s}: [{s}]({s})\n\n", .{ yt.channel_name, video.original_item.title, video.original_item.url });
                }
                has_content = true;
            }
        }
        
        if (!has_content) {
            try blog.appendSlice("No significant developments were identified in today's analysis.\n\n");
        }
    }
    
    /// Enhance blog content with Opus editor
    fn enhanceWithEditor(self: *BlogGenerator, initial_content: []const u8) ![]const u8 {
        // Create temporary file for the initial content
        const temp_filename = try std.fmt.allocPrint(self.allocator, "temp_blog_{d}.txt", .{types.getCurrentTimestamp()});
        defer self.allocator.free(temp_filename);
        
        // Write initial content to temp file
        const temp_file = try std.fs.cwd().createFile(temp_filename, .{});
        defer temp_file.close();
        defer std.fs.cwd().deleteFile(temp_filename) catch {};
        
        try temp_file.writeAll(initial_content);
        
        // Create editor prompt
        const editor_prompt = try std.fmt.allocPrint(self.allocator,
            \\You are an experienced tech journalist and editor. Please enhance the following AI news article to improve:
            \\
            \\1. Narrative flow and readability
            \\2. Technical accuracy and clarity  
            \\3. Source credibility verification (use web search tools to verify key claims)
            \\4. Engagement and human interest
            \\5. Professional journalistic style (NPR/Vox level)
            \\
            \\Please verify any factual claims using web search tools when needed. Make the piece more engaging while maintaining accuracy.
            \\
            \\Original article:
            \\{s}
            \\
            \\Please return only the enhanced article text.
        , .{initial_content});
        defer self.allocator.free(editor_prompt);
        
        // Create temporary prompt file
        const prompt_filename = try std.fmt.allocPrint(self.allocator, "editor_prompt_{d}.txt", .{types.getCurrentTimestamp()});
        defer self.allocator.free(prompt_filename);
        
        const prompt_file = try std.fs.cwd().createFile(prompt_filename, .{});
        defer prompt_file.close();
        defer std.fs.cwd().deleteFile(prompt_filename) catch {};
        
        try prompt_file.writeAll(editor_prompt);
        
        // Execute Claude command safely without shell injection
        // Validate prompt filename to prevent injection
        if (std.mem.indexOf(u8, prompt_filename, "..") != null or 
            std.mem.indexOf(u8, prompt_filename, ";") != null or 
            std.mem.indexOf(u8, prompt_filename, "|") != null or 
            std.mem.indexOf(u8, prompt_filename, "&") != null or 
            std.mem.indexOf(u8, prompt_filename, "`") != null or 
            std.mem.indexOf(u8, prompt_filename, "$") != null) {
            std.log.err("Unsafe filename detected: {s}", .{prompt_filename});
            return try self.allocator.dupe(u8, initial_content);
        }
        
        std.log.info("Executing Claude Opus editor with file: {s}", .{prompt_filename});
        
        // Execute Claude directly with validated arguments - no shell involved
        var child = std.process.Child.init(&[_][]const u8{ 
            "claude", 
            prompt_filename,
            "--model", 
            "opus", 
            "--max-turns", 
            "5",
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
            return try self.allocator.dupe(u8, initial_content);
        };
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);
        
        const exit_code = try child.wait();
        
        if (exit_code != .Exited or exit_code.Exited != 0) {
            std.log.err("Claude Opus editor failed with exit code: {}", .{exit_code});
            std.log.err("stderr: {s}", .{stderr});
            // Fallback to original content
            return try self.allocator.dupe(u8, initial_content);
        }
        
        return stdout;
    }
    
    /// Add research papers section
    fn addResearchSection(self: *BlogGenerator, blog: *std.ArrayList(u8), papers: []claude.AnalyzedItem) !void {
        _ = self;
        try blog.writer().print("## 🔬 Research Papers\n\n*{d} papers covering the latest AI/ML research*\n\n", .{papers.len});
        
        for (papers, 1..) |paper, i| {
            try blog.writer().print("### {d}. {s}\n\n", .{ i, paper.original_item.title });
            
            // Enhanced summary from Claude
            try blog.writer().print("**Summary:** {s}\n\n", .{paper.enhanced_summary});
            
            // Metadata
            if (paper.original_item.huggingface_metadata) |hf| {
                if (hf.authors.len > 0) {
                    try blog.writer().print("**Authors:** {s}", .{hf.authors[0]});
                    if (hf.authors.len > 1) {
                        try blog.writer().print(" et al. ({d} authors)", .{hf.authors.len});
                    }
                    try blog.appendSlice("\n\n");
                }
                
                if (hf.likes > 0 or hf.downloads > 0) {
                    try blog.writer().print("**Metrics:** ", .{});
                    if (hf.likes > 0) try blog.writer().print("❤️ {d} likes ", .{hf.likes});
                    if (hf.downloads > 0) try blog.writer().print("⬇️ {d} downloads", .{hf.downloads});
                    try blog.appendSlice("\n\n");
                }
                
                if (hf.github_repo != null and hf.github_repo.?.len > 0) {
                    try blog.writer().print("**Code:** [{s}]({s})\n\n", .{ hf.github_repo.?, hf.github_repo.? });
                }
            }
            
            // Scores and insights from Claude
            try blog.writer().print(
                \\**AI Analysis:**
                \\- Technical Score: {d:.1}/10
                \\- Relevance Score: {d:.1}/10
                \\- Key Insights: {s}
                \\- Target Audience: {s}
                \\
                \\**Source:** [{s}]({s})
                \\
                \\---
                \\
                \\
            , .{
                paper.technical_score,
                paper.relevance_score,
                paper.key_insights,
                paper.target_audience,
                paper.original_item.source,
                paper.original_item.url,
            });
        }
    }
    
    /// Add video highlights section
    fn addVideoSection(self: *BlogGenerator, blog: *std.ArrayList(u8), videos: []claude.AnalyzedItem) !void {
        _ = self;
        try blog.writer().print("## 🎥 Video Highlights\n\n*{d} videos from top AI/tech creators*\n\n", .{videos.len});
        
        for (videos, 1..) |video, i| {
            try blog.writer().print("### {d}. {s}\n\n", .{ i, video.original_item.title });
            
            // Enhanced summary from Claude
            try blog.writer().print("**Summary:** {s}\n\n", .{video.enhanced_summary});
            
            // Video metadata
            if (video.original_item.youtube_metadata) |yt| {
                try blog.writer().print("**Channel:** {s}\n", .{yt.channel_name});
                if (yt.view_count > 0) try blog.writer().print("**Views:** {d}\n", .{yt.view_count});
                if (yt.duration.len > 0) try blog.writer().print("**Duration:** {s}\n", .{yt.duration});
                try blog.appendSlice("\n");
            }
            
            // Scores and insights from Claude
            try blog.writer().print(
                \\**AI Analysis:**
                \\- Educational Value: {d:.1}/10
                \\- Technical Depth: {d:.1}/10
                \\- Key Insights: {s}
                \\- Recommended For: {s}
                \\
                \\**Watch:** [{s}]({s})
                \\
                \\---
                \\
                \\
            , .{
                video.technical_score,
                video.relevance_score,
                video.key_insights,
                video.target_audience,
                video.original_item.source,
                video.original_item.url,
            });
        }
    }
    
    /// Add community highlights section
    fn addCommunitySection(self: *BlogGenerator, blog: *std.ArrayList(u8), discussions: []claude.AnalyzedItem) !void {
        _ = self;
        try blog.writer().print("## 💬 Community Highlights\n\n*{d} top discussions from Reddit AI communities*\n\n", .{discussions.len});
        
        for (discussions, 1..) |discussion, i| {
            // Natural paragraph format without headers
            try blog.writer().print("{d}. **{s}**\n\n", .{ i, discussion.original_item.title });
            
            // Enhanced summary from Claude as natural paragraph
            try blog.writer().print("{s}\n\n", .{discussion.enhanced_summary});
            
            // Add author attribution naturally
            if (discussion.original_item.reddit_metadata) |reddit| {
                try blog.writer().print("— u/{s} on r/{s}", .{ reddit.author, reddit.subreddit });
                
                // Add comment count if significant
                if (reddit.comment_count > 5) {
                    try blog.writer().print(" ({d} comments)", .{reddit.comment_count});
                }
                try blog.appendSlice("\n\n");
            }
            
            // Add source link naturally
            try blog.writer().print("[Continue reading →]({s})\n\n", .{discussion.original_item.url});
            
            // Simple separator
            if (i < discussions.len) {
                try blog.appendSlice("---\n\n");
            }
        }
    }
    
    /// Add model releases section
    fn addModelReleaseSection(self: *BlogGenerator, blog: *std.ArrayList(u8), releases: []claude.AnalyzedItem) !void {
        try blog.writer().print("## 🚀 Model Releases\n\n*{d} new AI models and product announcements*\n\n", .{releases.len});
        
        for (releases, 1..) |release, i| {
            try self.addStandardItem(blog, release, i, "🚀");
        }
    }
    
    /// Add industry news section
    fn addIndustrySection(self: *BlogGenerator, blog: *std.ArrayList(u8), news: []claude.AnalyzedItem) !void {
        try blog.writer().print("## 📰 Industry News\n\n*{d} important developments in the AI industry*\n\n", .{news.len});
        
        for (news, 1..) |item, i| {
            try self.addStandardItem(blog, item, i, "📰");
        }
    }
    
    /// Add tutorials section
    fn addTutorialSection(self: *BlogGenerator, blog: *std.ArrayList(u8), tutorials: []claude.AnalyzedItem) !void {
        try blog.writer().print("## 📚 Tutorials & Demos\n\n*{d} educational resources and practical guides*\n\n", .{tutorials.len});
        
        for (tutorials, 1..) |tutorial, i| {
            try self.addStandardItem(blog, tutorial, i, "📚");
        }
    }
    
    /// Add standard item format (used by multiple sections)
    fn addStandardItem(self: *BlogGenerator, blog: *std.ArrayList(u8), item: claude.AnalyzedItem, index: usize, emoji: []const u8) !void {
        _ = self;
        
        try blog.writer().print("### {d}. {s} {s}\n\n", .{ index, emoji, item.original_item.title });
        
        // Enhanced summary from Claude
        try blog.writer().print("**Summary:** {s}\n\n", .{item.enhanced_summary});
        
        // Scores and insights from Claude
        try blog.writer().print(
            \\**AI Analysis:**
            \\- Technical Score: {d:.1}/10
            \\- Impact Score: {d:.1}/10
            \\- Key Insights: {s}
            \\- Target Audience: {s}
            \\
            \\**Source:** [{s}]({s})
            \\
            \\---
            \\
            \\
        , .{
            item.technical_score,
            item.relevance_score,
            item.key_insights,
            item.target_audience,
            item.original_item.source,
            item.original_item.url,
        });
    }
    
    /// Add simple footer with attribution
    fn addSimpleFooter(self: *BlogGenerator, blog: *std.ArrayList(u8), analyzed_content: claude.AnalyzedContent) !void {
        const total_items = self.countTotalItems(analyzed_content);
        
        try blog.writer().print(
            \\---
            \\
            \\*Analysis compiled from {d} sources including Reddit communities, research papers, and industry blogs.*
            \\
        , .{total_items});
    }
    
    /// Ensure output directory exists
    fn ensureOutputDirectory(self: *BlogGenerator) !void {
        std.fs.cwd().makeDir(self.output_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Directory exists, that's fine
            else => return err,
        };
    }
    
    /// Generate filename based on current date
    fn generateFilename(self: *BlogGenerator) ![]const u8 {
        const now = types.getCurrentTimestamp();
        const date_str = try types.timestampToString(self.allocator, now);
        defer self.allocator.free(date_str);
        
        // Extract just the date part (YYYY-MM-DD)
        const date_part = date_str[0..10];
        
        return std.fmt.allocPrint(self.allocator, "ai-news-{s}.md", .{date_part});
    }
    
    /// Write blog content to file
    fn writeBlogToFile(self: *BlogGenerator, file_path: []const u8, content: []const u8) !void {
        _ = self;
        
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        try file.writeAll(content);
        
        std.log.info("Blog post written to: {s}", .{file_path});
    }
    
    /// Count words in content
    fn countWords(self: *BlogGenerator, content: []const u8) u32 {
        _ = self;
        
        var word_count: u32 = 0;
        var in_word = false;
        
        for (content) |char| {
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
    
    /// Count sections in analyzed content
    fn countSections(self: *BlogGenerator, analyzed_content: claude.AnalyzedContent) u32 {
        _ = self;
        
        var section_count: u32 = 1; // Executive summary
        
        if (analyzed_content.research_papers.len > 0) section_count += 1;
        if (analyzed_content.video_highlights.len > 0) section_count += 1;
        if (analyzed_content.community_highlights.len > 0) section_count += 1;
        if (analyzed_content.model_releases.len > 0) section_count += 1;
        if (analyzed_content.industry_news.len > 0) section_count += 1;
        if (analyzed_content.tutorials_demos.len > 0) section_count += 1;
        
        return section_count;
    }
    
    /// Count total items across all categories
    fn countTotalItems(self: *BlogGenerator, analyzed_content: claude.AnalyzedContent) u32 {
        _ = self;
        
        return @as(u32, @intCast(
            analyzed_content.research_papers.len +
            analyzed_content.video_highlights.len +
            analyzed_content.community_highlights.len +
            analyzed_content.model_releases.len +
            analyzed_content.industry_news.len +
            analyzed_content.tutorials_demos.len
        ));
    }
};

/// Generated blog post with metadata
pub const GeneratedBlog = struct {
    content: []const u8,
    metadata: GenerationMetadata,
    
    pub fn deinit(self: GeneratedBlog, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.metadata.deinit(allocator);
    }
};

/// Metadata about the generated blog post
pub const GenerationMetadata = struct {
    filename: []const u8,
    full_path: []const u8,
    word_count: u32,
    character_count: u32,
    section_count: u32,
    generation_time: i64,
    total_items_included: u32,
    
    pub fn deinit(self: GenerationMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.full_path);
    }
};

// Test function
test "blog generator filename generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var generator = BlogGenerator.init(allocator, "./output");
    
    const filename = try generator.generateFilename();
    defer allocator.free(filename);
    
    try std.testing.expect(std.mem.startsWith(u8, filename, "ai-news-"));
    try std.testing.expect(std.mem.endsWith(u8, filename, ".md"));
}