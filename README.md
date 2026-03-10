# Clip Dock iOS

The iOS client for [Pinix](https://github.com/epiral/pinix) — use Clips on your iPhone and iPad.

[English](README.md) | [中文](README.zh-CN.md)

## Features

- Connect to any Pinix Server via Bookmarks (URL + Token)
- Native WKWebView rendering for Clip web UIs
- Bridge API for Clip ↔ native communication
- Connect-RPC (gRPC) for Invoke / ReadFile / GetInfo

## Build

```bash
# Generate protobuf
buf generate

# Open in Xcode
open ClipDock.xcodeproj

# Or generate via project.yml (XcodeGen)
xcodegen generate
```

## Requirements

- Xcode 16+
- iOS 17+
- A running Pinix Server (local or remote)

## Architecture

```
┌──────────────────────────────────┐
│  ClipDock iOS App                 │
│                                   │
│  WKWebView                        │
│  ├─ Loads pinix-web://<clip>/    │
│  ├─ Bridge.invoke() → native     │
│  └─ pinix-data:// for files     │
│                                   │
│  Native Layer                     │
│  ├─ Connect-RPC client           │
│  ├─ ClipService.Invoke (stream)  │
│  ├─ ClipService.ReadFile         │
│  └─ Bookmark management          │
└──────────────────────────────────┘
         │
         ▼
   Pinix Server
```
