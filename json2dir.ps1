#!/usr/bin/env pwsh
# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
# Pure PowerShell: a hand-written JSON parser plus the .NET base library pwsh runs on.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class Json2dirError : System.Exception {
    Json2dirError([string]$message) : base($message) {}
}

# A JSON value json2dir does not allow (number, true, false, null); kept so validation can name it.
class JsonOther {
    [string]$Kind
    JsonOther([string]$kind) { $this.Kind = $kind }
}

# Strict RFC 8259 parser. Objects -> Dictionary[string,object] (ordinal keys, last duplicate wins),
# arrays -> List[object], strings -> string, everything else -> JsonOther.
class JsonParser {
    [string]$s
    [int]$i = 0

    JsonParser([string]$text) { $this.s = $text }

    [void] Fail([string]$what) {
        throw [Json2dirError]::new("input is not valid JSON: $what at offset $($this.i)")
    }

    [void] SkipWs() {
        while ($this.i -lt $this.s.Length) {
            $c = $this.s[$this.i]
            if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r") { $this.i++ } else { break }
        }
    }

    [object] ParseDocument() {
        $this.SkipWs()
        $v = $this.ParseValue()
        $this.SkipWs()
        if ($this.i -ne $this.s.Length) { $this.Fail('trailing data') }
        return $v
    }

    [object] ParseValue() {
        if ($this.i -ge $this.s.Length) { $this.Fail('unexpected end of input') }
        $c = $this.s[$this.i]
        switch -CaseSensitive ($c) {
            '{' { return $this.ParseObject() }
            '[' { return $this.ParseArray() }
            '"' { return $this.ParseString() }
            't' { $this.Literal('true'); return [JsonOther]::new('true') }
            'f' { $this.Literal('false'); return [JsonOther]::new('false') }
            'n' { $this.Literal('null'); return [JsonOther]::new('null') }
        }
        if ($c -eq '-' -or ($c -ge '0' -and $c -le '9')) { return $this.ParseNumber() }
        $this.Fail("unexpected character '$c'")
        return $null
    }

    [void] Literal([string]$word) {
        if ($this.i + $word.Length -gt $this.s.Length -or
            -not [string]::Equals($this.s.Substring($this.i, $word.Length), $word, [StringComparison]::Ordinal)) {
            $this.Fail('invalid literal')
        }
        $this.i += $word.Length
    }

    [bool] IsDigit([int]$at) {
        return $at -lt $this.s.Length -and $this.s[$at] -ge '0' -and $this.s[$at] -le '9'
    }

    [object] ParseNumber() {
        if ($this.s[$this.i] -eq '-') { $this.i++ }
        if (-not $this.IsDigit($this.i)) { $this.Fail('invalid number') }
        if ($this.s[$this.i] -eq '0') { $this.i++ } else { while ($this.IsDigit($this.i)) { $this.i++ } }
        if ($this.i -lt $this.s.Length -and $this.s[$this.i] -eq '.') {
            $this.i++
            if (-not $this.IsDigit($this.i)) { $this.Fail('invalid number') }
            while ($this.IsDigit($this.i)) { $this.i++ }
        }
        if ($this.i -lt $this.s.Length -and ($this.s[$this.i] -eq 'e' -or $this.s[$this.i] -eq 'E')) {
            $this.i++
            if ($this.i -lt $this.s.Length -and ($this.s[$this.i] -eq '+' -or $this.s[$this.i] -eq '-')) { $this.i++ }
            if (-not $this.IsDigit($this.i)) { $this.Fail('invalid number') }
            while ($this.IsDigit($this.i)) { $this.i++ }
        }
        return [JsonOther]::new('number')
    }

    [string] ParseString() {
        $this.i++  # opening quote
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            if ($this.i -ge $this.s.Length) { $this.Fail('unterminated string') }
            $c = $this.s[$this.i]
            $code = [int]$c
            if ($code -eq 0x22) { $this.i++; break }
            if ($code -lt 0x20) { $this.Fail('control character in string') }
            if ($code -ne 0x5C) { [void]$sb.Append($c); $this.i++; continue }
            $this.i++
            if ($this.i -ge $this.s.Length) { $this.Fail('unterminated string') }
            $e = [int]$this.s[$this.i]
            $this.i++
            switch ($e) {
                0x22 { [void]$sb.Append([char]0x22) }
                0x5C { [void]$sb.Append([char]0x5C) }
                0x2F { [void]$sb.Append([char]0x2F) }
                0x62 { [void]$sb.Append([char]0x08) }
                0x66 { [void]$sb.Append([char]0x0C) }
                0x6E { [void]$sb.Append([char]0x0A) }
                0x72 { [void]$sb.Append([char]0x0D) }
                0x74 { [void]$sb.Append([char]0x09) }
                0x75 {
                    if ($this.i + 4 -gt $this.s.Length) { $this.Fail('invalid \u escape') }
                    $hex = $this.s.Substring($this.i, 4)
                    if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { $this.Fail('invalid \u escape') }
                    [void]$sb.Append([char][Convert]::ToInt32($hex, 16))
                    $this.i += 4
                }
                default { $this.i--; $this.Fail('invalid escape') }
            }
        }
        return $sb.ToString()
    }

    [object] ParseArray() {
        $this.i++
        $list = [System.Collections.Generic.List[object]]::new()
        $this.SkipWs()
        if ($this.i -lt $this.s.Length -and $this.s[$this.i] -eq ']') { $this.i++; return $list }
        while ($true) {
            $this.SkipWs()
            $list.Add($this.ParseValue())
            $this.SkipWs()
            if ($this.i -ge $this.s.Length) { $this.Fail('unterminated array') }
            $c = $this.s[$this.i]
            $this.i++
            if ($c -eq ']') { break }
            if ($c -ne ',') { $this.i--; $this.Fail("expected ',' or ']'") }
        }
        return $list
    }

    [object] ParseObject() {
        $this.i++
        $obj = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $this.SkipWs()
        if ($this.i -lt $this.s.Length -and $this.s[$this.i] -eq '}') { $this.i++; return $obj }
        while ($true) {
            $this.SkipWs()
            if ($this.i -ge $this.s.Length -or $this.s[$this.i] -ne '"') { $this.Fail('expected a member name') }
            $name = $this.ParseString()
            $this.SkipWs()
            if ($this.i -ge $this.s.Length -or $this.s[$this.i] -ne ':') { $this.Fail("expected ':'") }
            $this.i++
            $this.SkipWs()
            $obj[$name] = $this.ParseValue()  # §4.2: last duplicate wins
            $this.SkipWs()
            if ($this.i -ge $this.s.Length) { $this.Fail('unterminated object') }
            $c = $this.s[$this.i]
            $this.i++
            if ($c -eq '}') { break }
            if ($c -ne ',') { $this.i--; $this.Fail("expected ',' or '}'") }
        }
        return $obj
    }
}

function Fail([string]$message) { throw [Json2dirError]::new($message) }

# Ordinal equality: PowerShell's -ceq is culture-aware and ignores characters such as NUL.
function Same([string]$a, [string]$b) { [string]::Equals($a, $b, [StringComparison]::Ordinal) }

function Quote([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`0", '\u0000') + '"' }

# §3.5: an unpaired surrogate cannot be encoded as UTF-8.
function Test-WellFormed([string]$s) {
    for ($k = 0; $k -lt $s.Length; $k++) {
        $c = $s[$k]
        if ([char]::IsHighSurrogate($c)) {
            if ($k + 1 -lt $s.Length -and [char]::IsLowSurrogate($s[$k + 1])) { $k++; continue }
            return $false
        }
        if ([char]::IsLowSurrogate($c)) { return $false }
    }
    return $true
}

function Assert-String([string]$s, [string]$where) {
    if (-not (Test-WellFormed $s)) { Fail "${where}: string contains an unpaired surrogate" }
}

# §4.2.1: names are used exactly; nothing is trimmed.
function Assert-Name([string]$name, [string]$where) {
    if ($name.Length -eq 0 -or (Same $name '.') -or (Same $name '..') -or $name.Contains('/') -or $name.Contains([char]0)) {
        Fail "${where}: invalid name $(Quote $name)"
    }
}

# §4, §6: validate the whole document before touching the file system.
function Assert-Value($value, [string]$where) {
    if ($value -is [string]) { Assert-String $value $where; return }
    if ($value -is [System.Collections.Generic.List[object]]) {
        if ($value.Count -ne 2 -or $value[0] -isnot [string] -or $value[1] -isnot [string]) {
            Fail "${where}: an array must be [""link"", target] or [""script"", content]"
        }
        if (-not (Same $value[0] 'link') -and -not (Same $value[0] 'script')) { Fail "${where}: unknown array kind $(Quote $value[0])" }
        if ((Same $value[0] 'link') -and $value[1].Contains([char]0)) { Fail "${where}: a link target cannot contain NUL" }
        Assert-String $value[1] $where
        return
    }
    if ($value -is [System.Collections.Generic.Dictionary[string, object]]) {
        foreach ($name in $value.Keys) {
            $child = if (Same $where '.') { $name } else { "$where/$name" }
            Assert-String $name $child
            Assert-Name $name $child
            Assert-Value $value[$name] $child
        }
        return
    }
    Fail "${where}: $($value.Kind) values are not allowed"
}

$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

# Returns the entry at $path without following symlinks: $null, 'link', 'dir' or 'file'.
function Get-EntryKind([string]$path) {
    $info = [System.IO.FileInfo]::new($path)
    if ($null -ne $info.LinkTarget) { return 'link' }
    if ([System.IO.Directory]::Exists($path)) { return 'dir' }
    if ($info.Exists) { return 'file' }
    return $null
}

# §5.2, §5.3: an existing non-directory is removed (a symlink itself, never its target);
# §5.4: a directory in the way of a non-object is an error.
function Clear-Entry([string]$path, $kind) {
    if ($null -eq $kind) { return }
    if ($kind -eq 'dir') { Fail "${path}: a directory is in the way" }
    [System.IO.File]::Delete($path)
}

function Write-Entry([string]$path, [string]$content, [bool]$executable) {
    # CreateNew = O_CREAT | O_EXCL; .NET creates files with mode 0666 & ~umask.
    $bytes = $Utf8.GetBytes($content)
    $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    if ($executable) {
        $exec = [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherExecute
        [System.IO.File]::SetUnixFileMode($path, [System.IO.File]::GetUnixFileMode($path) -bor $exec)
    }
}

function Invoke-Apply([string]$dir, $tree) {
    $names = [string[]]@($tree.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
        $path = "$dir/$name"
        $value = $tree[$name]
        $kind = Get-EntryKind $path
        if ($value -is [string]) {
            Clear-Entry $path $kind
            Write-Entry $path $value $false
        } elseif ($value -is [System.Collections.Generic.List[object]]) {
            Clear-Entry $path $kind
            if (Same $value[0] 'link') { [void][System.IO.File]::CreateSymbolicLink($path, $value[1]) }
            else { Write-Entry $path $value[1] $true }
        } else {
            if ($kind -ne 'dir') {
                if ($null -ne $kind) { [System.IO.File]::Delete($path) }
                [void][System.IO.Directory]::CreateDirectory($path)
            }
            Invoke-Apply $path $value
        }
    }
}

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('usage: json2dir < document.json')
    exit 2
}

try {
    $stdin = [Console]::OpenStandardInput()
    $buffer = [System.IO.MemoryStream]::new()
    $stdin.CopyTo($buffer)
    $bytes = $buffer.ToArray()
    try { $text = $Utf8.GetString($bytes) } catch { Fail 'input is not valid UTF-8' }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }  # §3: BOM may be ignored
    $document = [JsonParser]::new($text).ParseDocument()
    if ($document -isnot [System.Collections.Generic.Dictionary[string, object]]) {
        Fail 'the root of the document must be an object'
    }
    Assert-Value $document '.'
    Invoke-Apply ([Environment]::CurrentDirectory) $document
    exit 0
} catch {
    $e = $_.Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $null -ne $e.InnerException) { $e = $e.InnerException }
    [Console]::Error.WriteLine("json2dir: $($e.Message)")
    exit 1
}
