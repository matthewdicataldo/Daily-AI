const std = @import("std");
const builtin = @import("builtin");
const http = @import("common_http.zig");
const config = @import("core_config.zig");

/// Model download configuration
pub const ModelConfig = struct {
    model_id: []const u8,
    filename: ?[]const u8 = null,
    local_path: []const u8 = "models",
    hf_token: ?[]const u8 = null,
    resume_download: bool = true,
    validate_checksum: bool = true,
    progress_callback: ?*const fn (downloaded: u64, total: u64) void = null,
};

/// Download progress information
pub const DownloadProgress = struct {
    downloaded_bytes: u64,
    total_bytes: u64,
    download_speed: f64, // bytes per second
    eta_seconds: f64,
    percentage: f32,
};

/// Model downloader errors
pub const DownloadError = error{
    ModelNotFound,
    NetworkError,
    FileSystemError,
    ChecksumMismatch,
    InvalidModelId,
    AuthenticationRequired,
    QuotaExceeded,
    PermissionDenied,
};

/// HuggingFace model downloader
pub const ModelDownloader = struct {
    allocator: std.mem.Allocator,
    http_client: *http.HttpClient,
    base_url: []const u8 = "https://huggingface.co",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, http_client: *http.HttpClient) Self {
        return Self{
            .allocator = allocator,
            .http_client = http_client,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Download a model from HuggingFace Hub
    pub fn downloadModel(self: *Self, model_config: ModelConfig) ![]const u8 {
        std.log.info("🚀 Starting download of model: {s}", .{model_config.model_id});

        // Validate model ID format
        if (!self.isValidModelId(model_config.model_id)) {
            return DownloadError.InvalidModelId;
        }

        // Get model information from HuggingFace API
        const model_info = try self.getModelInfo(model_config.model_id, model_config.hf_token);
        defer model_info.deinit(self.allocator);

        // Find the GGUF file to download
        const gguf_file = try self.findGGUFFile(model_info, model_config.filename);
        defer self.allocator.free(gguf_file.filename);
        defer self.allocator.free(gguf_file.download_url);

        // Ensure download directory exists
        const local_dir = try self.ensureDownloadDirectory(model_config.local_path);
        defer self.allocator.free(local_dir);

        // Create local file path
        const local_file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ local_dir, gguf_file.filename });
        defer self.allocator.free(local_file_path);

        // Check if file already exists and is complete
        if (try self.isFileComplete(local_file_path, gguf_file.size)) {
            std.log.info("✅ Model already downloaded: {s}", .{local_file_path});
            return try self.allocator.dupe(u8, local_file_path);
        }

        // Download the file with progress tracking
        try self.downloadFileWithProgress(gguf_file, local_file_path, model_config);

        // Validate the downloaded file
        if (model_config.validate_checksum and gguf_file.sha256) |expected_checksum| {
            try self.validateFileChecksum(local_file_path, expected_checksum);
        }

        std.log.info("✅ Model download completed: {s}", .{local_file_path});
        return try self.allocator.dupe(u8, local_file_path);
    }

    /// Download Jan nano model specifically
    pub fn downloadJanNanoModel(self: *Self, local_path: []const u8) ![]const u8 {
        const model_config = ModelConfig{
            .model_id = "unsloth/Jan-nano-128k-GGUF",
            .filename = "Jan-nano-128k-UD-Q8_K_XL.gguf",
            .local_path = local_path,
            .resume_download = true,
            .validate_checksum = true,
        };

        return try self.downloadModel(model_config);
    }

    /// Get model information from HuggingFace API
    fn getModelInfo(self: *Self, model_id: []const u8, hf_token: ?[]const u8) !ModelInfo {
        const api_url = try std.fmt.allocPrint(self.allocator, "{s}/api/models/{s}", .{ self.base_url, model_id });
        defer self.allocator.free(api_url);

        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        // Add authorization header if token provided
        if (hf_token) |token| {
            try headers.append(http.Header{
                .name = try self.allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token}),
            });
        }

        try headers.append(http.Header{
            .name = try self.allocator.dupe(u8, "User-Agent"),
            .value = try self.allocator.dupe(u8, "daily-ai-zig/1.0"),
        });

        const response = try self.http_client.get(api_url, headers.items);
        defer response.deinit(self.allocator);

        if (response.status_code == 404) {
            return DownloadError.ModelNotFound;
        }

        if (response.status_code == 401) {
            return DownloadError.AuthenticationRequired;
        }

        if (response.status_code != 200) {
            std.log.err("HuggingFace API error: {d}", .{response.status_code});
            return DownloadError.NetworkError;
        }

        // Parse JSON response
        return try self.parseModelInfo(response.body);
    }

    /// Parse model information from JSON response
    fn parseModelInfo(self: *Self, json_data: []const u8) !ModelInfo {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const parsed = try std.json.parseFromSlice(std.json.Value, temp_allocator, json_data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract model name
        const model_name = if (root.get("modelId")) |name_val|
            if (name_val == .string) try self.allocator.dupe(u8, name_val.string) else try self.allocator.dupe(u8, "unknown")
        else
            try self.allocator.dupe(u8, "unknown");

        // Extract siblings (files) information
        var files = std.ArrayList(FileInfo).init(self.allocator);

        if (root.get("siblings")) |siblings_val| {
            if (siblings_val == .array) {
                for (siblings_val.array.items) |file_val| {
                    if (file_val == .object) {
                        const file_info = try self.parseFileInfo(file_val.object);
                        try files.append(file_info);
                    }
                }
            }
        }

        return ModelInfo{
            .model_name = model_name,
            .files = try files.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Parse individual file information
    fn parseFileInfo(self: *Self, file_obj: std.json.ObjectMap) !FileInfo {
        const filename = if (file_obj.get("rfilename")) |name_val|
            if (name_val == .string) try self.allocator.dupe(u8, name_val.string) else try self.allocator.dupe(u8, "unknown")
        else
            try self.allocator.dupe(u8, "unknown");

        const size = if (file_obj.get("size")) |size_val| blk: {
            switch (size_val) {
                .float => break :blk @as(u64, @intFromFloat(size_val.float)),
                .integer => break :blk @as(u64, @intCast(size_val.integer)),
                else => break :blk 0,
            }
        } else 0;

        const lfs = if (file_obj.get("lfs")) |lfs_val|
            lfs_val == .object
        else
            false;

        const sha256 = if (lfs and file_obj.get("lfs")) |lfs_val| blk: {
            if (lfs_val.object.get("sha256")) |sha_val| {
                if (sha_val == .string) {
                    break :blk try self.allocator.dupe(u8, sha_val.string);
                }
            }
            break :blk null;
        } else null;

        return FileInfo{
            .filename = filename,
            .size = size,
            .sha256 = sha256,
        };
    }

    /// Find GGUF file in model files
    fn findGGUFFile(self: *Self, model_info: ModelInfo, preferred_filename: ?[]const u8) !DownloadableFile {
        var best_file: ?FileInfo = null;

        // Look for preferred filename first
        if (preferred_filename) |preferred| {
            for (model_info.files) |file| {
                if (std.mem.eql(u8, file.filename, preferred)) {
                    best_file = file;
                    break;
                }
            }
        }

        // If not found, look for any GGUF file
        if (best_file == null) {
            for (model_info.files) |file| {
                if (std.mem.endsWith(u8, file.filename, ".gguf")) {
                    // Prefer Q8 or Q4 quantizations
                    if (std.mem.indexOf(u8, file.filename, "Q8") != null or
                        std.mem.indexOf(u8, file.filename, "Q4") != null)
                    {
                        best_file = file;
                        break;
                    } else if (best_file == null) {
                        best_file = file;
                    }
                }
            }
        }

        if (best_file == null) {
            std.log.err("No GGUF files found in model", .{});
            return DownloadError.ModelNotFound;
        }

        const file = best_file.?;
        const download_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/resolve/main/{s}", .{ self.base_url, model_info.model_name, file.filename });

        return DownloadableFile{
            .filename = try self.allocator.dupe(u8, file.filename),
            .download_url = download_url,
            .size = file.size,
            .sha256 = if (file.sha256) |sha| try self.allocator.dupe(u8, sha) else null,
        };
    }

    /// Download file with progress tracking
    fn downloadFileWithProgress(self: *Self, file: DownloadableFile, local_path: []const u8, model_config: ModelConfig) !void {
        std.log.info("📥 Downloading {s} ({d} MB)...", .{ file.filename, file.size / (1024 * 1024) });

        // Check if partial file exists for resume
        var resume_offset: u64 = 0;
        if (model_config.resume_download) {
            resume_offset = self.getFileSize(local_path) catch 0;
        }

        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        // Add range header for resume if needed
        if (resume_offset > 0) {
            const range_header = try std.fmt.allocPrint(self.allocator, "bytes={d}-", .{resume_offset});
            defer self.allocator.free(range_header);

            try headers.append(http.Header{
                .name = try self.allocator.dupe(u8, "Range"),
                .value = try self.allocator.dupe(u8, range_header),
            });

            std.log.info("🔄 Resuming download from byte {d}", .{resume_offset});
        }

        try headers.append(http.Header{
            .name = try self.allocator.dupe(u8, "User-Agent"),
            .value = try self.allocator.dupe(u8, "daily-ai-zig/1.0"),
        });

        // Open file for writing (truncate if not resuming)
        const local_file = try std.fs.cwd().createFile(local_path, .{ .truncate = resume_offset == 0 });
        defer local_file.close();

        if (resume_offset > 0) {
            try local_file.seekTo(resume_offset);
        }

        // Download with streaming
        try self.streamDownload(file.download_url, local_file, file.size, resume_offset, model_config.progress_callback);
    }

    /// Stream download with progress callbacks
    fn streamDownload(self: *Self, url: []const u8, output_file: std.fs.File, total_size: u64, resume_offset: u64, progress_callback: ?*const fn (u64, u64) void) !void {
        // This is a simplified implementation - in practice you'd use a proper HTTP client
        // For now, we'll use curl as a subprocess with progress tracking

        const curl_args = try self.buildCurlArgs(url, output_file, resume_offset > 0);
        defer {
            for (curl_args) |arg| {
                self.allocator.free(arg);
            }
            self.allocator.free(curl_args);
        }

        var child = std.process.Child.init(curl_args, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Monitor progress (simplified - would need proper curl progress parsing)
        var downloaded: u64 = resume_offset;
        const start_time = std.time.milliTimestamp();

        while (true) {
            std.time.sleep(1000 * 1000 * 1000); // 1 second

            const current_size = self.getFileSize(output_file) catch downloaded;
            if (current_size > downloaded) {
                downloaded = current_size;

                if (progress_callback) |callback| {
                    callback(downloaded, total_size);
                }

                const elapsed = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time)) / 1000.0;
                const speed = @as(f64, @floatFromInt(downloaded - resume_offset)) / elapsed;
                const percentage = @as(f32, @floatFromInt(downloaded * 100)) / @as(f32, @floatFromInt(total_size));

                std.log.info("📊 Progress: {d:.1}% ({d:.1} MB/s)", .{ percentage, speed / (1024 * 1024) });
            }

            // Check if process is still running
            if (child.poll()) |_| break;
        }

        const exit_code = try child.wait();
        if (exit_code != .Exited or exit_code.Exited != 0) {
            return DownloadError.NetworkError;
        }
    }

    /// Build curl arguments for download
    fn buildCurlArgs(self: *Self, url: []const u8, output_file: std.fs.File, should_resume: bool) ![][]const u8 {
        _ = output_file;

        var args = std.ArrayList([]const u8).init(self.allocator);

        try args.append(try self.allocator.dupe(u8, "curl"));
        try args.append(try self.allocator.dupe(u8, "-L")); // Follow redirects
        try args.append(try self.allocator.dupe(u8, "--progress-bar"));

        if (should_resume) {
            try args.append(try self.allocator.dupe(u8, "-C"));
            try args.append(try self.allocator.dupe(u8, "-")); // Auto-resume
        }

        try args.append(try self.allocator.dupe(u8, "-o"));
        try args.append(try self.allocator.dupe(u8, "-")); // Output to stdout
        try args.append(try self.allocator.dupe(u8, url));

        return try args.toOwnedSlice();
    }

    /// Utility functions
    fn isValidModelId(self: *Self, model_id: []const u8) bool {
        _ = self;
        return std.mem.indexOf(u8, model_id, "/") != null and model_id.len > 3;
    }

    fn ensureDownloadDirectory(self: *Self, path: []const u8) ![]const u8 {
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return try self.allocator.dupe(u8, path);
    }

    fn isFileComplete(self: *Self, file_path: []const u8, expected_size: u64) !bool {
        const file_size = self.getFileSize(file_path) catch return false;
        return file_size == expected_size;
    }

    fn getFileSize(self: *Self, file_path: anytype) !u64 {
        _ = self;

        // Handle both file paths and file handles
        const T = @TypeOf(file_path);
        if (T == std.fs.File) {
            const stat = try file_path.stat();
            return stat.size;
        } else {
            const file = std.fs.cwd().openFile(file_path, .{}) catch return 0;
            defer file.close();
            const stat = try file.stat();
            return stat.size;
        }
    }

    fn validateFileChecksum(self: *Self, file_path: []const u8, expected_sha256: []const u8) !void {
        std.log.info("🔒 Validating SHA256 checksum for {s}", .{file_path});

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.log.err("Failed to open file for checksum validation: {}", .{err});
            return DownloadError.FileSystemError;
        };
        defer file.close();

        // Initialize SHA256 hasher
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Read file in chunks and update hasher
        const chunk_size = 64 * 1024; // 64KB chunks
        var buffer = try self.allocator.alloc(u8, chunk_size);
        defer self.allocator.free(buffer);

        while (true) {
            const bytes_read = try file.readAll(buffer);
            if (bytes_read == 0) break;

            hasher.update(buffer[0..bytes_read]);

            if (bytes_read < chunk_size) break;
        }

        // Finalize hash and convert to hex string
        var hash_bytes: [32]u8 = undefined;
        hasher.final(&hash_bytes);

        const computed_hash = try self.allocator.alloc(u8, 64);
        defer self.allocator.free(computed_hash);

        _ = std.fmt.bufPrint(computed_hash, "{}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch {
            return DownloadError.ChecksumMismatch;
        };

        // Compare with expected hash (case insensitive)
        const expected_lower = std.ascii.allocLowerString(self.allocator, expected_sha256) catch {
            return DownloadError.ChecksumMismatch;
        };
        defer self.allocator.free(expected_lower);

        if (!std.mem.eql(u8, computed_hash, expected_lower)) {
            std.log.err("❌ Checksum mismatch! Expected: {s}, Got: {s}", .{ expected_lower, computed_hash });
            return DownloadError.ChecksumMismatch;
        }

        std.log.info("✅ SHA256 checksum validation passed");
    }
};

/// Model information from HuggingFace API
const ModelInfo = struct {
    model_name: []const u8,
    files: []FileInfo,
    allocator: std.mem.Allocator,

    fn deinit(self: ModelInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.model_name);
        for (self.files) |file| {
            file.deinit(allocator);
        }
        allocator.free(self.files);
    }
};

/// File information
const FileInfo = struct {
    filename: []const u8,
    size: u64,
    sha256: ?[]const u8,

    fn deinit(self: FileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        if (self.sha256) |sha| {
            allocator.free(sha);
        }
    }
};

/// Downloadable file with URL
const DownloadableFile = struct {
    filename: []const u8,
    download_url: []const u8,
    size: u64,
    sha256: ?[]const u8,
};

/// Download the Jan nano model automatically
pub fn downloadJanNanoModel(allocator: std.mem.Allocator, http_client: *http.HttpClient, models_dir: []const u8) ![]const u8 {
    var downloader = ModelDownloader.init(allocator, http_client);
    defer downloader.deinit();

    return try downloader.downloadJanNanoModel(models_dir);
}

// Test function
test "Model downloader validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();

    var downloader = ModelDownloader.init(allocator, &http_client);
    defer downloader.deinit();

    // Test model ID validation
    try std.testing.expect(downloader.isValidModelId("unsloth/Jan-nano-128k-GGUF"));
    try std.testing.expect(!downloader.isValidModelId("invalid"));
}
