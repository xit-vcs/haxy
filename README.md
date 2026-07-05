<p align="center">
<code>                                                 
░██    ░██     ░████    ░██    ░██ ░██    ░██
░██    ░██    ░██ ░██    ░██  ░██   ░██  ░██
░██    ░██   ░██   ░██    ░█████     ░█████
░█████████  ░█████████     ░███       ░███
░██    ░██ ░██      ░██    ░████      ░██
░██    ░██ ░██      ░██   ░██ ░██     ░██
░██    ░██ ░██      ░██  ░██   ░██    ░██
                                                 </code></p>

You're looking at Haxy, a new git forge. This is a work in progress. We're about to do for git forges what Bill Hicks did for comedy, Earth Crisis did for hardcore music, and Marvin Heemeyer did for exterior remodeling. I'm not sure what any of that means but it sounded cool. The point is, strap yourselves in...we're gonna Leeroy Jenkins our way through this!

Haxy isn't usable yet, but you can follow the devlogs starting with [the first one](https://www.youtube.com/watch?v=m7BOY1OCH_Q).

## Why another git forge?

Haxy is based around two design ideas:

### 1. Store project metadata (issues, pull requests, and discussions) in the repo

Keeping project metadata in the repo has a few benefits:

* You can easily replicate it to different Haxy instances.
* You can view/edit it locally and push your changes later, just like you do with code.

You will still be able to edit this data via the UI of a Haxy instance just like any other git forge. Additionally, however, you'll be able to run the Haxy binary locally to browse a repo's issues and other metadata offline. If you have commit access to the repo, you'll also be able to make changes that you can push later.

Haxy repos will have a special branch where events will be stored. Any time project metadata is created or updated, an event will be created. There will be one event per commit and it will be stored as JSON in the commit message itself. The server will consume these events into its database when it receives them -- essentially, a form of event sourcing. See [an early look](https://www.youtube.com/watch?v=0kKKWfaYaKE) at this event system in action.

### 2. Provide a TUI that is served over SSH, in addition to a web UI

Haxy will provide a text user interface (TUI) over SSH, so you can browse the Haxy instance entirely from your terminal. These are sometimes called SSH apps. One big advantage they have is that you are automatically authenticated with your SSH key, so creating an account on a Haxy instance and associating it with your SSH public key can be done instantly.

Additionally, Haxy will provide a web UI for a more typical experience in a web browser. To avoid having separate UI codebases, the web UI will simply render the TUI in your browser. This sounds frightening but it can be done in an accessible way that is usable for screen readers and mobile devices. See [an early look](https://www.youtube.com/watch?v=47e0rzLF1oc) at how the web UI will work.

Here's what it looks like so far in the terminal and on the web:

<p align="center">
<a href="https://raw.githubusercontent.com/xit-vcs/haxy/refs/heads/master/screenshots/terminal.avif"><img src="screenshots/terminal.avif" width="49%" /></a>
<a href="https://raw.githubusercontent.com/xit-vcs/haxy/refs/heads/master/screenshots/web.avif"><img src="screenshots/web.avif" width="49%" /></a>
</p>

## Why not Radicle?

The main difference between Haxy's design and [Radicle](https://radicle.dev/) is that Haxy is not peer-to-peer. While a p2p architecture can be useful in free speech contexts, it can lead to a significant amount of complexity and make it more difficult to have a consistently good experience. Haxy is *federated* in the sense that anyone can run a Haxy instance, and your projects can be easily moved between them. I believe that is pragmatically the kind of decentralization that people want, and it significantly simplifies the implementation.

## How to fire this puppy up and get 'er done

To build, install zig 0.16.0 and do `zig build` and you'll find the binary at `zig-out/bin/haxy`. On a production server you would run this binary with the `serve` subcommand.

The easiest way to try Haxy out is like this:

```
zig build try
```

This will launch a server with fake data that it stores in the `temp-try` directory. It will then launch the TUI directly in your terminal (you can exit by pressing escape). Additionally, you can view the web UI at http://localhost:8000.

A fun test is to push Haxy itself to the server. You can do that by running the following command, which will push it to the server using SSH:

```
GIT_SSH_COMMAND='ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i temp-try/key' git push localhost:admin/haxy HEAD:master
```

After that, go to the admin user in the UI and you'll see Haxy's repo page: http://localhost:8000/repo/admin/haxy/files/branch/master

*"C'mon Alex! You always dreamt about going on a big adventure! Let this be our first!" -- Lunar: Silver Star Story*
