Haxy has one UI, and it's a TUI. Rather than build a terminal UI for the nerds and a separate web UI for everyone else, haxy builds a single TUI with [xitui](https://github.com/xit-vcs/xitui) and renders it in three places: your terminal, an SSH session, and a web browser.

The terminal

* In local mode, you just run `haxy` inside a repo and the TUI is drawn directly in your terminal. While it runs, haxy also serves the web UI for that repo on a local port, which is shown in the footer.

* A haxy server lets you browse the instance over SSH. When you connect, the server runs the TUI and streams it to you over the SSH channel, so all you need is an SSH client. Each connection gets its own session with its own state.

* Since SSH already authenticates you with your key, this is also the quickest way to make an account: log in once and your key is associated with it.

The web

* The web UI is the same TUI. The server builds the same widgets it would build for a terminal, lays them out on the same grid of characters, and turns that grid into HTML. Each cell is text in a monospace font, so it looks exactly like the terminal version.

* Rendering a TUI in a browser sounds like a recipe for an inaccessible mess, so haxy doesn't just paint characters. Anything you can interact with becomes a standard HTML element placed on top of the grid: text fields are `input` and `textarea`, buttons are `button`, choices are radio inputs, file uploads are file inputs, and links are real `a` tags. Forms are real HTML forms that post to the server.

* This means browsers, screenreaders, and touchscreen devices all know what each control is. Tapping a text field on a phone brings up the keyboard, autofill and spellcheck work, and scrollable areas are native scrolling divs, so they scroll with a finger like any other page.

* The page is rendered on the server first, so it works with javascript disabled. Links navigate, forms submit, and search boxes fall back to plain forms.

* When javascript is enabled, a small webassembly build of haxy takes over. The server embeds the page's data as JSON, and the wasm uses it to build the same widgets in the browser. Keyboard navigation, focus, and resizing are then handled client-side, without a request for every key press. It only goes back to the server when you navigate to another page or submit a form.

* The wasm lays the TUI out to the width of the browser window, so responsive layouts work the same way they do in a resized terminal. On a narrow screen, a list and its detail view show one at a time instead of side by side.
