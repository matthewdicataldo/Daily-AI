# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Build and Run
```bash
# Build the project (automatically downloads dependencies)
zig build

# Run with all sources enabled
./zig-out/bin/daily_ai --model claude-sonnet-4 --verbose

# Run specific source types
./zig-out/bin/daily_ai --reddit-only
./zig-out/bin/daily_ai --rss-only --no-reddit
```

### Testing and Development
```bash
# Run all tests
zig build test

# Clean build artifacts
rm -rf zig-cache zig-out .zig-cache

# Format code
zig fmt src/

# Memory leak detection (development)
valgrind ./zig-out/bin/daily_ai --reddit-only
```

## Architecture Overview

### Core Design Principles
- **Data-Oriented Design**: Memory-efficient arena allocators with hierarchical cleanup
- **Parallel Content Extraction**: Multi-threaded processing across 6 source types (Reddit, YouTube, TikTok, Research, News, RSS)
- **Unified Caching System**: Multi-backend caching (Skytable + memory fallback) with configurable TTL
- **Progressive Stream Processing**: Real-time progress tracking with operation-level status updates

### Key Architecture Components

#### Content Extraction Pipeline
- **Base Extractor Framework** (`src/extract_base.zig`): Common functionality for all extractors
- **Source-Specific Extractors**: Modular extractors for each content type with API integration
- **Cache-Aware Processing**: All extractors check cache first, extract on miss, then cache results
- **Parallel Execution**: Thread pool manages concurrent extraction across source types

#### AI Processing Chain
- **Content Processor** (`src/ai_processor.zig`): Deduplication, relevance filtering, data-oriented processing
- **Claude AI Integration** (`src/ai_claude.zig`): Full content analysis with proper categorization
- **Relevance Filter** (`src/ai_relevance_filter.zig`): Centralized keyword matching system

#### Caching Architecture
- **Multi-Backend System**: Skytable primary + memory fallback
- **Cache Hierarchy**: Hot/cold cache separation with memory pools
- **TTL Management**: 3-day content cache, 1-hour LLM response cache
- **Performance Monitoring**: Built-in cache hit/miss tracking

#### Configuration System
- **Compile-Time Configuration** (`src/core_config.zig`): Edit source arrays to add/remove content sources
- **Environment-Based Settings**: API keys, output directories, model selection via `.env`
- **CLI Override System**: Command-line arguments override configuration defaults

### Module Organization

#### Core Modules
- `src/core_*`: Configuration, types, utilities
- `src/common_*`: HTTP client, environment loading

#### Content Extraction
- `src/extract_*`: Source-specific extractors (Reddit, YouTube, RSS, etc.)
- `src/external_*`: Third-party API integrations (Firecrawl, GitIngest, MCP)

#### AI Processing
- `src/ai_*`: Claude integration, content processing, research analysis
- `src/cache_*`: Multi-backend caching system with Skytable integration

#### Output Generation
- `src/output_generator.zig`: Markdown blog post generation
- `src/cli_*`: Command-line interface and progress tracking

## Key Configuration Files

### Content Sources (`src/core_config.zig`)
- **Reddit Sources**: 7 AI/ML subreddits with customizable max posts
- **YouTube Channels**: 9 AI education channels with transcript support
- **RSS Feeds**: 7 major tech news outlets
- **Research Sources**: ArXiv and Hugging Face papers
- **Blog Sources**: Official AI company blogs (OpenAI, Anthropic, etc.)

### Environment Setup
```bash
# Required
FIRECRAWL_API_KEY=your_key_here

# Optional
CLAUDE_MODEL=claude-sonnet-4
REDDIT_CLIENT_ID=your_reddit_id
REDDIT_CLIENT_SECRET=your_reddit_secret
```

## Development Notes

### Memory Management
- All extractors use arena allocators to prevent memory leaks
- Main arena deallocates all memory at program end
- Individual item cleanup handled explicitly in loops

### Error Handling
- Graceful degradation: failed extractors don't stop the pipeline
- Detailed logging with progress tracking
- Cache fallbacks for reliability

### Performance Optimization
- Parallel extraction reduces total runtime significantly
- Caching reduces API calls and improves response times
- Data-oriented processing minimizes allocations

### Adding New Content Sources
1. Add source configuration to appropriate array in `src/core_config.zig`
2. Implement extractor following the base extractor pattern
3. Add parallel extraction function in `src/main.zig`
4. Update CLI argument parsing if needed