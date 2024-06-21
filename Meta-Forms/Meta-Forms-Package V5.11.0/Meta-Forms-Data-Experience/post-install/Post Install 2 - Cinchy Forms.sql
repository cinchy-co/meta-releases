DECLARE @Execute AS VARCHAR

UPDATE f1
SET 
f1.[Form ID] = f2.[Form ID]
FROM [Cinchy Forms].[Forms] f1
INNER JOIN [Cinchy Forms].[Forms] f2 ON f2.[Deleted] IS NULL AND f2.[Form ID] = f1.[Form ID]
WHERE f1.[Deleted] IS NULL


UPDATE fs1
SET
fs1.[Name] = fs2.[Name]
FROM [Cinchy Forms].[Form Sections] fs1
INNER JOIN [Cinchy Forms].[Form Sections] fs2 ON fs2.[Deleted] IS NULL AND fs1.[Form] = fs2.[Form] AND fs1.[Name] = fs2.[Name]
WHERE fs1.[Deleted] IS NULL



UPDATE ff1
SET
ff1.[Caption Override] = ff2.[Caption Override]
FROM [Cinchy Forms].[Form Fields] ff1
INNER JOIN [Cinchy Forms].[Form Fields] ff2 ON ff2.[Deleted] IS NULL AND ff1.[Form Section] = ff2.[Form Section] AND ff1.[Table Column] = ff2.[Table Column]
WHERE ff1.[Deleted] IS NULL



