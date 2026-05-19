This folder is the drop zone for the Windows Server installation ISO.

USAGE
=====
1. Drop your Windows Server .iso file directly into this folder. Any version
   from Server 2012 R2 onwards works. Recommended: match the version you
   installed on the EPM server VM.

2. From the project root, run ..\populator.ps1 (see PutPatch\README.txt for
   the full command).

3. The populator mounts the ISO automatically, copies \sources\sxs\ (the
   .NET 3.5 source files) into ..\assets\sxs\, and dismounts the ISO.

NOTES
=====
- The ISO file is NOT deleted after the run. It remains here.

- Mount-DiskImage works without admin rights on Windows 8 / Server 2012 R2
  and newer. If mounting fails, run PowerShell as Administrator.

- If the .iso turns out not to be a Windows install image (no \sources\sxs\
  inside), the populator warns and continues with sxs marked as missing.

- Only ONE .iso file should live here. If you drop multiple, the populator
  uses the first one and warns about the rest.

- This README.txt is ignored by the populator and is never moved.
