# Mac-Olama

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/Mac-Olama)](https://github.com/andrey-lysikov/Mac-Olama/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/andrey-lysikov/Mac-Olama/total)](https://github.com/andrey-lysikov/Mac-Olama/releases)
![Platform](https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-blue)

A local LLM assistant for the Mac: a menu bar app that runs MLX models on your machine and answers from a quick panel,
a chat window or Spotlight. Nothing leaves the computer unless you turn web search on.

## Features

- **Ask anywhere** — quick panel (left click on the menu bar icon or a system keyboard shortcut), chat window, Spotlight action "Ask Mac-Olama".
- **Models** — search Hugging Face and the Ollama library, or paste a link; a verdict shows whether a model fits this Mac.
  One download at a time with pause, resume after restart and per-model context size.
- **Images and files** — drop images (vision models), PDF and text files into a question.
- **Features for the model** (off by default) — web search (DuckDuckGo or Google), reading files in folders you allow, running Shortcuts with a confirmation.
- **API** — Ollama-compatible and OpenAI-compatible server on `localhost:11434`.
- **Memory-friendly** — the model is unloaded after an idle timeout, or kept resident if you choose "Never".
- English and Russian interface, Liquid Glass design.

## Install

Download the dmg from the [latest release](https://github.com/andrey-lysikov/Mac-Olama/releases/latest) and drag the app to Applications.

The application is not officially signed: on first launch allow it in **System Settings → Privacy & Security**.

## Build

Xcode 26+, Apple Silicon. Run `xcodebuild -downloadComponent MetalToolchain` once, open `MacOlama.xcodeproj` and run.
Spotlight only sees the app from an indexed location, so copy the built app to `/Applications` to try the Spotlight action.
Release dmg files are built by GitHub Actions (`.github/workflows/release.yml`) when the project version is raised.

When Xcode asks about the `MLXHuggingFaceMacros` macro, choose **Trust & Enable**.

## Tech

Swift 6, SwiftUI + AppKit, AppIntents, SwiftData. Inference: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm);
tokenizers: [swift-transformers](https://github.com/huggingface/swift-transformers). Everything else is in the project.

## License

Apache 2.0 — see [LICENSE](LICENSE).
