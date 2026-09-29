# Deep Read for KOReader

Pick a topic and read one continuous article about it. Each article is a real book that
KOReader's own reader opens, so your fonts, margins, dictionary, highlights and progress
all work as usual. The book keeps growing ahead of you: when three or fewer pages remain,
the next part is written in the background and added to the end.

This is a KOReader client for the Deep Read service at <https://deepread.toolbox.md>.

## Install

Works with KOReader v2025.04 and later (tested on v2025.04 and v2026.07.1).

1. Copy the `deepread.koplugin` folder into KOReader's `plugins/` folder
   (for example `koreader/plugins/deepread.koplugin`).
2. Restart KOReader. A `Deep Read` folder with a `Deep Read` book appears in your home
   folder.

## Use

1. Open the `Deep Read` book (or **Tools → Deep Read**). Type a topic (up to 200
   characters) and tap **Read**. KOReader turns on Wi-Fi if needed.
2. A "Thinking about where to begin…" message shows while the first part is written.
   Tap it to cancel.
3. The article opens as its own book in the `Deep Read` folder. Read it like any book.
   New parts are added in place without moving your page.
4. If you ever reach the end before the next part arrives, you see
   "Writing what comes next…" until it does.
5. To continue an article later, open its book again.

Each article keeps its state in hidden files next to it (`.<title>.epub.deepread.lua`
and KOReader's `.old` backup of it). Deleting the book and those files deletes the
article.

## How it talks to the service

Each part is one `POST /api/next` with the topic and the parts written so far. The
service holds the model key and pays for the writing, so there is no API key or account
on the device. When the service has run out of reading credit, the plugin says so.
The plugin honours KOReader's HTTP proxy setting.

## Configuration

Optional. Copy `deepread_configuration.sample.lua` to `deepread_configuration.lua` in
the plugin folder to point the plugin at another Deep Read server.

## Development

`tests/run.lua` checks the event-stream parser, the math cleanup and the zip writer with
plain LuaJIT, outside KOReader:

```sh
luajit tests/run.lua /path/to/koreader/frontend/apps/filemanager/lib/md.lua
```

The Markdown path argument is optional; without it the HTML rendering test is skipped.
