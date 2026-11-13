Most git forges keep issues, pull requests, and discussions in a database on the server, completely separate from the repo. While it is easy to move your repo to another forge, it's often a pain to move the rest of this data. Like Hotel California, you can come but you can never leave.

Haxy instead stores all of that in the repo itself, so it moves around with your code. This also means you can view and edit this metadata locally. If you have haxy installed locally, just clone the repo and run `haxy` inside it. Haxy will run in [local mode](local.md), displaying its UI in your terminal and all your issues and other metadata will be readable offline.

The events branch

* Every haxy repo has a branch called `haxy/events`. It has nothing to do with your code; it is just a long chain of commits, one per event.

* Other projects like [git-bug](https://github.com/git-bug/git-bug) and  [Radicle](https://radicle.dev/) (mentioned below) also store issues in the git repo, but they choose to use custom refs. Haxy just puts them in a branch, because git retrieves branches with every `clone` and `fetch`. This makes it very easy to see your issues offline: just clone a repo and run `haxy` inside it. Using a branch also means two events branches can be combined with an ordinary merge commit (see the section below on merging).

* An event is created whenever some piece of metadata is created, updated, or removed. The event is stored as JSON in the commit message:

  ```json
  {"id":"5f1c...","kind":"issue","data":{"title":"it crashes","description":"...","labels":"bug","status":"open"}}
  ```

* The `id` names the thing being changed, not the event. Creating an issue makes up a new random id, and editing it later makes another event with the same id and the full new contents. A `null` data removes it.

* Anything that a commit already records is not repeated in the JSON. The author line is who made the event, and the timestamp is when. This matters because events travel between haxy instances, and an instance-specific user id would be meaningless on another server.

* Some events need to carry files. An attachment puts the file in the commit's tree, and a patch revision puts the trees of the code being proposed there, so the objects travel with the branch like any other git objects. Commits on this branch never inherit the parent commit's file tree, so these files won't conflict with any existing files added by other commits.

Consuming events

* Reading a chain of commits every time you want to list issues would be painfully slow, so haxy "consumes" the events into a database: essentially, a form of event sourcing. Consuming walks the new commits on the events branch and turns each one into a record, along with the indexes the UI needs (open issues, issues per label, comments per thread, and so on).

* On the server, repos are stored by xit, so this database is just more data inside the repo's own [xitdb](https://xitdb.net/) file. A push and the consuming of the events it carries happen in a single transaction, so if an event is invalid, the whole push is rejected.

* In [local mode](local.md), a plain git repo has no database to put this in, so haxy keeps a standalone one in a file called `haxy` inside the `.git` dir. It's only a cache; if you delete it, haxy just consumes the events again the next time it opens the repo.

* xitdb is immutable, so haxy keeps the database state after every event commit. If someone rebases and force-pushes the events branch, haxy finds the last commit that is still in the history, throws away every state after it, and consumes from there. Nothing has to be rebuilt from scratch.

Merging

* Since the metadata is in a branch, two people can change it at the same time: one person might edit issues offline using haxy's local mode, and another person may do so on the server. Haxy's local mode displays a "sync" button in the events tab. This will pull the latest events from the server, combine them with the local changes using a regular merge commit, and then push.

* A merge commit isn't an event, so instead of consuming it, haxy does a three-way merge of the records on each side, using their common ancestor as the base. For issues and patches this is done field by field: if only one side changed the title, that change is taken. If both sides changed the same field differently, the record is marked as conflicted and shows up in the UI for someone to resolve. Every other kind of record is merged as a whole: a change made on only one side is taken, and if both sides changed it, the target's version wins.

* A merge never fails. A metadata conflict is something for a person to look at later, not a reason to refuse a sync, because a branch that can't be consumed would be stuck forever. Metadata conflicts are *not* git conflicts; they are first-class conflicts that haxy lets you resolve in the UI.

Where events live

* The project metadata (issues, comments, attachments, assignees, discussions, patches) is in the project's own repo.

* A fork's repo carries the patches and patch revisions it proposes to its target.

* Haxy also uses the event system internally to store instance-specific data like user accounts and user roles for each repo. These are stored in internal git repos and cannot currently be moved to a different haxy instance because they reference internal user IDs.

Comparison to Radicle

* Radicle also stores issues in the repo, but in a different format. Haxy stores all events in a single branch, while Radicle uses custom refs. See the section above on the events branch for an explanation of why haxy went with this design.

* Unlike Radicle, Haxy is not peer-to-peer. I believe p2p architectures lead to a significant amount of complexity and make it difficult to have a consistently good experience. Haxy is *federated* in the sense that anyone can run a Haxy instance, and your projects can be easily moved between them. I believe that is pragmatically the kind of decentralization that people want, and it dramatically simplifies the implementation. See my [video on decentralized p2p](https://www.youtube.com/watch?v=P0yxbttcmzw) for an elaboration of this.
