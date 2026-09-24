# Mahabbat pilot license generator

This tool signs offline pilot licenses for a specific Mahabbat installation. The Ed25519 private key is generated once and stays in the deployment repository's ignored `.private/` directory. Never copy it to an installation or release archive.

Initialize once on the private release workstation:

```powershell
.\tools\license-generator\initialize-license-signing.ps1
```

Issue a 30-day license from the restaurant's `activation-request.json`:

```powershell
.\tools\license-generator\generate-license.ps1 `
  -Customer 'Restaurant Mahabbat' `
  -ActivationRequest '.\activation-request.json' `
  -Days 30
```

The generated `artifacts\licenses\*.license.json` is bound to both the installation ID and machine fingerprint in the request. Transfer only that signed license file to the matching installation. A replacement license is issued with a new validity period; it does not alter the database.

The tool refuses to overwrite an existing signing key or license output. Back up the private key separately in an approved offline secure location; without it, existing installations remain verifiable but no new or extended license can be issued.
