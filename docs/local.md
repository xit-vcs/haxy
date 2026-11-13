Most git forges only let you see your issues via their website, so you lose access when their server goes down. Since haxy stores issues and other project metadata in the repo itself, there's nothing stopping you from reading and editing them on your own computer. That is what local mode is for.

Running it

* Install haxy and run it with no subcommand inside any git repo:

  ```
  git clone ssh://try.haxy.net/user:project
  cd project
  haxy
  ```

* The TUI opens in your terminal, showing the repo's files, commits, refs, issues, patches, and discussions. Haxy also serves the same UI on a local port, which is shown in the footer, in case you'd rather use a browser.

* If you cloned the repo from a haxy server, its `haxy/events` branch came along with it, so all of the project's metadata is already there. Haxy reads it straight from the remote-tracking branch, so you don't need to check anything out. It all works completely offline.

Editing

* You can create and edit issues, discussions, and comments just like you would on the server. You can also open a patch from one of your local branches.

* Each change is committed as an event on your local `haxy/events` branch. There is no account in local mode, so the commit author comes from your `user.name` and `user.email` git config, just like your normal commits.

* None of this touches your working tree, index, or `HEAD`. The events branch is updated in the background, so you can keep working on your code while you file issues about it.

Syncing

* When you're ready, go to the events tab and press the sync button. It says "sync needed!" when your local events differ from the server's.

* Sync pulls in everyone else's changes and pushes yours. If you both changed the same issue, the changes are merged via the [event system](event.md). A field that both of you changed differently is marked as a conflict for someone to resolve; the sync itself never fails because of it.

* Pushing requires that you have push access to the repo on the server. The server consumes your events as part of the push, so if any of them are invalid, the whole push is rejected and nothing changes on the server.

* Sync goes over SSH and never prompts for anything, so your SSH key must already be registered on the server.

Making your own client

* Haxy's TUI is not the only way to use this data. The events branch is just a bunch of commits, so any program that can read a git repo can build its own UI for it, whether that's an editor plugin, a GUI, or a script.

* Such a client reads the events on the `haxy/events` branch, shows them however it likes, and makes edits by committing new events to it. Read more about the [event system](event.md).

* To sync, do what haxy's sync button does:

  1. Fetch the server's events branch with `git fetch origin +refs/heads/haxy/events:refs/remotes/origin/haxy/events`.

  2. Combine it with your local `haxy/events`. If one is an ancestor of the other, just move your local branch to the newer one. Otherwise, make a merge commit with an empty tree whose parents are your local tip and the remote tip.

  3. Push it with `git push origin haxy/events`.

Browsing an instance

* A client doesn't even need a clone. Any page on a haxy server returns JSON instead of HTML if the request has an `Accept: application/json` header. It's the same data haxy's own web UI renders from, so a client can use it to browse an instance in whatever UI it likes.

* Pages that don't need a login can be fetched from any origin, so a web page hosted somewhere else can build a read-only client this way.

* A native client can also make changes. It logs in by posting to `/login` at the end of any page's url, and keeps the session cookie it gets back. After that it can post the same forms haxy's web UI does, such as `/new`, `/edit`, or `/close` at the end of an issue's url. Each one answers with a redirect, and following it with the JSON header returns the updated page, including the error if the form failed. That's everything needed for a fully-functional client.
