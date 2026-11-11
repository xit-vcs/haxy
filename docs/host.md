Running a haxy instance is meant to be boring. It's a single binary with no database server, no background workers, and no config file. Everything it knows lives in one data directory.

The serve subcommand

* Build haxy with `zig build` and copy `zig-out/bin/haxy` to your server. Then run it with the `serve` subcommand:

  ```
  haxy serve --data-dir /var/lib/haxy --web-url https://example.com --ssh-listen 0.0.0.0:22 --ssh-url ssh://example.com
  ```

* `--data-dir` is where everything is stored. It defaults to the current directory, so you'll want to set it. It's created on the first run.

* `--web-listen` is the address the web UI listens on. It defaults to `127.0.0.1:8080`, which is what you want if a reverse proxy sits in front of it (see below). The same listener serves git clones over HTTP.

* `--ssh-listen` is the address the SSH server listens on. It defaults to `127.0.0.1:8022`, so it's only reachable from the server itself until you change it. SSH serves the TUI and handles git over SSH. You can pass `none` to disable it, but keep in mind that pushes only go over SSH, so nobody will be able to push.

* `--web-url` and `--ssh-url` are the public urls shown to users, such as in clone commands. Haxy can't guess these, because it doesn't know what is in front of it, so without them it shows localhost urls.

* `--max-repo-size` caps how big each repo can get on disk, like `1G`. A push that would go past it is rejected. There is no limit by default, which is fine if you trust your users, and not fine if you've put your instance on the internet.

* The listen addresses are IPv4 only for now.

The reverse proxy

* Haxy's web listener only speaks plain HTTP. It doesn't do TLS or certificates, so you need a reverse proxy in front of it to provide HTTPS.

* [Caddy](https://caddyserver.com/) is the easiest choice, because it gets and renews certificates by itself. The entire Caddyfile is:

  ```
  example.com {
      reverse_proxy 127.0.0.1:8080
  }
  ```

* Whatever proxy you use, it must pass along the original `Host` header (Caddy does by default). Haxy compares it against the `Origin` header to reject form posts from other websites, so a proxy that rewrites it will make every form fail.

* SSH does not go through the proxy. It's not HTTP, so haxy has to listen on a public address itself. Haxy should have port 22, so users don't need to type a port. That means moving your server's own sshd to a high port like 2222.

The data directory

* Inside the data dir you'll find:

  * `admin/` is the instance's own repo, which holds the user accounts. It also has an `ABOUT.md` file that is shown on the home page. Just edit it in place; it's re-read on every page load. The first line is "# HAXY" which determines what is shown at the top of the page; editing that will allow you to customize the title.

  * `users/` holds a directory per user, with their own repo plus the repos and forks they own.

  * `ssh_host_ed25519_key` is the SSH host key, which is generated on the first run. Back it up. If it changes, everyone who has connected before gets a scary host key warning.

  * `sessions/` holds web login sessions. Deleting it logs everyone out.

* Backing up the data dir is enough to back up the whole instance. Since all project metadata is stored in the repos themselves (see [event.md](event.md)), there is no separate database to dump.

* When someone makes a new repo with "copy repo" or makes a new patch that forks the repo, haxy copies that repo's database file. On most filesystems that is a full copy, so a fork of a big repo costs just as much disk as the original. However, haxy copies with `copy_file_range`, which makes a reflink on filesystems that support them, such as XFS and Btrfs. A reflinked copy is nearly instant and shares its blocks with the original until one of them changes. It's worth putting the data dir on one of these filesystems.

Customizing the web UI

* You can change the web UI without forking haxy. Make a small Zig project that depends on haxy, and in its root file re-export haxy's `main` and declare `pub const haxy_frontend: haxy.web.Frontend`. Its `files` are served ahead of haxy's own, so a file with the same path replaces haxy's version.
* For a light restyle, set `files` to include your own copy of `index.html`.
* To show a different name than "HAXY" in page titles, set `site_name`. Haxy always follows it with the user or repo the page shows.
* To replace the web UI completely, also set `renderHtml`, which receives each page's data and writes the html for the template's `{{{ HAXY_HTML }}}` token. Everything else works as before, including the `serve` subcommand, the TUI over SSH and git. See [hyperhaxy](https://github.com/xit-vcs/hyperhaxy) for an example of this.
