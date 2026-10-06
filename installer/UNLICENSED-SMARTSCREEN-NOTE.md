# Mahabbat installer is NOT code-signed (no publisher certificate).

What the venue operator sees: on first launch Windows SmartScreen (and some
antivirus products) show an "unknown publisher / unrecognized app" warning for
`Mahabbat-Setup-*.exe`. This is expected for an unsigned internal installer —
it does NOT mean the file is tampered, but it also does NOT prove origin.

Safe handling:

1. Run the setup EXE only from the venue owner's own build on this PC
   (`installer/build/output/Mahabbat-Setup-*.exe`, built by
   `installer/build/build-installer.ps1`). Never run a copy received by
   e-mail, messenger, or download link.
2. When SmartScreen asks, choose "Don't run" unless step 1 holds. There is no
   "Run anyway" path documented here on purpose.
3. After install, backups live OUTSIDE the app dir
   (`%ProgramData%\Mahabbat\backups` unless `MAHABBAT_BACKUP_ROOT` is set), so
   uninstalling Mahabbat never deletes venue backups. Keep at least one
   encrypted copy password on paper, stored away from this PC.

If the venue later buys a code-signing certificate, sign the setup EXE at
build time and delete this note.
