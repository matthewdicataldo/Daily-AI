const std = @import("std");

/// Progress tracker with visual progress bar
pub const ProgressTracker = struct {
    allocator: std.mem.Allocator,
    progress_arena: std.heap.ArenaAllocator,
    total_steps: u32,
    current_step: u32,
    current_phase: []const u8,
    start_time: i64,
    last_update_time: i64,
    
    pub fn init(allocator: std.mem.Allocator, total_steps: u32) ProgressTracker {
        const now = std.time.timestamp();
        return ProgressTracker{
            .allocator = allocator,
            .progress_arena = std.heap.ArenaAllocator.init(allocator),
            .total_steps = total_steps,
            .current_step = 0,
            .current_phase = "Initializing",
            .start_time = now,
            .last_update_time = now,
        };
    }
    
    pub fn deinit(self: *ProgressTracker) void {
        self.progress_arena.deinit();
    }
    
    pub fn updatePhase(self: *ProgressTracker, phase: []const u8, step: u32) void {
        self.current_phase = phase;
        self.current_step = step;
        self.last_update_time = std.time.timestamp();
        self.printProgress();
    }
    
    pub fn incrementStep(self: *ProgressTracker, phase: []const u8) void {
        self.current_step += 1;
        self.current_phase = phase;
        self.last_update_time = std.time.timestamp();
        self.printProgress();
    }
    
    pub fn complete(self: *ProgressTracker) void {
        self.current_step = self.total_steps;
        self.current_phase = "Complete";
        self.last_update_time = std.time.timestamp();
        self.printProgress();
        
        const total_time = self.last_update_time - self.start_time;
        const minutes = @divTrunc(total_time, 60);
        const seconds = @mod(total_time, 60);
        
        std.log.info("🎉 Pipeline completed in {}m {}s", .{ minutes, seconds });
    }
    
    fn printProgress(self: *ProgressTracker) void {
        const percentage = @min(100, (@as(u32, @intCast(self.current_step)) * 100) / self.total_steps);
        
        // Create progress bar (50 characters wide)
        const bar_width: u32 = 50;
        const filled_width = (@as(u64, percentage) * @as(u64, bar_width)) / 100;
        
        var bar_buffer: [52]u8 = undefined; // 50 + 2 for brackets
        bar_buffer[0] = '[';
        bar_buffer[51] = ']';
        
        const filled_width_u32 = @as(u32, @intCast(filled_width));
        var i: u32 = 1;
        while (i <= bar_width) : (i += 1) {
            if (i <= filled_width_u32) {
                bar_buffer[i] = '=';
            } else {
                bar_buffer[i] = '-';
            }
        }
        
        const bar_str = bar_buffer[0..52];
        
        // Calculate elapsed time with 0.1 second precision using arena allocator
        const elapsed = self.last_update_time - self.start_time;
        const elapsed_seconds_f = @as(f64, @floatFromInt(elapsed));
        const arena_allocator = self.progress_arena.allocator();
        const time_str = std.fmt.allocPrint(arena_allocator, "{d:.1}s", .{elapsed_seconds_f}) catch "0.0s";
        
        std.log.info("📊 {s} {:>3}% {s} | {s} ({}/{})", .{ 
            bar_str, 
            percentage, 
            self.current_phase, 
            time_str,
            self.current_step,
            self.total_steps 
        });
    }
};

/// Progress phases for the AI news generation pipeline
pub const ProgressPhases = struct {
    pub const INIT: u32 = 1;
    pub const CLI_PARSE: u32 = 2;
    pub const CONFIG_LOAD: u32 = 3;
    pub const CLIENT_INIT: u32 = 4;
    pub const REDDIT_EXTRACT: u32 = 5;
    pub const YOUTUBE_EXTRACT: u32 = 6;
    pub const RESEARCH_EXTRACT: u32 = 7;
    pub const BLOG_EXTRACT: u32 = 8;
    pub const NEWS_EXTRACT: u32 = 9;
    pub const CONTENT_PROCESS: u32 = 10;
    pub const CLAUDE_ANALYSIS: u32 = 11;
    pub const BLOG_GENERATION: u32 = 12;
    pub const COMPLETE: u32 = 13;
    
    pub const TOTAL_STEPS: u32 = 13;
};

test "progress tracker basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tracker = ProgressTracker.init(allocator, 5);
    defer tracker.deinit();
    
    tracker.updatePhase("Testing", 1);
    tracker.incrementStep("Testing Step 2");
    tracker.complete();
    
    try std.testing.expect(tracker.current_step == 5);
}