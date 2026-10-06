# Mahabbat password-encrypted backup crypto (.NET only, no external binaries).
# File format database.dump.enc:
#   MAGIC 6 bytes ASCII "MHBE01" | SALT 16 bytes | IV 16 bytes |
#   CIPHERTEXT N bytes (AES-256-CBC, PKCS7) | HMAC 32 bytes.
# Key: PBKDF2-HMAC-SHA256(password UTF-8, salt, 200000) -> 64 bytes,
#   ENC = bytes 0..31, MAC = bytes 32..63.
# HMAC-SHA256(MAC, MAGIC|SALT|IV|CIPHERTEXT) appended last (Encrypt-then-MAC).
# Verification order on decrypt: MAGIC -> sizes -> SHA256/manifest -> HMAC
# (constant-time) -> only then AES decrypt. Any mismatch throws before the
# caller touches containers. Dumps are streamed in 1 MB blocks, never fully
# loaded into memory.

$script:MahabbatBackupMagic = 'MHBE01'
$script:MahabbatBackupSaltBytes = 16
$script:MahabbatBackupIvBytes = 16
$script:MahabbatBackupHmacBytes = 32
$script:MahabbatBackupHeaderBytes = 38
$script:MahabbatBackupPbkdf2Iterations = 200000
$script:MahabbatBackupPasswordMinLength = 10
$script:MahabbatBackupBlockBytes = 1048576

function Get-MahabbatNightlyKeyPath {
  # DPAPI-ключ ночной копии: расшифровать может только этот пользователь
  # Windows на этом компьютере. Requires mahabbat-common.ps1 (ACL helper).
  return (Join-Path (Join-Path (Get-MahabbatRoot) '.private') 'backup-nightly.dpapi')
}

function Assert-MahabbatDpapiAvailable {
  try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
  $t = [System.Type]::GetType('System.Security.Cryptography.ProtectedData, System.Security, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
  if ($null -eq $t) { $t = [System.Type]::GetType('System.Security.Cryptography.ProtectedData') }
  if ($null -eq $t) {
    throw 'DPAPI unavailable in this .NET runtime.'
  }
}

function New-MahabbatNightlyBackupKey {
  # Создаёт 32-байтный ключ ночной копии под DPAPI CurrentUser, если его нет.
  # Возвращает путь. Пароль нигде не хранится и не нужен для расшифровки.
  Assert-MahabbatDpapiAvailable
  $path = Get-MahabbatNightlyKeyPath
  $dir = Split-Path -Parent $path
  [IO.Directory]::CreateDirectory($dir) | Out-Null
  if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $key = New-Object byte[] 32
  try {
    $rng.GetBytes($key)
    $blob = [System.Security.Cryptography.ProtectedData]::Protect($key, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [IO.File]::WriteAllBytes($path, $blob) } finally { [Array]::Clear($blob, 0, $blob.Length) }
  } finally {
    $rng.Dispose()
    Clear-MahabbatByteArray -Bytes $key
  }
  Set-MahabbatPrivateFileAcl -Path $path
  Write-Host 'Создан DPAPI-ключ ночной копии (только этот пользователь Windows).'
  return $path
}

function Get-MahabbatNightlyBackupKeyBytes {
  # Расшифровывает ночной ключ через DPAPI. Caller MUST clear the bytes.
  Assert-MahabbatDpapiAvailable
  $path = Get-MahabbatNightlyKeyPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'Ночной ключ отсутствует. Запустите копию один раз — ключ создастся автоматически.'
  }
  $blob = [IO.File]::ReadAllBytes($path)
  try {
    return [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  } finally {
    [Array]::Clear($blob, 0, $blob.Length)
  }
}

function Read-MahabbatNightlyBackupKeyBase64 {
  # Unprotect ночного ключа для передачи в дочерний процесс через env
  # (трей: Unprotect здесь, backup.ps1 читает MAHABBAT_BACKUP_NIGHTLY_B64).
  # Base64-строку caller стирает из env сразу после чтения.
  $keyBytes = Get-MahabbatNightlyBackupKeyBytes
  try { return [Convert]::ToBase64String($keyBytes) }
  finally { Clear-MahabbatByteArray -Bytes $keyBytes }
}

function Assert-MahabbatBackupCryptoAvailable {
  # Fail-closed: the 4-argument Rfc2898DeriveBytes overload carrying
  # HashAlgorithmName exists only on .NET Framework 4.7.2+. Without it the
  # constructor silently falls back to HMAC-SHA1, which this format forbids.
  $sha256Kdf = $false
  foreach ($ctor in [System.Security.Cryptography.Rfc2898DeriveBytes].GetConstructors()) {
    $params = $ctor.GetParameters()
    if (($params.Count -eq 4) -and ($params[3].ParameterType -eq [System.Security.Cryptography.HashAlgorithmName])) {
      $sha256Kdf = $true
      break
    }
  }
  if (-not $sha256Kdf) {
    throw 'Зашифрованная копия требует .NET Framework 4.7.2+ (PBKDF2-HMAC-SHA256). Операция прервана до любых изменений.'
  }
  $probeAes = $null
  try {
    $probeAes = New-Object System.Security.Cryptography.AesManaged
    $probeAes.KeySize = 256
  } catch {
    throw 'AES-256 недоступен в этой среде .NET. Операция прервана до любых изменений.'
  } finally {
    if ($null -ne $probeAes) { $probeAes.Dispose() }
  }
}

function Read-MahabbatBackupPassword {
  # Password comes ONLY from the process environment (never argv: command
  # lines are visible in process lists). Reads once and clears the variable
  # immediately. Empty/unset means plaintext mode for the nightly auto-backup.
  param([string]$EnvVar = 'MAHABBAT_BACKUP_PASSWORD')
  $raw = [Environment]::GetEnvironmentVariable($EnvVar, 'Process')
  [Environment]::SetEnvironmentVariable($EnvVar, $null, 'Process')
  if ([string]::IsNullOrEmpty($raw)) { return $null }
  if ($raw.Length -lt $script:MahabbatBackupPasswordMinLength) {
    throw 'Пароль для шифрования копии — минимум 10 символов. Пустое значение — обычная копия без шифрования.'
  }
  return $raw
}

function Convert-MahabbatSecureStringToString {
  param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Clear-MahabbatByteArray {
  param([byte[]]$Bytes)
  if ($null -ne $Bytes -and $Bytes.Length -gt 0) {
    [Array]::Clear($Bytes, 0, $Bytes.Length)
  }
}

function Test-MahabbatBytesEqual {
  param([byte[]]$A, [byte[]]$B)
  if ($null -eq $A -or $null -eq $B) { return $false }
  if ($A.Length -ne $B.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $A.Length; $i++) {
    $diff = $diff -bor ($A[$i] -bxor $B[$i])
  }
  return ($diff -eq 0)
}

function Read-MahabbatStreamExact {
  param($Stream, [byte[]]$Buffer, [int]$Offset, [int]$Count)
  $total = 0
  while ($total -lt $Count) {
    $n = $Stream.Read($Buffer, ($Offset + $total), ($Count - $total))
    if ($n -le 0) { throw (New-MahabbatBackupAuthError) }
    $total = $total + $n
  }
}

function New-MahabbatBackupAuthError {
  return (New-Object System.Security.Authentication.AuthenticationException('Неверный пароль или повреждённый файл.'))
}

function New-MahabbatBackupKeys {
  param(
    [Parameter(Mandatory = $true)][byte[]]$PasswordBytes,
    [Parameter(Mandatory = $true)][byte[]]$Salt
  )
  $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PasswordBytes, $Salt, $script:MahabbatBackupPbkdf2Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
  try {
    $full = $kdf.GetBytes(64)
  } finally {
    $kdf.Dispose()
  }
  $enc = New-Object byte[] 32
  $mac = New-Object byte[] 32
  [Array]::Copy($full, 0, $enc, 0, 32)
  [Array]::Copy($full, 32, $mac, 0, 32)
  [Array]::Clear($full, 0, $full.Length)
  return @{ Enc = $enc; Mac = $mac }
}

function Get-MahabbatFileSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = $null
  $buf = New-Object byte[] $script:MahabbatBackupBlockBytes
  try {
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $read = 0
    do {
      $read = $fs.Read($buf, 0, $buf.Length)
      if ($read -gt 0) { $sha.TransformBlock($buf, 0, $read, $buf, 0) | Out-Null }
    } while ($read -gt 0)
    $sha.TransformFinalBlock($buf, 0, 0) | Out-Null
    $hash = $sha.Hash
    $sb = New-Object System.Text.StringBuilder($hash.Length * 2)
    foreach ($b in $hash) { $sb.Append($b.ToString('x2')) | Out-Null }
    return $sb.ToString()
  } finally {
    if ($null -ne $fs) { $fs.Close() }
    $sha.Dispose()
    Clear-MahabbatByteArray -Bytes $buf
  }
}

function Write-MahabbatBackupHmac {
  param(
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][byte[]]$MacKey
  )
  $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $MacKey)
  $fs = $null
  $ws = $null
  $buf = New-Object byte[] $script:MahabbatBackupBlockBytes
  try {
    $fs = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $read = 0
    do {
      $read = $fs.Read($buf, 0, $buf.Length)
      if ($read -gt 0) { $hmac.TransformBlock($buf, 0, $read, $buf, 0) | Out-Null }
    } while ($read -gt 0)
    $hmac.TransformFinalBlock($buf, 0, 0) | Out-Null
    $tag = $hmac.Hash
    $fs.Close(); $fs = $null
    $ws = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $ws.Write($tag, 0, $tag.Length)
  } finally {
    if ($null -ne $fs) { $fs.Close() }
    if ($null -ne $ws) { $ws.Close() }
    $hmac.Dispose()
    Clear-MahabbatByteArray -Bytes $buf
  }
}

function Test-MahabbatBackupHmac {
  param(
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][byte[]]$MacKey
  )
  $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $MacKey)
  $fs = $null
  $buf = New-Object byte[] $script:MahabbatBackupBlockBytes
  try {
    $fs = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $dataLen = $fs.Length - $script:MahabbatBackupHmacBytes
    if ($dataLen -lt $script:MahabbatBackupHeaderBytes) { return $false }
    $remaining = $dataLen
    while ($remaining -gt 0) {
      $want = $buf.Length
      if ($want -gt $remaining) { $want = [int]$remaining }
      $n = $fs.Read($buf, 0, $want)
      if ($n -le 0) { return $false }
      $hmac.TransformBlock($buf, 0, $n, $buf, 0) | Out-Null
      $remaining = $remaining - $n
    }
    $hmac.TransformFinalBlock($buf, 0, 0) | Out-Null
    $computed = $hmac.Hash
    $stored = New-Object byte[] $script:MahabbatBackupHmacBytes
    Read-MahabbatStreamExact -Stream $fs -Buffer $stored -Offset 0 -Count $stored.Length
    return (Test-MahabbatBytesEqual -A $computed -B $stored)
  } finally {
    if ($null -ne $fs) { $fs.Close() }
    $hmac.Dispose()
    Clear-MahabbatByteArray -Bytes $buf
  }
}

function Test-MahabbatBackupPassword {
  # «Проверить пароль»: только HMAC + SHA256-манифест, без расшифровки
  # и без restore.
  param(
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][byte[]]$PasswordBytes
  )
  if (-not (Test-Path -LiteralPath $EncPath -PathType Leaf)) { throw "Файл не найден: $EncPath" }
  Assert-MahabbatBackupCryptoAvailable
  $fs = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $minBytes = $script:MahabbatBackupHeaderBytes + $script:MahabbatBackupHmacBytes + 16
    if ($fs.Length -lt $minBytes) { return $false }
    $header = New-Object byte[] $script:MahabbatBackupHeaderBytes
    Read-MahabbatStreamExact -Stream $fs -Buffer $header -Offset 0 -Count $header.Length
    $magic = [Text.Encoding]::ASCII.GetString($header, 0, 6)
    if ($magic -cne $script:MahabbatBackupMagic) { return $false }
    $salt = New-Object byte[] $script:MahabbatBackupSaltBytes
    [Array]::Copy($header, 6, $salt, 0, $script:MahabbatBackupSaltBytes)
    Clear-MahabbatByteArray -Bytes $header
    $keys = New-MahabbatBackupKeys -PasswordBytes $PasswordBytes -Salt $salt
    Clear-MahabbatByteArray -Bytes $salt
    try {
      if (-not (Test-MahabbatBackupHmac -EncPath $EncPath -MacKey $keys.Mac)) { return $false }
    } finally {
      Clear-MahabbatByteArray -Bytes $keys.Mac
      Clear-MahabbatByteArray -Bytes $keys.Enc
    }
  } finally {
    $fs.Close()
  }
  if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
    try {
      $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
      if ($null -ne $manifest.encryption.ciphertextSha256) {
        $actual = (Get-MahabbatFileSha256Hex -Path $EncPath).ToLowerInvariant()
        $expected = ([string]$manifest.encryption.ciphertextSha256).ToLowerInvariant()
        if ($actual -cne $expected) { return $false }
      }
    } catch { return $false }
  }
  return $true
}

function Test-MahabbatBackupPayloadPassword {
  # Backup v2: verify ANY encrypted payload (DB dump or files tar) with the
  # SAME password bytes — HMAC (constant-time) + optional expected SHA256.
  # HMAC-only, no decrypt, no restore. Returns $false on wrong password,
  # corrupt file or digest mismatch; throws when the file is missing.
  param(
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][byte[]]$PasswordBytes,
    [string]$ExpectedSha256 = ''
  )
  if (-not (Test-Path -LiteralPath $EncPath -PathType Leaf)) { throw "Файл не найден: $EncPath" }
  Assert-MahabbatBackupCryptoAvailable
  $fs = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $minBytes = $script:MahabbatBackupHeaderBytes + $script:MahabbatBackupHmacBytes + 16
    if ($fs.Length -lt $minBytes) { return $false }
    $header = New-Object byte[] $script:MahabbatBackupHeaderBytes
    Read-MahabbatStreamExact -Stream $fs -Buffer $header -Offset 0 -Count $header.Length
    $magic = [Text.Encoding]::ASCII.GetString($header, 0, 6)
    if ($magic -cne $script:MahabbatBackupMagic) { return $false }
    $salt = New-Object byte[] $script:MahabbatBackupSaltBytes
    [Array]::Copy($header, 6, $salt, 0, $script:MahabbatBackupSaltBytes)
    Clear-MahabbatByteArray -Bytes $header
    $keys = New-MahabbatBackupKeys -PasswordBytes $PasswordBytes -Salt $salt
    Clear-MahabbatByteArray -Bytes $salt
    try {
      if (-not (Test-MahabbatBackupHmac -EncPath $EncPath -MacKey $keys.Mac)) { return $false }
    } finally {
      Clear-MahabbatByteArray -Bytes $keys.Mac
      Clear-MahabbatByteArray -Bytes $keys.Enc
    }
  } finally {
    $fs.Close()
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    try {
      $actual = (Get-MahabbatFileSha256Hex -Path $EncPath).ToLowerInvariant()
    } catch { return $false }
    if ($actual -cne $ExpectedSha256.Trim().ToLowerInvariant()) { return $false }
  }
  return $true
}

function Protect-MahabbatDump {
  param(
    [Parameter(Mandatory = $true)][string]$PlainPath,
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][byte[]]$PasswordBytes
  )
  Assert-MahabbatBackupCryptoAvailable
  if (-not (Test-Path -LiteralPath $PlainPath -PathType Leaf)) { throw "Исходный файл не найден: $PlainPath" }
  if (Test-Path -LiteralPath $EncPath) { throw "Файл уже существует, шифрование остановлено: $EncPath" }
  $magicBytes = [Text.Encoding]::ASCII.GetBytes($script:MahabbatBackupMagic)
  $salt = New-Object byte[] $script:MahabbatBackupSaltBytes
  $iv = New-Object byte[] $script:MahabbatBackupIvBytes
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try {
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
  } finally {
    $rng.Dispose()
  }
  $keys = New-MahabbatBackupKeys -PasswordBytes $PasswordBytes -Salt $salt
  $encKey = $keys.Enc
  $macKey = $keys.Mac
  $aes = New-Object System.Security.Cryptography.AesManaged
  $inStream = $null
  $outStream = $null
  $encryptor = $null
  $crypto = $null
  $buf = New-Object byte[] $script:MahabbatBackupBlockBytes
  try {
    $aes.KeySize = 256
    $aes.Key = $encKey
    $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $inStream = New-Object System.IO.FileStream($PlainPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $outStream = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $outStream.Write($magicBytes, 0, $magicBytes.Length)
    $outStream.Write($salt, 0, $salt.Length)
    $outStream.Write($iv, 0, $iv.Length)
    $encryptor = $aes.CreateEncryptor()
    $crypto = New-Object System.Security.Cryptography.CryptoStream($outStream, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
    $read = 0
    do {
      $read = $inStream.Read($buf, 0, $buf.Length)
      if ($read -gt 0) { $crypto.Write($buf, 0, $read) }
    } while ($read -gt 0)
    $crypto.FlushFinalBlock()
  } finally {
    if ($null -ne $crypto) { $crypto.Close() } elseif ($null -ne $outStream) { $outStream.Close() }
    if ($null -ne $inStream) { $inStream.Close() }
    if ($null -ne $encryptor) { $encryptor.Dispose() }
    $aes.Dispose()
    Clear-MahabbatByteArray -Bytes $buf
  }
  try {
    Write-MahabbatBackupHmac -EncPath $EncPath -MacKey $macKey
  } finally {
    Clear-MahabbatByteArray -Bytes $encKey
    Clear-MahabbatByteArray -Bytes $macKey
    Clear-MahabbatByteArray -Bytes $salt
    Clear-MahabbatByteArray -Bytes $iv
  }
}

function Unprotect-MahabbatDump {
  param(
    [Parameter(Mandatory = $true)][string]$EncPath,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [Parameter(Mandatory = $true)][byte[]]$PasswordBytes
  )
  Assert-MahabbatBackupCryptoAvailable
  if (Test-Path -LiteralPath $OutPath) { throw "Временный файл уже существует, расшифровка остановлена: $OutPath" }
  $fs = New-Object System.IO.FileStream($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $minBytes = $script:MahabbatBackupHeaderBytes + $script:MahabbatBackupHmacBytes + 16
    if ($fs.Length -lt $minBytes) { throw (New-MahabbatBackupAuthError) }
    $header = New-Object byte[] $script:MahabbatBackupHeaderBytes
    Read-MahabbatStreamExact -Stream $fs -Buffer $header -Offset 0 -Count $header.Length
    $magic = [Text.Encoding]::ASCII.GetString($header, 0, 6)
    if ($magic -cne $script:MahabbatBackupMagic) { throw (New-MahabbatBackupAuthError) }
    $salt = New-Object byte[] $script:MahabbatBackupSaltBytes
    $iv = New-Object byte[] $script:MahabbatBackupIvBytes
    [Array]::Copy($header, 6, $salt, 0, $script:MahabbatBackupSaltBytes)
    [Array]::Copy($header, 22, $iv, 0, $script:MahabbatBackupIvBytes)
    Clear-MahabbatByteArray -Bytes $header
    $keys = New-MahabbatBackupKeys -PasswordBytes $PasswordBytes -Salt $salt
    Clear-MahabbatByteArray -Bytes $salt
    try {
      if (-not (Test-MahabbatBackupHmac -EncPath $EncPath -MacKey $keys.Mac)) { throw (New-MahabbatBackupAuthError) }
    } finally {
      Clear-MahabbatByteArray -Bytes $keys.Mac
    }
    # HMAC verified above; now decrypt exactly the ciphertext region
    # [header .. Length-32), never the trailing HMAC tag. Streaming
    # TransformBlock with separate input/output buffers (in-place reuse
    # corrupts multi-block output on .NET Framework Rijndael).
    $cipherLen = $fs.Length - $script:MahabbatBackupHeaderBytes - $script:MahabbatBackupHmacBytes
    if (($cipherLen -lt 16) -or (($cipherLen % 16) -ne 0)) { throw (New-MahabbatBackupAuthError) }
    $aes = New-Object System.Security.Cryptography.AesManaged
    $decryptor = $null
    $os = $null
    $inBuf = New-Object byte[] $script:MahabbatBackupBlockBytes
    $outBuf = New-Object byte[] $script:MahabbatBackupBlockBytes
    try {
      $aes.KeySize = 256
      $aes.Key = $keys.Enc
      $aes.IV = $iv
      $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
      $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
      $decryptor = $aes.CreateDecryptor()
      $fs.Seek($script:MahabbatBackupHeaderBytes, [System.IO.SeekOrigin]::Begin) | Out-Null
      $os = New-Object System.IO.FileStream($OutPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $remaining = $cipherLen
      while ($remaining -gt $inBuf.Length) {
        Read-MahabbatStreamExact -Stream $fs -Buffer $inBuf -Offset 0 -Count $inBuf.Length
        $produced = $decryptor.TransformBlock($inBuf, 0, $inBuf.Length, $outBuf, 0)
        $os.Write($outBuf, 0, $produced)
        $remaining = $remaining - $inBuf.Length
      }
      $tail = New-Object byte[] ([int]$remaining)
      Read-MahabbatStreamExact -Stream $fs -Buffer $tail -Offset 0 -Count $tail.Length
      try {
        $final = $decryptor.TransformFinalBlock($tail, 0, $tail.Length)
      } catch {
        throw (New-MahabbatBackupAuthError)
      }
      $os.Write($final, 0, $final.Length)
    } finally {
      if ($null -ne $os) { $os.Close() }
      if ($null -ne $decryptor) { $decryptor.Dispose() }
      $aes.Dispose()
      Clear-MahabbatByteArray -Bytes $inBuf
      Clear-MahabbatByteArray -Bytes $outBuf
      Clear-MahabbatByteArray -Bytes $keys.Enc
      Clear-MahabbatByteArray -Bytes $iv
    }
    $fs.Close()
  } catch {
    if ($null -ne $fs) { try { $fs.Close() } catch { } }
    throw
  }
}

function Remove-MahabbatFileSecure {
  # Overwrites the file with random bytes (single pass, 1 MB blocks) and
  # deletes it. Used for plaintext shredding after encryption and for
  # wiping decrypted temp files after restore/verification.
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  $fs = $null
  try {
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $buf = New-Object byte[] $script:MahabbatBackupBlockBytes
    try {
      $remaining = $fs.Length
      while ($remaining -gt 0) {
        $rng.GetBytes($buf)
        $want = $buf.Length
        if ($want -gt $remaining) { $want = [int]$remaining }
        $fs.Write($buf, 0, $want)
        $remaining = $remaining - $want
      }
      $fs.Flush()
    } finally {
      $rng.Dispose()
      Clear-MahabbatByteArray -Bytes $buf
    }
  } finally {
    if ($null -ne $fs) { $fs.Close() }
  }
  Remove-Item -LiteralPath $Path -Force
}


function New-MahabbatScopedEnvFile {
  # Scoped temp env-file: только нужные ключи, user-only ACL, caller стирает.
  # Предпочтительно вместо передачи всего .env в docker --env-file.
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)
  $dir = Join-Path ([IO.Path]::GetTempPath()) 'mahabbat-scoped-env'
  [IO.Directory]::CreateDirectory($dir) | Out-Null
  $path = Join-Path $dir ('scoped-' + [Guid]::NewGuid().ToString('N') + '.env')
  $lines = @()
  foreach ($entry in $Values.GetEnumerator()) {
    $name = [string]$entry.Key
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Bad env name: $name" }
    $lines += "$name=$([string]$entry.Value)"
  }
  [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
  Set-MahabbatPrivateFileAcl -Path $path
  return $path
}

function Remove-MahabbatScopedEnvFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  Remove-MahabbatFileSecure -Path $Path
}