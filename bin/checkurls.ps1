<#
.SYNOPSIS
    List manifests which do not have valid URLs.
.PARAMETER App
    Manifest name to search.
    Placeholder is supported.
.PARAMETER Dir
    Where to search for manifest(s).
.PARAMETER Timeout
    How long (seconds) the request can be pending before it times out.
.PARAMETER SkipValid
    Manifests will all valid URLs will not be shown.
#>
param(
    [string] $App = '*',
    [Parameter(Mandatory = $true)]
    [ValidateScript( {
        if (!(Test-Path $_ -Type Container)) {
            throw "$_ is not a directory!"
        } else {
            $true
        }
    })]
    [string] $Dir,
    [int] $Timeout = 5,
    [switch] $SkipValid
)

. "$PSScriptRoot\..\lib\core.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\install.ps1"

$Dir = Resolve-Path $Dir
$Queue = @()

Get-ChildItem $Dir "$App.json" | ForEach-Object {
    $manifest = parse_json "$Dir\$($_.Name)"
    $Queue += , @($_.Name, $manifest)
}

Write-Host '[' -NoNewline
Write-Host 'U' -NoNewline -ForegroundColor Cyan
Write-Host ']RLs'
Write-Host ' | [' -NoNewline
Write-Host 'O' -NoNewline -ForegroundColor Green
Write-Host ']kay'
Write-Host ' |  | [' -NoNewline
Write-Host 'F' -NoNewline -ForegroundColor Red
Write-Host ']ailed'
Write-Host ' |  |  |'

function test_dl([string]$url, $cookies) {
    # Trim renaming suffix, prevent getting 40x response
    $url = ($url -split '#/')[0]

    $wreq = [System.Net.WebRequest]::Create($url)
    $wreq.Timeout = $Timeout * 1000
    if ($wreq -is [Net.HttpWebRequest]) {
        $wreq.UserAgent = Get-UserAgent
        $wreq.Referer = strip_filename $url
        if ($cookies) {
            $wreq.Headers.Add('Cookie', (cookie_header $cookies))
        }
    }
    $wres = $null
    try {
        $wres = $wreq.GetResponse()

        return $url, $wres.StatusCode, $null
    } catch {
        $e = $_.Exception
        if ($e.InnerException) { $e = $e.InnerException }

        return $url, 'Error', $e.Message
    } finally {
        if ($null -ne $wres -and $wres -isnot [System.Net.FtpWebResponse]) {
            $wres.Close()
        }
    }
}

foreach ($man in $Queue) {
    $name, $manifest = $man
    $urls = @()
    $ok = 0
    $failed = 0
    $errors = @()

    if ($manifest.url) {
        $manifest.url | ForEach-Object { $urls += $_ }
    } else {
        script:url $manifest '64bit' | ForEach-Object { $urls += $_ }
        script:url $manifest '32bit' | ForEach-Object { $urls += $_ }
    }

    $urls | ForEach-Object {
        $url, $status, $msg = test_dl $_ $manifest.cookie
        if ($msg) { $errors += "$msg ($url)" }
        if ($status -eq 'OK' -or $status -eq 'OpeningData') { $ok += 1 } else { $failed += 1 }
    }

    if (($ok -eq $urls.Length) -and $SkipValid) { continue }

    # URLS
    Write-Host '[' -NoNewline
    Write-Host $urls.Length -NoNewline -ForegroundColor Cyan
    Write-Host ']' -NoNewline

    # Okay
    Write-Host '[' -NoNewline
    if ($ok -eq $urls.Length) {
        Write-Host $ok -NoNewline -ForegroundColor Green
    } elseif ($ok -eq 0) {
        Write-Host $ok -NoNewline -ForegroundColor Red
    } else {
        Write-Host $ok -NoNewline -ForegroundColor Yellow
    }
    Write-Host ']' -NoNewline

    # Failed
    Write-Host '[' -NoNewline
    if ($failed -eq 0) {
        Write-Host $failed -NoNewline -ForegroundColor Green
    } else {
        Write-Host $failed -NoNewline -ForegroundColor Red
    }
    Write-Host '] ' -NoNewline
    Write-Host (strip_ext $name)

    $errors | ForEach-Object {
        Write-Host "       > $_" -ForegroundColor DarkRed
    }
}
