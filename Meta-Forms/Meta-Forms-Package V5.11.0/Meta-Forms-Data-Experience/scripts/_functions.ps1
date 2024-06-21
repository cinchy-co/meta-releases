$Global:Token = $Global:TokenExpires = $null

function WriteMessage($Message, $Append = $false, $Time = $true) {
  $MessageTime = if ($Time) { "[{0:MM/dd/yyyy} {0:HH:mm:ss.fff}] | " -f (Get-Date) }
  $Message     = "$($MessageTime)$($Message)"
  $WriteHost   = @{ Object = $Message; NoNewLine = $Append }
  $AddContent  = @{ Path = "$(Join-Path $LogPath $LogFile)"; Value = $Message; NoNewLine = $Append; ErrorAction = "Ignore" }
  Add-Content @AddContent
  if (!$LogOnly) { 
    if ($Message -like "*ERROR -*") {
      Write-Host @WriteHost -ForegroundColor Yellow
    } else {
      Write-Host @WriteHost
    }
  }
}

function ExceptionMessage($CatchResults, $CatchMessages, $StopOnError = $false) {
  $CatchMessages | ForEach-Object { WriteMessage $_ }
  $i = 0
  $CatchResults.StatusDescription | ForEach-Object { 
    if ($_) { WriteMessage "ERROR - $(if ($i++ -eq 0) {"($($CatchResults.StatusCode)) "})$_" }
  }
  if ($StopOnError) { exit }
  return $CatchResults
}

function BuildEndpoints($s, $h, $r) {
  $Endpoints = @{}
  $BaseUri = "$(($h ? 'https' : 'http'))://$s"

  $Endpoints.UseHttps    = $h
  $Endpoints.ServerUri   = $s
  $Endpoints.ServerUrl   = $BaseUri
  $Endpoints.Healthcheck = "$BaseUri/healthcheck"
  $Endpoints.Api         = "$BaseUri/api"
  $Endpoints.ExecuteCql  = "$BaseUri/api/executecql"
  $Endpoints.CreateDx    = "$BaseUri/api/createdxversion"
  $Endpoints.ModelLoader = "$BaseUri/apps/modelloader"
  $Endpoints.Files       = "$BaseUri/api/files/v1.0"
  $r.Content | ConvertFrom-Json | ForEach-Object {
    $_.connections_endpoint = $_.connections_endpoint -replace ";/[^;]*silent-refresh.html", ""
    $Endpoints.Connections = "$($_.connections_endpoint)/api/v1.0/jobs"
    $Endpoints.Auth        = "$($_.idp_endpoint)/identity/connect/token"
  }

  return $Endpoints
}

function GetEndpoints($CinchyServer) {
  $CinchyServer = $CinchyServer.Split('://')[-1].TrimEnd('/').ToLower()

  try {
    $Response = Invoke-WebRequest "https://$($CinchyServer)/.well-known/cinchy-configuration" -Method GET -TimeoutSec 10
    if ($Response.StatusCode -eq 200) { return BuildEndpoints $CinchyServer $true $Response }
    else { throw }
  }
  catch {
    try {
      $Response = Invoke-WebRequest "http://$($CinchyServer)/.well-known/cinchy-configuration" -Method GET -TimeoutSec 10
      if ($Response.StatusCode -eq 200) { return BuildEndpoints $CinchyServer $false $Response }
      else { throw }
    }
    catch {
      WriteMessage "ERROR - Could not connect to Cinchy. Verify the URL before attempting another retry."
      return $null
    }
  }
}

function GetCinchyVersion() {
  $Header = @{
    Authorization = "Bearer $(GetBearerToken)"
  }
  try {
    $Result = Invoke-WebRequest -Uri $Endpoints.Healthcheck -UseBasicParsing -Method GET -Headers $Header -ErrorAction Stop | ConvertFrom-Json
    return [version]$Result.version
  }
  catch {
    WriteMessage "ERROR - Could not retrieve Healthcheck from Cinchy. Verify the server status and URL before attempting another retry."
    exit 1
  }
}

function GetBearerToken() {
  if ($CinchyPAT) { return $CinchyPAT }
  elseif ($(Get-Date) -ge $Global:TokenExpires) {
    $Header = @{
      Content_Type = "application/x-www-form-urlencoded"
    }
    $Body = @{
      username      = [System.Web.HttpUtility]::UrlEncode($CinchyUser)
      password      = [System.Web.HttpUtility]::UrlEncode($CinchyPswd)
      client_id     = $ApiClientID
      client_secret = $ApiClientSecret
      grant_type    = "password"
      scope         = "js_api"
    }
    $Body = ($Body.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"

    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $Result = Invoke-RestMethod -Uri $Endpoints.Auth -Method POST -Body $Body -Headers $Header -ErrorAction Stop
      $Token = $Result.access_token
      $Expires = $Result.expires_in

      $Global:Token = $Token
      $Global:TokenExpires = (Get-Date).AddSeconds($Expires - 60)

      return $Global:Token
    }
    catch {
      $CatchResults = Results $_.Exception.Response -IsException
      $CatchMessages = @(
        "ERROR - (GetBearerToken) An error occurred while attempting to obtain the Bearer Token."
        "ERROR - Verify both the server status and your credentials before attempting another retry."
      )
      ExceptionMessage $CatchResults $CatchMessages $true
    }
  }
  else {
    return $Global:Token
  }
}

function Results {
  param (
    [Parameter(Mandatory = $true)] [PSObject] $r,
    [Parameter(Mandatory = $false)] [String] $ResultFormat,
    [Parameter(Mandatory = $false)] [Switch] $IsException
  )
  $Headers = @{}
  if ($IsException) {
    $r.Headers | ForEach-Object { $Headers += @{ $_.Key = [string]$_.Value[0] } }
  } else {
    $r.Headers.Keys | ForEach-Object { $Headers += @{ $_ = [string]$r.Headers[$_] } }
  }
  return @{
    StatusCode        = [int]$r.StatusCode
    StatusDescription = if ($IsException) { @("$($r.ReasonPhrase)"; "$($Headers.'x-cinchy-error')") } else { $r.StatusDescription }
    Headers           = $Headers
    Data              = switch ($ResultFormat) {
                          XML      { $r.Content }
                          JSON     { $r.Content | ConvertFrom-Json }
                          CSV      { $r.Content }
                          TSV      { $r.Content }
                          PSV      { $r.Content }
                          PROTOBUF { $r.Content }
                          Default  { $r }
                        }
  }
}

function ExecuteQuery {
  param (
    [Parameter(Mandatory = $true)] [String] $Query,
    [Parameter(Mandatory = $false)] [ValidateSet("QUERY","DRAFT_QUERY","SCALAR","NONQUERY","VERSION_HISTORY_QUERY")] [String] $QueryType = "QUERY",
    [Parameter(Mandatory = $false)] [ValidateSet("XML","JSON","CSV","TSV","PSV","PROTOBUF")] [String] $ResultFormat = "JSON",
    [Parameter(Mandatory = $false)] [Bool] $CompressJSON = $false,
    [Parameter(Mandatory = $false)] [Switch] $StopOnError
  )
  $Header = @{
    Authorization = "Bearer $(GetBearerToken)"
  }
  $Body = @{
    Resultformat = $ResultFormat
    Type         = $QueryType
    Query        = $Query
    CompressJSON = $CompressJSON
  }
  try {
    $Result = Invoke-WebRequest -Uri $Endpoints.ExecuteCql -UseBasicParsing -Method POST -Body $Body -Headers $Header -ErrorAction Stop
    return Results $Result $ResultFormat
  }
  catch {
    $CatchResults = Results $_.Exception.Response -IsException
    $CatchMessages = switch ($QueryType) {
      NONQUERY { "ERROR - (ExecuteQuery) Could not insert/update data in Cinchy" }
      default  { "ERROR - (ExecuteQuery) Could not retrieve $ResultFormat data from Cinchy" }
    }
    ExceptionMessage $CatchResults $CatchMessages $StopOnError
  }
}

function GetDXD($DxdGuid) {
  $DxdMetadata = GetCompatibleFiles -Version $CinchyVersion -Path $(Join-Path $Location "scripts/sql/cinchy") -File "Data Experience Definitions.sql"
  $DxdMetadata = Get-Content -LiteralPath $DxdMetadata.FullName -Raw
  $Result = ExecuteQuery ($DxdMetadata -f $DxdGuid, "") -StopOnError
  return $Result.Data
}

function PauseOnError($Message) {
  $Title   = "INSTALL PAUSED"
  $Choices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new("&Retry", "Retry the last operation")
    [System.Management.Automation.Host.ChoiceDescription]::new("&Ignore", "Ignore the error and continue the Install")
    [System.Management.Automation.Host.ChoiceDescription]::new("Ignore &All", "Ignore all errors and continue the Install")
    [System.Management.Automation.Host.ChoiceDescription]::new("E&xit", "Exit the Install")
  )
  $Decision = $Host.UI.PromptForChoice($Title, "$($Message)`n`n", $Choices, 0)
  switch ($Decision) {
    0 {
      WriteMessage "- Retrying the last operation"
      return "Retry"
    }
    1 {
      WriteMessage "- Ignoring this error and continuing the Install"
      return "Ignore"
    }
    2 {
      $global:PauseOnError = $global:PauseOnModel = $false
      WriteMessage "- Ignoring all errors and continuing the Install"
      return "IgnoreAll"
    }
    3 {
      WriteMessage "Exiting the Install at Step [$($Steps[$i])]"
      exit  
    }
  }
}

function ExportConnectionErrors($ExecutionId, $SyncConfig) {
  if (![string]::IsNullOrEmpty($ConnectionsTempPath)) {
    WriteMessage "- Syncing : $('{0,-55}' -f $SyncConfig) : Saving Error Files"
    $Header = @{
      Authorization = "Bearer $(GetBearerToken)"
    }
    $Files = "source-errors", "sync-errors", "target-errors", "logs"
    $Files | ForEach-Object {
      $Endpoint = "$($Endpoints.Connections)/$($ExecutionId)/$($_)?cinchyUrl=$($Endpoints.ServerUrl)&model=Cinchy"
      $OutFile = $(Join-Path $ConnectionsTempPath "$($ExecutionId)$($_ -eq "logs" ? ".log" : "_$($_).csv")")
      for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
          $Response = Invoke-WebRequest -Uri $Endpoint -UseBasicParsing -Method GET -Headers $Header -PassThru -OutFile $OutFile
          if ($Response.StatusCode -eq 200) { break }
        }
        catch {
          Start-Sleep -Milliseconds 1000
        }
      }
    }
  }
}

function ExecuteConnection($SyncConfig, $Parameters, $FileParameters, $Table, $WriteToFile = $false, $RetrievalBatchSize = 5000, $BatchSize = 5000, $MessagePrefix, [Switch]$StopOnError) {
  if ($CinchyDb -eq "PGSQL") {
    $SyncConfig = [System.Net.WebUtility]::HtmlEncode($SyncConfig)
    $SyncConfig = $SyncConfig.Replace( '&', '&amp;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;amp;amp;', '&amp;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;amp;', '&amp;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;lt;', '&lt;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;gt;', '&gt;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;quot;', '&quot;' )
    $SyncConfig = $SyncConfig.Replace( '&amp;apos;', '&apos;' )
  } else {
    $SyncConfig = [System.Net.WebUtility]::HtmlDecode($SyncConfig)
    $SyncConfig = $SyncConfig -replace '&lt;', '<' -replace '&gt;', '>'
  }

  $Options = @{}
  $Options.server             = $Endpoints.ServerUri
  $Options.useHttps           = $Endpoints.UseHttps
  $Options.userId             = $CinchyUser
  $Options.password           = $CinchyPswd
  $Options.model              = "Cinchy"
  $Options.feed               = $SyncConfig
  $Options.batchsize          = [int16]$BatchSize
  $Options.retrievalbatchsize = [int16]$RetrievalBatchSize
  $Options.writeToFile        = $WriteToFile

  $Options.paramValues = @{}
  if ($Parameters) {
    foreach ($Key in $Parameters.Keys) {
      $Options.paramValues.Add($Key, @{
        isFile = $false
        value  = $Parameters[$Key]
      })
    }
  }
  if ($FileParameters) {
    foreach ($Key in $FileParameters.Keys) {
      $Options.paramValues.Add($Key, @{
        isFile = $true
        value  = $(Get-Item -LiteralPath $FileParameters[$Key]).Name
      })
    }
  }
  
  $Header = @{
    "Authorization" = "Bearer $(GetBearerToken)"
    "Content-Type" = "multipart/form-data"
  }
  $Form = @{
    options = $Options | ConvertTo-Json -Depth 4 -Compress
  }

  $Files = if ($FileParameters) { $FileParameters.Keys | ForEach-Object { $FileParameters[$_] } }
  if ($Files) {
    $Form.files = Get-Item -Path $Files
  }

  try {
    $Result = Invoke-RestMethod -Uri $Endpoints.Connections -Method POST -Form $Form -Headers $Header
    if ($Result.executionId) {
      WriteMessage "$($MessagePrefix)- Syncing : $('{0,-55}' -f $SyncConfig.Replace("&amp;","&")) : ExecutionId $($Result.executionId)" $true $true
      do {
        $ExecutionStatus = ExecuteQuery $($ConnectionsStatus -f $Result.executionId) -StopOnError
        Start-Sleep -Milliseconds 2000
      } while (
        $ExecutionStatus.Data.State -eq "Running"
      )
      $Result = $Result | Add-Member -NotePropertyName Status -NotePropertyValue $ExecutionStatus.Data.State -PassThru
      $Result = $Result | Add-Member -NotePropertyName StatusDescription -NotePropertyValue ($ExecutionStatus.Data.Output -replace "`n`n", "`n") -PassThru
      WriteMessage " : $($ExecutionStatus.Data.State.ToUpper())" $false $false
      if ($ConnectionsOutput) {
        $Result.StatusDescription += "`n`n$($ExecutionStatus.Data.Output -replace "`n`n", "`n$(" " * 25)")"
        WriteMessage "- $($ExecutionStatus.Data.Output -replace "`n`n", "`n$(" " * 25)")`n"
      }
      if ($ExecutionStatus.Data.State -ne "Succeeded") {
        ExportConnectionErrors $Result.executionId $SyncConfig | Out-Null
        if ($global:PauseOnError) {
          $Decision = PauseOnError "Sync state `"$($ExecutionStatus.Data.State)`" encountered. Do you wish to continue?"
          if ($Decision -eq "Retry") { ExecuteConnection $SyncConfig $Parameters $FileParameters }
        }
      }
      return $Result
    }
  }
  catch {
    $CatchResults = Results $_.Exception.Response -IsException
    $CatchMessages = @( "ERROR - (ExecuteConnection) Could not start connection : $SyncConfig" )
    ExceptionMessage $CatchResults $CatchMessages $true
  }
}

function GenerateModel($Guid, $ReleaseVersion, $OutFile) {
  $Header = @{
    Authorization = "Bearer $(GetBearerToken)"
  }
  try {
    $Endpoint = "$($Endpoints.CreateDx)?guid=$($Guid)&modelVersion=$($ReleaseVersion)"
    Invoke-WebRequest -Uri $Endpoint -UseBasicParsing -Method GET -Headers $Header -PassThru -OutFile $OutFile -ErrorAction Stop
  }
  catch {
    continue
  }
}

function LoadModel($Model) {
  $Boundary = "----" + [guid]::NewGuid().ToString()

  $FileBin = [System.IO.File]::ReadAllBytes($Model)
  $Enc = [System.Text.Encoding]::GetEncoding("UTF-8")

  $Body = $ModelLoaderTemplate -f $Boundary, $Model.Name, $Enc.GetString($FileBin)
  $ContentType = "multipart/form-data; boundary=$Boundary"
  $Header = @{
    "Authorization" = "Bearer $(GetBearerToken)"
    "cache-control" = "no-cache"
  }

  try {
    $Result = Invoke-RestMethod -Uri $Endpoints.ModelLoader -UseBasicParsing -Method POST -Body $Body -ContentType $ContentType -Headers $Header -ErrorAction Stop
    return $Result
  }
  catch {
    $ErrorMessages = @()
    $_ | Format-List -Force
    $_.ErrorDetails.Message | Select-String -Pattern "---&gt; .*Exception:.*?&#xA;" -AllMatches | ForEach-Object {
      $ErrorMessage = $_.Matches.Value -replace "---&gt; .*Exception: "
      $ErrorMessage = $ErrorMessage -replace "&#xA;", ""
      $ErrorMessages += $ErrorMessage
    }
    $FormattedErrorMessage = $ErrorMessages | Select-Object -Unique | Join-String -Separator "`n"
    $FormattedErrorMessage = $FormattedErrorMessage -replace "(.{1,70})(\s|$)", "`$1`n"
    
    $Message  = "`nERROR - ModelLoader failed to load the following model XML:`n`n"
    $Message += "        /$($DxdName)/model/$(($Model.BaseName))`n`n"
    $Message += "        Check $($Endpoints.ServerUrl)/Table/Cinchy/Models`n"
    $Message += "        If a newer model than `"$(($Model.BaseName).Replace("&","&amp;")) V$($DxdVersion)`"`n"
    $Message += "        exists and you intend to deploy this DXD's version, the newer model record`n"
    $Message += "        must be removed.`n"
    $Message += "        If a newer model does not exist and this model continues to fail, consult the`n"
    $Message += "        Cinchy Platform Web service logs for ModelLoader errors.`n"
    if ($ErrorMessages) {
      $Message += "`n        Additional error information:`n`n "
      $MessageLines = $FormattedErrorMessage -split "`n"
    }
    $Message += foreach ($Line in $MessageLines) { "       $($Line)`n" }

    if ($global:PauseOnModel) {
      $Decision = PauseOnError $Message
      if ($Decision -eq "Retry") { LoadModel $Model }
    } else {
      $MessageLines = $Message -split "`n"
      foreach ($Line in $MessageLines) { WriteMessage $Line }
    }
  }
}

function GenerateCSV($File) {
  $SqlTemplate = Get-Content -LiteralPath $File.FullName
  if ($File.BaseName -eq 'Data Experience Releases') {
    $Result = ExecuteQuery ($SqlTemplate -f $DxdGuid, $ReleaseVersion) 'QUERY' 'CSV' -StopOnError
  } else {
    $Result = ExecuteQuery ($SqlTemplate -f $DxdGuid, $ForXmlValue) 'QUERY' 'CSV' -StopOnError
  }
  return $Result.Data
}

function GenerateRefDataCSV($Query) {
  $Result = ExecuteQuery $Query 'QUERY' 'CSV' -StopOnError
  return $Result.Data
}

function FormatXML([xml]$Xml, $Indent = 2) {
  $StringWriter = New-Object System.IO.StringWriter
  $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter
  $XmlWriter.Formatting = “indented”
  $XmlWriter.Indentation = $Indent
  $Xml.WriteContentTo($XmlWriter)
  $XmlWriter.Flush()
  $StringWriter.Flush()
  return $StringWriter.ToString()
}

function GenerateRefDataXml($RefDataId, $Name) {
  $RefDataColumnMetadata = GetCompatibleFiles -Version $CinchyVersion -Path $(Join-Path $Location "scripts/sql/refdata") -File "Table Columns Metadata.sql"
  $RefDataColumnMetadata = Get-Content -LiteralPath $RefDataColumnMetadata.FullName -Raw
  $RefDataColumnMetadataResult = ExecuteQuery ($RefDataColumnMetadata -f $RefDataId) -StopOnError
  foreach ($Column in $RefDataColumnMetadataResult.Data) {
    $local:Columns += $CliXmlColumnsTemplate -f $Column.name, $Column.dataType
    $ColumnMappings +=
    if ($Column.linkColumn) {
      $CliXmlColumnMappingLinkTemplate -f $Column.sourceColumn, $Column.targetColumn, $Column.linkColumn
    }
    else {
      $CliXmlColumnMappingTemplate -f $Column.sourceColumn, $Column.targetColumn
    }
  }

  #SyncKeys
  $RefDataSyncKeys = GetCompatibleFiles -Version $CinchyVersion -Path $(Join-Path $Location "scripts/sql/refdata") -File "Table SyncKeys.sql"
  $RefDataSyncKeys = Get-Content -LiteralPath $RefDataSyncKeys.FullName -Raw
  $RefDataSyncKeysResult = ExecuteQuery ($RefDataSyncKeys -f $RefDataId) -StopOnError
  foreach ($SyncKey in $RefDataSyncKeysResult.Data) {
    $SyncKeys += $CliXmlSyncKeyTemplate -f $SyncKey.SyncKey
  }

  #Header and New, Changed, Deleted record behaviours
  $RefDataTableMetadata = GetCompatibleFiles -Version $CinchyVersion -Path $(Join-Path $Location "scripts/sql/refdata") -File "Table Metadata.sql"
  $RefDataTableMetadata = Get-Content -LiteralPath $RefDataTableMetadata.FullName -Raw
  $RefDataTableMetadataResult = ExecuteQuery ($RefDataTableMetadata -f $RefDataId) -StopOnError

  if ($RefDataTableMetadataResult.Data.ExpirationTimestamp -ne '' -and $RefDataTableMetadataResult.Data.DroppedRecords -eq 'EXPIRE') {
    $ExpirationTimestamp = " expirationTimestampField=`"$($RefDataTableMetadataResult.Data.ExpirationTimestamp)`""
  }

  #Final XML
  $Name = [System.Security.SecurityElement]::Escape($Name)
  $CliXmlTemp = $CliXmlTemplate -f $Name, $local:Columns, $RefDataTableMetadataResult.Data.Domain, $RefDataTableMetadataResult.Data.TableName, $ColumnMappings, $RefDataTableMetadataResult.Data.TargetFilter, $SyncKeys, $RefDataTableMetadataResult.Data.NewRecords, $RefDataTableMetadataResult.Data.ChangedRecords, $RefDataTableMetadataResult.Data.DroppedRecords, $ExpirationTimestamp
  $CliXmlTemp = $CliXmlTemp.Replace( '&', '&amp;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;amp;amp;', '&amp;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;amp;', '&amp;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;lt;', '&lt;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;gt;', '&gt;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;quot;', '&quot;' )
  $CliXmlTemp = $CliXmlTemp.Replace( '&amp;apos;', '&apos;' )

  return FormatXML($CliXmlTemp) -Indent 4
}

function RemoveXmlElement([xml]$XmlDocument, $ElementName) {
  $xml = $XmlDocument
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("ns", $xml.DocumentElement.NamespaceURI)
  $node = $xml.BatchDataSyncConfig.CinchyTableTarget.ColumnMappings.SelectSingleNode("//ns:ColumnMapping[@targetColumn='$($ElementName)']",$ns)
  $node.ParentNode.RemoveChild($node) | Out-Null
  return $xml
}

function WriteDataSyncConfiguration([xml]$XmlDoc, $SyncName) {
  $DSCFileContents = FormatXml $XmlDoc.OuterXml -Indent 4 | Out-String
  $DSCFileContents = $DSCFileContents -replace "'", "''"
  $SyncGuid = "$DxdfGuid`_$DxdCliVersion`_$($SyncName)"
  $Query = $InsertDataSyncConfigurations -f $DSCFileContents, $SyncGuid
  WriteMessage "- Loading Connection XML : $($SyncName)"
  ExecuteQuery $Query 'NONQUERY' -StopOnError | Out-Null
}

function LoadDXDATA($Table) {
  $XmlDoc = $null
  if (!$Skips.Contains($Table)) {
    # Check for Skipped Columns and modify the sync XML
    if ($Skips) {
      foreach ($Element in $Skips -like "$($Table).*") {
        $Column = $Element.Split(".")[1]
        if ($XmlDoc) {
          $XmlDoc = RemoveXmlElement $XmlDoc $Column
        } else {
          $XmlDoc = RemoveXmlElement (Get-Content -LiteralPath $(Join-Path $Location "cli/$($FileTemplateDXDATA -f "Cinchy", $Table).xml")) $Column
        }
      }
      if ($XmlDoc) {
        WriteDataSyncConfiguration $XmlDoc ($FileTemplateDXDATA -f "Cinchy", $Table)
      }
    }

    $CliName = $FileTemplateDXDATA -f 'Cinchy', $Table
    $CsvFile = $FileTemplateDXDATA -f $DxdName, $Table
    # Check if the file contains data to sync
    $CsvLength = Get-Content (Join-Path $Location "csv/$($CsvFile).csv") | Measure-Object –Line
    if ($CsvLength.Lines -gt 1) {
      ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile).csv")"} $Table | Out-Null
    } else {
      # The CSV is empty. Only sync if the table contains data for this DXD from a previous deployment
      $CurrentRows = ExecuteQuery "SELECT COUNT(*) FROM [Cinchy].[Cinchy].[$($Table)] WHERE [Deleted] IS NULL AND [Sync GUID] LIKE '$($DxdGuid)_%'" "SCALAR" "JSON" $false
      if ($CurrentRows.Content -gt 0) {
        ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile).csv")"} $Table | Out-Null
      } else {
        WriteMessage "- Skipping : $($CliName)"
      }
    }
  } else {
    WriteMessage "- Skipping Table Sync: $($Table)"
  }
}

function LoadREFDATA($CsvFile) {
  $CliName = $CsvFile.Replace( '.csv', '' )
  ExecuteConnection $CliName $null @{"filePath"="$(Join-Path $Location "csv/$($CsvFile)")"} $CliName | Out-Null
}

function Base64Encode($File) {
  $BinaryFile = [System.IO.File]::ReadAllBytes("$File")
  $Base64File = [System.Convert]::ToBase64String($BinaryFile)
  return $Base64File
}

function WriteArtifact($Type, $File) {
  $global:ArtifactCount ++
  $FileName = Split-Path $File -leaf
  Compress-Archive -Path $File -DestinationPath "$DeployPath\temp\$FileName.zip" -CompressionLevel "Optimal" -Force
  if ($KeepFiles -eq $True) {
    $Query = $InsertDataExperienceReleaseArtifacts -f $Type, $ArtifactCount, "$FileName.zip", $(Base64Encode $File), "$($DxdName -replace '&', '&amp;' -replace '&amp;amp;', '&amp;') V$($ReleaseVersion)"
  }
  else {
    $Query = $InsertDataExperienceReleaseArtifacts -f $Type, $ArtifactCount, "$FileName", $Null, "$($DxdName -replace '&', '&amp;' -replace '&amp;amp;', '&amp;') V$($ReleaseVersion)"
  }
  ExecuteQuery $Query 'NONQUERY' -StopOnError | Out-Null
  WriteMessage "- Saved Artifact : $FileName"
}

function CreateEncryptionKey($PathOut) {
  $EncryptionKeyBytes = New-Object Byte[] 32
  [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($EncryptionKeyBytes)
  $EncryptionKeyBytes | Out-File -FilePath $PathOut
  WriteMessage "Encryption Key file created at $PathOut`n"
}

function EncryptFile($File, $EncryptedFile, $KeyFile) {
  $EncryptionKeyData = Get-Content -LiteralPath $KeyFile
  $ContentSecure     = Get-Content -LiteralPath $File | Out-String | ConvertTo-SecureString -AsPlainText -Force
  $ContentEncrypted  = ConvertFrom-SecureString $ContentSecure -Key $EncryptionKeyData
  $ContentEncrypted | Out-File -FilePath $EncryptedFile
}

function DecryptFile($EncryptedFile, $File, $KeyFile) {
  $EncryptionKeyData = Get-Content -LiteralPath $KeyFile
  $ContentEncrypted  = Get-Content -LiteralPath $EncryptedFile | ConvertTo-SecureString -Key $EncryptionKeyData
  $Content           = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ContentEncrypted))
  $Content | Out-File -FilePath $File
}

function GetCompatibleFiles([version]$Version, [string]$Path, [string]$File = $null) {
  $Files = Get-ChildItem -Path $Path -Recurse -File
  if ($File) {
    $Files = $Files | Where-Object { $_.Name -eq $File }
  }
  $Files = $Files | Where-Object { [version]($_.Directory.Name) -le $Version } # Remove future versions
  $FilesToRemove = @()
  $Files | Sort-Object Name, { [version]$_.Directory.Name } | ForEach-Object {
    if ($PreviousFile -and $PreviousFile.Name -eq $_.Name) {
      $FilesToRemove += $PreviousFile # Remove past versions if there are duplicate files
    }
    $PreviousFile = $_
  }
  $Files = $Files | Where-Object { $FilesToRemove -notcontains $_ } | Sort-Object Name
  return $Files
}

#region Initialization
$LogFile = "$($(Split-Path $MyInvocation.PSCommandPath -Leaf) -replace '.ps1', '') $("{0:yyyyMMdd}_{0:HHmmssfff}" -f (Get-Date)).log"

if ($global:Action -ne "keygen") {
  $Endpoints = GetEndpoints($CinchyServer)
  if (!$Endpoints) {
    WriteMessage "ERROR - Could not connect to Cinchy. Verify the server status and URL before attempting another retry."
    exit 2
  }
  $CinchyPAT = (!$u) ? $p : $null
  $CinchyDb  = (ExecuteQuery "SELECT 1" -StopOnError ).Data.'?column?' ? "PGSQL" : "TSQL"
  }
#endregion Initialization
