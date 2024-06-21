DECLARE @CinchyURL VARCHAR(100)
DECLARE @MetaFormsURL VARCHAR(100)
DECLARE @CinchyVersion VARCHAR(100)

/*                   Input the below              */ 

SET @CinchyURL = '<Cinchy URL with Protocol>'
SET @MetaFormsURL = '<Metaforms URL with Protocol>'
SET @CinchyVersion = '5.11.0'

/*                    End of Input                 */


SELECT 
[Path] =
CASE WHEN LEN(@CinchyURL) - LEN(REPLACE(@CinchyURL, '/', '')) > 2 THEN
SUBSTRING(
			SUBSTRING(@CinchyURL,CHARINDEX('//',@CinchyURL)+2,LEN(@CinchyURL)),
			CHARINDEX('/',
						SUBSTRING(@CinchyURL,
        				 			CHARINDEX('//',@CinchyURL)+2,
                 		 			LEN(@CinchyURL)
                  					)
        			  ),
			LEN(@CinchyURL))
ELSE ''
END
INTO #path


/* Retrieving Cinchy Id of the Editor Applet */
SELECT 
ca.[Cinchy Id]
INTO #editorID
FROM [Cinchy].[Applets] ca
WHERE ca.[Deleted] IS NULL
AND ca.[Full Name] = 'Cinchy Forms.Editor'




UPDATE a
SET
a.[Application URL] = CASE WHEN a.[Full Name] = 'Cinchy Forms.Editor' THEN @MetaFormsURL
					  ELSE REPLACE(REPLACE(LOWER(a.[Application URL]), 'https://pilot.cinchy.net/dxdev-mssql-1', LOWER(@CinchyURL)),'2',CAST(e.[Cinchy Id] AS VARCHAR(100)))
                      END
FROM [Cinchy].[Applets] a
LEFT JOIN #editorID e ON 1=1
WHERE a.[Deleted] IS NULL
AND a.[Full Name] IN ('Cinchy Forms.Editor','Cinchy Forms.Form Designer')
AND a.[Application Url] != CASE WHEN a.[Full Name] = 'Cinchy Forms.Editor' THEN @MetaFormsURL
					  ELSE REPLACE(REPLACE(LOWER(a.[Application URL]), 'https://pilot.cinchy.net/dxdev-mssql-1', LOWER(@CinchyURL)),'2',CAST(e.[Cinchy Id] AS VARCHAR(100)))
            END

UPDATE i
SET
i.[Permitted Login Redirect URLs] = @MetaFormsURL,
i.[Permitted Logout Redirect URLs] = @MetaFormsURL
FROM [Cinchy].[Integrated Clients] i
WHERE i.[Deleted] IS NULL
AND i.[Client Id] = 'cinchy_meta_forms'
AND LEFT(CAST(@CinchyVersion AS VARCHAR(100)),1) = '4'
  AND (
    i.[Permitted Login Redirect URLs] != @MetaFormsURL
    OR i.[Permitted Logout Redirect URLs] != @MetaFormsURL
  ) 



UPDATE tc
SET 
tc.[Calculated Column Expression] = 
  REPLACE(REPLACE(
    tc.[Calculated Column Expression],'/dxdev-mssql-1',p.[Path]),'appId=2',CONCAT('appId=',CAST(e.[Cinchy Id] AS VARCHAR(100))))
FROM [Cinchy].[Table Columns] tc
LEFT JOIN #editorID e ON 1=1
LEFT JOIN #path p ON 1=1
WHERE
  tc.[Deleted] IS NULL
  AND tc.[Full Name] IN ('Cinchy Forms.Forms.Actions','Cinchy Forms.Form Sections.Actions','Cinchy Forms.Form Fields.Actions')
  AND tc.[Calculated Column Expression] != 
  REPLACE(REPLACE(
    tc.[Calculated Column Expression],'/dxdev-mssql-1',p.[Path]),'appId=2',CONCAT('appId=',CAST(e.[Cinchy Id] AS VARCHAR(100))))


UPDATE s
SET 
s.[Json] =
  REPLACE(REPLACE(
    s.[Json],'/dxdev-mssql-1',p.[Path]),'appId=2',CONCAT('appId=',CAST(e.[Cinchy Id] AS VARCHAR(100))))
FROM [Cinchy].[Tables] s
LEFT JOIN #editorID e ON 1=1
LEFT JOIN #path p ON 1=1
WHERE
  s.[Deleted] IS NULL
  AND s.[Full Name] IN ('Cinchy Forms.Forms','Cinchy Forms.Form Sections','Cinchy Forms.Form Fields')
  AND s.[Json] !=   REPLACE(REPLACE(
    s.[Json],'/dxdev-mssql-1',p.[Path]),'appId=2',CONCAT('appId=',CAST(e.[Cinchy Id] AS VARCHAR(100))))


    






