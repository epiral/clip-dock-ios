# Clip Dock iOS

[Pinix](https://github.com/epiral/pinix) 的 iOS 客户端 — 在 iPhone 和 iPad 上使用 Clips。

[English](README.md) | [中文](README.zh-CN.md)

## 功能

- 通过 Bookmark（URL + Token）连接任意 Pinix Server
- 原生 WKWebView 渲染 Clip 的 Web UI
- Bridge API 实现 Clip ↔ 原生通信
- Connect-RPC (gRPC) 调用 Invoke / ReadFile / GetInfo

## 构建

```bash
# 生成 protobuf
buf generate

# 在 Xcode 中打开
open ClipDock.xcodeproj

# 或通过 project.yml 生成（XcodeGen）
xcodegen generate
```

## 要求

- Xcode 16+
- iOS 17+
- 一个运行中的 Pinix Server（本地或远程）

## 架构

```
┌──────────────────────────────────┐
│  ClipDock iOS App                 │
│                                   │
│  WKWebView                        │
│  ├─ 加载 pinix-web://<clip>/     │
│  ├─ Bridge.invoke() → 原生层     │
│  └─ pinix-data:// 读取文件       │
│                                   │
│  原生层                           │
│  ├─ Connect-RPC 客户端            │
│  ├─ ClipService.Invoke（流式）    │
│  ├─ ClipService.ReadFile          │
│  └─ Bookmark 管理                 │
└──────────────────────────────────┘
         │
         ▼
   Pinix Server
```
