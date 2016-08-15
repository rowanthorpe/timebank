Timebank
========

This is a combination of a PostgreSQL schema, Nginx config, Kong config, Freeswitch
config, and Lua scripts.

When combined they provide a REST interface and an IVR interface for manipulating the
same data (for participation in a "time bank").

History
-------

This code was written for [Open Lab Athens](https://www.olathens.org) in 2016 and was
left in a transitional state when during a "version 2" rewrite the project was put on
hiatus so we could work on other more urgent/clearly defined projects. It is based on
a previously fully working (less functional) "version 1", much of which is still
visible in commented-out sections, and this code is expected to be most useful for
scavenging from and altering for different needs. Due to having to heavily redact
settings and data, much of this code doesn't work (or make sense) without having new
settings and data added back in its place. This is left as an exercise for the
reader…

Authors
-------

Rowan Thorpe

License
-------

See "LICENSE" file.
