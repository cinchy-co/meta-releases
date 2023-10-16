# Cinchy DXD common functions
$ProgressPreference = 'SilentlyContinue'
$LogFile = Split-Path $MyInvocation.PSCommandPath -Leaf
$LogFile = "$($LogFile -replace '.ps1', '') $(get-date -format `"yyyyMMdd_hhmmsstt`").log"

function WriteMessage($Message, $Append = $false, $Time = $true) {
  $MessageTime = if ($Time) { "[{0:MM/dd/yyyy} {0:HH:mm:ss}] | " -f (Get-Date) }
  $Message     = "$($MessageTime)$($Message)"
  $WriteHost   = @{ Object = $Message; NoNewLine = $Append }
  $AddContent  = @{ Path = "$(Join-Path $LogPath $LogFile)"; Value = $Message; NoNewLine = $Append; ErrorAction = "Ignore" }
  Add-Content @AddContent
  if (!$LogOnly) { Write-Host @WriteHost }
}

function BuildEndpoints($s, $h, $r) {
  $Endpoints = @()
  if ($h) { 
    $Endpoints += @{UseHttps = "true" }
    $p = "https"
  }
  else {
    $Endpoints += @{UseHttps = "false" }
    $p = "http"
  }
  $BaseUri = "$($p)://$($s)"
  $Endpoints += @{ServerUri = $s }
  $Endpoints += @{ServerUrl = $BaseUri }
  $Endpoints += @{Healthcheck = "$($BaseUri)/healthcheck" }
  $Endpoints += @{Api = "$($BaseUri)/api" }
  $Endpoints += @{ExecuteCql = "$($BaseUri)/api/executecql" }
  $Endpoints += @{CreateDx = "$($BaseUri)/api/createdxversion" }
  $Endpoints += @{ModelLoader = "$($BaseUri)/apps/modelloader" }
  $r.Content | ConvertFrom-Json | ForEach-Object {
    $Endpoints += @{Connections = "$($_.connections_endpoint)/api/jobs" }
    $Endpoints += @{Auth = "$($_.idp_endpoint)/identity/connect/token" }
  }
  return $Endpoints
}

function GetEndpoints($CinchyServer) {
  $CinchyServer = $CinchyServer.Split('://')
  $CinchyServer = $CinchyServer[-1].TrimEnd('/').ToLower()

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
      return $null
    }
  }
}

function GetCinchyVersion() {
  $Header = @{
    Authorization = "Bearer $($BearerToken)"
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
  $Header = @{
    Content_Type = "application/x-www-form-urlencoded"
  }
  $Body = @{
    username      = $CinchyUser
    password      = $CinchyPswd
    client_id     = $ApiClientID
    client_secret = $ApiClientSecret
    grant_type    = 'password'
    scope         = 'js_api'
  }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Result = Invoke-WebRequest -Uri $Endpoints.Auth -UseBasicParsing -Method POST -Body $Body -Headers $Header -ErrorAction Stop
    $Token = $Result | ConvertFrom-JSON | Select-Object -ExpandProperty access_token
    return $Token
  }
  catch {
    WriteMessage "ERROR - An error occurred while attempting to obtain the Bearer Token. Verify both"
    WriteMessage "        the server status and your credentials before attempting another retry.`n"
    break
  }
}

function ExecuteQuery($Query, $QueryType, $ResultFormat, $CompressJSON = $true) {
  $Header = @{
    Authorization = "Bearer $($BearerToken)"
  }
  $Body = @{
    Resultformat = $ResultFormat
    Type         = $QueryType
    Query        = $Query
    CompressJSON = $CompressJSON
  }
  try {
    $Result = Invoke-WebRequest -Uri $Endpoints.ExecuteCql -UseBasicParsing -Method POST -Body $Body -Headers $Header -ErrorAction Stop
    return $Result
  }
  catch {
    switch ($QueryType) {
      QUERY    { WriteMessage "ERROR - (ExecuteQuery) Could not retrieve $ResultFormat data from Cinchy" }
      NONQUERY { WriteMessage "ERROR - (ExecuteQuery) Could not insert data into Cinchy" }
    }
    exit 1
  }
}

function GetDXD($DxdGuid) {
  $DxdMetadata = Get-Content -Path $(Join-Path $Location "scripts/sql/cinchy/Data Experience Definitions.sql")
  $Result = ExecuteQuery ($DxdMetadata -f $DxdGuid, "") 'QUERY' 'JSON' $false | ConvertFrom-Json -ErrorAction Stop
  return $Result
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
  if ($ConnectionsTempPath -ne "") {
    WriteMessage "- Syncing : $('{0,-55}' -f $SyncConfig) : Saving Error Files"
    $Header = @{
      Authorization = "Bearer $($BearerToken)"
    }
    $Files = "source-errors", "sync-errors", "target-errors", "logs"
    $Files | ForEach-Object {
      $Endpoint = "$($Endpoints.Connections)/$($ExecutionId)/$($_)?cinchyUrl=$($Endpoints.ServerUrl)&model=Cinchy"
      $OutFile = $(Join-Path $ConnectionsTempPath "$($ExecutionId)$($_ -eq "logs" ? ".log" : "_$($_).csv")")
      $Attempt = 0
      do {
        $Attempt += 1
        try {
          $Response = Invoke-WebRequest -Uri $Endpoint -UseBasicParsing -Method GET -Headers $Header -PassThru -OutFile $OutFile
          $ResponseCode = $Response.StatusCode
        }
        catch {
          $ResponseCode = ($_ | ConvertFrom-Json).status
          Start-Sleep -Milliseconds 1000
        }
      } until (
        $ResponseCode -eq 200 -or $Attempt -eq 3
      )
    }
  }
}

function ExecuteConnection($SyncConfig, $Parameters, $FileParameters, $Table) {
  $ParamValues  = @()
  $ParamValues += if ($Parameters)     { $Parameters.Keys | ForEach-Object { $ConnectionsParam -f $_, "false", $Parameters[$_] } }
  $ParamValues += if ($FileParameters) { $FileParameters.Keys | ForEach-Object { $ConnectionsParam -f $_, "true", $(Get-Item -Path $FileParameters[$_]).Name } }
                  if ($ParamValues)    { $ParamValues = $ConnectionsParamValues -f $($ParamValues -join(',')) }
  $Options = $ConnectionsOptions -f $Endpoints.ServerUri, $Endpoints.UseHttps, $CinchyUser, $CinchyPswd, "Cinchy", $SyncConfig, 5000, 5000, "false", $ParamValues
  $Files = if ($FileParameters) { $FileParameters.Keys | ForEach-Object { $FileParameters[$_] } }

  $Header = @{
    "Authorization" = "Bearer $($BearerToken)"
    "Content-Type" = "multipart/form-data"
  }
  $Form = @{
    options = $Options
    files   = Get-Item -Path $Files
  }
  try {
    $Result = Invoke-RestMethod -Uri $Endpoints.Connections -Method POST -Form $Form -Headers $Header
    if ($Result.executionId) {
      WriteMessage "- Syncing : $('{0,-55}' -f $SyncConfig.Replace("&amp;","&")) : ExecutionId $($Result.executionId)" $true $true
      do {
        $ExecutionStatus = ExecuteQuery $($ConnectionsStatus -f $Result.executionId) "QUERY" "JSON" $false | ConvertFrom-Json
        Start-Sleep -Milliseconds 2000
      } while (
        $ExecutionStatus.State -eq "Running"
      )
      WriteMessage " : $($ExecutionStatus.State.ToUpper())" $false $false
      if ($ConnectionsOutput) {
        WriteMessage "- $($ExecutionStatus.Output -replace "`n`n", "`n$(" " * 25)")`n"
      }
      if ($ExecutionStatus.State -ne "Succeeded") {
        ExportConnectionErrors $Result.executionId $SyncConfig | Out-Null
        if ($global:PauseOnError) {
          $Decision = PauseOnError "Sync state `"$($ExecutionStatus.State)`" encountered. Do you wish to continue?"
          if ($Decision -eq "Retry") { ExecuteConnection $SyncConfig $Parameters $FileParameters $Table }
        }
      }
    }
  }
  catch {
    WriteMessage "ERROR - (ExecuteConnection) Could not start connection : $SyncConfig"
    exit 1
  }
}

function GenerateModel($Guid, $ReleaseVersion, $OutFile) {
  $Header = @{
    Authorization = "Bearer $($BearerToken)"
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
  $ModelPath = Join-Path $Location "model/$($Model)"
  $FileName = Split-Path $ModelPath -leaf
  $Boundary = "----" + [guid]::NewGuid().ToString()

  $FileBin = [System.IO.File]::ReadAllBytes($ModelPath)
  $Enc = [System.Text.Encoding]::GetEncoding("iso-8859-1")

  $Body = $ModelLoaderTemplate -f $Boundary, $FileName, $Enc.GetString($FileBin)
  $ContentType = "multipart/form-data; boundary=$Boundary"
  $Header = @{
    "Authorization" = "Bearer $($BearerToken)"
    "cache-control" = "no-cache"
  }

  try {
    $Result = Invoke-RestMethod -Uri $Endpoints.ModelLoader -UseBasicParsing -Method POST -Body $Body -ContentType $ContentType -Headers $Header -ErrorAction Stop
    return $Result
  }
  catch {
    if ($global:PauseOnModel) {
      $Message  = "ERROR - ModelLoader failed to load $($ModelPath)`n"
      $Message += "        Check $($Endpoints.ServerUrl)/Table/Cinchy/Models`n"
      $Message += "        If a model exists for `"$($DxdName) $($DxdVersion)`" and you intend to`n"
      $Message += "        redeploy this version, the model record must be removed.`n"
      $Message += "        If this model does not exist and it continues to fail, consult the`n"
      $Message += "        Cinchy Platform Web service logs for ModelLoader errors."
      $Decision = PauseOnError $Message
      if ($Decision -eq "Retry") { LoadModel $Model }
    } else {
      WriteMessage "ERROR - ModelLoader failed to load $($ModelPath)"
      WriteMessage "        Check $($Endpoints.ServerUrl)/Table/Cinchy/Models"
      WriteMessage "        If a model exists for `"$($DxdName) $($DxdVersion)`" and you intend to"
      WriteMessage "        redeploy this version, the model record must be removed."
      WriteMessage "        If this model does not exist and it continues to fail, consult the"
      WriteMessage "        Cinchy Platform Web service logs for ModelLoader errors."
    }
  }
}

function GenerateCSV($Query) {
  $SqlTemplate = Get-Content -Path $(Join-Path $Location "scripts/sql/cinchy/$Query")
  if ($Query -eq 'Data Experience Releases.sql') {
    $Result = ExecuteQuery ($SqlTemplate -f $DxdGuid, $ReleaseVersion) 'QUERY' 'CSV'
  } else {
    $Result = ExecuteQuery ($SqlTemplate -f $DxdGuid) 'QUERY' 'CSV'
  }
  return $Result.Content
}

function GenerateRefDataCSV($Query) {
  $Result = ExecuteQuery $Query 'QUERY' 'CSV' $false
  return $Result.Content
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
  $RefDataTableMetadata = Get-Content -Path $(Join-Path $Location "scripts/sql/refdata/Table Metadata.sql")
  $Result = ExecuteQuery ($RefDataTableMetadata -f $RefDataId) 'QUERY' 'JSON'
  try {
    $Recordset = $Result.content | ConvertFrom-Json -ErrorAction Stop
    if (($Recordset.data.Count) -ne 1) {
      WriteMessage "ERROR - $($Recordset.data.Count) records retrieved, expecting only one record"
      exit 1
    }
    else {
      $Domain = $Recordset.data[0][0]
      $TableName = $Recordset.data[0][1]
      $Ordinal = $Recordset.data[0][2]
      $TargetFilter = $Recordset.data[0][3]
      $NewRecords = $Recordset.data[0][4]
      $ChangedRecords = $Recordset.data[0][5]
      $DroppedRecords = $Recordset.data[0][6]
      $ExpirationTimestamp = $Recordset.data[0][7]
    }
  }
  catch {
    WriteMessage ("ERROR - Could not retrieve table configuration from Cinchy`n" + $_.Exception.Message) "Y"
    exit 1
  }

  $RefDataColumnMetadata = Get-Content -Path $(Join-Path $Location "scripts/sql/refdata/Table Columns Metadata.sql")
  $Result = ExecuteQuery ($RefDataColumnMetadata -f $RefDataId) 'QUERY' 'JSON'
  try {
    $Recordset = $Result.content | ConvertFrom-Json -ErrorAction Stop
    if (($Recordset.data.Count) -eq 0) {
      WriteMessage "ERROR - $($Recordset.data.Count) records retrieved, expecting more than one record"
      exit 1
    }
    else {
      $Columns =
      foreach ($Record in $Recordset.data) {
        $CliXmlColumnsTemplate -f $Record[1], $Record[2]
      }
      $ColumnMappings =
      foreach ($Record in $Recordset.data) {
        if ($Record[5]) {
          $CliXmlColumnMappingLinkTemplate -f $Record[3], $Record[4], $Record[5]
        }
        else {
          $CliXmlColumnMappingTemplate -f $Record[3], $Record[4]
        }
      }
      $Columns = $Columns | Out-String
      $ColumnMappings = $ColumnMappings | Out-String
    }
  }
  catch {
    WriteMessage "ERROR - Could not retrieve column metadata from Cinchy`n"
    exit 1
  }

  #SyncKeys
  $RefDataSyncKeys = Get-Content -Path $(Join-Path $Location "scripts/sql/refdata/Table SyncKeys.sql")
  $Result = ExecuteQuery ($RefDataSyncKeys -f $RefDataId) 'QUERY' 'JSON'
  try {
    $Recordset = $Result.content | ConvertFrom-Json -ErrorAction Stop
    if (($Recordset.data.Count) -eq 0) {
      WriteMessage "ERROR - $($Recordset.data.Count) records retrieved, expecting more than one record"
      exit 1
    }
    else {
      $SyncKeys = foreach ($Record in $Recordset.data) {
        $CliXmlSyncKeyTemplate -f $Record
      }
      $SyncKeys = $SyncKeys | Out-String
    }
  }
  catch {
    WriteMessage "ERROR - Could not retrieve sync keys from Cinchy`n"
    exit 1
  }

  if ($ExpirationTimestamp -ne '' -and $DroppedRecords -eq 'EXPIRE') {
    $ExpirationTimestamp = " expirationTimestampField=`"$ExpirationTimestamp`""
  }
  else {
    $ExpirationTimestamp = ''
  }
  $CliXmlTemp = $CliXmlTemplate -f $Name, $Columns, $Domain, $TableName, $ColumnMappings, $TargetFilter, $SyncKeys, $NewRecords, $ChangedRecords, $DroppedRecords, $ExpirationTimestamp
  $CliXmlTemp = $CliXmlTemp.replace( '&', '&amp;' )
  $CliXmlTemp = $CliXmlTemp.replace( '&amp;amp;', '&amp;')
  $CliXmlTemp = $CliXmlTemp.replace( '&amp;lt;', '&lt;')
  $CliXmlTemp = $CliXmlTemp.replace( '&amp;gt;', '&gt;')
  $CliXmlTemp = $CliXmlTemp.replace( '&amp;quot;', '&quot;')
  $CliXmlTemp = $CliXmlTemp.replace( '&amp;apos;', '&apos;')

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
  ExecuteQuery $Query 'NONQUERY' 'JSON' | Out-Null
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
          $XmlDoc = RemoveXmlElement (Get-Content -Path $(Join-Path $Location "cli/$($FileTemplateDXDATA -f "Cinchy", $Table).xml")) $Column
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
      ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile).csv")"} $Table
    } else {
      # The CSV is empty. Only sync if the table contains data for this DXD from a previous deployment
      $CurrentRows = ExecuteQuery "SELECT COUNT(*) FROM [Cinchy].[Cinchy].[$($Table)] WHERE [Deleted] IS NULL AND [Sync GUID] LIKE '$($DxdGuid)_%'" "SCALAR" "JSON" $false
      if ($CurrentRows.Content -gt 0) {
        ExecuteConnection $CliName @{"dxdGuid"="$($DxdGuid)"} @{"filePath"="$(Join-Path $Location "csv/$($CsvFile).csv")"} $Table
      } else {
        WriteMessage "- Skipping : $($CliName)"
      }
    }
  } else {
    WriteMessage "- Skipping Table Sync: $($Table)"
  }
}

function LoadREFDATA($CsvFile) {
  $CliName = $CsvFile -Replace '.csv', ''
  ExecuteConnection $CliName.Replace("&","&amp;") $null @{"filePath"="$(Join-Path $Location "csv/$($CsvFile)")"} $CliName
}

function Base64Encode($File) {
  $BinaryFile = [System.IO.File]::ReadAllBytes("$File")
  $Base64File = [System.Convert]::ToBase64String($BinaryFile)
  return $Base64File
}

function WriteArtifact($Type, $File) {
  $global:ArtifactCount ++
  $FileName = Split-Path $File -leaf
  Compress-Archive -Path "$File" -DestinationPath "$DeployPath\temp\$FileName.zip" -CompressionLevel "Optimal" -Force
  if ($KeepFiles -eq $True) {
    $Query = $InsertDataExperienceReleaseArtifacts -f $Type, $ArtifactCount, "$FileName.zip", $(Base64Encode $File), "$($DxdName -replace '&', '&amp;' -replace '&amp;amp;', '&amp;') V$($ReleaseVersion)"
  }
  else {
    $Query = $InsertDataExperienceReleaseArtifacts -f $Type, $ArtifactCount, "$FileName", $Null, "$($DxdName -replace '&', '&amp;' -replace '&amp;amp;', '&amp;') V$($ReleaseVersion)"
  }
  ExecuteQuery $Query 'NONQUERY' 'JSON' | Out-Null
  WriteMessage "- Saved Artifact : $FileName"
}

function CreateEncryptionKey($PathOut) {
  $EncryptionKeyBytes = New-Object Byte[] 32
  [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($EncryptionKeyBytes)
  $EncryptionKeyBytes | Out-File -FilePath $PathOut
  WriteMessage "Encryption Key file created at $PathOut`n"
}

function EncryptFile($File, $EncryptedFile, $KeyFile) {
  $EncryptionKeyData = Get-Content $KeyFile
  $ContentSecure     = Get-Content -Path $File | Out-String | ConvertTo-SecureString -AsPlainText -Force
  $ContentEncrypted  = ConvertFrom-SecureString $ContentSecure -Key $EncryptionKeyData
  $ContentEncrypted | Out-File -FilePath $EncryptedFile
}

function DecryptFile($EncryptedFile, $File, $KeyFile) {
  $EncryptionKeyData = Get-Content $KeyFile
  $ContentEncrypted  = Get-Content $EncryptedFile | ConvertTo-SecureString -Key $EncryptionKeyData
  $Content           = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ContentEncrypted))
  $Content | Out-File -FilePath $File
}

# Global executions
if ($global:Action -ne "keygen") {
  $Endpoints = GetEndpoints($CinchyServer)
  if (!$Endpoints) {
    WriteMessage "ERROR - Could not connect to Cinchy. Verify the server status and URL before attempting another retry."
    exit 2
  }
  $BearerToken = (!$u) ? $p : (GetBearerToken)
}
