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
sector_spend AS (
    SELECT
        [FanID],
        [SectorName],
        SUM([Spend]) AS [SectorSpend]
    FROM joined_transactions
    GROUP BY [FanID], [SectorName]
),
sector_pct AS (
    SELECT
        [FanID],
        [SectorName],
        [SectorSpend],
        [SectorSpend] / NULLIF(SUM([SectorSpend]) OVER (PARTITION BY [FanID]), 0) AS [SectorSpendPct]
    FROM sector_spend
),
sector_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [SectorName]) AS [UniqueSectorCategories],
        MAX(CASE WHEN [SectorRank] = 1 THEN [SectorName] END) AS [FavouriteSectorName],
        STRING_AGG(CONCAT([SectorName], ':', CAST(ROUND([SectorSpendPct] * 100, 2) AS VARCHAR(20)), '%'), '; ') WITHIN GROUP (ORDER BY [SectorSpend] DESC) AS [SectorSpendPct]
    FROM (
        SELECT
            [FanID],
            [SectorName],
            [SectorSpend],
            [SectorSpendPct],
            ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [SectorSpend] DESC, [SectorName]) AS [SectorRank]
        FROM sector_pct
    ) AS x
    GROUP BY [FanID]
),
group_spend AS (
    SELECT
        [FanID],
        [GroupName],
        SUM([Spend]) AS [GroupSpend]
    FROM joined_transactions
    GROUP BY [FanID], [GroupName]
),
group_pct AS (
    SELECT
        [FanID],
        [GroupName],
        [GroupSpend],
        [GroupSpend] / NULLIF(SUM([GroupSpend]) OVER (PARTITION BY [FanID]), 0) AS [GroupSpendPct]
    FROM group_spend
),
group_summary AS (
    SELECT
        [FanID],
        COUNT(DISTINCT [GroupName]) AS [UniqueGroupCategories],
        MAX(CASE WHEN [GroupRank] = 1 THEN [GroupName] END) AS [FavouriteGroupName],
        STRING_AGG(CONCAT([GroupName], ':', CAST(ROUND([GroupSpendPct] * 100, 2) AS VARCHAR(20)), '%'), '; ') WITHIN GROUP (ORDER BY [GroupSpend] DESC) AS [GroupSpendPct]
    FROM (
        SELECT
            [FanID],
            [GroupName],
            [GroupSpend],
            [GroupSpendPct],
            ROW_NUMBER() OVER (PARTITION BY [FanID] ORDER BY [GroupSpend] DESC, [GroupName]) AS [GroupRank]
        FROM group_pct
    ) AS x
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
    gs.[FavouriteGroupName],
    ss.[SectorSpendPct],
    gs.[GroupSpendPct],
    COALESCE(ss.[UniqueSectorCategories], 0) AS [SectorCategoryDiversity],
    COALESCE(gs.[UniqueGroupCategories], 0) AS [GroupCategoryDiversity]
FROM customer_metrics AS cm
LEFT JOIN sector_summary AS ss
    ON cm.[FanID] = ss.[FanID]
LEFT JOIN group_summary AS gs
    ON cm.[FanID] = gs.[FanID]
ORDER BY cm.[Spend_365d] DESC;