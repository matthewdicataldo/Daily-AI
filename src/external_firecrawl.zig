const std = @import("std");
const http = @import("common_http.zig");
const types = @import("core_types.zig");
const config = @import("core_config.zig");

pub const FirecrawlClient = struct {
    allocator: std.mem.Allocator,
    http_client: http.HttpClient,
    api_key: []const u8,
    base_url: []const u8,
    
    const BASE_URL = "https://api.firecrawl.dev";
    
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !FirecrawlClient {
        return FirecrawlClient{
            .allocator = allocator,
            .http_client = try http.HttpClient.init(allocator),
            .api_key = api_key,
            .base_url = BASE_URL,
        };
    }
    
    pub fn deinit(self: *FirecrawlClient) void {
        self.http_client.deinit();
    }
    
    /// Scrape a single URL and return the content
    pub fn scrape(self: *FirecrawlClient, url: []const u8, options: ScrapeOptions) !types.FirecrawlResponse {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/scrape", .{self.base_url});
        defer self.allocator.free(endpoint);
        
        // Build request body
        const request_body = try buildScrapeRequestBody(self.allocator, url, options);
        defer self.allocator.free(request_body);
        
        // Create headers with temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const auth_value = try std.fmt.allocPrint(temp_allocator, "Bearer {s}", .{self.api_key});
        
        var headers = [_]types.HttpRequest.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };
        
        // Make the request
        const response = try self.http_client.post(endpoint, &headers, request_body);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            // Sanitize error message to avoid logging sensitive information
            std.log.err("Firecrawl scrape failed with status {d} (response body hidden for security)", .{response.status_code});
            return types.AppError.FirecrawlError;
        }
        
        // Parse JSON response
        return try parseFirecrawlResponse(self.allocator, response.body);
    }
    
    /// Crawl a website and return multiple pages
    pub fn crawl(self: *FirecrawlClient, url: []const u8, options: CrawlOptions) !types.FirecrawlResponse {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/crawl", .{self.base_url});
        defer self.allocator.free(endpoint);
        
        // Build request body
        const request_body = try buildCrawlRequestBody(self.allocator, url, options);
        defer self.allocator.free(request_body);
        
        // Create headers with temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const auth_value = try std.fmt.allocPrint(temp_allocator, "Bearer {s}", .{self.api_key});
        
        var headers = [_]types.HttpRequest.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };
        
        // Make the request
        const response = try self.http_client.post(endpoint, &headers, request_body);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            // Sanitize error message to avoid logging sensitive information
            std.log.err("Firecrawl crawl failed with status {d} (response body hidden for security)", .{response.status_code});
            return types.AppError.FirecrawlError;
        }
        
        // Parse JSON response
        return try parseFirecrawlResponse(self.allocator, response.body);
    }
    
    /// Map a website to discover URLs
    pub fn map(self: *FirecrawlClient, url: []const u8, options: MapOptions) ![][]const u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/v1/map", .{self.base_url});
        defer self.allocator.free(endpoint);
        
        // Build request body
        const request_body = try buildMapRequestBody(self.allocator, url, options);
        defer self.allocator.free(request_body);
        
        // Create headers with temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const auth_value = try std.fmt.allocPrint(temp_allocator, "Bearer {s}", .{self.api_key});
        
        var headers = [_]types.HttpRequest.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };
        
        // Make the request
        const response = try self.http_client.post(endpoint, &headers, request_body);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            // Sanitize error message to avoid logging sensitive information
            std.log.err("Firecrawl map failed with status {d} (response body hidden for security)", .{response.status_code});
            return types.AppError.FirecrawlError;
        }
        
        // Parse JSON response to extract URLs
        return try parseMapResponse(self.allocator, response.body);
    }
    
};

pub const ScrapeOptions = struct {
    include_html: bool = false,
    include_raw_html: bool = false,
    only_main_content: bool = true,
    include_links: bool = false,
    wait_for: ?u32 = null, // milliseconds
};

pub const CrawlOptions = struct {
    includes: ?[][]const u8 = null,
    excludes: ?[][]const u8 = null,
    generate_img_alt_text: bool = false,
    return_only_urls: bool = false,
    max_depth: ?u32 = null,
    mode: enum { default, fast } = .default,
    ignore_sitemap: bool = false,
    limit: ?u32 = null,
    allow_backwards_crawling: bool = false,
    allow_external_content_links: bool = false,
};

pub const MapOptions = struct {
    search: ?[]const u8 = null,
    ignore_sitemap: bool = false,
    include_subdomains: bool = false,
    limit: ?u32 = null,
};


fn buildScrapeRequestBody(allocator: std.mem.Allocator, url: []const u8, options: ScrapeOptions) ![]const u8 {
    // Simple JSON construction - in a production app, you'd want a proper JSON library
    const wait_for_str = if (options.wait_for) |wait| 
        try std.fmt.allocPrint(allocator, ",\"waitFor\":{d}", .{wait}) 
    else 
        try allocator.dupe(u8, "");
    defer allocator.free(wait_for_str);
    
    const formats = if (options.include_links) 
        "\"formats\": [\"markdown\", \"links\"]" 
    else 
        "\"formats\": [\"markdown\"]";
    
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "url": "{s}",
        \\  {s},
        \\  "onlyMainContent": {s}{s}
        \\}}
    , .{
        url,
        formats,
        if (options.only_main_content) "true" else "false",
        wait_for_str,
    });
}

fn buildCrawlRequestBody(allocator: std.mem.Allocator, url: []const u8, options: CrawlOptions) ![]const u8 {
    const limit_str = if (options.limit) |limit| 
        try std.fmt.allocPrint(allocator, ",\"limit\":{d}", .{limit}) 
    else 
        try allocator.dupe(u8, "");
    defer allocator.free(limit_str);
    
    const max_depth_str = if (options.max_depth) |depth| 
        try std.fmt.allocPrint(allocator, ",\"maxDepth\":{d}", .{depth}) 
    else 
        try allocator.dupe(u8, "");
    defer allocator.free(max_depth_str);
    
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "url": "{s}",
        \\  "crawlerOptions": {{
        \\    "returnOnlyUrls": {s},
        \\    "mode": "{s}",
        \\    "ignoreSitemap": {s},
        \\    "allowBackwardsCrawling": {s},
        \\    "allowExternalContentLinks": {s}{s}{s}
        \\  }}
        \\}}
    , .{
        url,
        if (options.return_only_urls) "true" else "false",
        if (options.mode == .fast) "fast" else "default",
        if (options.ignore_sitemap) "true" else "false",
        if (options.allow_backwards_crawling) "true" else "false",
        if (options.allow_external_content_links) "true" else "false",
        limit_str,
        max_depth_str,
    });
}

fn buildMapRequestBody(allocator: std.mem.Allocator, url: []const u8, options: MapOptions) ![]const u8 {
    const search_str = if (options.search) |search| 
        try std.fmt.allocPrint(allocator, ",\"search\":\"{s}\"", .{search}) 
    else 
        try allocator.dupe(u8, "");
    defer allocator.free(search_str);
    
    const limit_str = if (options.limit) |limit| 
        try std.fmt.allocPrint(allocator, ",\"limit\":{d}", .{limit}) 
    else 
        try allocator.dupe(u8, "");
    defer allocator.free(limit_str);
    
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "url": "{s}",
        \\  "ignoreSitemap": {s},
        \\  "includeSubdomains": {s}{s}{s}
        \\}}
    , .{
        url,
        if (options.ignore_sitemap) "true" else "false",
        if (options.include_subdomains) "true" else "false",
        search_str,
        limit_str,
    });
}

fn parseFirecrawlResponse(allocator: std.mem.Allocator, json_str: []const u8) !types.FirecrawlResponse {
    // Simple JSON parsing - in production, use a proper JSON parser
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch |err| {
        std.log.err("Failed to parse Firecrawl response JSON: {}", .{err});
        return types.AppError.ParseError;
    };
    defer parsed.deinit();
    
    const root = parsed.value;
    
    const success = if (root.object.get("success")) |success_value|
        success_value.bool
    else 
        false;
    
    if (!success) {
        const error_msg = if (root.object.get("error")) |error_value|
            try allocator.dupe(u8, error_value.string)
        else
            try allocator.dupe(u8, "Unknown Firecrawl error");
        
        return types.FirecrawlResponse{
            .success = false,
            .data = null,
            .@"error" = error_msg,
        };
    }
    
    // Parse data section
    const data = if (root.object.get("data")) |data_value| data_block: {
        const markdown = if (data_value.object.get("markdown")) |md_value|
            try allocator.dupe(u8, md_value.string)
        else
            null;
        
        const html = if (data_value.object.get("html")) |html_value|
            try allocator.dupe(u8, html_value.string)
        else
            null;
            
        // Parse metadata if present
        const metadata = if (data_value.object.get("metadata")) |metadata_value| blk: {
            if (metadata_value == .object) {
                break :blk try parseMetadata(allocator, metadata_value.object);
            }
            break :blk null;
        } else null;
        
        // Parse links if present
        const links = if (data_value.object.get("links")) |links_value| blk: {
            if (links_value == .array) {
                break :blk try parseLinks(allocator, links_value.array);
            }
            break :blk null;
        } else null;
        
        break :data_block types.FirecrawlResponse.FirecrawlData{
            .markdown = markdown,
            .html = html,
            .metadata = metadata,
            .links = links,
        };
    } else null;
    
    return types.FirecrawlResponse{
        .success = true,
        .data = data,
        .@"error" = null,
    };
}

fn parseMapResponse(allocator: std.mem.Allocator, json_str: []const u8) ![][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch |err| {
        std.log.err("Failed to parse Firecrawl map response JSON: {}", .{err});
        return types.AppError.ParseError;
    };
    defer parsed.deinit();
    
    const root = parsed.value;
    
    if (root.object.get("data")) |data_value| {
        if (data_value == .array) {
            var urls = std.ArrayList([]const u8).init(allocator);
            
            for (data_value.array.items) |item| {
                if (item == .string) {
                    try urls.append(try allocator.dupe(u8, item.string));
                }
            }
            
            return try urls.toOwnedSlice();
        }
    }
    
    return &[_][]const u8{};
}

fn parseMetadata(allocator: std.mem.Allocator, metadata_obj: std.json.ObjectMap) !?types.FirecrawlResponse.FirecrawlData.FirecrawlMetadata {
    var metadata = types.FirecrawlResponse.FirecrawlData.FirecrawlMetadata{
        .title = null,
        .description = null,
        .language = null,
        .sourceURL = null,
        .statusCode = null,
    };
    
    if (metadata_obj.get("title")) |title_value| {
        if (title_value == .string) {
            metadata.title = try allocator.dupe(u8, title_value.string);
        }
    }
    
    if (metadata_obj.get("description")) |desc_value| {
        if (desc_value == .string) {
            metadata.description = try allocator.dupe(u8, desc_value.string);
        }
    }
    
    if (metadata_obj.get("language")) |lang_value| {
        if (lang_value == .string) {
            metadata.language = try allocator.dupe(u8, lang_value.string);
        }
    }
    
    if (metadata_obj.get("sourceURL")) |url_value| {
        if (url_value == .string) {
            metadata.sourceURL = try allocator.dupe(u8, url_value.string);
        }
    }
    
    if (metadata_obj.get("statusCode")) |status_value| {
        if (status_value == .integer) {
            metadata.statusCode = @as(u16, @intCast(status_value.integer));
        }
    }
    
    return metadata;
}

fn parseLinks(allocator: std.mem.Allocator, links_array: std.json.Array) !?[]types.FirecrawlResponse.FirecrawlData.FirecrawlLink {
    var links = std.ArrayList(types.FirecrawlResponse.FirecrawlData.FirecrawlLink).init(allocator);
    defer links.deinit();
    
    for (links_array.items) |link_value| {
        if (link_value == .object) {
            const link_obj = link_value.object;
            
            var link = types.FirecrawlResponse.FirecrawlData.FirecrawlLink{
                .text = null,
                .href = null,
            };
            
            if (link_obj.get("text")) |text_value| {
                if (text_value == .string) {
                    link.text = try allocator.dupe(u8, text_value.string);
                }
            }
            
            if (link_obj.get("href")) |href_value| {
                if (href_value == .string) {
                    link.href = try allocator.dupe(u8, href_value.string);
                }
            }
            
            try links.append(link);
        }
    }
    
    if (links.items.len > 0) {
        return try links.toOwnedSlice();
    } else {
        return null;
    }
}

// Convenience functions for different source types
pub fn scrapeRedditPage(client: *FirecrawlClient, subreddit: []const u8) !types.FirecrawlResponse {
    const url = try std.fmt.allocPrint(client.allocator, "https://old.reddit.com/r/{s}/", .{subreddit});
    defer client.allocator.free(url);
    
    const options = ScrapeOptions{
        .only_main_content = true,
        .include_links = true,
    };
    
    return try client.scrape(url, options);
}

pub fn scrapeYouTubeChannel(client: *FirecrawlClient, handle: []const u8) !types.FirecrawlResponse {
    const url = try std.fmt.allocPrint(client.allocator, "https://www.youtube.com/{s}/videos", .{handle});
    defer client.allocator.free(url);
    
    const options = ScrapeOptions{
        .only_main_content = true,
        .include_links = true,
        .wait_for = 3000, // Wait for JavaScript to load
    };
    
    return try client.scrape(url, options);
}

pub fn scrapeHuggingFacePapers(client: *FirecrawlClient) !types.FirecrawlResponse {
    const options = ScrapeOptions{
        .only_main_content = true,
        .include_links = true,
    };
    
    return try client.scrape("https://huggingface.co/papers", options);
}

pub fn scrapeBlogPage(client: *FirecrawlClient, url: []const u8) !types.FirecrawlResponse {
    const options = ScrapeOptions{
        .only_main_content = true,
        .include_links = false,
    };
    
    return try client.scrape(url, options);
}

// Test function
test "Firecrawl client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var client = try FirecrawlClient.init(allocator, "test-api-key");
    defer client.deinit();
    
    try std.testing.expect(std.mem.eql(u8, client.api_key, "test-api-key"));
    try std.testing.expect(std.mem.eql(u8, client.base_url, "https://api.firecrawl.dev"));
}