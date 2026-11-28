# Changelog

## 1.0

- Introducing cloud models! Browser sign-in (OAuth), a live model catalog, per-model context and thinking effort
- Cloud models appear in every model list and in the app's API, with tool support
- Dedicated DeepSeek, Alibaba Cloud and OpenAI tabs; DeepSeek balance, Coding Plan limits and ChatGPT quota bars
- Coding agent: per-chat projects, AGENTS.md and skills, reviewed edits and patches, scripts and commands, Git and PR/MR
- LSP navigation and diagnostics, persistent coding snapshots/tasks, and mandatory build/test verification after edits
- Hour and monthly quota bars, remaining quota, a profile with an avatar, and a subscription management link
- Update dependencies (swift-transformers 1.4.0, SwiftSoup 2.14.4)
- Bug fixes

## 0.8

- Remove toolbar in chats
- Optimise menu
- Remove comments
- Add model descriptions and links in search

## 0.7

- Mail plugin: search and read emails and the text of their attachments
- Video transcripts for YouTube, VK Video and Rutube
- Chat export to PDF, Markdown and HTML
- Update dependencies
- Chat behavior update
- Bug fixes


## 0.6

- Behavior fixes in chats
- Update dependencies
- About page
- Maps navigator plugin


## 0.5

- Model search lists only MLX builds for Apple Silicon
- Connect by API speaks only the OpenAI-compatible API
- API: reasoning comes apart from the answer (`thinking`, `reasoning_content`)
- API: pull and delete are refused, models are managed in the app
- Multiple fixes

## 0.4

- Enable arrow for chat scroll position.
- Update icon for new chat in panel.
- Contexts are shown in the panel search input; move them to the bottom.
- Get Location plugin.
- Maps plugin for LLM.
- Safari browser control plugin for LLM.
- Calendar plugin control.
- Screen control plugin.
- Timer and Time plugin.

## 0.3

- Rewrite chat windows
- Add MTP support
- Increase size under messages
- Add model temperature control
- Dynamic t/s format
- Toggle for showing LLM thinking
- New settings page


## 0.2

- HTML and Markdown reader
- The panel now floats above other windows
- Allow adding models via API
- Check models and the application for updates
- Update app icon
- Remove Ollama and add ModelScope as models hub
- Remove system keychain usage

## 0.1

- First release: menu bar app, quick panel, chat window, Spotlight action
- MLX inference for text and vision models
- Model library: Hugging Face, Ollama and links; download queue with pause and resume
- Ollama and OpenAI compatible API on localhost
- Web search, file reading and Shortcuts as optional features for the model
- Safari toolbar button and pasted/dropped links attach the page text for the model
- English and Russian interface
