<#
.SYNOPSIS
    Check manifest for newer version.
.DESCRIPTION
    Checks websites for newer versions using an (optional) regular expression defined in the manifest.
.PARAMETER App
    Manifest name to search.
    Placeholders are supported.
.PARAMETER Dir
    Where to seach for manfiest(s).
.PARAMETER Update
    Update given manifest
.PARAMETER ForceUpdate
    Update given manfiest(s) even when there is no new version.
    Usefull for hash updates.
.PARAMETER SkipSupported
    Updated manifests will not be showed.
.EXAMPLE
    PS $BUCKETDIR $ .\bin\checkver.ps1
    Check all manifest inside default directory.
#>
param(
	[String] $App = '*',
	[ValidateScript( {Test-Path $_ -Type Container})]
	[String] $Dir = "$psscriptroot\..\bucket",
	[Switch] $Update,
	[Switch] $ForceUpdate,
	[Switch] $SkipSupported
)

if (($App -eq '*') -and $Update) {
	# While developing the feature we only allow specific updates
	Write-Host '[ERROR] AUTOUPDATE CAN ONLY BE USED WITH A APP SPECIFIED' -ForegroundColor DarkRed
	exit
}

. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\manifest.ps1"
. "$psscriptroot\..\lib\config.ps1"
. "$psscriptroot\..\lib\buckets.ps1"
. "$psscriptroot\..\lib\autoupdate.ps1"
. "$psscriptroot\..\lib\json.ps1"
. "$psscriptroot\..\lib\versions.ps1"
. "$psscriptroot\..\lib\install.ps1" # needed for hash generation
. "$psscriptroot\..\lib\unix.ps1"

$Dir = Resolve-Path $Dir
$Search = $App

# get apps to check
$Queue = @()
$json = ''
Get-ChildItem $Dir "$Search.json" | ForEach-Object {
	$json = parse_json "$Dir\$($_.Name)"
	if ($json.checkver) {
		$Queue += , @($_.Name, $json)
	}
}

# clear any existing events
Get-Event | ForEach-Object {
	Remove-Event $_.SourceIdentifier
}

$original = use_any_https_protocol

# start all downloads
$Queue | ForEach-Object {
	$name, $json = $_

	$substitutions = get_version_substitutions $json.version

	$wc = New-Object Net.Webclient
	if ($json.checkver.useragent) {
		$wc.Headers.Add('User-Agent', (substitute $json.checkver.useragent $substitutions))
	} else {
		$wc.Headers.Add('User-Agent', (Get-UserAgent))
	}
	Register-ObjectEvent $wc downloadstringcompleted -ErrorAction Stop | Out-Null

	$githubRegex = '\/releases\/tag\/(?:v)?([\d.]+)'

	$url = $json.homepage
	if ($json.checkver.url) {
		$url = $json.checkver.url
	}
	$regex = ''
	$jsonpath = ''
	$replace = ''

	if ($json.checkver -eq 'github') {
		if (!$json.homepage.StartsWith('https://github.com/')) {
			error "$name checkver expects the homepage to be a github repository"
		}
		$url = $json.homepage + '/releases/latest'
		$regex = $githubRegex
	}

	if ($json.checkver.github) {
		$url = $json.checkver.github + '/releases/latest'
		$regex = $githubRegex
	}

	if ($json.checkver.re) {
		$regex = $json.checkver.re
	}
	if ($json.checkver.regex) {
		$regex = $json.checkver.regex
	}

	if ($json.checkver.jp) {
		$jsonpath = $json.checkver.jp
	}
	if ($json.checkver.jsonpath) {
		$jsonpath = $json.checkver.jsonpath
	}

	if ($json.checkver.replace -and $json.checkver.replace.GetType() -eq [System.String]) {
		$replace = $json.checkver.replace
	}

	if (!$jsonpath -and !$regex) {
		$regex = $json.checkver
	}

	$reverse = $json.checkver.reverse -and $json.checkver.reverse -eq 'true'

	$url = substitute $url $substitutions

	$state = New-Object psobject @{
		app      = (strip_ext $name);
		url      = $url;
		regex    = $regex;
		json     = $json;
		jsonpath = $jsonpath;
		reverse  = $reverse;
		replace  = $replace;
	}

	$wc.Headers.Add('Referer', (strip_filename $url))
	$wc.DownloadStringAsync($url, $state)
}

function handleErrors($man) {
	return $man
}

# wait for all to complete
$in_progress = $Queue.length
while ($in_progress -gt 0) {
	$ev = Wait-Event
	Remove-Event $ev.SourceIdentifier
	$in_progress--

	$state = $ev.SourceEventArgs.UserState;
	$json_u = $state.json
	$manifest = New-Object psobject @{
		state        = $state;
		app          = $state.app;
		json         = $json_u;
		url          = $state.url;
		expected_ver = $json_u.version;
		regexp       = $state.regex;
		jsonpath     = $state.jsonpath;
		reverse      = $state.reverse;
		replace      = $state.replace;
		ver          = '';
		err          = $ev.SourceEventArgs.Error;
		page         = $ev.SourceEventArgs.Result;
		errors       = @();
	}

	$manifest = (handleErrors $manifest)
	# Write-Host ($ev.SourceEventArgs.UserState -eq $manifest.state) -f Yellow

	$state = $manifest.state
	$app = $manifest.app
	$json = $manifest.json
	$url = $manifest.url
	$expected_ver = $manifest.expected_ver
	$regexp = $manifest.regexp
	$jsonpath = $manifest.jsonpath
	$reverse = $manifest.reverse
	$replace = $manifest.replace
	$ver = $manifest.ver
	$err = $manifest.err
	$page = $manifest.page
	$errors = $manifest.errors

	Write-Host "$app`: " -NoNewline

	if ($err) {
		Write-Host $err.message -ForegroundColor DarkRed
		Write-Host "URL $url is not valid" -ForegroundColor DarkRed
		continue
	}

	if (!$regex -and $replace) {
		Write-Host "'replace' requires 're' or 'regex'" -ForegroundColor DarkRed
		continue
	}

	if ($jsonpath) {
		$ver = json_path $page $jsonpath
		if (!$ver) {
			$ver = json_path_legacy $page $jsonpath
		}
		if (!$ver) {
			Write-Host "couldn't find '$jsonpath' in $url" -ForegroundColor DarkRed
			continue
		}
	}

	if ($jsonpath -and $regexp) {
		$page = $ver
		$ver = ''
	}

	if ($regexp) {
		$regex = New-Object System.Text.RegularExpressions.Regex($regexp)
		if ($reverse) {
			$match = $regex.Matches($page) | Select-Object -Last 1
		} else {
			$match = $regex.Matches($page) | Select-Object -First 1
		}

		if ($match -and $match.Success) {
			$matchesHashtable = @{}
			$regex.GetGroupNames() | ForEach-Object { $matchesHashtable.Add($_, $match.Groups[$_].Value) }
			$ver = $matchesHashtable['1']
			if ($replace) {
				$ver = $regex.Replace($match.Value, $replace)
			}
			if (!$ver) {
				$ver = $matchesHashtable['version']
			}
		} else {
			Write-Host "couldn't match '$regexp' in $url" -ForegroundColor DarkRed
			continue
		}
	}

	if (!$ver) {
		Write-Host "couldn't find new version in $url" -ForegroundColor DarkRed
		continue
	}

	# version hasn't changed (step over if forced update)
	if ($ver -eq $expected_ver -and $ForceUpdate -eq $false) {
		Write-Host $ver -ForegroundColor DarkGreen
		continue
	}

	Write-Host $ver -ForegroundColor DarkRed -NoNewline
	Write-Host " (scoop version is $expected_ver)" -NoNewline
	$Update_available = (compare_versions $expected_ver $ver) -eq -1

	if ($json.autoupdate -and $Update_available) {
		Write-Host ' autoupdate available' -ForegroundColor Cyan
	} else {
		Write-Host ''
	}

	# forcing an update implies updating, right?
	if ($ForceUpdate) { $Update = $true }

	if ($Update -and $json.autoupdate) {
		if ($ForceUpdate) {
			Write-Host 'Forcing autoupdate!' -ForegroundColor DarkMagenta
		}
		try {
			autoupdate $App $Dir $json $ver $matchesHashtable
		} catch {
			error $_.Exception.Message
		}
	}
}

set_https_protocols $original
