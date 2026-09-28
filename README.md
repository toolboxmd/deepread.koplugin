# Deep Read for KOReader

Pick a topic and read one continuous article about it. The article is written as you
read: when two or fewer pages remain, the next part is requested in the background
and added to the end, so the pages keep coming.

This is a KOReader client for the Deep Read service at <https://deepread.toolbox.md>.

## Install

1. Copy the `deepread.koplugin` folder into KOReader's `plugins/` folder
   (for example `koreader/plugins/deepread.koplugin`).
2. Restart KOReader.
3. Open the menu, then **Tools → Deep Read**.

## Use

1. Type a topic (up to 200 characters) and tap **Read**. KOReader turns on Wi-Fi if needed.
2. A "Thinking about where to begin…" message shows while the first part is written. Tap it to cancel.
3. Turn pages by tapping the right or left side, swiping, or with the page keys.
   Close the article with the × in the title bar or the Back key.
4. If you reach the last page before the next part arrives, you see
   "Writing what comes next…" until it does.

Articles are not saved; closing the viewer ends the article.

## How it talks to the service

Each part is one `POST /api/next` with the topic and the parts written so far. The
service holds the model key and pays for the writing, so there is no API key or account
on the device. When the service has run out of reading credit, the plugin says so.
The plugin honours KOReader's HTTP proxy setting.

## Configuration

Optional. Copy `deepread_configuration.sample.lua` to `deepread_configuration.lua` in
the plugin folder to point the plugin at another Deep Read server.

## Development

`tests/run.lua` checks the event-stream parser and the math cleanup with plain LuaJIT,
outside KOReader:

```sh
luajit tests/run.lua /path/to/koreader/frontend/apps/filemanager/lib/md.lua
```

The Markdown path argument is optional; without it the HTML rendering test is skipped.
