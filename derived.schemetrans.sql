SET NOCOUNT ON;

DECLARE @as_of_date DATE = CAST(GETDATE() AS DATE);
DECLARE @sample_size INT = 1000;
DECLARE @lookback_7 INT = 7;
DECLARE @lookback_30 INT = 30;
DECLARE @lookback_90 INT = 90;
DECLARE @lookback_365 INT = 365;

WITH sampled_transactions AS (
    SELECT TOP (@sample_size)
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
    WHERE st.[FanID] IS NOT NULL
      AND st.[TranDate] IS NOT NULL
      AND st.[Spend] IS NOT NULL
    ORDER BY NEWID()
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
    WHERE [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date)
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
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_7, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_7d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_30, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_30d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_90, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_90d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Spend] ELSE 0 END) AS [Spend_365d],
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
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) AS [Transactions_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_7, @as_of_date) THEN 1 END) AS [Purchases_7d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_30, @as_of_date) THEN 1 END) AS [Purchases_30d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_90, @as_of_date) THEN 1 END) AS [Purchases_90d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) AS [Purchases_365d],
        COUNT(DISTINCT CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN CAST([TranDate] AS DATE) END) AS [PurchaseDays_365d],
        ROUND(AVG(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [RetailerCashback] END), 2) AS [AvgRetailerCashback_365d],
        ROUND(AVG(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Investment] END), 2) AS [AvgInvestment_365d],
        ROUND(AVG(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [RewardCommission] END), 2) AS [AvgRewardCommission_365d],
        ROUND(AVG(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [VATCommission] END), 2) AS [AvgVATCommission_365d],
        ROUND(AVG(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [GrossCommission] END), 2) AS [AvgGrossCommission_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) < 12 THEN 1 END) AS [AM_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) < 12 THEN [Spend] ELSE 0 END) AS [AM_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) >= 12 THEN 1 END) AS [PM_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(hour, [TranTime]) >= 12 THEN [Spend] ELSE 0 END) AS [PM_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) NOT IN (1, 7) THEN 1 END) AS [Weekday_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) NOT IN (1, 7) THEN [Spend] ELSE 0 END) AS [Weekday_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) IN (1, 7) THEN 1 END) AS [Weekend_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(weekday, [TranDate]) IN (1, 7) THEN [Spend] ELSE 0 END) AS [Weekend_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (12, 1, 2) THEN 1 END) AS [Winter_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (12, 1, 2) THEN [Spend] ELSE 0 END) AS [Winter_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (3, 4, 5) THEN 1 END) AS [Spring_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (3, 4, 5) THEN [Spend] ELSE 0 END) AS [Spring_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (6, 7, 8) THEN 1 END) AS [Summer_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (6, 7, 8) THEN [Spend] ELSE 0 END) AS [Summer_Spend_365d],
        COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (9, 10, 11) THEN 1 END) AS [Autumn_Purchases_365d],
        SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) AND DATEPART(month, [TranDate]) IN (9, 10, 11) THEN [Spend] ELSE 0 END) AS [Autumn_Spend_365d],
        CASE
            WHEN COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END) = 0 THEN NULL
            ELSE ROUND(SUM(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN [Spend] ELSE 0 END) / NULLIF(COUNT(CASE WHEN [TranDate] >= DATEADD(day, -@lookback_365, @as_of_date) THEN 1 END), 0), 2)
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
        ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [SectorPurchases] DESC, [SectorName]) AS [SectorRank]
    FROM sector_purchase_summary
),
sector_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [SectorName]) AS [UniqueSectorCategories],
        MAX(CASE WHEN [SectorRank] = 1 THEN [SectorName] END) AS [FavouriteSectorName],
        ROUND(100.0 * MAX(CASE WHEN [SectorRank] = 1 THEN [SectorSpend] END) / NULLIF(MAX([TotalSectorSpend]), 0), 2) AS [SectorSpendPct]
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
        ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [GroupPurchases] DESC, [GroupName]) AS [GroupRank]
    FROM group_purchase_summary
),
group_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [GroupName]) AS [UniqueGroupCategories],
        MAX(CASE WHEN [GroupRank] = 1 THEN [GroupName] END) AS [FavouriteGroupName],
        ROUND(100.0 * MAX(CASE WHEN [GroupRank] = 1 THEN [GroupSpend] END) / NULLIF(MAX([TotalGroupSpend]), 0), 2) AS [GroupSpendPct]
    FROM group_ranked
    GROUP BY [FanID]
)
SELECT
    cm.[FanID],
    cm.[Spend_7d],
    cm.[Spend_30d],
    cm.[Spend_90d],
    cm.[Spend_365d],
    cm.[Spend_CurrentMonth],
    cm.[Spend_PriorMonth],
    CASE
        WHEN cm.[Spend_PriorMonth] = 0 THEN NULL
        ELSE ROUND(100.0 * (cm.[Spend_CurrentMonth] - cm.[Spend_PriorMonth]) / NULLIF(cm.[Spend_PriorMonth], 0), 2)
    END AS [SpendAccelerationPct_MonthVsPriorMonth],
    ROUND(CAST(cm.[Transactions_365d] AS DECIMAL(12, 2)) / 12.0, 2) AS [AvgMonthlyTransactions],
    DATEDIFF(day, cm.[LastPurchaseDate], @as_of_date) AS [DaysSinceLastPurchase],
    pim.[AvgDaysBetweenPurchases],
    pim.[StdDevDaysBetweenPurchases],
    cwm.[ConsecutiveWeeksWithActivity],
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
    ss.[FavouriteSectorName],
    ss.[SectorSpendPct],
    gs.[FavouriteGroupName],
    gs.[GroupSpendPct]
FROM customer_metrics AS cm
LEFT JOIN purchase_interval_metrics AS pim
    ON cm.[FanID] = pim.[FanID]
LEFT JOIN consecutive_week_metrics AS cwm
    ON cm.[FanID] = cwm.[FanID]
LEFT JOIN sector_summary AS ss
    ON cm.[FanID] = ss.[FanID]
LEFT JOIN group_summary AS gs
    ON cm.[FanID] = gs.[FanID]
ORDER BY cm.[Spend_365d] DESC;