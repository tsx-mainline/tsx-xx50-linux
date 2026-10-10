TSXLOG: the FAT partition of the xx50 card (Crestron TSS-752)

Any PC can read and write this partition. The panel mounts it at
/mnt/tsxlog. Use it to move files between a PC and the panel, for example
a log or a layout file.

The panel keeps its logs in /var/log (on the data partition). Log in with
ssh to read them. The panel writes nothing to this partition by itself.
