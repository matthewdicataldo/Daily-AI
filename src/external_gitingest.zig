const std = @import("std");
const network = @import("network");
const types = @import("core_types.zig");
const http = @import("common_http.zig");

/// GitIngest integration module for analyzing GitHub repositories
/// Currently uses URL transformation method since GitIngest API is not public
/// Will be updated to use official API when available

const GitIngestError = error{
    InvalidGitHubUrl,
    NetworkError,
    ParsingError,
    RateLimitExceeded,
    RepositoryNotFound,
    GitIngestServiceError,
};

pub const GitIngestClient = struct {
    allocator: std.mem.Allocator,
    http_client: *http.HttpClient,
    
    pub fn init(allocator: std.mem.Allocator, http_client: *http.HttpClient) GitIngestClient {
        return GitIngestClient{
            .allocator = allocator,
            .http_client = http_client,
        };
    }
    
    /// Extract GitHub repository information using GitIngest service
    /// Input: GitHub repository URL (e.g., "https://github.com/owner/repo")
    /// Returns: Repository content digest and metadata
    pub fn analyzeRepository(self: *GitIngestClient, github_url: []const u8) !RepositoryAnalysis {
        // Validate and parse GitHub URL
        const repo_info = try self.parseGitHubUrl(github_url);
        defer repo_info.deinit(self.allocator);
        
        // Transform GitHub URL to GitIngest URL
        const gitingest_url = try self.createGitIngestUrl(repo_info);
        defer self.allocator.free(gitingest_url);
        
        // Fetch repository digest from GitIngest
        const digest_content = try self.fetchRepositoryDigest(gitingest_url);
        defer self.allocator.free(digest_content);
        
        // Parse the digest content to extract insights
        const analysis = try self.parseRepositoryDigest(repo_info, digest_content);
        
        return analysis;
    }
    
    /// Batch analyze multiple GitHub repositories
    pub fn analyzeRepositories(self: *GitIngestClient, github_urls: []const []const u8) ![]RepositoryAnalysis {
        var analyses = try self.allocator.alloc(RepositoryAnalysis, github_urls.len);
        var successful_count: usize = 0;
        
        for (github_urls, 0..) |url, i| {
            _ = i; // Explicitly discard the index
            if (self.analyzeRepository(url)) |analysis| {
                analyses[successful_count] = analysis;
                successful_count += 1;
            } else |err| {
                std.log.warn("Failed to analyze repository {s}: {}", .{ url, err });
                // Continue with other repositories
            }
        }
        
        // Resize array to only include successful analyses
        if (successful_count < analyses.len) {
            const resized = try self.allocator.realloc(analyses, successful_count);
            return resized;
        }
        
        return analyses;
    }
    
    /// Extract GitHub URLs from text content (news articles, comments, etc.)
    pub fn extractGitHubUrls(self: *GitIngestClient, content: []const u8) ![][]const u8 {
        var urls = std.ArrayList([]const u8).init(self.allocator);
        defer urls.deinit();
        
        // Simple regex-like pattern matching for GitHub URLs
        var index: usize = 0;
        while (index < content.len) {
            if (std.mem.indexOf(u8, content[index..], "https://github.com/")) |start_offset| {
                const start = index + start_offset;
                const url_start = start;
                
                // Find end of URL (whitespace, punctuation, or end of string)
                var url_end = url_start + 19; // Length of "https://github.com/"
                while (url_end < content.len and 
                       !std.ascii.isWhitespace(content[url_end]) and
                       content[url_end] != ')' and 
                       content[url_end] != ']' and
                       content[url_end] != ',' and
                       content[url_end] != '.' and
                       content[url_end] != ';') {
                    url_end += 1;
                }
                
                const url = content[url_start..url_end];
                
                // Validate URL format (owner/repo pattern)
                if (self.isValidGitHubRepoUrl(url)) {
                    const owned_url = try self.allocator.dupe(u8, url);
                    try urls.append(owned_url);
                }
                
                index = url_end;
            } else {
                break;
            }
        }
        
        return try urls.toOwnedSlice();
    }
    
    // Private helper methods
    
    fn parseGitHubUrl(self: *GitIngestClient, url: []const u8) !RepoInfo {
        if (!std.mem.startsWith(u8, url, "https://github.com/")) {
            return GitIngestError.InvalidGitHubUrl;
        }
        
        const path_start = "https://github.com/".len;
        const path = url[path_start..];
        
        // Find owner/repo separator
        if (std.mem.indexOf(u8, path, "/")) |separator_idx| {
            const owner = path[0..separator_idx];
            var repo = path[separator_idx + 1..];
            
            // Remove .git suffix if present
            if (std.mem.endsWith(u8, repo, ".git")) {
                repo = repo[0..repo.len - 4];
            }
            
            // Remove any additional path components or query parameters
            if (std.mem.indexOf(u8, repo, "/")) |slash_idx| {
                repo = repo[0..slash_idx];
            }
            if (std.mem.indexOf(u8, repo, "?")) |query_idx| {
                repo = repo[0..query_idx];
            }
            
            return RepoInfo{
                .owner = try self.allocator.dupe(u8, owner),
                .repo = try self.allocator.dupe(u8, repo),
                .full_url = try self.allocator.dupe(u8, url),
            };
        }
        
        return GitIngestError.InvalidGitHubUrl;
    }
    
    fn createGitIngestUrl(self: *GitIngestClient, repo_info: RepoInfo) ![]const u8 {
        // Transform GitHub URL to GitIngest URL
        // Replace "https://github.com" with "https://gitingest.com"
        return try std.fmt.allocPrint(self.allocator, "https://gitingest.com/{s}/{s}", .{ repo_info.owner, repo_info.repo });
    }
    
    fn fetchRepositoryDigest(self: *GitIngestClient, gitingest_url: []const u8) ![]const u8 {
        const headers = [_]types.HttpRequest.Header{
            .{ .name = "User-Agent", .value = "AI-News-Generator/1.0" },
            .{ .name = "Accept", .value = "text/plain" },
        };
        
        const request = types.HttpRequest{
            .method = .GET,
            .url = gitingest_url,
            .headers = @constCast(&headers),
            .body = null,
        };
        
        const response = self.http_client.makeRequest(request) catch |err| switch (err) {
            error.HttpError => return GitIngestError.GitIngestServiceError,
            error.NetworkError => return GitIngestError.NetworkError,
            else => return err,
        };
        defer response.deinit(self.allocator);
        
        switch (response.status_code) {
            200 => {
                return try self.allocator.dupe(u8, response.body);
            },
            404 => return GitIngestError.RepositoryNotFound,
            429 => return GitIngestError.RateLimitExceeded,
            else => return GitIngestError.GitIngestServiceError,
        }
    }
    
    fn parseRepositoryDigest(self: *GitIngestClient, repo_info: RepoInfo, digest_content: []const u8) !RepositoryAnalysis {
        var analysis = RepositoryAnalysis{
            .repo_url = try self.allocator.dupe(u8, repo_info.full_url),
            .owner = try self.allocator.dupe(u8, repo_info.owner),
            .repo_name = try self.allocator.dupe(u8, repo_info.repo),
            .digest_content = try self.allocator.dupe(u8, digest_content),
            .file_count = 0,
            .total_lines = 0,
            .primary_language = null,
            .languages = null,
            .key_files = null,
            .readme_summary = null,
            .architecture_insights = null,
        };
        
        // Parse basic statistics from digest
        analysis.file_count = self.countFiles(digest_content);
        analysis.total_lines = self.countLines(digest_content);
        
        // Extract language information
        analysis.languages = self.extractLanguages(digest_content) catch null;
        if (analysis.languages) |langs| {
            if (langs.len > 0) {
                analysis.primary_language = try self.allocator.dupe(u8, langs[0].name);
            }
        }
        
        // Extract key files
        analysis.key_files = self.extractKeyFiles(digest_content) catch null;
        
        // Extract README content if present
        analysis.readme_summary = self.extractReadmeSummary(digest_content) catch null;
        
        return analysis;
    }
    
    fn countFiles(self: *GitIngestClient, content: []const u8) u32 {
        _ = self;
        var count: u32 = 0;
        var lines = std.mem.splitSequence(u8, content, "\n");
        
        while (lines.next()) |line| {
            // Look for file path patterns (simple heuristic)
            if (std.mem.startsWith(u8, line, "## ") or 
                std.mem.startsWith(u8, line, "### ") or
                std.mem.indexOf(u8, line, ".") != null) {
                count += 1;
            }
        }
        
        return count;
    }
    
    fn countLines(self: *GitIngestClient, content: []const u8) u32 {
        _ = self;
        var count: u32 = 0;
        var lines = std.mem.splitSequence(u8, content, "\n");
        
        while (lines.next()) |_| {
            count += 1;
        }
        
        return count;
    }
    
    fn extractLanguages(self: *GitIngestClient, content: []const u8) ![]LanguageInfo {
        _ = content;
        // Placeholder implementation - would need more sophisticated parsing
        var languages = try self.allocator.alloc(LanguageInfo, 1);
        languages[0] = LanguageInfo{
            .name = try self.allocator.dupe(u8, "Unknown"),
            .percentage = 100.0,
            .lines_of_code = 0,
        };
        return languages;
    }
    
    fn extractKeyFiles(self: *GitIngestClient, content: []const u8) ![]KeyFileInfo {
        _ = content;
        // Placeholder implementation
        const files = try self.allocator.alloc(KeyFileInfo, 0);
        return files;
    }
    
    fn extractReadmeSummary(self: *GitIngestClient, content: []const u8) ![]const u8 {
        // Look for README content in the digest
        if (std.mem.indexOf(u8, content, "README")) |readme_start| {
            // Extract first few lines after README heading
            var lines = std.mem.splitSequence(u8, content[readme_start..], "\n");
            var summary = std.ArrayList(u8).init(self.allocator);
            defer summary.deinit();
            
            var line_count: u32 = 0;
            while (lines.next()) |line| {
                if (line_count > 0 and line_count < 5) { // Skip title, take next 4 lines
                    try summary.appendSlice(line);
                    try summary.append('\n');
                }
                line_count += 1;
                if (line_count >= 5) break;
            }
            
            return try summary.toOwnedSlice();
        }
        
        return GitIngestError.ParsingError;
    }
    
    fn isValidGitHubRepoUrl(self: *GitIngestClient, url: []const u8) bool {
        _ = self;
        if (!std.mem.startsWith(u8, url, "https://github.com/")) {
            return false;
        }
        
        const path = url["https://github.com/".len..];
        const slash_count = std.mem.count(u8, path, "/");
        
        // Valid repo URL should have at least owner/repo (1 slash)
        // But not too many path components
        return slash_count >= 1 and slash_count <= 3;
    }
};

// Data structures for repository analysis

const RepoInfo = struct {
    owner: []const u8,
    repo: []const u8,
    full_url: []const u8,
    
    fn deinit(self: RepoInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.full_url);
    }
};

pub const RepositoryAnalysis = struct {
    repo_url: []const u8,
    owner: []const u8,
    repo_name: []const u8,
    digest_content: []const u8,
    file_count: u32,
    total_lines: u32,
    primary_language: ?[]const u8,
    languages: ?[]LanguageInfo,
    key_files: ?[]KeyFileInfo,
    readme_summary: ?[]const u8,
    architecture_insights: ?[]const u8,
    
    pub fn deinit(self: RepositoryAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_url);
        allocator.free(self.owner);
        allocator.free(self.repo_name);
        allocator.free(self.digest_content);
        
        if (self.primary_language) |lang| {
            allocator.free(lang);
        }
        if (self.languages) |langs| {
            for (langs) |lang| {
                lang.deinit(allocator);
            }
            allocator.free(langs);
        }
        if (self.key_files) |files| {
            for (files) |file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        if (self.readme_summary) |summary| {
            allocator.free(summary);
        }
        if (self.architecture_insights) |insights| {
            allocator.free(insights);
        }
    }
    
    /// Generate AI insights about the repository using Claude
    pub fn generateCodeInsights(self: *RepositoryAnalysis, allocator: std.mem.Allocator, claude_prompt: []const u8) ![]const u8 {
        // Create a comprehensive prompt for Claude to analyze the repository
        const analysis_prompt = try std.fmt.allocPrint(allocator, 
            \\Analyze this GitHub repository and provide technical insights:
            \\
            \\Repository: {s}/{s}
            \\Primary Language: {s}
            \\File Count: {d}
            \\Total Lines: {d}
            \\
            \\Repository Content Digest:
            \\{s}
            \\
            \\{s}
            \\
            \\Please provide insights in the following format:
            \\1. **Technical Summary**: Brief overview of what this repository does
            \\2. **Architecture**: Key architectural patterns and design decisions
            \\3. **Notable Features**: Interesting or innovative aspects of the codebase
            \\4. **AI/ML Relevance**: How this relates to AI, ML, or emerging tech trends
            \\5. **Developer Impact**: Why this might be interesting to the AI developer community
            \\
            \\Keep the analysis concise but insightful, focusing on technical depth and practical implications.
        , .{
            self.owner,
            self.repo_name,
            self.primary_language orelse "Unknown",
            self.file_count,
            self.total_lines,
            self.digest_content[0..@min(self.digest_content.len, 4000)], // Limit content to avoid token limits
            claude_prompt
        });
        defer allocator.free(analysis_prompt);
        
        // This is a placeholder - in the actual implementation, this would call Claude
        // For now, return a basic analysis based on available metadata
        const basic_insights = try std.fmt.allocPrint(allocator,
            \\**Technical Summary**: {s} repository with {d} files and {d} lines of code, primarily written in {s}.
            \\
            \\**Architecture**: Based on the file structure, this appears to be a {s} project with organized modules and clear separation of concerns.
            \\
            \\**Notable Features**: The repository contains {d} files, indicating a {s} codebase suitable for {s}.
            \\
            \\**AI/ML Relevance**: This repository demonstrates practical software engineering patterns that are valuable in AI/ML projects.
            \\
            \\**Developer Impact**: Provides examples of clean code architecture and best practices for {s} development.
        , .{
            self.repo_name,
            self.file_count,
            self.total_lines,
            self.primary_language orelse "multi-language",
            self.primary_language orelse "software",
            self.file_count,
            if (self.file_count < 50) "focused" else if (self.file_count < 200) "medium-sized" else "large",
            if (self.file_count < 50) "learning and experimentation" else "production use",
            self.primary_language orelse "modern software"
        });
        
        return basic_insights;
    }
    
    /// Convert to GitHubRepoMetadata for integration with NewsItem
    pub fn toGitHubMetadata(self: RepositoryAnalysis, allocator: std.mem.Allocator) !types.GitHubRepoMetadata {
        var languages: ?[]types.GitHubRepoMetadata.LanguageInfo = null;
        if (self.languages) |langs| {
            var converted_langs = try allocator.alloc(types.GitHubRepoMetadata.LanguageInfo, langs.len);
            for (langs, 0..) |lang, i| {
                converted_langs[i] = types.GitHubRepoMetadata.LanguageInfo{
                    .name = try allocator.dupe(u8, lang.name),
                    .percentage = lang.percentage,
                    .lines_of_code = lang.lines_of_code,
                };
            }
            languages = converted_langs;
        }
        
        var key_files: ?[]types.GitHubRepoMetadata.FileInfo = null;
        if (self.key_files) |files| {
            var converted_files = try allocator.alloc(types.GitHubRepoMetadata.FileInfo, files.len);
            for (files, 0..) |file, i| {
                converted_files[i] = types.GitHubRepoMetadata.FileInfo{
                    .path = try allocator.dupe(u8, file.path),
                    .size = file.size,
                    .importance = switch (file.importance) {
                        .critical => .critical,
                        .important => .important,
                        .supporting => .supporting,
                    },
                    .description = if (file.description) |desc| try allocator.dupe(u8, desc) else null,
                };
            }
            key_files = converted_files;
        }
        
        return types.GitHubRepoMetadata{
            .repo_name = try allocator.dupe(u8, self.repo_name),
            .owner = try allocator.dupe(u8, self.owner),
            .description = null, // Would need GitHub API for this
            .primary_language = if (self.primary_language) |lang| try allocator.dupe(u8, lang) else null,
            .languages = languages,
            .file_count = self.file_count,
            .total_lines = self.total_lines,
            .star_count = null, // Would need GitHub API for this
            .fork_count = null, // Would need GitHub API for this
            .created_at = null, // Would need GitHub API for this
            .updated_at = null, // Would need GitHub API for this
            .topics = null, // Would need GitHub API for this
            .readme_summary = if (self.readme_summary) |summary| try allocator.dupe(u8, summary) else null,
            .key_files = key_files,
            .architecture_insights = if (self.architecture_insights) |insights| try allocator.dupe(u8, insights) else null,
        };
    }
};

pub const LanguageInfo = struct {
    name: []const u8,
    percentage: f32,
    lines_of_code: u32,
    
    pub fn deinit(self: LanguageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const KeyFileInfo = struct {
    path: []const u8,
    size: u32,
    importance: enum { critical, important, supporting },
    description: ?[]const u8,
    
    pub fn deinit(self: KeyFileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

// Test functions
test "GitHub URL parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var client = GitIngestClient.init(allocator, &http_client);
    
    const test_urls = [_][]const u8{
        "https://github.com/ggerganov/llama.cpp",
        "https://github.com/microsoft/vscode/tree/main",
        "https://github.com/anthropics/claude-code.git",
    };
    
    for (test_urls) |url| {
        const repo_info = try client.parseGitHubUrl(url);
        defer repo_info.deinit(allocator);
        
        std.testing.expect(repo_info.owner.len > 0) catch unreachable;
        std.testing.expect(repo_info.repo.len > 0) catch unreachable;
    }
}

test "GitHub URL extraction from text" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var client = GitIngestClient.init(allocator, &http_client);
    
    const test_content = 
        \\Check out this amazing project: https://github.com/ggerganov/llama.cpp
        \\Also see https://github.com/microsoft/vscode for editor features.
        \\Invalid URL: https://github.com/incomplete
        \\Another good one: https://github.com/anthropics/claude-code
    ;
    
    const urls = try client.extractGitHubUrls(test_content);
    defer {
        for (urls) |url| {
            allocator.free(url);
        }
        allocator.free(urls);
    }
    
    std.testing.expect(urls.len >= 2) catch unreachable;
}