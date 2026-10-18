**Haxy is now in preview! Try it now: https://try.haxy.net/**

You're looking at Haxy, a new git forge. We're about to do for git forges what Bill Hicks did for comedy, Earth Crisis did for hardcore music, and Marvin Heemeyer did for exterior remodeling. I'm not sure what any of that means but it sounded cool. The point is, strap yourselves in...we're gonna Leeroy Jenkins our way through this!

## Why another git forge?

Haxy is based around two design ideas:

### 1. Store project metadata (issues, pull requests, and discussions) in the repo

Keeping project metadata in the repo has a few benefits:

* You can easily replicate it to different Haxy instances.
* You can view/edit it locally and push your changes later, just like you do with code.

You can still edit this data via the UI of a Haxy instance just like any other git forge. Additionally, however, you can run the Haxy binary locally to browse a repo's issues and other metadata offline. If you have push access to the repo, you can make changes locally and push them later. See the devlog about [local mode](https://www.youtube.com/watch?v=BZwUNrJ95ng) and [the issue tracker](https://www.youtube.com/watch?v=kkGUARj5Wdw).

Haxy repos have a special branch called `haxy/events` where events are stored. Any time project metadata is created or updated, an event is created. There's one event per commit, which is stored as JSON in the commit message itself. The server consumes these events into its database when it receives them -- essentially, a form of event sourcing. See the devlog about [the event system](https://www.youtube.com/watch?v=0kKKWfaYaKE).

### 2. Provide a TUI that is served over SSH, in addition to a web UI

Haxy provides a text user interface (TUI) over SSH, so you can browse the Haxy instance entirely from your terminal. These are sometimes called SSH apps. One big advantage they have is that you are automatically authenticated with your SSH key, so creating an account on a Haxy instance and associating it with your SSH public key can be done instantly.

Additionally, Haxy provides a web UI for a more typical experience in a web browser. The web UI simply renders the TUI in your browser. This sounds terrifying, but the web renderer still uses standard HTML controls. The renderer runs from a small webassembly binary, but pages are also initially server-rendered so content can be viewed even if scripts are disabled.

See [the devlogs](https://www.youtube.com/watch?v=89yAiqYEwKg&list=PLhBlJpTc_51WMi20GmgYBTPy0JjAXV3gM) for more.

## Why not Radicle?

The main difference between Haxy and [Radicle](https://radicle.dev/) is that Haxy is not peer-to-peer. I believe p2p architectures lead to a significant amount of complexity and make it difficult to have a consistently good experience. Haxy is *federated* in the sense that anyone can run a Haxy instance, and your projects can be easily moved between them. I believe that is pragmatically the kind of decentralization that people want, and it dramatically simplifies the implementation. See my [video on decentralized p2p](https://www.youtube.com/watch?v=P0yxbttcmzw) for an elaboration of this.

## How to fire this puppy up and get 'er done

To build, install zig 0.17.0 and do `zig build` and you'll find the binary at `zig-out/bin/haxy`. On a production server you would run this binary with the `serve` subcommand. To run it in local mode, just run it with no subcommand in any git repo.

The easiest way to try Haxy out is like this:

```
zig build try
```

This will launch a server with fake data that it stores in the `temp-try` directory. It will then launch the TUI directly in your terminal (you can exit by pressing escape). Additionally, you can view the web UI at http://localhost:8080.

A fun test is to push Haxy itself to the server. You can do that by running the following command, which will push it to the server using SSH:

```
GIT_SSH_COMMAND='ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i temp-try/key' git push localhost:admin:haxy HEAD:master
```

After that, go to the admin user in the UI and you'll see Haxy's repo page: http://localhost:8080/repo/admin/haxy/files/branch:master

*"C'mon Alex! You always dreamt about going on a big adventure! Let this be our first!" -- Lunar: Silver Star Story*
