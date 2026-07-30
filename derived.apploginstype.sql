SET NOCOUNT ON;

DECLARE @as_of_date DATE = CAST(GETDATE() AS DATE);
DECLARE @period_1_days INT = 7;
DECLARE @period_2_days INT = 14;
DECLARE @period_3_days INT = 30;
DECLARE @cutoff_1 DATE = DATEADD(day, -@period_1_days, @as_of_date);
DECLARE @cutoff_2 DATE = DATEADD(day, -@period_2_days, @as_of_date);
DECLARE @cutoff_3 DATE = DATEADD(day, -@period_3_days, @as_of_date);
DECLARE @period_1_label NVARCHAR(50) = CONCAT('cutoff_', @period_1_days, 'd');
DECLARE @period_2_label NVARCHAR(50) = CONCAT('cutoff_', @period_2_days, 'd');
DECLARE @period_3_label NVARCHAR(50) = CONCAT('cutoff_', @period_3_days, 'd');

WITH customer_sample AS (
    SELECT TOP (1000)
        [CustomerGUID]
    FROM [WH_NWG].[Derived].[Customer]
    WHERE [CustomerGUID] IS NOT NULL
    ORDER BY [CustomerGUID]
),
login_counts AS (
    SELECT
        c.[CustomerGUID],
        t.[LoginTypeDesc],
        SUM(CASE WHEN a.[TrackDate] >= @cutoff_1 THEN 1 ELSE 0 END) AS [Logins_P1],
        SUM(CASE WHEN a.[TrackDate] >= @cutoff_2 THEN 1 ELSE 0 END) AS [Logins_P2],
        SUM(CASE WHEN a.[TrackDate] >= @cutoff_3 THEN 1 ELSE 0 END) AS [Logins_P3]
    FROM customer_sample AS cs
    INNER JOIN [WH_NWG].[Derived].[Customer] AS c
        ON cs.[CustomerGUID] = c.[CustomerGUID]
    LEFT JOIN [WH_NWG].[Derived].[AppLogins] AS a
        ON c.[CustomerGUID] = a.[CustomerGUID]
    LEFT JOIN [WH_NWG].[Derived].[AppLoginsType] AS t
        ON a.[LoginTypeID] = t.[LoginTypeID]
    WHERE c.[CustomerGUID] IS NOT NULL
      AND a.[TrackDate] >= @cutoff_3
    GROUP BY
        c.[CustomerGUID],
        t.[LoginTypeDesc]
),
login_metrics AS (
    SELECT
        c.[CustomerGUID],
        DATEDIFF(day, MAX(a.[TrackDate]), @as_of_date) AS [DaysSinceLastLogin],
        COUNT(DISTINCT CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
            THEN CAST(a.[TrackDate] AS DATE)
        END) AS [ActiveDaysPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
            THEN 1
        END) AS [SessionsPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
             AND DATEPART(hour, a.[TrackDate]) < 12
            THEN 1
        END) AS [AMSessionsPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
             AND DATEPART(hour, a.[TrackDate]) >= 12
            THEN 1
        END) AS [PMSessionsPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
             AND DATEPART(weekday, a.[TrackDate]) NOT IN (1, 7)
            THEN 1
        END) AS [WeekdaySessionsPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
             AND a.[TrackDate] < DATEADD(month, 1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
             AND DATEPART(weekday, a.[TrackDate]) IN (1, 7)
            THEN 1
        END) AS [WeekendSessionsPerMonth],
        COUNT(CASE
            WHEN a.[TrackDate] >= DATEADD(month, -1, DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1))
             AND a.[TrackDate] < DATEFROMPARTS(YEAR(@as_of_date), MONTH(@as_of_date), 1)
            THEN 1
        END) AS [SessionsLastMonth]
    FROM customer_sample AS cs
    INNER JOIN [WH_NWG].[Derived].[Customer] AS c
        ON cs.[CustomerGUID] = c.[CustomerGUID]
    LEFT JOIN [WH_NWG].[Derived].[AppLogins] AS a
        ON c.[CustomerGUID] = a.[CustomerGUID]
    WHERE c.[CustomerGUID] IS NOT NULL
    GROUP BY
        c.[CustomerGUID]
)
SELECT TOP (1000)
    c.[FanID],
    c.[CustomerGUID],
    c.[ClubID],
    c.[CompositeID],
    c.[SourceUID],
    c.[AccountType],
    c.[EmailStructureValid],
    c.[Title],
    c.[City],
    c.[County],
    c.[Region],
    c.[PostCode],
    c.[PostalSector],
    c.[PostCodeDistrict],
    c.[PostArea],
    c.[CAMEOCode],
    c.[Gender],
    c.[AgeCurrent],
    c.[AgeCurrentBandText],
    c.[CashbackPending],
    c.[CashbackAvailable],
    c.[CashbackLTV],
    c.[Unsubscribed],
    c.[Hardbounced],
    c.[MarketableByEmail],
    c.[EmailTracking],
    c.[MarketableByPush],
    c.[CurrentlyActive],
    c.[RegistrationDate],
    c.[DeactivatedDate],
    c.[ClosedDate],
    c.[IsCredit],
    c.[IsDebit],
    lc.[LoginTypeDesc],
    lc.[Logins_P1] AS [Logins_7d],
    lc.[Logins_P2] AS [Logins_14d],
    lc.[Logins_P3] AS [Logins_30d],
    lm.[DaysSinceLastLogin],
    lm.[ActiveDaysPerMonth],
    lm.[SessionsPerMonth],
    lm.[AMSessionsPerMonth],
    lm.[PMSessionsPerMonth],
    lm.[WeekdaySessionsPerMonth],
    lm.[WeekendSessionsPerMonth],
    CAST(ROUND(CASE
        WHEN lm.[SessionsLastMonth] = 0 THEN NULL
        ELSE CAST(lm.[SessionsPerMonth] AS DECIMAL(10, 3)) / NULLIF(lm.[SessionsLastMonth], 0)
    END, 3) AS DECIMAL(10, 3)) AS [LoginAcceleration]
FROM [WH_NWG].[Derived].[Customer] AS c
INNER JOIN customer_sample AS cs
    ON c.[CustomerGUID] = cs.[CustomerGUID]
LEFT JOIN login_counts AS lc
    ON c.[CustomerGUID] = lc.[CustomerGUID]
LEFT JOIN login_metrics AS lm
    ON c.[CustomerGUID] = lm.[CustomerGUID]
ORDER BY
    c.[CustomerGUID],
    lc.[LoginTypeDesc];