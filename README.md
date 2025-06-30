# AI News Generator

A Zig application that automatically generates comprehensive AI news blog posts by aggregating content from multiple sources and analyzing it with Claude AI.

## 🔧 Setup & Installation

### Prerequisites
- **Zig 0.14.1+** ([Download here](https://ziglang.org/download/))
- **Firecrawl API Key** ([Get one here](https://firecrawl.dev/))

### Quick Start
```bash
# Clone and navigate
cd "daily ai"

# Build the project (automatically downloads dependencies)
zig build

# Configure environment variables
cp .env.example .env
# Edit .env and add your FIRECRAWL_API_KEY

# Run with all sources enabled
./zig-out/bin/daily_ai --model claude-sonnet-4 --verbose

# Run with specific sources only
./zig-out/bin/daily_ai --reddit-only
./zig-out/bin/daily_ai --rss-only --no-reddit
```

## ⚙️ Configuration

### Command Line Options
```bash
Usage: daily_ai [OPTIONS]

Options:
  -o, --output=<output>     Output directory (default: ./output)
  -m, --model=<model>       Claude model (default: sonnet)
  -v, --verbose            Enable verbose output
  
Source Filters:
  --reddit-only            Only process Reddit sources
  --no-reddit             Skip Reddit sources
  --rss-only               Only process RSS feeds
  --youtube-only           Only process YouTube sources
  # ... and more for each source type
```

### Source Configuration
Edit `src/core_config.zig` to customize sources:

```zig
// Reddit sources - AI/ML focused subreddits
pub const reddit_sources = [_]RedditSource{
    .{ .subreddit = "LocalLLaMA", .max_posts = 25 },
    .{ .subreddit = "MachineLearning", .max_posts = 20 },
    .{ .subreddit = "artificial", .max_posts = 15 },
    .{ .subreddit = "singularity", .max_posts = 15 },
};

// RSS sources - Major tech news outlets
pub const rss_sources = [_]RssSource{
    .{ .name = "Google AI News", .url = "https://news.google.com/rss/search?q=artificial+intelligence", .max_articles = 20 },
    .{ .name = "TechCrunch AI", .url = "https://techcrunch.com/category/artificial-intelligence/feed/", .max_articles = 15 },
    .{ .name = "Ars Technica", .url = "https://feeds.arstechnica.com/arstechnica/technology-lab", .max_articles = 10 },
};
```

## 🌐 Environment Variables

### Required
- `FIRECRAWL_API_KEY` - Your Firecrawl API key for web content extraction

### Optional  
- `CLAUDE_MODEL` - Claude model to use (default: "sonnet")
- `OUTPUT_DIR` - Output directory (default: "./output")
- `VERBOSE` - Enable verbose logging (default: false)
- `REDDIT_CLIENT_ID` - Reddit API client ID (for API access)
- `REDDIT_CLIENT_SECRET` - Reddit API client secret

## 🧪 Testing & Development

```bash
# Run all tests
zig build test

# Build without running
zig build

# Clean build artifacts
rm -rf zig-cache zig-out .zig-cache

# Check for memory leaks (development)
valgrind ./zig-out/bin/daily_ai --reddit-only
```

### Memory Management
- **Arena allocators** prevent memory leaks
- **Zero double-free errors** after reorganization
- **Shared Reddit client** eliminates concurrent authentication issues
- **Automatic cleanup** at scope boundaries

### Caching Performance
- **3-day TTL** for extracted content (reduces API calls)
- **1-hour TTL** for LLM responses (balances freshness/cost)
- **Skytable backend** for persistent storage
- **Memory fallback** for reliability

## 📋 Current Content Sources

### Reddit (4 subreddits)
- **r/LocalLLaMA** - Local AI model discussions
- **r/MachineLearning** - Academic ML research  
- **r/artificial** - General AI discussions
- **r/singularity** - AGI and future AI topics

### RSS News Feeds (6 sources)
- **Google AI News** - Comprehensive AI news aggregation
- **TechCrunch AI** - Startup and industry news
- **Ars Technica** - Technical analysis and reviews
- **VentureBeat AI** - Business and investment news
- **The Verge AI** - Consumer technology focus
- **MIT Technology Review** - Research and analysis

### Research & Blogs (8 sources)
- **Hugging Face Papers** - Latest ML research
- **OpenAI Blog** - Official announcements
- **Anthropic Blog** - AI safety research
- **Google AI Blog** - Research updates
- **Microsoft AI Blog** - Enterprise AI developments
- **DeepMind Blog** - Advanced AI research

### Social Media (6 sources)
- **YouTube Channels** - AI education and tutorials
- **TikTok** - AI trends and demonstrations

## 🏗️ Architecture Highlights

### Design Principles
- **Data-Oriented Design** - Optimized for memory efficiency
- **Arena Allocators** - Hierarchical memory management
- **Type Safety** - Comprehensive compile-time validation
- **Error Handling** - Graceful degradation with detailed logging
- **Modular Architecture** - Clean separation of concerns

### Key Patterns
- **Base Extractor Framework** - Common functionality inheritance
- **Unified Cache Interface** - Multiple backend support
- **AI Relevance Filtering** - Centralized keyword matching
- **Content Source Abstraction** - Standardized data flow
- **Progress Stream System** - Real-time operation tracking

## 🔒 Security & Privacy

### Data Protection
- **No secrets in source code** - All API keys from environment
- **Secure memory handling** - Proper cleanup of sensitive data
- **Rate limiting** - Respects API terms of service
- **Error sanitization** - No sensitive data in logs

### API Security  
- **OAuth2 for Reddit** - Secure authentication flow
- **HTTPS only** - All external requests encrypted
- **User-Agent compliance** - Respectful API usage
- **Timeout handling** - Prevents hanging connections

## 🎯 Usage Examples

### Generate Today's AI News
```bash
# Complete AI news roundup
./zig-out/bin/daily_ai --verbose

# Focus on specific topics
./zig-out/bin/daily_ai --reddit-only --rss-only

# Quick research update  
./zig-out/bin/daily_ai --research-only --blogs-only
```

### Output Example
see /output

### Development Setup
```bash
# Enable development mode
export VERBOSE=true
export CLAUDE_MODEL=claude-sonnet-4

# Run with memory leak detection
zig build run -Doptimize=Debug

# Format code
zig fmt src/
```