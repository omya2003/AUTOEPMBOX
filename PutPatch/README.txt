This folder is the drop zone for the Iraje EPM patch.

USAGE
=====
1. Drop your Iraje patch here. Any of these formats is fine:
   - A folder (any name, any depth of nesting).
   - A .zip file (auto-extracted).
   - A .7z file (auto-extracted; requires 7-Zip installed and -ArchivePassword).

2. From the project root, open elevated PowerShell and run:
       cd C:\path\to\EPMBoxMaking Scripts
       Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
       .\populator.ps1

3. The script discovers the EPM pieces wherever they live in your drop,
   moves them into ..\assets\, auto-edits db_setup.ps1, and validates.

NOTES
=====
- You can drop the patch with ANY naming convention. Examples that all work:
      EPM_Setup_files_V1\
      EPM_Setup_files_V1_10_Feb_26\
      epm-patch-2026-q1.zip
      EPM_Tools_Setup.7z

- Multiple patches in this folder are also fine. The populator looks at
  everything and picks the best match for each slot.

- Anything the script does NOT recognize is moved to PutPatch\_unmapped\
  after the run, so nothing is silently deleted.

- For .7z files: install 7-Zip first (https://www.7-zip.org/) and pass
  the password with -ArchivePassword '<pwd>'.

- This README.txt is ignored by the populator and is never moved.
