SET NOCOUNT ON;

DECLARE @as_of_date DATE = CAST(GETDATE() AS DATE);
DECLARE @sample_size INT = 2000000;
DECLARE @lookback_7 INT = 7;
DECLARE @lookback_30 INT = 30;
DECLARE @lookback_90 INT = 90;
DECLARE @lookback_365 INT = 365;
DECLARE @lookback_days INT = 1460; -- customizable lookback window (in days)

DECLARE @use_7 BIT;
DECLARE @use_30 BIT;
DECLARE @use_90 BIT;
DECLARE @use_365 BIT;

SET @use_7 = CASE WHEN @lookback_7 <= @lookback_days THEN 1 ELSE 0 END;
SET @use_30 = CASE WHEN @lookback_30 <= @lookback_days THEN 1 ELSE 0 END;
SET @use_90 = CASE WHEN @lookback_90 <= @lookback_days THEN 1 ELSE 0 END;
SET @use_365 = CASE WHEN @lookback_365 <= @lookback_days THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#sampled_customers') IS NOT NULL DROP TABLE #sampled_customers;
IF OBJECT_ID('tempdb..#customer_base') IS NOT NULL DROP TABLE #customer_base;
IF OBJECT_ID('tempdb..#joined_transactions') IS NOT NULL DROP TABLE #joined_transactions;
IF OBJECT_ID('tempdb..#fan_sector_affinity') IS NOT NULL DROP TABLE #fan_sector_affinity;
IF OBJECT_ID('tempdb..#fan_group_affinity') IS NOT NULL DROP TABLE #fan_group_affinity;
IF OBJECT_ID('tempdb..#population_sector_affinity') IS NOT NULL DROP TABLE #population_sector_affinity;
IF OBJECT_ID('tempdb..#population_group_affinity') IS NOT NULL DROP TABLE #population_group_affinity;
IF OBJECT_ID('tempdb..#fan_sector_affinity_avg') IS NOT NULL DROP TABLE #fan_sector_affinity_avg;
IF OBJECT_ID('tempdb..#fan_group_affinity_avg') IS NOT NULL DROP TABLE #fan_group_affinity_avg;

-- Get a random sample of 1000 or so customers
SELECT TOP (@sample_size)
    st.FanID
INTO #sampled_customers
FROM [WH_AllPublishers].[Derived].[SchemeTrans] AS st
WHERE st.FanID IS NOT NULL 
AND st.PublisherID = 132
GROUP BY st.FanID
ORDER BY NEWID();

-- Joined sampled customers with their respective transaction history
WITH sampled_transactions AS (
    SELECT
        st.[ID],
        st.[FanID],
        st.[Spend],
        st.[TranDate],
        st.[TranTime],
        st.[RetailerCashback],
        st.[Investment],
        st.[RewardCommission],
        st.[VATCommission],
        st.[GrossCommission],
        st.[PartnerID],
        st.[PublisherID],
        st.[OfferID]
    FROM [WH_AllPublishers].[Derived].[SchemeTrans] AS st
    INNER JOIN #sampled_customers sc
        ON st.FanID = sc.FanID
    WHERE st.TranDate IS NOT NULL
      AND st.Spend IS NOT NULL
),
joined_transactions AS (
    SELECT
        st.[FanID],
        st.[Spend],
        st.[TranDate],
        st.[TranTime],
        st.[RetailerCashback],
        st.[Investment],
        st.[RewardCommission],
        st.[VATCommission],
        st.[GrossCommission],
        s.[SectorName],
        g.[GroupName]
    FROM sampled_transactions AS st
    INNER JOIN [WH_AllPublishers].[Derived].[Partner] AS a
        ON st.[PartnerID] = a.[PartnerID]
    INNER JOIN [WH_AllPublishers].[Derived].[Publisher] AS t
        ON st.[PublisherID] = t.[PublisherID]
    INNER JOIN [WH_AllPublishers].[Derived].[Offer] AS o
        ON st.[OfferID] = o.[OfferID]
    INNER JOIN [WH_AllPublishers].[Trans].[Brand] AS b
        ON a.[BrandID] = b.[BrandID]
    INNER JOIN [WH_AllPublishers].[Trans].[BrandSector] AS s
        ON b.[SectorID] = s.[SectorID]
    INNER JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
        ON s.[SectorGroupID] = g.[SectorGroupID]
    WHERE st.[Spend] > 0
),
purchase_dates AS (
    SELECT
        [FanID],
        CAST([TranDate] AS DATE) AS [PurchaseDate]
    FROM joined_transactions
    WHERE [TranDate] >= DATEADD(day, -@lookback_days, @as_of_date)
    GROUP BY [FanID], CAST([TranDate] AS DATE)
),
purchase_intervals AS (
    SELECT
        [FanID],
        [PurchaseDate],
        DATEDIFF(day, LAG([PurchaseDate]) OVER (PARTITION BY [FanID] ORDER BY [PurchaseDate]), [PurchaseDate]) AS [DaysBetweenPurchases]
    FROM purchase_dates
),
purchase_interval_metrics AS (
    SELECT
        [FanID],
        AVG(CASE WHEN [DaysBetweenPurchases] IS NOT NULL THEN [DaysBetweenPurchases] END) AS [AvgDaysBetweenPurchases],
        STDEV(CASE WHEN [DaysBetweenPurchases] IS NOT NULL THEN [DaysBetweenPurchases] END) AS [StdDevDaysBetweenPurchases]
    FROM purchase_intervals
    GROUP BY [FanID]
),
weekly_activity AS (
    SELECT
        [FanID],
        DATEADD(week, DATEDIFF(week, 0, [PurchaseDate]), 0) AS [WeekStart]
    FROM purchase_dates
    GROUP BY [FanID], DATEADD(week, DATEDIFF(week, 0, [PurchaseDate]), 0)
),
weekly_activity_ranked AS (
    SELECT
        [FanID],
        [WeekStart],
        ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [WeekStart]) AS [RowNum],
        DATEDIFF(week, 0, [WeekStart]) AS [WeekIndex]
    FROM weekly_activity
),
weekly_activity_groups AS (
    SELECT
        [FanID],
        ([WeekIndex] - [RowNum]) AS [GroupKey]
    FROM weekly_activity_ranked
),
consecutive_week_metrics AS (
    SELECT
        [FanID],
        MAX([GroupSize]) AS [ConsecutiveWeeksWithActivity]
    FROM (
        SELECT
            [FanID],
            [GroupKey],
            COUNT(*) AS [GroupSize]
        FROM weekly_activity_groups
        GROUP BY [FanID], [GroupKey]
    ) AS x
    GROUP BY [FanID]
),
customer_metrics AS (
    SELECT
        [FanID],
        SUM(CASE WHEN @use_7 = 1 AND [TranDate] >= DATEADD(day, -@lookback_7, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_7d],
        SUM(CASE WHEN @use_30 = 1 AND [TranDate] >= DATEADD(day, -@lookback_30, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_30d],
        SUM(CASE WHEN @use_90 = 1 AND [TranDate] >= DATEADD(day, -@lookback_90, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_90d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_365d],
        SUM(CASE
                WHEN [TranDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
                 AND [TranDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
                THEN [Spend]
                ELSE 0
            END) AS [Spend_CurrentMonth],
        SUM(CASE
                WHEN [TranDate] >= DATEADD(month, -1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
                 AND [TranDate] < DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
                THEN [Spend]
                ELSE 0
            END) AS [Spend_PriorMonth],
        MAX([TranDate]) AS [LastPurchaseDate],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) AS [Transactions_365d],
        COUNT(CASE WHEN @use_7 = 1 AND [TranDate] >= DATEADD(day, -@lookback_7, @as_of_date) THEN 1 END) AS [Purchases_7d],
        COUNT(CASE WHEN @use_30 = 1 AND [TranDate] >= DATEADD(day, -@lookback_30, @as_of_date) THEN 1 END) AS [Purchases_30d],
        COUNT(CASE WHEN @use_90 = 1 AND [TranDate] >= DATEADD(day, -@lookback_90, @as_of_date) THEN 1 END) AS [Purchases_90d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) AS [Purchases_365d],
        COUNT(DISTINCT CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN CAST([TranDate] AS DATE) END) AS [PurchaseDays_365d],
        ROUND(AVG(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [RetailerCashback] END), 2) AS [AvgRetailerCashback_365d],
        ROUND(AVG(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Investment] END), 2) AS [AvgInvestment_365d],
        ROUND(AVG(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [RewardCommission] END), 2) AS [AvgRewardCommission_365d],
        ROUND(AVG(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [VATCommission] END), 2) AS [AvgVATCommission_365d],
        ROUND(AVG(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [GrossCommission] END), 2) AS [AvgGrossCommission_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) < 12 THEN 1 END) AS [AM_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) < 12 THEN [Spend] ELSE 0 END) AS [AM_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) >= 12 THEN 1 END) AS [PM_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) >= 12 THEN [Spend] ELSE 0 END) AS [PM_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) NOT IN (1, 7) THEN 1 END) AS [Weekday_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) NOT IN (1, 7) THEN [Spend] ELSE 0 END) AS [Weekday_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) IN (1, 7) THEN 1 END) AS [Weekend_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) IN (1, 7) THEN [Spend] ELSE 0 END) AS [Weekend_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (12, 1, 2) THEN 1 END) AS [Winter_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (12, 1, 2) THEN [Spend] ELSE 0 END) AS [Winter_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (3, 4, 5) THEN 1 END) AS [Spring_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (3, 4, 5) THEN [Spend] ELSE 0 END) AS [Spring_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (6, 7, 8) THEN 1 END) AS [Summer_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (6, 7, 8) THEN [Spend] ELSE 0 END) AS [Summer_Spend_365d],
        COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (9, 10, 11) THEN 1 END) AS [Autumn_Purchases_365d],
        SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (9, 10, 11) THEN [Spend] ELSE 0 END) AS [Autumn_Spend_365d],
        CASE
            WHEN COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) = 0 THEN NULL
            ELSE ROUND(SUM(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Spend] ELSE 0 END) / NULLIF(COUNT(CASE WHEN @use_365 = 1 AND [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END), 0), 2)
        END AS [AverageBasketSize]
    FROM joined_transactions
    GROUP BY [FanID]
),
sector_purchase_summary AS (
    SELECT
        [FanID],
        [SectorName],
        SUM([Spend]) AS [SectorSpend],
        COUNT(*) AS [SectorPurchases]
    FROM joined_transactions
    GROUP BY [FanID], [SectorName]
),
sector_ranked AS (
    SELECT
        [FanID],
        [SectorName],
        [SectorSpend],
        [SectorPurchases],
        SUM([SectorSpend]) OVER (PARTITION BY [FanID]) AS [TotalSectorSpend],
        SUM([SectorPurchases]) OVER (PARTITION BY [FanID]) AS [TotalSectorPurchases],
        ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [SectorPurchases] DESC, [SectorName]) AS [SectorRank]
    FROM sector_purchase_summary
),
sector_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [SectorName]) AS [UniqueSectorCategories],
        MAX(CASE WHEN [SectorRank] = 1 THEN [SectorName] END) AS [FavouriteSectorName],
        MAX(CASE WHEN [SectorRank] = 1 THEN [SectorPurchases] END) AS [FavouriteSectorPurchases],
        MAX([TotalSectorPurchases]) AS [TotalSectorPurchases],
        ROUND(100.0 * MAX(CASE WHEN [SectorRank] = 1 THEN [SectorSpend] END) / NULLIF(MAX([TotalSectorSpend]), 0), 2) AS [SectorSpendPct],
        ROUND(1.0 * MAX(CASE WHEN [SectorRank] = 1 THEN [SectorPurchases] END) / NULLIF(MAX([TotalSectorPurchases]), 0), 4) AS [SectorAffinity]
    FROM sector_ranked
    GROUP BY [FanID]
),
group_purchase_summary AS (
    SELECT
        [FanID],
        [GroupName],
        SUM([Spend]) AS [GroupSpend],
        COUNT(*) AS [GroupPurchases]
    FROM joined_transactions
    GROUP BY [FanID], [GroupName]
),
group_ranked AS (
    SELECT
        [FanID],
        [GroupName],
        [GroupSpend],
        [GroupPurchases],
        SUM([GroupSpend]) OVER (PARTITION BY [FanID]) AS [TotalGroupSpend],
        SUM([GroupPurchases]) OVER (PARTITION BY [FanID]) AS [TotalGroupPurchases],
        ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [GroupPurchases] DESC, [GroupName]) AS [GroupRank]
    FROM group_purchase_summary
),
group_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [GroupName]) AS [UniqueGroupCategories],
        MAX(CASE WHEN [GroupRank] = 1 THEN [GroupName] END) AS [FavouriteGroupName],
        MAX(CASE WHEN [GroupRank] = 1 THEN [GroupPurchases] END) AS [FavouriteGroupPurchases],
        MAX([TotalGroupPurchases]) AS [TotalGroupPurchases],
        ROUND(100.0 * MAX(CASE WHEN [GroupRank] = 1 THEN [GroupSpend] END) / NULLIF(MAX([TotalGroupSpend]), 0), 2) AS [GroupSpendPct],
        ROUND(1.0 * MAX(CASE WHEN [GroupRank] = 1 THEN [GroupPurchases] END) / NULLIF(MAX([TotalGroupPurchases]), 0), 4) AS [GroupAffinity]
    FROM group_ranked
    GROUP BY [FanID]
),
fan_sector_affinity AS (
    SELECT
        [FanID],
        [SectorName],
        [SectorPurchases],
        SUM([SectorPurchases]) OVER (PARTITION BY [FanID]) AS [TotalPurchases],
        ROUND(1.0 * [SectorPurchases] / NULLIF(SUM([SectorPurchases]) OVER (PARTITION BY [FanID]), 0), 4) AS [SectorAffinity]
    FROM sector_purchase_summary
),
fan_group_affinity AS (
    SELECT
        [FanID],
        [GroupName],
        [GroupPurchases],
        SUM([GroupPurchases]) OVER (PARTITION BY [FanID]) AS [TotalPurchases],
        ROUND(1.0 * [GroupPurchases] / NULLIF(SUM([GroupPurchases]) OVER (PARTITION BY [FanID]), 0), 4) AS [GroupAffinity]
    FROM group_purchase_summary
),
customer_base AS (
    SELECT
        cm.[FanID],
        cm.[Spend_7d],
        cm.[Spend_30d],
        cm.[Spend_90d],
        cm.[Spend_365d],
        cm.[Spend_CurrentMonth],
        cm.[Spend_PriorMonth],
        cm.[Transactions_365d],
        cm.[LastPurchaseDate],
        cm.[Purchases_7d],
        cm.[Purchases_30d],
        cm.[Purchases_90d],
        cm.[Purchases_365d],
        cm.[AverageBasketSize],
        cm.[AvgRetailerCashback_365d],
        cm.[AvgInvestment_365d],
        cm.[AvgRewardCommission_365d],
        cm.[AvgVATCommission_365d],
        cm.[AvgGrossCommission_365d],
        cm.[AM_Purchases_365d],
        cm.[AM_Spend_365d],
        cm.[PM_Purchases_365d],
        cm.[PM_Spend_365d],
        cm.[Weekday_Purchases_365d],
        cm.[Weekday_Spend_365d],
        cm.[Weekend_Purchases_365d],
        cm.[Weekend_Spend_365d],
        cm.[Winter_Purchases_365d],
        cm.[Winter_Spend_365d],
        cm.[Spring_Purchases_365d],
        cm.[Spring_Spend_365d],
        cm.[Summer_Purchases_365d],
        cm.[Summer_Spend_365d],
        cm.[Autumn_Purchases_365d],
        cm.[Autumn_Spend_365d],
        COALESCE(ss.[UniqueSectorCategories], 0) AS [UniqueSectorCategories],
        COALESCE(gs.[UniqueGroupCategories], 0) AS [UniqueGroupCategories],
        COALESCE(ss.[FavouriteSectorName], '') AS [FavouriteSectorName],
        COALESCE(ss.[SectorSpendPct], 0) AS [SectorSpendPct],
        COALESCE(ss.[SectorAffinity], 0) AS [SectorAffinity],
        COALESCE(gs.[FavouriteGroupName], '') AS [FavouriteGroupName],
        COALESCE(gs.[GroupSpendPct], 0) AS [GroupSpendPct],
        COALESCE(gs.[GroupAffinity], 0) AS [GroupAffinity],
        COALESCE(pim.[AvgDaysBetweenPurchases], 0) AS [AvgDaysBetweenPurchases],
        COALESCE(pim.[StdDevDaysBetweenPurchases], 0) AS [StdDevDaysBetweenPurchases],
        COALESCE(cwm.[ConsecutiveWeeksWithActivity], 0) AS [ConsecutiveWeeksWithActivity]
    FROM customer_metrics AS cm
    LEFT JOIN purchase_interval_metrics AS pim
        ON cm.[FanID] = pim.[FanID]
    LEFT JOIN consecutive_week_metrics AS cwm
        ON cm.[FanID] = cwm.[FanID]
    LEFT JOIN sector_summary AS ss
        ON cm.[FanID] = ss.[FanID]
    LEFT JOIN group_summary AS gs
        ON cm.[FanID] = gs.[FanID]
)
SELECT *
INTO #customer_base
FROM customer_base;

SELECT
    st.[FanID],
    st.[Spend],
    st.[TranDate],
    st.[TranTime],
    st.[RetailerCashback],
    st.[Investment],
    st.[RewardCommission],
    st.[VATCommission],
    st.[GrossCommission],
    s.[SectorName],
    g.[GroupName]
INTO #joined_transactions
FROM [WH_AllPublishers].[Derived].[SchemeTrans] AS st
INNER JOIN #sampled_customers sc
    ON st.FanID = sc.FanID
INNER JOIN [WH_AllPublishers].[Derived].[Partner] AS a
    ON st.[PartnerID] = a.[PartnerID]
INNER JOIN [WH_AllPublishers].[Derived].[Publisher] AS t
    ON st.[PublisherID] = t.[PublisherID]
INNER JOIN [WH_AllPublishers].[Derived].[Offer] AS o
    ON st.[OfferID] = o.[OfferID]
INNER JOIN [WH_AllPublishers].[Trans].[Brand] AS b
    ON a.[BrandID] = b.[BrandID]
INNER JOIN [WH_AllPublishers].[Trans].[BrandSector] AS s
    ON b.[SectorID] = s.[SectorID]
INNER JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS g
    ON s.[SectorGroupID] = g.[SectorGroupID]
WHERE st.TranDate IS NOT NULL
  AND st.Spend IS NOT NULL
  AND st.Spend > 0;

SELECT
    [FanID],
    [SectorName],
    [SectorPurchases],
    [SectorAffinity]
INTO #fan_sector_affinity
FROM (
    SELECT
        [FanID],
        [SectorName],
        COUNT(*) AS [SectorPurchases],
        ROUND(1.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY [FanID]), 0), 4) AS [SectorAffinity]
    FROM #joined_transactions
    GROUP BY [FanID], [SectorName]
) AS x;

SELECT
    [FanID],
    [GroupName],
    [GroupPurchases],
    [GroupAffinity]
INTO #fan_group_affinity
FROM (
    SELECT
        [FanID],
        [GroupName],
        COUNT(*) AS [GroupPurchases],
        ROUND(1.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY [FanID]), 0), 4) AS [GroupAffinity]
    FROM #joined_transactions
    GROUP BY [FanID], [GroupName]
) AS x;

    SELECT
        [SectorName],
        1.0 * COUNT(*) / NULLIF(pt.[PopulationPurchases], 0) AS [PopulationSectorAffinity]
    INTO #population_sector_affinity
    FROM #joined_transactions
    CROSS JOIN (SELECT COUNT(*) AS [PopulationPurchases] FROM #joined_transactions) AS pt
    GROUP BY [SectorName], pt.[PopulationPurchases];

    SELECT
        [GroupName],
        1.0 * COUNT(*) / NULLIF(pt.[PopulationPurchases], 0) AS [PopulationGroupAffinity]
    INTO #population_group_affinity
    FROM #joined_transactions
    CROSS JOIN (SELECT COUNT(*) AS [PopulationPurchases] FROM #joined_transactions) AS pt
    GROUP BY [GroupName], pt.[PopulationPurchases];

DECLARE @sectorNames NVARCHAR(MAX);
DECLARE @groupNames NVARCHAR(MAX);
DECLARE @sectorAffinityCols NVARCHAR(MAX);
DECLARE @groupAffinityCols NVARCHAR(MAX);
DECLARE @sql NVARCHAR(MAX);
DECLARE @mCols NVARCHAR(MAX);
DECLARE @m2Cols NVARCHAR(MAX);

SELECT *
INTO #fan_sector_affinity_avg
FROM (
    SELECT
        [FanID],
        [SectorName],
        [SectorAffinity],
        CASE
            WHEN COUNT(*) OVER (PARTITION BY [SectorName]) > 1
            THEN (SUM([SectorAffinity]) OVER (PARTITION BY [SectorName]) - [SectorAffinity]) / NULLIF(COUNT(*) OVER (PARTITION BY [SectorName]) - 1, 0)
            ELSE NULL
        END AS [AvgOtherCustomerSectorAffinity]
    FROM #fan_sector_affinity
) AS t;

SELECT *
INTO #fan_group_affinity_avg
FROM (
    SELECT
        [FanID],
        [GroupName],
        [GroupAffinity],
        CASE
            WHEN COUNT(*) OVER (PARTITION BY [GroupName]) > 1
            THEN (SUM([GroupAffinity]) OVER (PARTITION BY [GroupName]) - [GroupAffinity]) / NULLIF(COUNT(*) OVER (PARTITION BY [GroupName]) - 1, 0)
            ELSE NULL
        END AS [AvgOtherCustomerGroupAffinity]
    FROM #fan_group_affinity
) AS t;

SELECT @sectorNames = STRING_AGG(CAST(QUOTENAME(REPLACE([SectorName],']',']]')) AS NVARCHAR(MAX)), ',')
FROM (
    SELECT DISTINCT [SectorName]
    FROM #fan_sector_affinity
) AS x;

SELECT @groupNames = STRING_AGG(CAST(QUOTENAME(REPLACE([GroupName],']',']]')) AS NVARCHAR(MAX)), ',')
FROM (
    SELECT DISTINCT [GroupName]
    FROM #fan_group_affinity
) AS x;

-- Build comma-separated lists of non-ID columns from the mosaic tables
SELECT @mCols = STRING_AGG('m.' + QUOTENAME(c.name), ', ')
FROM [WH_NWG].sys.columns c
JOIN [WH_NWG].sys.objects o ON c.object_id = o.object_id
JOIN [WH_NWG].sys.schemas s ON o.schema_id = s.schema_id
WHERE s.name = 'Derived' AND o.name = 'nw_cinid_mosaic' AND c.[name] NOT LIKE '%ID%'

SELECT @m2Cols = STRING_AGG('m2.' + QUOTENAME(c.name), ', ')
FROM [WH_NWG].sys.columns c
JOIN [WH_NWG].sys.objects o ON c.object_id = o.object_id
JOIN [WH_NWG].sys.schemas s ON o.schema_id = s.schema_id
WHERE s.name = 'Derived' AND o.name = 'nw_cinid_mosaic_8' AND c.[name] NOT LIKE '%ID%'

SET @mCols = COALESCE(@mCols, '');
SET @m2Cols = COALESCE(@m2Cols, '');

SELECT @sectorAffinityCols = STRING_AGG(CAST(
    'COALESCE(sec.' + QUOTENAME(REPLACE([SectorName],']',']]')) + ',0) AS ' + QUOTENAME('sector:' + LOWER(REPLACE([SectorName], ' ', '')) + 'affinity') + ', ' +
    'CASE WHEN secavg.' + QUOTENAME(REPLACE([SectorName],']',']]')) + ' IS NULL OR secavg.' + QUOTENAME(REPLACE([SectorName],']',']]')) + ' = 0 THEN NULL ELSE COALESCE(sec.' + QUOTENAME(REPLACE([SectorName],']',']]')) + ',0) / secavg.' + QUOTENAME(REPLACE([SectorName],']',']]')) + ' END AS ' + QUOTENAME('sector:' + LOWER(REPLACE([SectorName], ' ', '')) + 'relativeaffinity')
AS NVARCHAR(MAX)), ', ')
FROM (
    SELECT DISTINCT [SectorName]
    FROM #fan_sector_affinity
) AS x;

SELECT @groupAffinityCols = STRING_AGG(CAST(
    'COALESCE(grp.' + QUOTENAME(REPLACE([GroupName],']',']]')) + ',0) AS ' + QUOTENAME('group:' + LOWER(REPLACE([GroupName], ' ', '')) + 'affinity') + ', ' +
    'CASE WHEN grpavg.' + QUOTENAME(REPLACE([GroupName],']',']]')) + ' IS NULL OR grpavg.' + QUOTENAME(REPLACE([GroupName],']',']]')) + ' = 0 THEN NULL ELSE COALESCE(grp.' + QUOTENAME(REPLACE([GroupName],']',']]')) + ',0) / grpavg.' + QUOTENAME(REPLACE([GroupName],']',']]')) + ' END AS ' + QUOTENAME('group:' + LOWER(REPLACE([GroupName], ' ', '')) + 'relativeaffinity')
AS NVARCHAR(MAX)), ', ')
FROM (
    SELECT DISTINCT [GroupName]
    FROM #fan_group_affinity
) AS x;

SET @sql = N'
SELECT DISTINCT
    cb.[FanID],
    cb.[Spend_7d],
    cb.[Spend_30d],
    cb.[Spend_90d],
    cb.[Spend_365d],
    cb.[Spend_CurrentMonth],
    cb.[Spend_PriorMonth],
    CASE
        WHEN cb.[Spend_PriorMonth] = 0 AND cb.[Spend_CurrentMonth] = 0 THEN 0
        WHEN cb.[Spend_PriorMonth] = 0 THEN NULL
        ELSE ROUND(100.0 * (cb.[Spend_CurrentMonth] - cb.[Spend_PriorMonth]) / NULLIF(cb.[Spend_PriorMonth], 0), 2)
    END AS [SpendAccelerationPct_MonthVsPriorMonth],
    ROUND(CAST(cb.[Transactions_365d] AS DECIMAL(12, 2)) / 12.0, 2) AS [AvgMonthlyTransactions],
    DATEDIFF(day, cb.[LastPurchaseDate], @as_of_date) AS [DaysSinceLastPurchase],
    cb.[AvgDaysBetweenPurchases],
    cb.[StdDevDaysBetweenPurchases],
    cb.[ConsecutiveWeeksWithActivity],
    cb.[Purchases_7d],
    cb.[Purchases_30d],
    cb.[Purchases_90d],
    cb.[Purchases_365d],
    cb.[AverageBasketSize],
    cb.[AvgRetailerCashback_365d],
    cb.[AvgInvestment_365d],
    cb.[AvgRewardCommission_365d],
    cb.[AvgVATCommission_365d],
    cb.[AvgGrossCommission_365d],
    cb.[AM_Purchases_365d],
    cb.[AM_Spend_365d],
    cb.[PM_Purchases_365d],
    cb.[PM_Spend_365d],
    cb.[Weekday_Purchases_365d],
    cb.[Weekday_Spend_365d],
    cb.[Weekend_Purchases_365d],
    cb.[Weekend_Spend_365d],
    cb.[Winter_Purchases_365d],
    cb.[Winter_Spend_365d],
    cb.[Spring_Purchases_365d],
    cb.[Spring_Spend_365d],
    cb.[Summer_Purchases_365d],
    cb.[Summer_Spend_365d],
    cb.[Autumn_Purchases_365d],
    cb.[Autumn_Spend_365d],
    cb.[UniqueSectorCategories],
    cb.[UniqueGroupCategories],
    cb.[FavouriteSectorName],
    cb.[SectorSpendPct],
    cb.[FavouriteGroupName],
    cb.[GroupSpendPct],
    cust.[PublisherType],
    cust.[AccountType],
    cust.[Title],
    cust.[City],
    cust.[County],
    cust.[Region],
    cust.[PostalSector],
    cust.[PostCodeDistrict],
    cust.[PostArea],
    cust.[CAMEOCode],
    cust.[Gender],
    cust.[AgeCurrent],
    cust.[AgeCurrentBandText],
    cust.[CashbackPending],
    cust.[CashbackAvailable],
    cust.[CashbackLTV],
    cust.[Unsubscribed],
    cust.[Hardbounced],
    cust.[EmailTracking],
    cust.[MarketableByEmail],
    cust.[MarketableByPush],
    cust.[CurrentlyActive],
    cust.[RegistrationDate],
    cust.[DeactivatedDate],
    cust.[AddedDate],
    cust.[ModifiedDate],
    cust.[IsCredit],
    cust.[IsDebit],
    ' + @mCols + N',
    ' + @m2Cols + N',
    ' + @sectorAffinityCols + N',
    ' + @groupAffinityCols + N'
FROM #customer_base AS cb
LEFT JOIN (
    SELECT [FanID], [SectorName], [SectorAffinity]
    FROM #fan_sector_affinity
) AS srcsec
PIVOT (
    MAX([SectorAffinity]) FOR [SectorName] IN (' + @sectorNames + N')
) AS sec
    ON cb.[FanID] = sec.[FanID]
LEFT JOIN (
    SELECT [FanID], [SectorName], [AvgOtherCustomerSectorAffinity]
    FROM #fan_sector_affinity_avg
) AS srcsecavg
PIVOT (
    MAX([AvgOtherCustomerSectorAffinity]) FOR [SectorName] IN (' + @sectorNames + N')
) AS secavg
    ON cb.[FanID] = secavg.[FanID]
LEFT JOIN (
    SELECT [FanID], [GroupName], [GroupAffinity]
    FROM #fan_group_affinity
) AS srcgrp
PIVOT (
    MAX([GroupAffinity]) FOR [GroupName] IN (' + @groupNames + N')
) AS grp
    ON cb.[FanID] = grp.[FanID]
LEFT JOIN (
    SELECT [FanID], [GroupName], [AvgOtherCustomerGroupAffinity]
    FROM #fan_group_affinity_avg
) AS srcgrpavg
PIVOT (
    MAX([AvgOtherCustomerGroupAffinity]) FOR [GroupName] IN (' + @groupNames + N')
) AS grpavg
    ON cb.[FanID] = grpavg.[FanID]
LEFT JOIN (
    SELECT *
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY FanID ORDER BY AddedDate DESC) AS rn
        FROM [WH_AllPublishers].[Derived].[Customer]
    ) AS _cust
    WHERE rn = 1
) AS cust
    ON cb.[FanID] = cust.[FanID]
OUTER APPLY (
    SELECT TOP (1) *
    FROM [WH_NWG].[Derived].[nw_cinid_mosaic] mm
    WHERE mm.[CINID] = cust.[CINID]
) AS m
OUTER APPLY (
    SELECT TOP (1) *
    FROM [WH_NWG].[Derived].[nw_cinid_mosaic_8] mm2
    WHERE mm2.[CINID] = cust.[CINID]
) AS m2
ORDER BY cb.[Spend_365d] DESC;';

EXEC sp_executesql @sql, N'@as_of_date DATE', @as_of_date = @as_of_date;


