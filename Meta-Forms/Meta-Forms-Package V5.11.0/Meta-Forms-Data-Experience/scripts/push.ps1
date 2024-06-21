. $(Join-Path $Location "scripts/_templates.ps1")
. $(Join-Path $Location "scripts/_functions.ps1")

#region Process dxd.ini
Get-Content $(Join-Path $Location "dxd.ini") | ForEach-Object `
  -Begin { 
  $DxdIni = @{}
} `
  -Process {
  $Vars = [regex]::split($_, '=')
  if (($Vars[0].CompareTo("") -ne 0) -and ($Vars[0].StartsWith("[") -ne $True)) {
    $DxdIni.Add($Vars[0], $Vars[1])
  }
}

$CinchyVersion    = GetCinchyVersion
$DxdCinchyVersion = [version]$DxdIni.CinchyVers
$DxdGuid          = $DxdIni.DxdGuid
$DxdName          = $DxdIni.DxdName
$DxdVersion       = [version]$DxdIni.DxdVers
#endregion Process dxd.ini

WriteMessage "Installing the $($DxdName) Data Experience into $($CinchyServer)"

#region First check that the release doesn't already exist
$Query = $DxrQueryTemplate -f $DxdGuid, $DxdVersion
$Result = ExecuteQuery $Query -StopOnError
try {
  $Recordset = $Result.Data
  if ($Recordset.Count -eq 1 -and !$ForceInstall) {
    WriteMessage "ERROR - Release $($DxdName) V$($DxdVersion) already exists in $($CinchyServer)`n"
    exit 1
  }
  elseif ($Recordset.data.Count -eq 1 -and $ForceInstall) {
    WriteMessage "WARN - Release $($DxdName) V$($DxdVersion) already exists in $($CinchyServer)"
    WriteMessage "     - Will attempt to overwrite"
  }
}
catch {
  WriteMessage "ERROR - Could not retrieve Data Experience Release data from Cinchy`n"
  exit 1
}
#endregion First check that the release doesn't already exist

#region Compare Cinchy Versions
if ($DxdCinchyVersion -ne $CinchyVersion) {
  WriteMessage "WARN - Export Cinchy version is $($DxdCinchyVersion). $($CinchyServer) version is $($CinchyVersion)"
}
#endregion Compare Cinchy Versions

$Steps = @()
if     ($Start -gt $End) { WriteMessage "End value can not be less than Start value"; break }
elseif (($Start -le 0) -or ($End -le 0)) { WriteMessage "Start and/or End value must be greater than 0"; break }
else   {for ($i = $Start; $i -le $End; $i++) { $Steps = $Steps + $i }}
$i = 0

# Decrypt files
if ($KeyFile) {
  $Files = Get-ChildItem -Path $Location -Filter '*.encrypted' -Recurse
  foreach ($File in $Files) {
    DecryptFile $File.FullName $File.FullName.Replace('.encrypted','') $KeyFile | Out-Null
  }
}

switch ($Steps) {
  # Execute Pre Install Scripts
  1 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Executing $DxdName Pre-Install Scripts"

    $PrsFiles = Get-ChildItem -Path $(Join-Path $Location "pre-install") -Name -Filter '*.sql' | Sort-Object
    foreach ($PrsFile in $PrsFiles) {
      WriteMessage "- Executing Script : $PrsFile"
      $PrsFileCql = Get-Content -Path $(Join-Path "$($Location)/pre-install" $PrsFile)
      $Decision = "Retry"
      while ($Decision -eq "Retry") {
        $PreInstall = ExecuteQuery ($PrsFileCql -f $DxdGuid) 'NONQUERY' 'JSON'
        if ($PreInstall.StatusCode -ne 200 -and $global:PauseOnError) {
          $Decision = PauseOnError "Pre-Install Script error encountered. Do you wish to continue?"
        } else {
          $Decision = $null
        }
      }
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Insert Data Sync Configurations CLI
  2 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Loading the Cinchy Table CLIs"

    # Prepare the CLIs based on CinchyVersion
    Get-ChildItem -Path (Join-Path $Location "cli") -File | ForEach-Object { Remove-Item -Path $_.FullName -Force | Out-Null }
    $BaseFiles = GetCompatibleFiles -Version $CinchyVersion -Path (Join-Path $Location "cli")
    foreach ($File in $BaseFiles) {
      # If deploying from < 5.10.0 to 5.10.0+, use the 4.21.0 version of Saved Queries.xml
      if ($File.Name -eq "Saved Queries.xml" -and $CinchyVersion -ge [version]"5.10.0" -and $DxdCinchyVersion -lt [version]"5.10.0") {
        $File = GetCompatibleFiles -Version ([version]"4.21.0") -Path (Join-Path $Location "cli") -File "Saved Queries.xml"
      }
      $NewName = $FileTemplateDXDATA -f 'Cinchy', $File.Name
      Copy-Item -Path $File.FullName -Destination (Join-Path $Location "cli/$NewName") -Force
    }

    $XmlList = Get-ChildItem -Path $(Join-Path $Location "cli") -File -Name -Exclude "*- Groups.xml"
    foreach ($File in $XmlList) {
      WriteDataSyncConfiguration (Get-Content -Path $(Join-Path $Location "cli/$($File)")) $($File -replace '.xml', '')
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Load DXDATA and REFDATA Data Sync Configurations
  3 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Loading the $DxdName Data Experience and Reference Data CLIs"

    # Load System Colours and Domains first
    LoadDXDATA 'System Colours'
    LoadDXDATA 'Domains'

    #region Groups
    # Override skips momentarily to exclude child records on first Groups sync
    $HoldSkips = $Skips
    $Skips = ("$($Skip), Groups.User Groups, Groups.Owner Groups" -split ",").Trim()
    LoadDXDATA 'Groups'
    $Skips = $HoldSkips
    $Groups = Get-ChildItem -Path $(Join-Path $Location "cli") -File -Name -Filter "*- Groups.xml"
    WriteDataSyncConfiguration (Get-Content -Path $(Join-Path $Location "cli/$($Groups)")) $($Groups -replace '.xml', '')
    LoadDXDATA 'Groups'
    #endregion Groups

    LoadDXDATA 'User Defined Functions'

    $CliName = $FileTemplateDXDATA -f 'Cinchy', 'Data Sync Configurations'
    $CsvFiles = Get-ChildItem -Path $(Join-Path $Location "csv") -Name -Filter '*DXDATA - Data Sync Configurations.csv'
    foreach ($CsvFile in $CsvFiles) {
      ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)_DXDATA"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile)")"} | Out-Null
    }
    $CsvFiles = Get-ChildItem -Path $(Join-Path $Location "csv") -Name -Filter '*REFDATA - 0 - Data Sync Configurations.csv'
    foreach ($CsvFile in $CsvFiles) {
      ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)_REFDATA"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile)")"} | Out-Null
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Load MODEL
  4 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Installing the $DxdName Data Experience Model"

    # Load Model(s)
    $XmlFiles = Get-ChildItem -Path $(Join-Path $Location "model") | Sort-Object
    foreach ($XmlFile in $XmlFiles) {
      WriteMessage "- Loading Model : $('{0,-53}' -f $XmlFile.BaseName)"
      $ModelRows = Get-Content -LiteralPath $XmlFile -TotalCount 2 | Measure-Object -Line
      if ($ModelRows.Lines -gt 1) {
        WriteMessage "- Model `"$($DxdName) V$($DxdVersion)`" will be removed if it already exists"
        ExecuteQuery ($InitializeModel -f "$($DxdName) V$($DxdVersion)") 'NONQUERY' 'JSON' -StopOnError | Out-Null
        $Result = LoadModel $XmlFile
        if ($Result -eq "Success") {
          WriteMessage "- Loading Model : $('{0,-53}' -f $XmlFile.BaseName) : $($Result.ToUpper())"
        }
      }
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Load DXDATA (in order)
  5 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Installing the $DxdName Data Experience Metadata"

    LoadDXDATA 'Table Access Control'
    LoadDXDATA 'Models'
    # If deploying to versions < 5.10.0, use -skip to remove the "CompressJSON" and "Use Legacy URL Structure" columns
    if ($CinchyVersion -lt [version]"5.10.0") {
      $Skips = ("$($Skip), Saved Queries.CompressJSON, Saved Queries.Use Legacy URL Structure" -split ",").Trim()
    }
    LoadDXDATA 'Saved Queries'
    if ($CinchyVersion -ge [version]"5.7.0" -and $DxdCinchyVersion -ge [version]"5.7.0") {
      LoadDXDATA 'Webhooks'
      LoadDXDATA 'External Secrets Manager'
      LoadDXDATA 'Secrets'
      LoadDXDATA 'Listener Config'
    }

    #region Views
    ExecuteQuery $InitializeViews 'NONQUERY' 'JSON' $false | Out-Null
    LoadDXDATA 'Views'
    LoadDXDATA 'View Columns'
    LoadDXDATA 'View Column Link Graph'
    ExecuteQuery $InitializeViews 'NONQUERY' 'JSON' | Out-Null
    ExecuteQuery ($InitializeViewsDuplicates -f $DxdGuid) 'NONQUERY' 'JSON' | Out-Null
    #endregion Views

    LoadDXDATA 'Formatting Rules'
    LoadDXDATA 'Literal Groups'
    LoadDXDATA 'Literals'
    LoadDXDATA 'Literal Translations'
    LoadDXDATA 'Integrated Clients'
    LoadDXDATA 'Applets'
    LoadDXDATA 'Data Experience Reference Data'
    LoadDXDATA 'Data Experience Definitions'

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Load REFDATA
  6 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Installing the $DxdName Reference Data"

    $CsvFiles = Get-ChildItem -Path $(Join-Path $Location "csv") -Name -Filter '*REFDATA*.csv' -Exclude '*Data Sync Configurations*' | Sort-Object
    foreach ($CsvFile in $CsvFiles) {
      LoadREFDATA $CsvFile
    }
            
    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Execute Post Install Scripts
  7 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Executing $DxdName Post Install Scripts"

    $PsFiles = Get-ChildItem -Path $(Join-Path $Location "post-install") -Name -Filter '*.sql' | Sort-Object
    foreach ($PsFile in $PsFiles) {
      WriteMessage "- Executing Script : $PsFile"
      $PsFileCql = Get-Content -Path $(Join-Path "$($Location)/post-install" $PsFile)
      $Decision = "Retry"
      while ($Decision -eq "Retry") {
        $PostInstall = ExecuteQuery ($PsFileCql -f $DxdGuid) 'NONQUERY' 'JSON'
        if ($PostInstall.StatusCode -ne 200 -and $global:PauseOnError) {
          $Decision = PauseOnError "Post-Install Script error encountered. Do you wish to continue?"
        } else {
          $Decision = $null
        }
      }
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
  # Finalization
  8 {
    WriteMessage ("-" * 100)
    WriteMessage "Step: [$($Steps[$i])] - Clean up and register $DxdName in target"

    LoadDXDATA 'Data Experience Releases'
    if ($KeyFile) {
      foreach ($File in $Files) {
        Remove-Item -Path $File.FullName.Replace('.encrypted','') -Force | Out-Null
      }
    }

    WriteMessage "Step: [$($Steps[$i++])] - Complete"
  }
}

WriteMessage "$DxdName Data Experience install complete"
