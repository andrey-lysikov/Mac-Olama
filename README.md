<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="icon">

# Mac-Olama

[![Downloads](https://img.shields.io/github/downloads/andrey-lysikov/Mac-Olama/total)](https://github.com/andrey-lysikov/Mac-Olama/releases)
[![Release](https://img.shields.io/github/v/release/andrey-lysikov/Mac-Olama)](https://github.com/andrey-lysikov/Mac-Olama/releases/latest)
![Platform](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-blue)

An LLM assistant for the Mac: a menu bar app that runs MLX models locally, connects to cloud models, and answers through
a quick panel or a chat window.

## Features

- Quick panel (left click on the menu bar icon or ⌥Space, which you can change in the settings) and a chat window
- Search MLX models on Hugging Face or ModelScope, or connect a model served by another program over an
  OpenAI-compatible API
- Cloud Kimi, DeepSeek, Alibaba Cloud and OpenAI models in dedicated tabs, with per-model context, thinking effort and output limits
- Drop images (vision models), PDFs and text files into a question
- Coding agent: per-chat projects, AGENTS.md and project skills, reviewed edits and patches, scripts and commands,
  Git and PR/MR, LSP navigation and diagnostics, persistent snapshots and required build/test verification
- Built-in tools for web search, maps, tasks, Safari control, and more
- API: Ollama-compatible and OpenAI-compatible server on `localhost:11434`
- Models are unloaded after an idle timeout, or kept resident if you choose "Never"
- English and Russian interface
- Liquid Glass support

## Model hubs

- [Hugging Face](https://huggingface.co/models?library=mlx): search, links and downloads, gated repositories with an
  access token; community MLX builds such as [mlx-community](https://huggingface.co/mlx-community).
- [ModelScope](https://modelscope.cn/models): search, links and downloads; in the API a model is `modelscope:org/repo`.

Only MLX builds are listed: the app runs nothing else locally.

## Cloud models

The **Cloud Kimi** tab connects a [Kimi](https://www.kimi.ai/code) membership: sign in through the browser (OAuth).
The tab shows 5-hour and monthly quota usage with a link to manage the subscription. A custom Base API (and an API key
instead of OAuth) is supported under Advanced.

**Cloud DeepSeek** uses a [DeepSeek API key](https://platform.deepseek.com/api_keys) and shows the available, granted and
topped-up balances rather than subscription quotas. **Cloud Alibaba** accepts a Coding Plan `sk-sp-` key and provides
Qwen, GLM, Kimi and MiniMax models, including `qwen3.7-plus`, `qwen3.6-plus`, `glm-5` and `MiniMax-M2.5`. It shows the
published Pro limits; Alibaba exposes live consumption only in its console, so the tab links there instead of estimating it.

**Cloud OpenAI** signs in to a ChatGPT subscription through the Codex device-authorization flow. It downloads the models
available to the account and shows the current 5-hour, weekly and, where supplied, monthly limits.

## Privacy

Local MLX inference stays on your Mac. When you use cloud models, your messages, attached documents, and relevant chat
context are sent to the selected cloud provider. Optional tools such as web search, page reading, maps, and weather also
make network requests when used.

## Tech

Swift 6, SwiftUI + AppKit, SwiftData, Apple Silicon only, for macOS 26 and newer.

## Based on

- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
- [swift-transformers](https://github.com/huggingface/swift-transformers)
- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [SwiftSoup](https://github.com/scinfu/SwiftSoup)
- [SwiftMath](https://github.com/mgriebling/SwiftMath)
