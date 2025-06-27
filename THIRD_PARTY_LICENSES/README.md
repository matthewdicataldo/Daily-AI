# Third-Party Licenses

This directory contains license information for all third-party dependencies used in this project.

## Overview

This project uses the following third-party dependencies:

| Dependency | Version | License | Usage |
|------------|---------|---------|-------|
| [zig-network](https://github.com/ikskuh/zig-network) | bcf6cc8 | MIT | Networking library for HTTP clients |
| [yazap](https://github.com/prajwalch/yazap) | 0.6.3 | MIT | Command-line argument parsing |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | latest | Unlicense | YouTube video metadata extraction (runtime download) |
| [Skytable](https://github.com/skytable/skytable) | latest | Apache 2.0 | High-performance database for caching (runtime download) |

## Runtime Dependencies

Some dependencies are downloaded at runtime:

- **yt-dlp**: Downloaded from GitHub releases during build
- **Skytable (skyd)**: Downloaded from GitHub releases during build

## License Files

- `zig-network-LICENSE.txt` - MIT License for zig-network
- `yazap-LICENSE.txt` - MIT License for yazap  
- `yt-dlp-LICENSE.txt` - Unlicense for yt-dlp
- `skytable-LICENSE.txt` - Apache 2.0 License for Skytable

## Compliance

All dependencies are compatible with commercial use and distribution. This project complies with all license requirements including:

- Attribution requirements (MIT licenses)
- Copyright notice preservation
- License text inclusion (this directory)

## Updates

License information should be updated when dependencies are upgraded. Check the source repositories for the most current license terms.

Last updated: 2024-06-27