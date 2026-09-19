<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="icon">

# Mac-Olama

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/Mac-Olama)](https://github.com/andrey-lysikov/Mac-Olama/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/andrey-lysikov/Mac-Olama/total)](https://github.com/andrey-lysikov/Mac-Olama/releases)
![Platform](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-blue)

A local LLM assistant for the Mac: a menu bar app that runs MLX models on your machine and answers from a quick panel,
a chat window or Spotlight. Nothing leaves the computer unless you turn web search on.

## Features

- Quick panel (left click on the menu bar icon or a system keyboard shortcut), chat window, Spotlight action "Ask Mac-Olama".
- Search Hugging Face or ModelScope (MLX builds first) for models, or connect it by API.
- Drop images (vision models), PDF and text files into a question.
- Wb search (DuckDuckGo or Google), reading files in folders you allow, running Shortcuts with a confirmation.
- API: Ollama-compatible and OpenAI-compatible server on `localhost:11434`.
- The models is unloaded after an idle timeout, or kept resident if you choose "Never".
- English and Russian interface.
- Liquid Glass support.

## Tech

Swift 6, SwiftUI + AppKit, AppIntents, SwiftData, Apple Silicon only, for MacOS 26 and newer. Also: 
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm);
- [swift-transformers](https://github.com/huggingface/swift-transformers).
