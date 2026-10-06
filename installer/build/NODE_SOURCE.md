# Node runtime source for the Mahabbat installer (controlled, hashed).

Default: official `https://nodejs.org/dist/v<VERSION>/node-v<VERSION>-win-x64.zip`,
version pinned in `installer/app/runtime/NODE_VERSION.txt` (currently 24.16.0,
matching `mahabbat-app/.nvmrc`). `installer/build/build-installer.ps1`
downloads it when `-NodeExe` is omitted, verifies SHA256
(`installer/app/runtime/NODE_SHA256.txt`), and stages
`installer/app/runtime/node.exe` for the Inno Setup build.

The `.iss` references only the staged copy (`{#NodeSource}`) — never an
absolute path on a developer machine. A local `-NodeExe` is allowed for
offline builds but must still match the known-good hash (v24.16.0:
`b3094d0b49f9ad602262a9921551737bb97637c05dd357a06ae98188d7290aa3`).
Record a new hash deliberately when the pinned version changes.
