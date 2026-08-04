SELECT TOP (1000)
    b.[BrandID],
    b.[BrandName],
    b.[SectorID],
    b.[AddedDate],
    b.[ModifiedDate],
    s.[SectorID] AS SectorID_FromSector,
    s.[SectorGroupID],
    s.[SectorName],
    g.[SectorGroupID] AS SectorGroupID_FromGroup,
    g.[GroupName]
FROM [WH_AllPublishers].[Trans].[Brand] AS b
LEFT JOIN [WH_AllPublishers].[Trans].[BrandSector] AS s
    ON b.[SectorID] = s.[SectorID]
LEFT JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
    ON s.[SectorGroupID] = g.[SectorGroupID];