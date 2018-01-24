$cfgpath = "~/.scoop"

function hashtable ($obj) {
  $h = @{}
  $obj.psobject.properties | ForEach-Object {
    $h[$_.Name] = hashtable_val $_.Value
  }
  return $h
}

function hashtable_val ($obj) {
  if ($obj -eq $null) { return $null }
  if ($obj -is [array]) {
    $arr = @()
    $obj | ForEach-Object {
      $val = hashtable_val $_
      if ($val -is [array]) {
        $arr +=,@( $val)
      } else {
        $arr += $val
      }
    }
    return,$arr
  }
  if ($obj.GetType().Name -eq 'pscustomobject') { # -is is unreliable
    return hashtable $obj
  }
  return $obj # assume primitive
}

function load_cfg {
  if (!(Test-Path $cfgpath)) { return $null }

  try {
    hashtable (Get-Content $cfgpath -Raw | ConvertFrom-Json -ea stop)
  } catch {
    Write-Host "ERROR loading $cfgpath`: $($_.exception.message)"
  }
}

function get_config ($name) {
  return $cfg.$name
}

function set_config ($name,$val) {
  if (!$cfg) {
    $cfg = @{ $name = $val }
  } else {
    $cfg.$name = $val
  }

  if ($val -eq $null) {
    $cfg.remove($name)
  }

  ConvertTo-Json $cfg | Out-File $cfgpath -Encoding utf8
}

$cfg = load_cfg

# setup proxy
# note: '@' and ':' in password must be escaped, e.g. 'p@ssword' -> p\@ssword'
$p = get_config 'proxy'
if ($p) {
  try {
    $cred,$address = $p -split '(?<!\\)@'
    if (!$address) {
      $address,$cred = $cred,$null # no credentials supplied
    }

    if ($address -eq 'none') {
      [net.webrequest]::defaultwebproxy = $null
    } elseif ($address -ne 'default') {
      [net.webrequest]::defaultwebproxy = New-Object net.webproxy "http://$address"
    }

    if ($cred -eq 'currentuser') {
      [net.webrequest]::defaultwebproxy.credentials = [net.credentialcache]::defaultcredentials
    } elseif ($cred) {
      $user,$pass = $cred -split '(?<!\\):' | ForEach-Object { $_ -replace '\\([@:])','$1' }
      [net.webrequest]::defaultwebproxy.credentials = New-Object net.networkcredential ($user,$pass)
    }
  } catch {
    warn "Failed to use proxy '$p': $($_.exception.message)"
  }
}
