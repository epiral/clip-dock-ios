# Clip Dock iOS

The iOS client for [Pinix](https://github.com/epiral/pinix) — use Clips on your iPhone, and expose iPhone capabilities as Edge Clips.

[English](README.md) | [中文](README.zh-CN.md)

## Features

- Connect to any Pinix Server via Bookmarks (URL + Token)
- Native WKWebView rendering for Clip web UIs
- Bridge API for Clip ↔ native communication
- gRPC (grpc-swift-2) for Invoke / ReadFile / GetInfo

### Edge Clip

Turn your iPhone into a Pinix Edge device. Other Clips and Agents can invoke iPhone capabilities remotely:

| Command | Description |
|---------|-------------|
| `get-location` | GPS coordinates |
| `health-query` | HealthKit data (steps, heart rate, sleep, blood oxygen...) |
| `get-device-info` | Device model, OS version, battery |
| `send-notification` | Push a local notification |
| `get-clipboard` | Read clipboard |
| `set-clipboard` | Write clipboard |
| `haptic` | Trigger haptic feedback |
| `list-contacts` | Query address book |
| `list-events` | List calendar events |
| `create-event` | Create calendar event |

All commands support `--help` for usage details.

### Setup Edge

1. Open Clip Dock → tap 📡 (antenna icon) → Edge Settings
2. Enable Edge, enter Pinix Server URL and Super Token
3. Save → iPhone auto-connects and registers capabilities
4. From any terminal: `pinix invoke get-location --server <url> --token <token>`

Token is stable across reconnects and server restarts.

## Architecture

```
┌──────────────────────────────────┐
│  ClipDock iOS App                │
│                                  │
│  WKWebView (Clip UI)             │
│  ├─ Bridge.invoke() → native     │
│  └─ pinix-web/data:// schemes   │
│                                  │
│  Capabilities Layer              │
│  ├─ Location   ├─ Health         │
│  ├─ Contacts   ├─ Calendar       │
│  ├─ Clipboard  ├─ Notification   │
│  ├─ Haptic     └─ DeviceInfo     │
│                                  │
│  Edge Module                     │
│  ├─ EdgeService.Connect (gRPC)   │
│  ├─ EdgeCommandRouter            │
│  └─ Auto-reconnect + status UI   │
│                                  │
│  Bridge Handlers (thin wrappers) │
│  └─ JS ↔ Capabilities           │
└──────────────────────────────────┘
         │              │
    ClipService    EdgeService
         │              │
         ▼              ▼
      Pinix Server (Hub)
```

## Build

```bash
buf generate              # Generate protobuf
xcodegen generate         # Generate Xcode project
open ClipDock.xcodeproj   # Open in Xcode
```

## Requirements

- Xcode 16+
- iOS 18+
- A running Pinix Server (local or remote)
