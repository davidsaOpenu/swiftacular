---
marp: true
theme: default
paginate: true
title: "The Swift Object Backend"
author: "Ziv Entin"
style: |
  section {
    font-size: 22px;
    padding: 20px;
  }
---

# The Swift Object Backend

Ziv Entin · 2026-07-03

![w:900](images/swift.jpg)

---

# Objectives

- How requests for objects are handled
- How Swift stores objects on disk
- What we can change in this process

---

# Request path
The proxy and ring decide where; the object server does as it's told.

![](graphs/slide03.svg)

<!--
A request for an object goes through several layers before it reaches the disk.
-->

---

# The storage classes
The object server reaches storage through a DiskFileManager and its DiskFiles.

![](images/classtree.svg)

<!--
This is the part of Swift responsible for disk operations. Swift provides two
DiskFile families: one for replication and one for erasure coding. In addition,
we can create our own.
-->

---

# What DiskFile does
DiskFile is the per-object interface: a reader, a writer, and direct operations.

![h:540](graphs/slide05.svg)

<!--
This interface is also the documented contract any replacement would need to
fulfill. reader() and get_metadata() need the DiskFile to be opened first;
writing, deleting and updating metadata do not.
-->

---

# Standard file layout
Objects live at `<device>/objects/<partition>/<suffix>/<hash>/<ts>.<ext>`.

![](graphs/slide06.svg)

<!--
Temporary files live outside objects/, in <device>/tmp. These are examples of
how different objects look on disk.
-->

---

# Standard write
Write to a temp file, attach metadata as xattrs, then rename it into place.

![h:540](graphs/slide07.svg)

<!--
Objects are written in steps. First create a temporary file under
<device>/tmp. Second fill it with the object's data. Lastly store the object's
metadata in the file's xattrs, fsync, and rename it to <ts>.data in the hash
directory.
-->

---

# Standard read
Sort the object's files by timestamp and use the newest.

![](graphs/slide08.svg)

<!--
The newest .meta supplies the metadata, the newest .data the body; a newer .ts
means the object is gone.
-->

---

# Safety
Readers never see an incomplete file: it only appears via an atomic rename.

![h:540](graphs/slide09.svg)

<!--
Files are written in <device>/tmp and only renamed into the object's directory
once complete. Afterwards the older .data is unlinked; a reader that already has
it open keeps reading it until it closes the file.
-->

---

# What DiskFileManager does
The object server gets DiskFiles through `get_diskfile()` — but other callers need more.

![h:540](graphs/slide10.svg)

<!--
The Manager is called in other ways too — shown here as ???.
-->

---

# Beyond the DiskFile interface
Swift's daemons also rely on these `diskfile.py` helpers and the layout they assume.

![](graphs/slide11.svg)

<!--
These are not part of any documented interface; most are module-level
functions rather than DiskFileManager methods. This list is incomplete and may
change.
-->

---

# Erasure Coding
EC adds `#<frag>` (fragment index) and `#d` (durable, set by `commit()`).

![](graphs/slide12.svg)

---

# Custom DiskFileManager
A replacement keeps Swift's core strengths but loses what depends on the reference layout.

![h:530](graphs/slide13.svg)

---

# Conclusion

- Object storage is controlled by DiskFileManager
- Immutable timestamped storage allows efficient reads/writes
- The DiskFileManager can be swapped at a cost

---

# Q&A
