# Model Template
$ModelLoaderTemplate                  = @'
--{0}
Content-Disposition: form-data; name="xmlFile"; filename="{1}"
Content-Type: text/xml

{2}
--{0}
Content-Disposition: form-data; name="dropColumns"

true
--{0}
Content-Disposition: form-data; name="updateColumns"

true
--{0}
Content-Disposition: form-data; name="renameTablesAndUpdateDomains"

true
--{0}
Content-Disposition: form-data; name="recalulateCalculatedColumns"

true
--{0}--

'@

# CLI Templates
$CliXmlTemplate                       = @'
<?xml version="1.0" encoding="utf-16"?>
<BatchDataSyncConfig name="{0}" version="1.0.0" xmlns="http://www.cinchy.co">
  <Parameters>
    <Parameter name="filePath" />
  </Parameters>
  <DelimitedDataSource source="PATH" path="@filePath" delimiter="," textQualifier="&quot;" headerRowsToIgnore="0" encoding="UTF8" useHeaderRecord="true">
    <Schema>
{1}    </Schema>
  </DelimitedDataSource>
  <CinchyTableTarget model="" domain="{2}" table="{3}" suppressDuplicateErrors="false">
    <ColumnMappings>
{4}    </ColumnMappings>
    <Filter>{5}</Filter>
    <SyncKey>
{6}    </SyncKey>
    <NewRecordBehaviour type="{7}" />
    <ChangedRecordBehaviour type="{8}" />
    <DroppedRecordBehaviour type="{9}"{10} />
  </CinchyTableTarget>
</BatchDataSyncConfig>
'@
$CliXmlColumnsTemplate                = '      <Column name="{0}" dataType="{1}" />'
$CliXmlColumnMappingTemplate          = '      <ColumnMapping sourceColumn="{0}" targetColumn="{1}" />'
$CliXmlColumnMappingLinkTemplate      = '      <ColumnMapping sourceColumn="{0}" targetColumn="{1}" linkColumn="{2}" />'
$CliXmlSyncKeyTemplate                = '      <SyncKeyColumnReference name="{0}" />'
$ConnectionsStatus                    = 'SELECT [State], [Output] = [Execution Output] FROM [Cinchy].[Execution Log] WHERE [Deleted] IS NULL AND [Cinchy Id] = {0}'

# File Templates
$FileTemplateMODEL                    = 'DXDF - {0} - MODEL - Model'
$FileTemplateREFDATA                  = 'DXDF - {0} - REFDATA - {1} - {2}'
$FileTemplateDXDF                     = 'DXDF - {0} - DXDF - {1}'
$FileTemplateDXDATA                   = 'DXDF - {0} - DXDATA - {1}'

# Select Templates
$RefDataQueryTemplate                 = 'SELECT{0} FROM {1}{2}'
$DxrQueryTemplate                     = "SELECT [Data Experience], [Release Version] FROM [Cinchy].[Cinchy].[Data Experience Releases] WHERE [Deleted] IS NULL AND ISNULL([Data Experience].[Sync GUID],[Data Experience].[Guid]) = '{0}' AND [Release Version] = '{1}'"

# Insert/Update Templates
$InsertDataSyncConfigurations         = @"
IF (
  SELECT 1
  FROM [Cinchy].[Cinchy].[Data Sync Configurations]
  WHERE
    [Deleted] IS NULL
    AND [Sync GUID] = '{1}'
  ) = 1
BEGIN
  UPDATE dsc
  SET
    dsc.[Config XML] = CAST('{0}' AS NVARCHAR(MAX))
  FROM [Cinchy].[Cinchy].[Data Sync Configurations] dsc
  WHERE
    dsc.[Deleted] IS NULL
    AND dsc.[Config XML] != '{0}'
    AND dsc.[Sync GUID] = '{1}'
END
ELSE
BEGIN
  INSERT INTO [Cinchy].[Cinchy].[Data Sync Configurations] ([Config XML], [Sync GUID], [Admin Groups]) VALUES ('{0}','{1}',RESOLVELINK('All Users','Name'))
END
"@
$InsertDataExperienceReleases         = "INSERT INTO [Cinchy].[Cinchy].[Data Experience Releases] ([Release Version], [Data Experience]) VALUES ('{0}',RESOLVELINK('{1}','Guid'))"
$UpdateDataExperienceReleases         = "UPDATE [Cinchy].[Cinchy].[Data Experience Releases] SET [Release Binary] = CAST('{0}' AS VARBINARY) WHERE [Deleted] IS NULL AND [Data Experience] = '{1}'"
$InsertDataExperienceReleaseArtifacts = "INSERT INTO [Cinchy].[Cinchy].[Data Experience Release Artifacts] ([Type], [Ordinal], [File Name], [File Binary], [Data Experience Release]) VALUES ('{0}',{1},'{2}','{3}',RESOLVELINK('{4}','Release Name'))"

$InitializeViews                      = @"
DELETE v 
FROM [Cinchy].[Cinchy].[Views] v 
WHERE
  v.[Deleted] IS NULL
  AND (
    v.[Name] = 'All Data'
    OR v.[Table].[Deleted] IS NOT NULL
  );

DELETE vc 
FROM [Cinchy].[Cinchy].[View Columns] vc 
WHERE
  vc.[Deleted] IS NULL
  AND (
    vc.[View].[Deleted] IS NOT NULL
    OR vc.[Column].[Deleted] IS NOT NULL
  );

DELETE vclg 
FROM [Cinchy].[Cinchy].[View Column Link Graph] vclg 
WHERE
  vclg.[Deleted] IS NULL
  AND (
    vclg.[View Column].[Deleted] IS NOT NULL
    OR vclg.[Link Column].[Deleted] IS NOT NULL
  );
"@

$InitializeViewsDuplicates            = @"
DELETE vc
FROM [Cinchy].[View Columns] vc
WHERE
  vc.[Deleted] IS NULL
  AND vc.[Sync GUID] IS NULL
  AND EXISTS (
    SELECT 1
    FROM [Cinchy].[View Columns] vci
    WHERE
      vci.[Deleted] IS NULL
      AND vci.[Sync GUID] LIKE '{0}_%'
      AND vci.[View].[Cinchy Id] = vc.[View].[Cinchy Id]
  )
"@

$InitializeModel                      = "DELETE m FROM [Cinchy].[Models] m WHERE m.[Deleted] IS NULL AND m.[Name] = '{0}'"
