<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="icon">

# Mac-Olama

[![Downloads](https://img.shields.io/github/downloads/andrey-lysikov/Mac-Olama/total)](https://github.com/andrey-lysikov/Mac-Olama/releases)
[![Release](https://img.shields.io/github/v/release/andrey-lysikov/Mac-Olama)](https://github.com/andrey-lysikov/Mac-Olama/releases/latest)
![Platform](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-blue)

A local LLM assistant for the Mac: a menu bar app that runs MLX models on your machine and answers from a quick panel,
a chat window. Nothing leaves the computer unless you turn web search on.

## Features

- Quick panel (left click on the menu bar icon or ⌥Space, which you can change in the settings) and a chat window.
- Search Hugging Face or ModelScope (MLX builds first) for models, or connect it by API.
- Drop images (vision models), PDF and text files into a question.
- Multiple plugins in system for models (like search, maps, task, safari control etc)
- API: Ollama-compatible and OpenAI-compatible server on `localhost:11434`; the port, the interface and whether it
  answers at all are in the settings.
- The models is unloaded after an idle timeout, or kept resident if you choose "Never".
- English and Russian interface.
- Liquid Glass support.

## Tech

Swift 6, SwiftUI + AppKit, SwiftData, Apple Silicon only, for MacOS 26 and newer. Also: 
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm);
- [swift-transformers](https://github.com/huggingface/swift-transformers).
