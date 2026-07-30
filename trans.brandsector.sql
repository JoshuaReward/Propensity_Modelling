SELECT TOP (1000)
    s.[SectorID],
    s.[SectorGroupID],
    s.[SectorName],
    g.[GroupName]
FROM [WH_AllPublishers].[Trans].[BrandSector] AS s
INNER JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
    ON s.[SectorGroupID] = g.[SectorGroupID];