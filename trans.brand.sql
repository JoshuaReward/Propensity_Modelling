DECLARE @groupCols NVARCHAR(MAX);
DECLARE @sql NVARCHAR(MAX);

WITH distinct_groups AS (
    SELECT DISTINCT
        g.[GroupName]
    FROM [WH_AllPublishers].[Trans].[Brand] AS b
    LEFT JOIN [WH_AllPublishers].[Trans].[BrandSector] AS s
        ON b.[SectorID] = s.[SectorID]
    LEFT JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
        ON s.[SectorGroupID] = g.[SectorGroupID]
    WHERE g.[GroupName] IS NOT NULL
)
SELECT @groupCols = STRING_AGG(
    CONCAT(
        N'SUM(CASE WHEN g.[GroupName] = ''',
        REPLACE([GroupName], '''', ''''''),
        N''' THEN 1 ELSE 0 END) AS ',
        QUOTENAME([GroupName])
    ),
    N', '
) WITHIN GROUP (ORDER BY [GroupName])
FROM distinct_groups;

SET @sql = N'
SELECT
    b.[BrandID],
    COUNT(*) AS [TotalTransactions],
    ' + @groupCols + N'
FROM [WH_AllPublishers].[Trans].[Brand] AS b
LEFT JOIN [WH_AllPublishers].[Trans].[BrandSector] AS s
    ON b.[SectorID] = s.[SectorID]
LEFT JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
    ON s.[SectorGroupID] = g.[SectorGroupID]
WHERE g.[GroupName] IS NOT NULL
GROUP BY b.[BrandID]
ORDER BY b.[BrandID];
';

EXEC sp_executesql @sql;
