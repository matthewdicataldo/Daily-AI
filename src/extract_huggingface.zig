const std = @import("std");
const types = @import("core_types.zig");
const firecrawl = @import("external_firecrawl.zig");
const config = @import("core_config.zig");

pub const HuggingFaceClient = struct {
    allocator: std.mem.Allocator,
    firecrawl_client: *firecrawl.FirecrawlClient,
    
    pub fn init(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) HuggingFaceClient {
        return HuggingFaceClient{
            .allocator = allocator,
            .firecrawl_client = firecrawl_client,
        };
    }
    
    /// Extract trending papers from Hugging Face using comptime configuration
    pub fn extractTrendingPapers(self: *HuggingFaceClient, source: config.ResearchSource) ![]types.NewsItem {
        // Scrape the papers page
        const response = try self.firecrawl_client.scrape(source.url, .{
            .only_main_content = true,
            .include_links = true,
            .wait_for = 3000, // Wait for content to load
        });
        defer response.deinit(self.allocator);
        
        if (!response.success) {
            std.log.err("Failed to scrape Hugging Face papers: {s}", .{response.@"error" orelse "Unknown error"});
            return types.AppError.FirecrawlError;
        }
        
        const markdown = response.data.?.markdown orelse {
            std.log.warn("No markdown content for Hugging Face papers", .{});
            return &[_]types.NewsItem{};
        };
        
        // Parse papers from markdown content
        return try self.parsePapersMarkdown(markdown, source);
    }
    
    /// Parse Hugging Face papers markdown content
    fn parsePapersMarkdown(self: *HuggingFaceClient, markdown: []const u8, source: config.ResearchSource) ![]types.NewsItem {
        var papers = std.ArrayList(types.NewsItem).init(self.allocator);
        defer {
            for (papers.items) |paper| {
                paper.deinit(self.allocator);
            }
            papers.deinit();
        }
        
        var lines = std.mem.splitScalar(u8, markdown, '\n');
        var current_paper: ?PartialPaper = null;
        var paper_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Look for paper titles and links
            if (self.isPaperLink(trimmed)) {
                // Save previous paper if exists
                if (current_paper) |paper| {
                    if (try self.shouldIncludePaper(paper, source)) {
                        const news_item = try self.convertToNewsItem(paper, source);
                        try papers.append(news_item);
                        paper_count += 1;
                        
                        if (paper_count >= source.max_papers) break;
                    }
                    current_paper.?.deinit(self.allocator);
                }
                
                // Start new paper
                current_paper = try self.parsePaperLink(trimmed);
            } else if (current_paper != null) {
                // Look for additional metadata (authors, abstract, etc.)
                try self.addPaperMetadata(&current_paper.?, trimmed);
            }
        }
        
        // Handle last paper
        if (current_paper) |paper| {
            if (try self.shouldIncludePaper(paper, source)) {
                const news_item = try self.convertToNewsItem(paper, source);
                try papers.append(news_item);
            }
            current_paper.?.deinit(self.allocator);
        }
        
        const result = try papers.toOwnedSlice();
        papers = std.ArrayList(types.NewsItem).init(self.allocator); // Prevent cleanup
        return result;
    }
    
    fn isPaperLink(self: *HuggingFaceClient, line: []const u8) bool {
        _ = self;
        
        // Look for Hugging Face paper URLs
        if (std.mem.indexOf(u8, line, "huggingface.co/papers/") != null) {
            return true;
        }
        
        // Look for arXiv links (common in paper listings)
        if (std.mem.indexOf(u8, line, "arxiv.org/abs/") != null) {
            return true;
        }
        
        // Look for paper title patterns in markdown links
        if (std.mem.startsWith(u8, line, "[") and std.mem.indexOf(u8, line, "](") != null) {
            const title_end = std.mem.indexOf(u8, line, "](").?;
            const title = line[1..title_end];
            
            // Check if title looks like a research paper (long, technical)
            if (title.len > 20 and 
                (std.mem.indexOf(u8, title, ":") != null or 
                 std.mem.indexOf(u8, title, "Learning") != null or
                 std.mem.indexOf(u8, title, "Neural") != null or
                 std.mem.indexOf(u8, title, "Model") != null)) {
                return true;
            }
        }
        
        return false;
    }
    
    fn parsePaperLink(self: *HuggingFaceClient, line: []const u8) !PartialPaper {
        var paper = PartialPaper{
            .title = try self.allocator.dupe(u8, ""),
            .url = try self.allocator.dupe(u8, ""),
            .paper_id = try self.allocator.dupe(u8, ""),
            .authors = std.ArrayList([]u8).init(self.allocator),
            .abstract = std.ArrayList(u8).init(self.allocator),
            .publication_date = try self.allocator.dupe(u8, ""),
            .likes = 0,
            .downloads = 0,
            .trending_score = 0.0,
            .arxiv_id = try self.allocator.dupe(u8, ""),
            .github_repo = try self.allocator.dupe(u8, ""),
            .allocator = self.allocator,
        };
        
        // Extract title and URL from markdown link format [title](url)
        if (std.mem.indexOf(u8, line, "[") != null and std.mem.indexOf(u8, line, "](") != null) {
            const title_start = std.mem.indexOf(u8, line, "[").? + 1;
            const title_end = std.mem.indexOf(u8, line, "](").?;
            const url_start = title_end + 2;
            const url_end = std.mem.indexOf(u8, line[url_start..], ")");
            
            if (title_end > title_start) {
                self.allocator.free(paper.title);
                paper.title = try self.allocator.dupe(u8, line[title_start..title_end]);
            }
            
            if (url_end != null and url_start < line.len) {
                self.allocator.free(paper.url);
                const url_slice = line[url_start..url_start + url_end.?];
                paper.url = try self.allocator.dupe(u8, url_slice);
                
                // Extract paper ID from URL
                self.allocator.free(paper.paper_id);
                paper.paper_id = try self.extractPaperId(url_slice);
                
                // Extract arXiv ID if present
                if (std.mem.indexOf(u8, url_slice, "arxiv.org/abs/")) |_| {
                    self.allocator.free(paper.arxiv_id);
                    paper.arxiv_id = try self.extractArxivId(url_slice);
                }
            }
        }
        
        return paper;
    }
    
    fn addPaperMetadata(self: *HuggingFaceClient, paper: *PartialPaper, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Look for author information
        if (std.mem.indexOf(u8, trimmed, "Author") != null or 
           std.mem.indexOf(u8, trimmed, "by ") != null) {
            try self.parseAuthors(paper, trimmed);
        }
        
        // Look for metrics (likes, downloads)
        if (std.mem.indexOf(u8, trimmed, "like") != null or std.mem.indexOf(u8, trimmed, "♥") != null) {
            paper.likes = self.extractNumber(trimmed, "like") orelse paper.likes;
        }
        
        if (std.mem.indexOf(u8, trimmed, "download") != null) {
            paper.downloads = self.extractNumber(trimmed, "download") orelse paper.downloads;
        }
        
        // Look for publication dates
        if (self.isDateLine(trimmed)) {
            self.allocator.free(paper.publication_date);
            paper.publication_date = try self.allocator.dupe(u8, trimmed);
        }
        
        // Look for GitHub repository links
        if (std.mem.indexOf(u8, trimmed, "github.com") != null) {
            self.allocator.free(paper.github_repo);
            paper.github_repo = try self.extractGithubUrl(trimmed);
        }
        
        // Add to abstract if it looks like descriptive content
        if (trimmed.len > 30 and 
            !std.mem.containsAtLeast(u8, trimmed, 1, "http") and
            !std.mem.containsAtLeast(u8, trimmed, 1, "[") and
            !std.mem.containsAtLeast(u8, trimmed, 1, "#")) {
            try paper.abstract.appendSlice(trimmed);
            try paper.abstract.append(' ');
        }
    }
    
    fn parseAuthors(self: *HuggingFaceClient, paper: *PartialPaper, line: []const u8) !void {
        // Simple author parsing - look for names after "by" or "Author:"
        var author_text = line;
        
        if (std.mem.indexOf(u8, line, "by ")) |pos| {
            author_text = line[pos + 3..];
        } else if (std.mem.indexOf(u8, line, "Author")) |pos| {
            if (std.mem.indexOf(u8, line[pos..], ":")) |colon_pos| {
                author_text = line[pos + colon_pos + 1..];
            }
        }
        
        // Split by common delimiters
        var author_split = std.mem.splitScalar(u8, author_text, ',');
        while (author_split.next()) |author| {
            const trimmed_author = std.mem.trim(u8, author, " \t\r");
            if (trimmed_author.len > 2 and trimmed_author.len < 50) {
                const author_copy = try self.allocator.dupe(u8, trimmed_author);
                try paper.authors.append(author_copy);
            }
        }
    }
    
    fn extractPaperId(self: *HuggingFaceClient, url: []const u8) ![]u8 {
        // Extract paper ID from Hugging Face URL
        if (std.mem.indexOf(u8, url, "huggingface.co/papers/")) |pos| {
            const id_start = pos + "huggingface.co/papers/".len;
            const id_end = std.mem.indexOf(u8, url[id_start..], "/") orelse 
                           std.mem.indexOf(u8, url[id_start..], "?") orelse 
                           (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        }
        
        // Fallback: generate ID from URL hash
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(url);
        const hash = hasher.final();
        return std.fmt.allocPrint(self.allocator, "hf_{x}", .{hash});
    }
    
    fn extractArxivId(self: *HuggingFaceClient, url: []const u8) ![]u8 {
        // Extract arXiv ID from URL
        if (std.mem.indexOf(u8, url, "arxiv.org/abs/")) |pos| {
            const id_start = pos + "arxiv.org/abs/".len;
            const id_end = std.mem.indexOf(u8, url[id_start..], "/") orelse 
                           std.mem.indexOf(u8, url[id_start..], "?") orelse 
                           (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        }
        
        return self.allocator.dupe(u8, "");
    }
    
    fn extractGithubUrl(self: *HuggingFaceClient, line: []const u8) ![]u8 {
        if (std.mem.indexOf(u8, line, "github.com")) |pos| {
            // Find the start of the URL
            var url_start = pos;
            while (url_start > 0 and line[url_start - 1] != ' ' and line[url_start - 1] != '(' and line[url_start - 1] != '[') {
                url_start -= 1;
            }
            
            // Find the end of the URL
            var url_end = pos + "github.com".len;
            while (url_end < line.len and line[url_end] != ' ' and line[url_end] != ')' and line[url_end] != ']') {
                url_end += 1;
            }
            
            return self.allocator.dupe(u8, line[url_start..url_end]);
        }
        
        return self.allocator.dupe(u8, "");
    }
    
    fn isDateLine(self: *HuggingFaceClient, line: []const u8) bool {
        _ = self;
        
        // Look for date patterns
        const date_patterns = [_][]const u8{
            "2024", "2023", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "ago", "day"
        };
        
        for (date_patterns) |pattern| {
            if (std.mem.indexOf(u8, line, pattern) != null) {
                return true;
            }
        }
        
        return false;
    }
    
    fn extractNumber(self: *HuggingFaceClient, text: []const u8, _: []const u8) ?u32 {
        _ = self;
        
        // Look for numbers in the text
        var i: usize = 0;
        while (i < text.len) {
            if (std.ascii.isDigit(text[i])) {
                const num_start = i;
                var num_end = i;
                
                // Collect digits and commas
                while (num_end < text.len and (std.ascii.isDigit(text[num_end]) or text[num_end] == ',')) {
                    num_end += 1;
                }
                
                // Parse the number
                const num_str = text[num_start..num_end];
                var clean_num = std.ArrayList(u8).init(std.heap.page_allocator);
                defer clean_num.deinit();
                
                for (num_str) |char| {
                    if (std.ascii.isDigit(char)) {
                        clean_num.append(char) catch continue;
                    }
                }
                
                if (clean_num.items.len > 0) {
                    return std.fmt.parseInt(u32, clean_num.items, 10) catch null;
                }
                
                i = num_end;
            } else {
                i += 1;
            }
        }
        
        return null;
    }
    
    fn shouldIncludePaper(self: *HuggingFaceClient, paper: PartialPaper, source: config.ResearchSource) !bool {
        
        // Filter by minimum downloads if specified
        if (source.min_downloads > 0 and paper.downloads < source.min_downloads) {
            return false;
        }
        
        // Filter by title length
        if (paper.title.len < 15) return false;
        
        // Filter by trending only if specified
        if (source.trending_only and paper.likes < 5) {
            return false;
        }
        
        // Always include papers with substantial abstracts
        if (paper.abstract.items.len > 100) return true;
        
        // Check for AI/ML relevance in title and abstract
        const ai_keywords = [_][]const u8{
            "neural", "learning", "model", "AI", "ML", "deep", "transformer",
            "attention", "embedding", "training", "inference", "language",
            "vision", "classification", "generation", "optimization"
        };
        
        const combined_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ paper.title, paper.abstract.items });
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
    
    fn convertToNewsItem(self: *HuggingFaceClient, paper: PartialPaper, source: config.ResearchSource) !types.NewsItem {
        _ = source;
        
        // Convert authors ArrayList to owned slice
        var authors_slice = try self.allocator.alloc([]const u8, paper.authors.items.len);
        for (paper.authors.items, 0..) |author, i| {
            authors_slice[i] = try self.allocator.dupe(u8, author);
        }
        
        const hf_metadata = types.HuggingFaceMetadata{
            .paper_id = try self.allocator.dupe(u8, paper.paper_id),
            .authors = authors_slice,
            .abstract = try self.allocator.dupe(u8, paper.abstract.items),
            .publication_date = try self.allocator.dupe(u8, paper.publication_date),
            .likes = paper.likes,
            .downloads = paper.downloads,
            .trending_score = paper.trending_score,
            .arxiv_id = if (paper.arxiv_id.len > 0) try self.allocator.dupe(u8, paper.arxiv_id) else null,
            .github_repo = if (paper.github_repo.len > 0) try self.allocator.dupe(u8, paper.github_repo) else null,
        };
        
        // Generate summary from abstract (first 200 chars)
        const abstract_text = paper.abstract.items;
        const summary_len = @min(abstract_text.len, 200);
        var summary: []u8 = undefined;
        if (abstract_text.len > 200) {
            summary = try self.allocator.alloc(u8, summary_len + 3);
            @memcpy(summary[0..summary_len], abstract_text[0..summary_len]);
            @memcpy(summary[summary_len..], "...");
        } else {
            summary = try self.allocator.alloc(u8, summary_len);
            @memcpy(summary, abstract_text[0..summary_len]);
        }
        
        // Calculate relevance score based on likes and downloads
        const like_score = @min(@as(f32, @floatFromInt(paper.likes)) / 50.0, 1.0);
        const download_score = @min(@as(f32, @floatFromInt(paper.downloads)) / 1000.0, 1.0);
        const relevance_score = 0.3 + (like_score * 0.4) + (download_score * 0.3);
        
        return types.NewsItem{
            .title = try self.allocator.dupe(u8, paper.title),
            .summary = summary,
            .url = try self.allocator.dupe(u8, paper.url),
            .source = try self.allocator.dupe(u8, "Hugging Face Papers"),
            .source_type = .research_hub,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = null,
            .huggingface_metadata = hf_metadata,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
};

const PartialPaper = struct {
    title: []u8,
    url: []u8,
    paper_id: []u8,
    authors: std.ArrayList([]u8),
    abstract: std.ArrayList(u8),
    publication_date: []u8,
    likes: u32,
    downloads: u32,
    trending_score: f32,
    arxiv_id: []u8,
    github_repo: []u8,
    allocator: std.mem.Allocator,
    
    fn deinit(self: PartialPaper, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.paper_id);
        
        for (self.authors.items) |author| {
            allocator.free(author);
        }
        self.authors.deinit();
        
        self.abstract.deinit();
        allocator.free(self.publication_date);
        allocator.free(self.arxiv_id);
        allocator.free(self.github_repo);
    }
};

/// Convenience function to extract papers from all configured research sources
pub fn extractAllResearchPapers(allocator: std.mem.Allocator, firecrawl_client: *firecrawl.FirecrawlClient) ![]types.NewsItem {
    var client = HuggingFaceClient.init(allocator, firecrawl_client);
    var all_papers = std.ArrayList(types.NewsItem).init(allocator);
    
    for (config.Config.research_sources) |source| {
        std.log.info("Extracting papers from {s}...", .{source.url});
        
        const papers = client.extractTrendingPapers(source) catch |err| {
            std.log.err("Failed to extract from {s}: {}", .{ source.url, err });
            continue; // Continue with other sources
        };
        
        for (papers) |paper| {
            try all_papers.append(paper);
        }
        
        std.log.info("Extracted {d} papers from research source", .{papers.len});
        allocator.free(papers);
    }
    
    return try all_papers.toOwnedSlice();
}

// Test function
test "HuggingFace client paper ID extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var firecrawl_client = try firecrawl.FirecrawlClient.init(allocator, "test-key");
    defer firecrawl_client.deinit();
    
    var hf_client = HuggingFaceClient.init(allocator, &firecrawl_client);
    
    // Test paper ID extraction
    const paper_id = try hf_client.extractPaperId("https://huggingface.co/papers/2401.12345");
    defer allocator.free(paper_id);
    
    try std.testing.expect(std.mem.eql(u8, paper_id, "2401.12345"));
}