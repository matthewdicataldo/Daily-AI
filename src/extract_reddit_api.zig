const std = @import("std");
const http = @import("common_http.zig");
const types = @import("core_types.zig");
const config = @import("core_config.zig");

/// Reddit API client for OAuth2 authentication and data fetching
pub const RedditApiClient = struct {
    allocator: std.mem.Allocator,
    http_client: *http.HttpClient,
    access_token: ?[]const u8 = null,
    client_id: []const u8,
    client_secret: []const u8,
    user_agent: []const u8,
    authenticating: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, http_client: *http.HttpClient, client_id: []const u8, client_secret: []const u8, user_agent: []const u8) RedditApiClient {
        return RedditApiClient{
            .allocator = allocator,
            .http_client = http_client,
            .client_id = client_id,
            .client_secret = client_secret,
            .user_agent = user_agent,
        };
    }
    
    pub fn deinit(self: *RedditApiClient) void {
        if (self.access_token) |token| {
            self.allocator.free(token);
        }
    }
    
    /// Authenticate with Reddit API using OAuth2 client credentials flow
    pub fn authenticate(self: *RedditApiClient) !void {
        // Prevent concurrent authentication
        if (self.authenticating) {
            std.log.debug("Authentication already in progress, waiting...", .{});
            return;
        }
        if (self.access_token != null) {
            std.log.debug("Already authenticated, skipping...", .{});
            return;
        }
        
        self.authenticating = true;
        defer self.authenticating = false;
        
        std.log.info("Authenticating with Reddit API...", .{});
        
        // Use arena allocator for temporary authentication data
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        // Prepare OAuth2 request
        const auth_url = "https://www.reddit.com/api/v1/access_token";
        const post_data = "grant_type=client_credentials";
        
        // Create basic auth header using arena allocator
        const auth_string = try std.fmt.allocPrint(temp_allocator, "{s}:{s}", .{ self.client_id, self.client_secret });
        const encoded_auth = try base64Encode(temp_allocator, auth_string);
        const auth_header = try std.fmt.allocPrint(temp_allocator, "Basic {s}", .{encoded_auth});
        
        // Create headers using arena allocator
        var headers = std.ArrayList(types.HttpRequest.Header).init(temp_allocator);
        
        try headers.append(.{ .name = try temp_allocator.dupe(u8, "Authorization"), .value = try temp_allocator.dupe(u8, auth_header) });
        try headers.append(.{ .name = try temp_allocator.dupe(u8, "Content-Type"), .value = try temp_allocator.dupe(u8, "application/x-www-form-urlencoded") });
        try headers.append(.{ .name = try temp_allocator.dupe(u8, "User-Agent"), .value = try temp_allocator.dupe(u8, self.user_agent) });
        
        const request = types.HttpRequest{
            .method = .POST,
            .url = auth_url,
            .headers = headers.items,
            .body = post_data,
        };
        
        const response = try self.http_client.makeRequest(request);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            std.log.err("Reddit authentication failed: {d} - {s}", .{ response.status_code, response.body });
            return error.AuthenticationFailed;
        }
        
        // Debug: Print authentication response status (token content redacted for security)
        std.log.info("Auth response status: {d}, body length: {d} chars", .{ response.status_code, response.body.len });
        
        // Parse access token from JSON response using arena allocator
        const token_response = try std.json.parseFromSlice(RedditTokenResponse, temp_allocator, response.body, .{});
        
        // Copy the access token IMMEDIATELY while arena is still valid
        const new_access_token = try self.allocator.dupe(u8, token_response.value.access_token);
        
        // Now safely free the old token and update
        if (self.access_token) |old_token| {
            self.allocator.free(old_token);
        }
        self.access_token = new_access_token;
        
        std.log.info("✅ Reddit API authentication successful", .{});
    }
    
    /// Fetch posts from a subreddit with timeout and today filter
    pub fn getSubredditPosts(self: *RedditApiClient, subreddit: []const u8, sort: RedditSort, limit: u32) ![]RedditPost {
        if (self.access_token == null) {
            try self.authenticate();
        }
        
        // Use arena allocator for temporary request data
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const sort_str = switch (sort) {
            .hot => "hot",
            .new => "new",
            .top => "top",
            .rising => "rising",
        };
        
        const url = try std.fmt.allocPrint(temp_allocator, "https://oauth.reddit.com/r/{s}/{s}/.json?limit={d}", .{ subreddit, sort_str, limit });
        
        var headers = std.ArrayList(types.HttpRequest.Header).init(temp_allocator);
        
        const auth_header = try std.fmt.allocPrint(temp_allocator, "Bearer {s}", .{self.access_token.?});
        
        try headers.append(.{ .name = try temp_allocator.dupe(u8, "Authorization"), .value = try temp_allocator.dupe(u8, auth_header) });
        try headers.append(.{ .name = try temp_allocator.dupe(u8, "User-Agent"), .value = try temp_allocator.dupe(u8, self.user_agent) });
        
        const request = types.HttpRequest{
            .method = .GET,
            .url = url,
            .headers = headers.items,
            .body = null,
        };
        
        const response = try self.http_client.makeRequest(request);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            std.log.err("Failed to fetch r/{s}: {d} - {s}", .{ subreddit, response.status_code, response.body });
            return error.ApiFetchFailed;
        }
        
        // Debug: Print first 500 characters of response
        std.log.info("Response body length: {d}", .{response.body.len});
        const preview_len = @min(500, response.body.len);
        std.log.info("Response preview: {s}", .{response.body[0..preview_len]});
        
        // Parse Reddit API response as generic JSON first using temp allocator
        const parsed = try std.json.parseFromSlice(std.json.Value, temp_allocator, response.body, .{});
        
        var posts = std.ArrayList(RedditPost).init(self.allocator);
        defer {
            // Only deinit ArrayList, not the posts (they're returned)
            posts.deinit();
        }
        
        // Navigate JSON structure manually with today filter
        const now = std.time.timestamp();
        const seconds_in_day: i64 = 24 * 60 * 60;
        const today_start = now - @rem(now, seconds_in_day);
        
        const root_obj = parsed.value.object;
        if (root_obj.get("data")) |data_val| {
            if (data_val.object.get("children")) |children_val| {
                for (children_val.array.items) |child_val| {
                    const child_obj = child_val.object;
                    if (child_obj.get("kind")) |kind_val| {
                        if (std.mem.eql(u8, kind_val.string, "t3")) { // t3 = submission/post
                            if (child_obj.get("data")) |post_data| {
                                // Check if post is from today
                                if (post_data.object.get("created_utc")) |created_val| {
                                    const created_utc = switch (created_val) {
                                        .float => @as(i64, @intFromFloat(created_val.float)),
                                        .integer => @as(i64, @intCast(created_val.integer)),
                                        else => continue,
                                    };
                                    
                                    // Only include posts from today
                                    if (created_utc >= today_start) {
                                        const post = try self.parseRedditPostFromJson(post_data, subreddit);
                                        try posts.append(post);
                                    }
                                } else {
                                    // If no timestamp, include anyway (fallback)
                                    const post = try self.parseRedditPostFromJson(post_data, subreddit);
                                    try posts.append(post);
                                }
                            }
                        }
                    }
                    
                    // Break early if we have enough posts
                    if (posts.items.len >= 25) break;
                }
            }
        }
        
        std.log.info("📱 Fetched {d} posts from r/{s}", .{ posts.items.len, subreddit });
        return try posts.toOwnedSlice();
    }
    
    /// Fetch comments for a specific post
    pub fn getPostComments(self: *RedditApiClient, subreddit: []const u8, post_id: []const u8, limit: u32) ![]RedditComment {
        if (self.access_token == null) {
            try self.authenticate();
        }
        
        const url = try std.fmt.allocPrint(self.allocator, "https://oauth.reddit.com/r/{s}/comments/{s}/.json?limit={d}", .{ subreddit, post_id, limit });
        defer self.allocator.free(url);
        
        var headers = std.ArrayList(types.HttpRequest.Header).init(self.allocator);
        defer {
            for (headers.items) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
            headers.deinit();
        }
        
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token.?});
        defer self.allocator.free(auth_header);
        
        try headers.append(.{ .name = try self.allocator.dupe(u8, "Authorization"), .value = try self.allocator.dupe(u8, auth_header) });
        try headers.append(.{ .name = try self.allocator.dupe(u8, "User-Agent"), .value = try self.allocator.dupe(u8, self.user_agent) });
        
        const request = types.HttpRequest{
            .method = .GET,
            .url = url,
            .headers = headers.items,
            .body = null,
        };
        
        const response = try self.http_client.makeRequest(request);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            std.log.warn("Failed to fetch comments for {s}: {d}", .{ post_id, response.status_code });
            return &[_]RedditComment{};
        }
        
        // Parse comments (Reddit returns an array with post + comments)
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        
        var comments = std.ArrayList(RedditComment).init(self.allocator);
        defer {
            // Only deinit ArrayList, not the comments (they're returned)
            comments.deinit();
        }
        
        // Reddit API returns array: [post_listing, comment_listing] - limit to top 10 comments for speed
        if (parsed.value.array.items.len >= 2) {
            const comment_listing = parsed.value.array.items[1].object;
            if (comment_listing.get("data")) |data_val| {
                if (data_val.object.get("children")) |children_val| {
                    var comment_count: u32 = 0;
                    for (children_val.array.items) |child_val| {
                        if (comment_count >= 10) break; // Limit to 10 comments max
                        
                        const child_obj = child_val.object;
                        if (child_obj.get("kind")) |kind_val| {
                            if (std.mem.eql(u8, kind_val.string, "t1")) { // t1 = comment
                                if (child_obj.get("data")) |comment_data| {
                                    const comment = try self.parseRedditCommentFromJson(comment_data);
                                    try comments.append(comment);
                                    comment_count += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return try comments.toOwnedSlice();
    }
    
    /// Parse Reddit post from JSON value
    fn parseRedditPostFromJson(self: *RedditApiClient, data: std.json.Value, subreddit: []const u8) !RedditPost {
        const obj = data.object;
        
        // Helper to safely get string values
        const getString = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: ?[]const u8) ?[]const u8 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .string => |s| return s,
                        .null => return default,
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        // Helper to safely get integer values
        const getInt = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: i32) i32 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .integer => |i| return @intCast(i),
                        .float => |f| return @intFromFloat(f),
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        // Helper to safely get float values
        const getFloat = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: f32) f32 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .float => |f| return @floatCast(f),
                        .integer => |i| return @floatFromInt(i),
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        // Helper to safely get boolean values
        const getBool = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
                if (object.get(key)) |value| {
                    switch (value) {
                        .bool => |b| return b,
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        const id_str = getString(obj, "id", "unknown") orelse "unknown";
        const title_str = getString(obj, "title", "Untitled") orelse "Untitled";
        const author_str = getString(obj, "author", "unknown") orelse "unknown";
        const permalink_str = getString(obj, "permalink", "/") orelse "/";
        
        return RedditPost{
            .id = try self.allocator.dupe(u8, id_str),
            .title = try self.allocator.dupe(u8, title_str),
            .author = try self.allocator.dupe(u8, author_str),
            .subreddit = try self.allocator.dupe(u8, subreddit),
            .url = if (getString(obj, "url", null)) |url| try self.allocator.dupe(u8, url) else null,
            .selftext = if (getString(obj, "selftext", null)) |text| 
                if (text.len > 0) try self.allocator.dupe(u8, text) else null 
            else null,
            .score = getInt(obj, "score", 0),
            .upvote_ratio = getFloat(obj, "upvote_ratio", 0.5),
            .num_comments = @intCast(@max(0, getInt(obj, "num_comments", 0))),
            .created_utc = getFloat(obj, "created_utc", 0.0),
            .permalink = try self.allocator.dupe(u8, permalink_str),
            .flair_text = if (getString(obj, "link_flair_text", null)) |flair| try self.allocator.dupe(u8, flair) else null,
            .is_self = getBool(obj, "is_self", false),
            .is_video = getBool(obj, "is_video", false),
            .over_18 = getBool(obj, "over_18", false),
        };
    }
    
    /// Parse Reddit comment from JSON value  
    fn parseRedditCommentFromJson(self: *RedditApiClient, data: std.json.Value) !RedditComment {
        const obj = data.object;
        
        // Helper functions (same as above)
        const getString = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: ?[]const u8) ?[]const u8 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .string => |s| return s,
                        .null => return default,
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        const getInt = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: i32) i32 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .integer => |i| return @intCast(i),
                        .float => |f| return @intFromFloat(f),
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        const getFloat = struct {
            fn call(object: std.json.ObjectMap, key: []const u8, default: f32) f32 {
                if (object.get(key)) |value| {
                    switch (value) {
                        .float => |f| return @floatCast(f),
                        .integer => |i| return @floatFromInt(i),
                        else => return default,
                    }
                }
                return default;
            }
        }.call;
        
        const id_str = getString(obj, "id", "unknown") orelse "unknown";
        const author_str = getString(obj, "author", "unknown") orelse "unknown";
        const body_str = getString(obj, "body", "") orelse "";
        
        return RedditComment{
            .id = try self.allocator.dupe(u8, id_str),
            .author = try self.allocator.dupe(u8, author_str),
            .body = try self.allocator.dupe(u8, body_str),
            .score = getInt(obj, "score", 0),
            .created_utc = getFloat(obj, "created_utc", 0.0),
            .parent_id = if (getString(obj, "parent_id", null)) |parent| try self.allocator.dupe(u8, parent) else null,
            .depth = @intCast(@max(0, getInt(obj, "depth", 0))),
        };
    }
};

// Use RedditSort from config module
const RedditSort = config.RedditSort;

/// Reddit post structure from API
pub const RedditPost = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    subreddit: []const u8,
    url: ?[]const u8,
    selftext: ?[]const u8,
    score: i32,
    upvote_ratio: f32,
    num_comments: u32,
    created_utc: f64,
    permalink: []const u8,
    flair_text: ?[]const u8,
    is_self: bool,
    is_video: bool,
    over_18: bool,
    
    pub fn deinit(self: RedditPost, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.author);
        allocator.free(self.subreddit);
        if (self.url) |url| allocator.free(url);
        if (self.selftext) |text| allocator.free(text);
        allocator.free(self.permalink);
        if (self.flair_text) |flair| allocator.free(flair);
    }
};

/// Reddit comment structure from API
pub const RedditComment = struct {
    id: []const u8,
    author: []const u8,
    body: []const u8,
    score: i32,
    created_utc: f64,
    parent_id: ?[]const u8,
    depth: u32,
    
    pub fn deinit(self: RedditComment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.author);
        allocator.free(self.body);
        if (self.parent_id) |parent| allocator.free(parent);
    }
};

// Simplified JSON response structure for Reddit API
const RedditTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u32,
    scope: []const u8,
};

/// Base64 encoding helper
fn base64Encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(input.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, input);
    return encoded;
}

test "Reddit API client initialization" {
    const allocator = std.testing.allocator;
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var reddit_client = RedditApiClient.init(allocator, &http_client, "test_id", "test_secret", "test_agent");
    defer reddit_client.deinit();
    
    // Test that client initializes without errors
    try std.testing.expect(reddit_client.access_token == null);
}

test "Base64 encoding" {
    const allocator = std.testing.allocator;
    
    const input = "test:secret";
    const encoded = try base64Encode(allocator, input);
    defer allocator.free(encoded);
    
    try std.testing.expect(encoded.len > 0);
}