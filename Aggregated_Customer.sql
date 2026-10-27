/*SELECT TOP (20)
      c.[CustomerID],
      c.[SourceSystemID],
      c.[PublisherType],
      c.[PublisherID],
      c.[FanID],
      c.[CustomerGUID],
      c.[CompositeID],
      c.[SourceUID],
      c.[CINID],
      c.[SourceCustomerID],
      c.[AccountType],
      c.[Title],
      c.[City],
      c.[County],
      c.[Region],
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
      c.[EmailTracking],
      c.[MarketableByEmail],
      c.[MarketableByPush],
      c.[CurrentlyActive],
      c.[RegistrationDate],
      c.[DeactivatedDate],
      c.[AddedDate],
      c.[ModifiedDate],
      c.[IsDebit],
      c.[BrazeUserID],
      ct.[DataSource],
      ct.[ConsumerCombinationID],
      ct.[Amount],
      ct.[IsOnline],
      ct.[TranDate],
      cc.[CCID_DataSource],
      cc.[BrandID],
      cc.[MID],
      cc.[Narrative],
      cc.[LocationCountry],
      cc.[MCCID],
      cc.[OriginatorID],
      cc.[IsHighVariance],
      cc.[IsUKSpend],
      cc.[PaymentGatewayStatusID],
      b.[BrandName],
      b.[BrandGroupID],
      b.[SectorID],
      b.[CategoryID],
      b.[IsHighRisk],
      b.[IsNamedException],
      b.[ChargeOnRedeem],
      b.[IsOnlineOnly],
      b.[IsPremiumRetailer],
      b.[IsSubscription],
      b.[IsLivePartner],
      bs.[SectorName],
      bsg.[GroupName]
FROM [WH_AllPublishers].[Derived].[Customer] AS c
LEFT JOIN [WH_AllPublishers].[Trans].[ConsumerTransaction] AS ct
      ON c.[CINID] = ct.[CINID]
INNER JOIN [WH_AllPublishers].[Trans].[ConsumerCombination] AS cc
      ON ct.[ConsumerCombinationID] = cc.[ConsumerCombinationID]
INNER JOIN [WH_AllPublishers].[Trans].[Brand] AS b
      ON cc.[BrandID] = b.[BrandID]
INNER JOIN [WH_AllPublishers].[Trans].[BrandSector] AS bs
      ON b.[SectorID] = bs.[SectorID]
INNER JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS bsg
      ON bs.[SectorGroupID] = bsg.[SectorGroupID]
      ORDER BY FanID, TranDate DESC

SELECT top (20) [DataSource]
	,[ConsumerCombinationID]
	,[CINID]
	,[Amount]
	,[IsOnline]
	,[TranDate]
FROM [WH_AllPublishers].[Trans].[ConsumerTransaction]

SELECT TOP (20) [DataSource]
      ,[ConsumerCombinationID]
      ,[CCID_DataSource]
      ,[BrandID]
      ,[MID]
      ,[Narrative]
      ,[LocationCountry]
      ,[MCCID]
      ,[OriginatorID]
      ,[IsHighVariance]
      ,[IsUKSpend]
      ,[PaymentGatewayStatusID]
  FROM [WH_AllPublishers].[Trans].[ConsumerCombination]

SELECT TOP (20) [BrandID]
      ,[BrandName]
      ,[BrandGroupID]
      ,[SectorID]
      ,[CategoryID]
      ,[IsHighRisk]
      ,[IsNamedException]
      ,[ChargeOnRedeem]
      ,[IsOnlineOnly]
      ,[IsPremiumRetailer]
      ,[IsSubscription]
      ,[IsLivePartner]
      ,[AddedDate]
      ,[ModifiedDate]
  FROM [WH_AllPublishers].[Trans].[Brand]


SELECT TOP (20) [SectorID]
      ,[SectorGroupID]
      ,[SectorName]
  FROM [WH_AllPublishers].[Trans].[BrandSector]

SELECT TOP (20) [SectorGroupID]
      ,[GroupName]
  FROM [WH_AllPublishers].[Trans].[BrandSectorGroup]

*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET DATEFIRST 1;  -- Monday = 1, Saturday = 6, Sunday = 7
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

/*==============================================================
  LONG-FORMAT PANEL: one row per (FanID, SectorID, ReferenceDate).

  Reference dates are @cycle_length_days apart; each has a
  @feature_window_days window of prior transactions (features) and a
  @label_window_days window afterwards (the label: did the customer
  spend in this sector in the next N days). With the defaults
  (90 + 30 = 120) these windows tile the timeline exactly -- no
  double-counting, no gaps. The latest reference date is
  @as_of_date - @label_window_days so its label window never needs
  data you don't have yet.

  Trade-offs vs. a one-row-per-customer wide table:
   - Rolling features (spend, recency, streaks, diversity, AM/PM,
     weekend split, online share) are computed per period from that
     period's own @feature_window_days window, not a single
     @as_of_date with up to 365 days of history. A year-long seasonal
     split doesn't fit a 90-day window, so it's replaced with
     ReferenceMonth/Quarter (+ sin/cos) so a model trained across
     many periods can still learn seasonality across rows.
   - Recency is censored at the feature window boundary -- no
     visibility before FeatureWindowStart.
   - Customer attributes are a single current snapshot applied to
     every historical period (the source isn't historized).
   - The panel cross-joins every customer against EVERY sector in the
     dimension, not just sectors they've bought in, so it supports
     scoring propensity into sectors they've never used (cross-sell).
     Set @restrict_sectors_to_observed = 1 to shrink this for dev.
     Row count ~= @sample_size x sectors x @num_reference_periods.
==============================================================*/


/*==============================================================
  1. PARAMETERS
==============================================================*/

DECLARE @as_of_date                    DATE = CAST(GETDATE() AS DATE);
DECLARE @sample_size                   INT  = 10000;   -- dev: 10,000; raise once validated

-- Comma-separated list of PublisherIDs to include, e.g. '132,182,2015'.
-- Leave as NULL or '' to include ALL publishers (no filter).
DECLARE @publisher_ids                 VARCHAR(MAX) = '132,182,2015';

DECLARE @sample_seed                   INT  = 20260915;
DECLARE @sample_mode                   TINYINT = 1;    -- 1=hash sample, 2=first N, 3=all
DECLARE @positive_spend_only           BIT  = 1;        -- exclude refunds/zero-value txns
DECLARE @trandate_has_time             BIT  = 1;        -- 0 if TranDate has no time component
DECLARE @hash_sample_threshold         INT  = 50;       -- mode 1: ~ (value/10)% of customers

DECLARE @num_reference_periods         INT  = 6;        -- how many snapshots to build
DECLARE @cycle_length_days             INT  = 120;       -- spacing between reference dates
DECLARE @feature_window_days           INT  = 90;        -- history used to build features
DECLARE @label_window_days             INT  = 30;        -- target: spend in next N days
DECLARE @restrict_sectors_to_observed  BIT  = 0;         -- 1 = smaller panel for dev

-- Lifecycle bucketing thresholds (days since RegistrationDate, as of ReferenceDate).
-- New: tenure < @new_customer_tenure_days. Mature: tenure >= @established_customer_tenure_days.
-- Established: everything in between.
DECLARE @new_customer_tenure_days         INT = 90;
DECLARE @established_customer_tenure_days INT = 365;

IF @cycle_length_days <> (@feature_window_days + @label_window_days)
    RAISERROR('Warning: cycle_length_days <> feature_window_days + label_window_days -- periods will overlap or leave gaps.', 10, 1) WITH NOWAIT;


/*==============================================================
  2. CLEAN UP
==============================================================*/

DROP TABLE IF EXISTS #PublisherIDs;
DROP TABLE IF EXISTS #SampledFanIDs;
DROP TABLE IF EXISTS #CustomerLatest;
DROP TABLE IF EXISTS #PublisherNames;
DROP TABLE IF EXISTS #EasterDates;
DROP TABLE IF EXISTS #YearEventDates;
DROP TABLE IF EXISTS #KeyRetailEvents;
DROP TABLE IF EXISTS #ReferenceDates;
DROP TABLE IF EXISTS #PeriodKeyEventFeatures;
DROP TABLE IF EXISTS #FilteredTransactions;
DROP TABLE IF EXISTS #Transactions;
DROP TABLE IF EXISTS #SectorDimension;
DROP TABLE IF EXISTS #PeriodFeatureTransactions;
DROP TABLE IF EXISTS #PeriodLabelTransactions;
DROP TABLE IF EXISTS #CustomerPeriodMetrics;
DROP TABLE IF EXISTS #PeriodSectorLong;
DROP TABLE IF EXISTS #PeriodGroupLong;
DROP TABLE IF EXISTS #SectorPopularityByPeriod;
DROP TABLE IF EXISTS #GroupPopularityByPeriod;
DROP TABLE IF EXISTS #PublisherSectorPopularityByPeriod;
DROP TABLE IF EXISTS #SectorMarginals;
DROP TABLE IF EXISTS #SectorPairCooccurrence;
DROP TABLE IF EXISTS #SectorPairLift;
DROP TABLE IF EXISTS #CustomerSectorAffinity;
DROP TABLE IF EXISTS #CustomerSpendEntropy;
DROP TABLE IF EXISTS #PeriodLabel;
DROP TABLE IF EXISTS #PeriodGroupLabel;
DROP TABLE IF EXISTS #BasePanel;


/*==============================================================
  2a. PARSE PUBLISHER FILTER

  Splits @publisher_ids into one row per PublisherID. To turn the
  filter OFF and include ALL publishers, set @publisher_ids to any
  of: NULL, '' (empty string), or a string with only whitespace/
  commas (e.g. ' ' or ',,') -- all of these leave #PublisherIDs
  empty. ISNULL(@publisher_ids, '') guards STRING_SPLIT against a
  NULL input so this never errors. An empty #PublisherIDs table
  means "no filter" -- every filter predicate below checks
  (NOT EXISTS (SELECT 1 FROM #PublisherIDs) OR c.PublisherID IN
  (SELECT PublisherID FROM #PublisherIDs)) to preserve that behaviour.
==============================================================*/

SELECT DISTINCT CONVERT(INT, LTRIM(RTRIM(s.value))) AS PublisherID
INTO #PublisherIDs
FROM STRING_SPLIT(ISNULL(@publisher_ids, ''), ',') AS s
WHERE LTRIM(RTRIM(s.value)) <> '';

CREATE UNIQUE CLUSTERED INDEX IX_PublisherIDs_PublisherID ON #PublisherIDs(PublisherID);

DECLARE @publisher_filter_count INT = (SELECT COUNT(*) FROM #PublisherIDs);

-- Used downstream (final assembly) to gate the PublisherSectorPopularityPrior feature:
-- it's only populated when a specific publisher subset is in play (see that section
-- for why). PublisherID/PublisherName themselves are for post-training slicing and
-- interpretability only -- they should NOT be fed into the model as features.
DECLARE @publisher_filter_active BIT = CASE WHEN @publisher_filter_count > 0 THEN 1 ELSE 0 END;

IF @publisher_filter_count > 0
    RAISERROR('Publisher filter ACTIVE: %d publisher(s) selected (see #PublisherIDs).', 10, 1, @publisher_filter_count) WITH NOWAIT;
ELSE
    RAISERROR('Publisher filter OFF: @publisher_ids was NULL/blank -- including ALL publishers.', 10, 1) WITH NOWAIT;

SELECT * FROM #PublisherIDs ORDER BY PublisherID;


/*==============================================================
  3. SAMPLE FANIDS
==============================================================*/

RAISERROR('Stage 1: Sampling FanIDs', 10, 1) WITH NOWAIT;

/*
  TOP (0) INTO, then branch-specific INSERT INTO: avoids SQL error
  2714 from multiple SELECT ... INTO targets across IF/ELSE branches.
*/
SELECT TOP (0) c.FanID
INTO #SampledFanIDs
FROM [WH_AllPublishers].[Derived].[Customer] AS c;

IF @sample_mode = 1
    INSERT INTO #SampledFanIDs (FanID)
    SELECT TOP (@sample_size) c.FanID
    FROM [WH_AllPublishers].[Derived].[Customer] AS c
    WHERE c.FanID IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM #PublisherIDs) OR c.PublisherID IN (SELECT PublisherID FROM #PublisherIDs))
      AND (ABS(CONVERT(BIGINT, CHECKSUM(c.FanID, @sample_seed))) % 1000) < @hash_sample_threshold
    GROUP BY c.FanID
    ORDER BY c.FanID
    OPTION (RECOMPILE);
ELSE IF @sample_mode = 2
    INSERT INTO #SampledFanIDs (FanID)
    SELECT TOP (@sample_size) c.FanID
    FROM [WH_AllPublishers].[Derived].[Customer] AS c
    WHERE c.FanID IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM #PublisherIDs) OR c.PublisherID IN (SELECT PublisherID FROM #PublisherIDs))
    GROUP BY c.FanID
    ORDER BY c.FanID
    OPTION (RECOMPILE);
ELSE
    INSERT INTO #SampledFanIDs (FanID)
    SELECT c.FanID
    FROM [WH_AllPublishers].[Derived].[Customer] AS c
    WHERE c.FanID IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM #PublisherIDs) OR c.PublisherID IN (SELECT PublisherID FROM #PublisherIDs))
    GROUP BY c.FanID
    OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SampledFanIDs_FanID ON #SampledFanIDs(FanID);

SELECT COUNT_BIG(*) AS SampledFanCount FROM #SampledFanIDs;


/*==============================================================
  4. LATEST CUSTOMER ROW PER SAMPLED FAN
==============================================================*/

RAISERROR('Stage 2: Retrieving latest customer records', 10, 1) WITH NOWAIT;

WITH CustomerRanked AS
(
    SELECT
        c.FanID, c.CINID, c.CustomerID, c.SourceSystemID, c.PublisherType, c.PublisherID,
        c.AccountType, c.City, c.County, c.Region, c.PostalSector, c.PostCodeDistrict, c.PostArea,
        c.CAMEOCode, c.Gender, c.AgeCurrent, c.AgeCurrentBandText, c.CashbackPending,
        c.CashbackAvailable, c.CashbackLTV, c.Unsubscribed, c.Hardbounced, c.EmailTracking,
        c.MarketableByEmail, c.MarketableByPush, c.CurrentlyActive, c.RegistrationDate,
        c.DeactivatedDate, c.IsDebit,
        ROW_NUMBER() OVER (PARTITION BY c.FanID ORDER BY c.ModifiedDate DESC, c.AddedDate DESC, c.CustomerID DESC) AS rn
    FROM [WH_AllPublishers].[Derived].[Customer] AS c
    INNER JOIN #SampledFanIDs AS sf ON sf.FanID = c.FanID
    WHERE c.CINID IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM #PublisherIDs) OR c.PublisherID IN (SELECT PublisherID FROM #PublisherIDs))
)
SELECT
    FanID, CINID, CustomerID, SourceSystemID, PublisherType, PublisherID, AccountType, City, County,
    Region, PostalSector, PostCodeDistrict, PostArea, CAMEOCode, Gender, AgeCurrent, AgeCurrentBandText,
    CashbackPending, CashbackAvailable, CashbackLTV, Unsubscribed, Hardbounced, EmailTracking,
    MarketableByEmail, MarketableByPush, CurrentlyActive, RegistrationDate, DeactivatedDate, IsDebit
INTO #CustomerLatest
FROM CustomerRanked
WHERE rn = 1
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_CustomerLatest_FanID ON #CustomerLatest(FanID);
CREATE INDEX IX_CustomerLatest_CINID ON #CustomerLatest(CINID) INCLUDE (FanID);

SELECT COUNT_BIG(*) AS CustomerLatestCount FROM #CustomerLatest;


/*==============================================================
  4a. PUBLISHER DIMENSION (PublisherName, for interpretability and
      post-training slicing only -- PublisherID/PublisherName are NOT
      intended as model features, just a way to read results and cut
      performance by publisher afterwards).

  Source confirmed: [WH_AllPublishers].[Derived].[Publisher].[PublisherName],
  joined on PublisherID (consistent with every other PublisherID column
  in this schema, e.g. Derived.Customer). Deduped defensively with the
  same ROW_NUMBER() pattern used for Brand/Sector/Group in stages 5-6,
  in case this "Derived" table is also SCD-style with no single
  current row per PublisherID -- if it's guaranteed one row per key,
  the ROW_NUMBER() is a harmless no-op.
==============================================================*/

RAISERROR('Stage 4a: Loading Publisher dimension for PublisherName', 10, 1) WITH NOWAIT;

;WITH PublisherOne AS
(
    SELECT PublisherID, PublisherName,
        ROW_NUMBER() OVER (PARTITION BY PublisherID ORDER BY (SELECT NULL)) AS rn
    FROM [WH_AllPublishers].[Derived].[Publisher]
)
SELECT PublisherID, PublisherName
INTO #PublisherNames
FROM PublisherOne
WHERE rn = 1
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_PublisherNames_PublisherID ON #PublisherNames(PublisherID);

SELECT COUNT_BIG(*) AS PublisherNamesLoaded FROM #PublisherNames;


/*==============================================================
  5. REFERENCE-DATE SPINE
==============================================================*/

RAISERROR('Stage 3: Building reference-date spine', 10, 1) WITH NOWAIT;

DECLARE @latest_reference_date DATE = DATEADD(DAY, -@label_window_days, @as_of_date);

;WITH Periods AS
(
    SELECT 0 AS PeriodIndex
    UNION ALL
    SELECT PeriodIndex + 1 FROM Periods WHERE PeriodIndex + 1 < @num_reference_periods
)
SELECT
    PeriodIndex,
    DATEADD(DAY, -@cycle_length_days * PeriodIndex, @latest_reference_date) AS ReferenceDate,
    DATEADD(DAY, -@cycle_length_days * PeriodIndex - @feature_window_days, @latest_reference_date) AS FeatureWindowStart,
    DATEADD(DAY, -@cycle_length_days * PeriodIndex, @latest_reference_date) AS FeatureWindowEnd,     -- exclusive
    DATEADD(DAY, -@cycle_length_days * PeriodIndex, @latest_reference_date) AS LabelWindowStart,      -- inclusive
    DATEADD(DAY, -@cycle_length_days * PeriodIndex + @label_window_days, @latest_reference_date) AS LabelWindowEnd  -- exclusive
INTO #ReferenceDates
FROM Periods
OPTION (MAXRECURSION 1000);

CREATE UNIQUE CLUSTERED INDEX IX_ReferenceDates_PeriodIndex ON #ReferenceDates(PeriodIndex);

SELECT * FROM #ReferenceDates ORDER BY PeriodIndex;


/*==============================================================
  5a. KEY RETAIL EVENT CALENDAR

  A small calendar of UK retail shopping events, built for every
  calendar year touched by any feature or label window in the spine
  (+/- 1 year buffer). Used next to flag whether a customer's
  feature/label window sits around Black Friday, Christmas, etc. --
  without this, elevated spend around those dates looks like ordinary
  customer-level propensity rather than a calendar effect, which the
  model can't otherwise separate out.

  Easter Sunday is computed per year via the standard Gregorian Easter
  algorithm (anonymous/Meeus algorithm) rather than hard-coded, so it
  stays correct for any @as_of_date. Black Friday is derived as the
  4th Friday of November (DATEFIRST 1 is set at the top of this
  script, so DATEPART(WEEKDAY, ...) = 5 is Friday throughout).

  Extend/trim the event list below to match what actually matters for
  your sectors (e.g. add Diwali, Ramadan/Eid if relevant to your
  customer base -- both are lunar and would need an external date
  table rather than a formula).
==============================================================*/

RAISERROR('Stage 5a: Building key retail event calendar', 10, 1) WITH NOWAIT;

DECLARE @calendar_start_year INT = YEAR((SELECT MIN(FeatureWindowStart) FROM #ReferenceDates)) - 1;
DECLARE @calendar_end_year   INT = YEAR((SELECT MAX(LabelWindowEnd) FROM #ReferenceDates)) + 1;

;WITH Years AS
(
    SELECT @calendar_start_year AS CalendarYear
    UNION ALL
    SELECT CalendarYear + 1 FROM Years WHERE CalendarYear + 1 <= @calendar_end_year
),
E1 AS
(
    SELECT CalendarYear,
        CalendarYear % 19 AS a,
        CalendarYear / 100 AS b,
        CalendarYear % 100 AS c
    FROM Years
),
E2 AS
(
    SELECT CalendarYear, a, b, c,
        b / 4 AS d,
        b % 4 AS e,
        (b + 8) / 25 AS f
    FROM E1
),
E3 AS
(
    SELECT CalendarYear, a, b, c, d, e,
        (b - f + 1) / 3 AS g
    FROM E2
),
E4 AS
(
    SELECT CalendarYear, a, e,
        (19 * a + b - d - g + 15) % 30 AS h,
        c / 4 AS i,
        c % 4 AS k
    FROM E3
),
E5 AS
(
    SELECT CalendarYear, a, h,
        (32 + 2 * e + 2 * i - h - k) % 7 AS l
    FROM E4
),
E6 AS
(
    SELECT CalendarYear, h, l,
        (a + 11 * h + 22 * l) / 451 AS m
    FROM E5
)
SELECT
    CalendarYear,
    DATEFROMPARTS(
        CalendarYear,
        (h + l - 7 * m + 114) / 31,
        ((h + l - 7 * m + 114) % 31) + 1
    ) AS EasterSunday
INTO #EasterDates
FROM E6
OPTION (MAXRECURSION 100);

CREATE UNIQUE CLUSTERED INDEX IX_EasterDates_Year ON #EasterDates(CalendarYear);

;WITH NovemberFirsts AS
(
    SELECT CalendarYear, EasterSunday, DATEFROMPARTS(CalendarYear, 11, 1) AS NovemberFirst
    FROM #EasterDates
),
FirstFridays AS
(
    SELECT CalendarYear, EasterSunday,
        DATEADD(DAY, (5 - DATEPART(WEEKDAY, NovemberFirst) + 7) % 7, NovemberFirst) AS FirstFridayInNovember
    FROM NovemberFirsts
)
SELECT
    CalendarYear,
    EasterSunday,
    DATEADD(DAY, 21, FirstFridayInNovember) AS BlackFriday
INTO #YearEventDates
FROM FirstFridays
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_YearEventDates_Year ON #YearEventDates(CalendarYear);

SELECT DATEFROMPARTS(CalendarYear, 1, 1) AS EventDate, 'New Year''s Day' AS EventName
INTO #KeyRetailEvents FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 2, 14), 'Valentine''s Day' FROM #YearEventDates
UNION ALL SELECT DATEADD(DAY, -2, EasterSunday), 'Good Friday' FROM #YearEventDates
UNION ALL SELECT EasterSunday, 'Easter Sunday' FROM #YearEventDates
UNION ALL SELECT DATEADD(DAY, 1, EasterSunday), 'Easter Monday' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 9, 1), 'Back to School' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 10, 31), 'Halloween' FROM #YearEventDates
UNION ALL SELECT BlackFriday, 'Black Friday' FROM #YearEventDates
UNION ALL SELECT DATEADD(DAY, 3, BlackFriday), 'Cyber Monday' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 12, 24), 'Christmas Eve' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 12, 25), 'Christmas Day' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 12, 26), 'Boxing Day' FROM #YearEventDates
UNION ALL SELECT DATEFROMPARTS(CalendarYear, 12, 31), 'New Year''s Eve' FROM #YearEventDates;

CREATE CLUSTERED INDEX IX_KeyRetailEvents_EventDate ON #KeyRetailEvents(EventDate);

SELECT * FROM #KeyRetailEvents ORDER BY EventDate;


/*==============================================================
  5b. PERIOD KEY-EVENT FEATURES

  Per reference period: whether the label window (the 30 days whose
  spend we're predicting) overlaps a key event, whether the feature
  window (recent history) did, and the name of / signed days to the
  nearest event relative to the label window start (negative = the
  event falls before the label window starts, positive = it falls on
  or after). Joined onto every row of the final panel by PeriodIndex.
==============================================================*/

RAISERROR('Stage 5b: Calculating period key-event features', 10, 1) WITH NOWAIT;

SELECT
    rd.PeriodIndex,
    CASE WHEN EXISTS (
        SELECT 1 FROM #KeyRetailEvents AS ke
        WHERE ke.EventDate >= rd.LabelWindowStart AND ke.EventDate < rd.LabelWindowEnd
    ) THEN 1 ELSE 0 END AS LabelWindowOverlapsKeyEvent,
    CASE WHEN EXISTS (
        SELECT 1 FROM #KeyRetailEvents AS ke
        WHERE ke.EventDate >= rd.FeatureWindowStart AND ke.EventDate < rd.FeatureWindowEnd
    ) THEN 1 ELSE 0 END AS FeatureWindowOverlapsKeyEvent,
    nearest.EventName AS LabelWindowNearestKeyEventName,
    nearest.DaysFromLabelWindowStart AS LabelWindowDaysToNearestKeyEvent
INTO #PeriodKeyEventFeatures
FROM #ReferenceDates AS rd
OUTER APPLY
(
    SELECT TOP (1) ke.EventName, DATEDIFF(DAY, rd.LabelWindowStart, ke.EventDate) AS DaysFromLabelWindowStart
    FROM #KeyRetailEvents AS ke
    ORDER BY ABS(DATEDIFF(DAY, rd.LabelWindowStart, ke.EventDate)) ASC
) AS nearest
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_PeriodKeyEventFeatures_PeriodIndex ON #PeriodKeyEventFeatures(PeriodIndex);

SELECT * FROM #PeriodKeyEventFeatures ORDER BY PeriodIndex;


/*==============================================================
  6. FILTERED TRANSACTIONS ACROSS THE FULL REQUIRED SPAN
==============================================================*/

RAISERROR('Stage 4: Extracting filtered transactions', 10, 1) WITH NOWAIT;

DECLARE @earliest_feature_start DATE = (SELECT MIN(FeatureWindowStart) FROM #ReferenceDates);

SELECT
    cl.FanID,
    ct.ConsumerCombinationID,
    CONVERT(DECIMAL(19,4), ct.Amount) AS Spend,
    ct.TranDate,
    CONVERT(DATE, ct.TranDate) AS PurchaseDate,
    ct.IsOnline
INTO #FilteredTransactions
FROM #CustomerLatest AS cl
INNER JOIN [WH_AllPublishers].[Trans].[ConsumerTransaction] AS ct ON ct.CINID = cl.CINID
WHERE ct.TranDate >= @earliest_feature_start
  AND ct.TranDate < @as_of_date
  AND ct.Amount IS NOT NULL
  AND ct.ConsumerCombinationID IS NOT NULL
  AND (@positive_spend_only = 0 OR ct.Amount > 0)
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_FilteredTransactions_FanDate ON #FilteredTransactions(FanID, TranDate);

SELECT
    COUNT_BIG(*) AS FilteredTransactionCount,
    COUNT(DISTINCT FanID) AS FansWithTransactions,
    MIN(TranDate) AS MinimumTransactionDate,
    MAX(TranDate) AS MaximumTransactionDate
FROM #FilteredTransactions;


/*==============================================================
  7. ENRICHED TRANSACTIONS (dimension joins inline; no separate
     "required combinations" narrowing step -- reintroduce one if
     this proves slow against the full population)
==============================================================*/

RAISERROR('Stage 5: Enriching transactions with brand/sector/group', 10, 1) WITH NOWAIT;

/*
  ConsumerCombination / Brand / BrandSector / BrandSectorGroup are not
  guaranteed one row per key (BrandID / SectorID / SectorGroupID) --
  e.g. a duplicate error was hit joining straight to BrandSector, so
  one of these dimensions has more than one row for the same key
  (likely an SCD-style history table with no "current row" filter).
  Each is deduped to one row per key before joining, so the chain can
  never fan out. ORDER BY (SELECT NULL) picks an arbitrary surviving
  row -- if you find a column that marks the current/most recent
  record (EffectiveDate, IsCurrent, ModifiedDate, ...), use that
  instead so the pick is deterministic rather than arbitrary.
*/
;WITH ComboOne AS
(
    SELECT ConsumerCombinationID, BrandID, LocationCountry, IsUKSpend,
        ROW_NUMBER() OVER (PARTITION BY ConsumerCombinationID ORDER BY (SELECT NULL)) AS rn
    FROM [WH_AllPublishers].[Trans].[ConsumerCombination]
),
BrandOne AS
(
    SELECT BrandID, BrandName, BrandGroupID, SectorID, IsOnlineOnly, IsPremiumRetailer, IsSubscription, IsLivePartner,
        ROW_NUMBER() OVER (PARTITION BY BrandID ORDER BY (SELECT NULL)) AS rn
    FROM [WH_AllPublishers].[Trans].[Brand]
),
SectorOne AS
(
    SELECT SectorID, SectorGroupID, SectorName,
        ROW_NUMBER() OVER (PARTITION BY SectorID ORDER BY (SELECT NULL)) AS rn
    FROM [WH_AllPublishers].[Trans].[BrandSector]
),
GroupOne AS
(
    SELECT SectorGroupID, GroupName,
        ROW_NUMBER() OVER (PARTITION BY SectorGroupID ORDER BY (SELECT NULL)) AS rn
    FROM [WH_AllPublishers].[Trans].[BrandSectorGroup]
)
SELECT
    ft.FanID, ft.ConsumerCombinationID, ft.Spend, ft.TranDate, ft.PurchaseDate,
    CASE WHEN @trandate_has_time = 1 THEN DATEPART(HOUR, ft.TranDate) ELSE NULL END AS PurchaseHour,
    ft.IsOnline,
    cc.BrandID, cc.LocationCountry, cc.IsUKSpend,
    b.BrandName, b.BrandGroupID, b.SectorID, b.IsOnlineOnly, b.IsPremiumRetailer, b.IsSubscription, b.IsLivePartner,
    bs.SectorGroupID, bs.SectorName,
    bsg.GroupName
INTO #Transactions
FROM #FilteredTransactions AS ft
INNER JOIN ComboOne AS cc ON cc.ConsumerCombinationID = ft.ConsumerCombinationID AND cc.rn = 1
INNER JOIN BrandOne AS b ON b.BrandID = cc.BrandID AND b.rn = 1
INNER JOIN SectorOne AS bs ON bs.SectorID = b.SectorID AND bs.rn = 1
INNER JOIN GroupOne AS bsg ON bsg.SectorGroupID = bs.SectorGroupID AND bsg.rn = 1
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_Transactions_FanDate ON #Transactions(FanID, TranDate);

SELECT COUNT_BIG(*) AS EnrichedTransactionCount FROM #Transactions;


/*==============================================================
  8. SECTOR DIMENSION (scoring universe for the cross join)
==============================================================*/

RAISERROR('Stage 6: Building sector dimension', 10, 1) WITH NOWAIT;

SELECT TOP (0) bs.SectorID, bs.SectorName, bs.SectorGroupID, bsg.GroupName
INTO #SectorDimension
FROM [WH_AllPublishers].[Trans].[BrandSector] AS bs
INNER JOIN [WH_AllPublishers].[Trans].[BrandSectorGroup] AS bsg ON bsg.SectorGroupID = bs.SectorGroupID;

IF @restrict_sectors_to_observed = 1
    INSERT INTO #SectorDimension (SectorID, SectorName, SectorGroupID, GroupName)
    SELECT DISTINCT t.SectorID, t.SectorName, t.SectorGroupID, t.GroupName
    FROM #Transactions AS t
    OPTION (RECOMPILE);
ELSE
    -- Same dedup as stage 5 -- BrandSector/BrandSectorGroup are not
    -- guaranteed one row per SectorID/SectorGroupID (see note there).
    INSERT INTO #SectorDimension (SectorID, SectorName, SectorGroupID, GroupName)
    SELECT bs.SectorID, bs.SectorName, bs.SectorGroupID, bsg.GroupName
    FROM
    (
        SELECT SectorID, SectorName, SectorGroupID,
            ROW_NUMBER() OVER (PARTITION BY SectorID ORDER BY (SELECT NULL)) AS rn
        FROM [WH_AllPublishers].[Trans].[BrandSector]
    ) AS bs
    INNER JOIN
    (
        SELECT SectorGroupID, GroupName,
            ROW_NUMBER() OVER (PARTITION BY SectorGroupID ORDER BY (SELECT NULL)) AS rn
        FROM [WH_AllPublishers].[Trans].[BrandSectorGroup]
    ) AS bsg ON bsg.SectorGroupID = bs.SectorGroupID AND bsg.rn = 1
    WHERE bs.rn = 1
    OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SectorDimension_SectorID ON #SectorDimension(SectorID);

SELECT COUNT_BIG(*) AS SectorDimensionCount FROM #SectorDimension;


/*==============================================================
  9. TAG TRANSACTIONS INTO FEATURE-WINDOW / LABEL-WINDOW PERIODS
==============================================================*/

RAISERROR('Stage 7: Tagging transactions into periods', 10, 1) WITH NOWAIT;

/*
  The spine tiles the timeline exactly (see header), so each
  transaction matches at most one feature window and at most one
  (different) label window -- a 1:1 tag, not a fan-out join.
*/
SELECT
    t.FanID, t.Spend, t.TranDate, t.PurchaseDate, t.PurchaseHour, t.IsOnline,
    t.BrandID, t.SectorID, t.SectorGroupID,
    rd.PeriodIndex, rd.ReferenceDate
INTO #PeriodFeatureTransactions
FROM #Transactions AS t
INNER JOIN #ReferenceDates AS rd
    ON t.TranDate >= rd.FeatureWindowStart AND t.TranDate < rd.FeatureWindowEnd
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_PFT_FanPeriod ON #PeriodFeatureTransactions(FanID, PeriodIndex, TranDate);
CREATE INDEX IX_PFT_FanPeriodSector ON #PeriodFeatureTransactions(FanID, PeriodIndex, SectorID)
    INCLUDE (Spend, TranDate, PurchaseDate, SectorGroupID, BrandID);

SELECT
    t.FanID, t.SectorID, t.SectorGroupID, t.Spend, t.TranDate, rd.PeriodIndex
INTO #PeriodLabelTransactions
FROM #Transactions AS t
INNER JOIN #ReferenceDates AS rd
    ON t.TranDate >= rd.LabelWindowStart AND t.TranDate < rd.LabelWindowEnd
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX IX_PLT_FanPeriodSector ON #PeriodLabelTransactions(FanID, PeriodIndex, SectorID);
CREATE INDEX IX_PLT_FanPeriodGroup ON #PeriodLabelTransactions(FanID, PeriodIndex, SectorGroupID)
    INCLUDE (Spend, TranDate);

SELECT COUNT_BIG(*) AS FeatureWindowRows FROM #PeriodFeatureTransactions;
SELECT COUNT_BIG(*) AS LabelWindowRows FROM #PeriodLabelTransactions;


/*==============================================================
  10. CUSTOMER-PERIOD FEATURES (sector-agnostic): spend/purchase
      windows, basket size, recency, diversity, online/AM-PM/
      weekend split, momentum, purchase-day counts, cadence and
      weekly-streak metrics -- all in one pass, per (FanID, PeriodIndex)
==============================================================*/

RAISERROR('Stage 8: Calculating customer-period features', 10, 1) WITH NOWAIT;

;WITH PurchaseDates AS
(
    SELECT FanID, PeriodIndex, ReferenceDate, PurchaseDate
    FROM #PeriodFeatureTransactions
    GROUP BY FanID, PeriodIndex, ReferenceDate, PurchaseDate
),
DayCounts AS
(
    SELECT
        FanID, PeriodIndex,
        SUM(CASE WHEN PurchaseDate >= DATEADD(DAY, -7, ReferenceDate) THEN 1 ELSE 0 END) AS ActivePurchaseDays_7d,
        SUM(CASE WHEN PurchaseDate >= DATEADD(DAY, -30, ReferenceDate) THEN 1 ELSE 0 END) AS ActivePurchaseDays_30d,
        COUNT(*) AS ActivePurchaseDays_90d
    FROM PurchaseDates
    GROUP BY FanID, PeriodIndex
),
Intervals AS
(
    SELECT FanID, PeriodIndex,
        DATEDIFF(DAY, LAG(PurchaseDate) OVER (PARTITION BY FanID, PeriodIndex ORDER BY PurchaseDate), PurchaseDate) AS Gap
    FROM PurchaseDates
),
IntervalMetrics AS
(
    SELECT
        FanID, PeriodIndex,
        CONVERT(DECIMAL(18,2), AVG(CONVERT(DECIMAL(18,4), Gap))) AS AvgDaysBetweenPurchases,
        CONVERT(DECIMAL(18,2), STDEV(CONVERT(FLOAT, Gap))) AS StdDevDaysBetweenPurchases,
        MIN(Gap) AS MinDaysBetweenPurchases,
        MAX(Gap) AS MaxDaysBetweenPurchases
    FROM Intervals
    WHERE Gap IS NOT NULL
    GROUP BY FanID, PeriodIndex
),
ActiveWeeks AS
(
    SELECT FanID, PeriodIndex,
        DATEADD(DAY, 1 - DATEPART(WEEKDAY, PurchaseDate), PurchaseDate) AS WeekStart
    FROM PurchaseDates
    GROUP BY FanID, PeriodIndex, DATEADD(DAY, 1 - DATEPART(WEEKDAY, PurchaseDate), PurchaseDate)
),
RankedWeeks AS
(
    SELECT FanID, PeriodIndex, WeekStart,
        ROW_NUMBER() OVER (PARTITION BY FanID, PeriodIndex ORDER BY WeekStart) AS rn
    FROM ActiveWeeks
),
Streaks AS
(
    SELECT FanID, PeriodIndex, MAX(WeekStart) AS StreakEnd, COUNT(*) AS StreakLength
    FROM RankedWeeks
    GROUP BY FanID, PeriodIndex, DATEDIFF(WEEK, '19000101', WeekStart) - rn
),
WeekSummary AS
(
    SELECT FanID, PeriodIndex, COUNT(*) AS ActiveWeeks_InWindow, MAX(WeekStart) AS LatestActiveWeek
    FROM ActiveWeeks
    GROUP BY FanID, PeriodIndex
),
StreakSummary AS
(
    SELECT
        s.FanID, s.PeriodIndex,
        MAX(s.StreakLength) AS MaxConsecutiveActiveWeeks_InWindow,
        MAX(CASE WHEN s.StreakEnd = ws.LatestActiveWeek THEN s.StreakLength ELSE 0 END) AS LatestActivityStreakWeeks
    FROM Streaks AS s
    INNER JOIN WeekSummary AS ws ON ws.FanID = s.FanID AND ws.PeriodIndex = s.PeriodIndex
    GROUP BY s.FanID, s.PeriodIndex
),
TxnAgg AS
(
    SELECT
        FanID, PeriodIndex, ReferenceDate,

        SUM(CASE WHEN TranDate >= DATEADD(DAY, -7, ReferenceDate) THEN Spend ELSE 0 END) AS Spend_7d,
        SUM(CASE WHEN TranDate >= DATEADD(DAY, -30, ReferenceDate) THEN Spend ELSE 0 END) AS Spend_30d,
        SUM(Spend) AS Spend_90d,

        SUM(CASE WHEN TranDate >= DATEADD(DAY, -7, ReferenceDate) THEN 1 ELSE 0 END) AS Purchases_7d,
        SUM(CASE WHEN TranDate >= DATEADD(DAY, -30, ReferenceDate) THEN 1 ELSE 0 END) AS Purchases_30d,
        COUNT(*) AS Purchases_90d,

        AVG(CASE WHEN TranDate >= DATEADD(DAY, -30, ReferenceDate) THEN Spend END) AS AvgBasketSize_30d,
        AVG(Spend) AS AvgBasketSize_90d,
        STDEV(CONVERT(FLOAT, Spend)) AS StdDevBasketSize_90d,

        MAX(TranDate) AS LastPurchaseDate,

        COUNT(DISTINCT BrandID) AS UniqueBrands_90d,
        COUNT(DISTINCT SectorID) AS UniqueSectors_90d,
        COUNT(DISTINCT SectorGroupID) AS UniqueGroups_90d,

        SUM(CASE WHEN IsOnline = 1 THEN Spend ELSE 0 END) AS OnlineSpend_90d,
        SUM(CASE WHEN IsOnline = 1 THEN 1 ELSE 0 END) AS OnlinePurchases_90d,

        SUM(CASE WHEN @trandate_has_time = 1 AND PurchaseHour < 12 THEN Spend ELSE 0 END) AS AMSpend_90d,
        SUM(CASE WHEN @trandate_has_time = 1 AND PurchaseHour < 12 THEN 1 ELSE 0 END) AS AMPurchases_90d,
        SUM(CASE WHEN @trandate_has_time = 1 AND PurchaseHour >= 12 THEN Spend ELSE 0 END) AS PMSpend_90d,
        SUM(CASE WHEN @trandate_has_time = 1 AND PurchaseHour >= 12 THEN 1 ELSE 0 END) AS PMPurchases_90d,

        SUM(CASE WHEN DATEPART(WEEKDAY, PurchaseDate) IN (6,7) THEN Spend ELSE 0 END) AS WeekendSpend_90d,
        SUM(CASE WHEN DATEPART(WEEKDAY, PurchaseDate) IN (6,7) THEN 1 ELSE 0 END) AS WeekendPurchases_90d,
        SUM(CASE WHEN DATEPART(WEEKDAY, PurchaseDate) NOT IN (6,7) THEN Spend ELSE 0 END) AS WeekdaySpend_90d,
        SUM(CASE WHEN DATEPART(WEEKDAY, PurchaseDate) NOT IN (6,7) THEN 1 ELSE 0 END) AS WeekdayPurchases_90d,

        -- Momentum: 30d immediately before ReferenceDate (Spend_30d above) vs the 30d before that
        SUM(CASE WHEN TranDate >= DATEADD(DAY, -60, ReferenceDate) AND TranDate < DATEADD(DAY, -30, ReferenceDate) THEN Spend ELSE 0 END) AS Spend_Prior30d,
        SUM(CASE WHEN TranDate >= DATEADD(DAY, -60, ReferenceDate) AND TranDate < DATEADD(DAY, -30, ReferenceDate) THEN 1 ELSE 0 END) AS Purchases_Prior30d

    FROM #PeriodFeatureTransactions
    GROUP BY FanID, PeriodIndex, ReferenceDate
)
SELECT
    ta.*,
    dc.ActivePurchaseDays_7d, dc.ActivePurchaseDays_30d, dc.ActivePurchaseDays_90d,
    im.AvgDaysBetweenPurchases, im.StdDevDaysBetweenPurchases, im.MinDaysBetweenPurchases, im.MaxDaysBetweenPurchases,
    ws.ActiveWeeks_InWindow,
    ss.MaxConsecutiveActiveWeeks_InWindow, ss.LatestActivityStreakWeeks
INTO #CustomerPeriodMetrics
FROM TxnAgg AS ta
LEFT JOIN DayCounts AS dc ON dc.FanID = ta.FanID AND dc.PeriodIndex = ta.PeriodIndex
LEFT JOIN IntervalMetrics AS im ON im.FanID = ta.FanID AND im.PeriodIndex = ta.PeriodIndex
LEFT JOIN WeekSummary AS ws ON ws.FanID = ta.FanID AND ws.PeriodIndex = ta.PeriodIndex
LEFT JOIN StreakSummary AS ss ON ss.FanID = ta.FanID AND ss.PeriodIndex = ta.PeriodIndex
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_CustomerPeriodMetrics_FanPeriod ON #CustomerPeriodMetrics(FanID, PeriodIndex);


/*==============================================================
  11. SECTOR-LEVEL PERIOD FEATURES (the core panel grain), with
      the favourite-sector flag computed inline via a window function
==============================================================*/

RAISERROR('Stage 9: Calculating sector-level period features', 10, 1) WITH NOWAIT;

;WITH SectorAgg AS
(
    SELECT
        FanID, PeriodIndex, SectorID,
        SUM(Spend) AS SectorSpend,
        COUNT_BIG(*) AS SectorPurchases,
        MAX(TranDate) AS LastSectorPurchaseDate
    FROM #PeriodFeatureTransactions
    GROUP BY FanID, PeriodIndex, SectorID
)
SELECT
    FanID, PeriodIndex, SectorID, SectorSpend, SectorPurchases, LastSectorPurchaseDate,
    CONVERT(DECIMAL(18,6), SectorSpend / NULLIF(SUM(SectorSpend) OVER (PARTITION BY FanID, PeriodIndex), 0)) AS SectorSpendPct,
    CONVERT(DECIMAL(18,6), 1.0 * SectorPurchases / NULLIF(SUM(SectorPurchases) OVER (PARTITION BY FanID, PeriodIndex), 0)) AS SectorTxnAffinity,
    CONVERT(BIT, 1) AS HasSectorTransaction_Feature,
    CASE WHEN ROW_NUMBER() OVER (PARTITION BY FanID, PeriodIndex ORDER BY SectorPurchases DESC, SectorSpend DESC, SectorID) = 1
         THEN 1 ELSE 0 END AS IsFavouriteSectorInWindow
INTO #PeriodSectorLong
FROM SectorAgg
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_PeriodSectorLong_FanPeriodSector ON #PeriodSectorLong(FanID, PeriodIndex, SectorID);

SELECT COUNT_BIG(*) AS PeriodSectorLongCount FROM #PeriodSectorLong;


/*==============================================================
  11a. SECTOR & GROUP POPULARITY PRIORS

  "How common is this sector right now, across the population?" --
  a standard recommender-style prior. Lets the model separate "this
  sector is just popular this period" from "this customer specifically
  is drawn to it" instead of learning that conflation implicitly.
  Computed as the share of the SAMPLED population with >=1 transaction
  in the sector during that period's feature window -- at
  @sample_size = 10000 this is already a reasonably large base, but
  it's still the dev sample, not the full population; recompute from
  the full customer base before using this for production training,
  and expect it to be noisier for periods/sectors with few positives.

  The per-publisher variant follows the same idea but denominated
  against only that publisher's sampled customers, and is only
  populated in the final panel when @publisher_ids selects a specific
  subset (@publisher_filter_active = 1) -- see note at declaration.
  With no filter, the sample can span many publishers of very
  different sizes and behaviour, and a per-publisher split of an
  arbitrary unfiltered sample is more likely to be noise than signal.
==============================================================*/

RAISERROR('Stage 11a: Calculating sector & group popularity priors', 10, 1) WITH NOWAIT;

DECLARE @total_sampled_customers INT = (SELECT COUNT(*) FROM #CustomerLatest);

SELECT
    pft.PeriodIndex,
    pft.SectorID,
    COUNT(DISTINCT pft.FanID) AS SectorActiveCustomers,
    CONVERT(DECIMAL(18,6), COUNT(DISTINCT pft.FanID) * 1.0 / NULLIF(@total_sampled_customers, 0)) AS SectorPopularityPrior
INTO #SectorPopularityByPeriod
FROM #PeriodFeatureTransactions AS pft
GROUP BY pft.PeriodIndex, pft.SectorID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SectorPopularityByPeriod ON #SectorPopularityByPeriod(PeriodIndex, SectorID);

SELECT
    pft.PeriodIndex,
    pft.SectorGroupID,
    COUNT(DISTINCT pft.FanID) AS GroupActiveCustomers,
    CONVERT(DECIMAL(18,6), COUNT(DISTINCT pft.FanID) * 1.0 / NULLIF(@total_sampled_customers, 0)) AS GroupPopularityPrior
INTO #GroupPopularityByPeriod
FROM #PeriodFeatureTransactions AS pft
GROUP BY pft.PeriodIndex, pft.SectorGroupID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_GroupPopularityByPeriod ON #GroupPopularityByPeriod(PeriodIndex, SectorGroupID);

SELECT
    cl.PublisherID,
    pft.PeriodIndex,
    pft.SectorID,
    COUNT(DISTINCT pft.FanID) AS PublisherSectorActiveCustomers,
    pubtotal.PublisherCustomerCount,
    CONVERT(DECIMAL(18,6), COUNT(DISTINCT pft.FanID) * 1.0 / NULLIF(pubtotal.PublisherCustomerCount, 0)) AS PublisherSectorPopularityPrior
INTO #PublisherSectorPopularityByPeriod
FROM #PeriodFeatureTransactions AS pft
INNER JOIN #CustomerLatest AS cl ON cl.FanID = pft.FanID
INNER JOIN
(
    SELECT PublisherID, COUNT(*) AS PublisherCustomerCount
    FROM #CustomerLatest
    GROUP BY PublisherID
) AS pubtotal ON pubtotal.PublisherID = cl.PublisherID
GROUP BY cl.PublisherID, pft.PeriodIndex, pft.SectorID, pubtotal.PublisherCustomerCount
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_PublisherSectorPopularityByPeriod ON #PublisherSectorPopularityByPeriod(PublisherID, PeriodIndex, SectorID);

SELECT COUNT_BIG(*) AS SectorPopularityRows FROM #SectorPopularityByPeriod;


/*==============================================================
  11b. SECTOR-SECTOR CO-OCCURRENCE & LIFT

  Market-basket-style association between sectors: for every ordered
  pair (A, B), Lift(A -> B) = P(B | basket has A) / P(B) across all
  (FanID, PeriodIndex) "baskets" in #PeriodSectorLong (a basket here
  is everything one customer bought across sectors within one
  feature window). Lift > 1 means having spent in A makes spending in
  B more likely than B's base rate alone would suggest; Lift = 1 means
  no association either way; Lift < 1 means a negative association.
  This is pooled across all sampled customers and periods together
  (not per period) since a single period's baskets are fairly sparse
  and a stable structural relationship is what we want here, not a
  period-specific one.

  Sector cardinality (a few dozen to ~100, not brand-level) keeps this
  a small dense-ish matrix -- if sectors are added or this later gets
  pushed down to Brand level, revisit before assuming it stays cheap.
==============================================================*/

RAISERROR('Stage 11b: Calculating sector-sector co-occurrence & lift', 10, 1) WITH NOWAIT;

DECLARE @total_sector_baskets INT =
(
    SELECT COUNT(*) FROM (SELECT DISTINCT FanID, PeriodIndex FROM #PeriodSectorLong) AS b
);

SELECT SectorID, COUNT(*) AS SectorBasketCount
INTO #SectorMarginals
FROM #PeriodSectorLong
GROUP BY SectorID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SectorMarginals ON #SectorMarginals(SectorID);

SELECT
    a.SectorID AS SourceSectorID,
    b.SectorID AS TargetSectorID,
    COUNT(*) AS PairBasketCount
INTO #SectorPairCooccurrence
FROM #PeriodSectorLong AS a
INNER JOIN #PeriodSectorLong AS b
    ON a.FanID = b.FanID AND a.PeriodIndex = b.PeriodIndex AND a.SectorID <> b.SectorID
GROUP BY a.SectorID, b.SectorID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SectorPairCooccurrence ON #SectorPairCooccurrence(SourceSectorID, TargetSectorID);

SELECT
    spc.SourceSectorID,
    spc.TargetSectorID,
    CONVERT(DECIMAL(18,6),
        (spc.PairBasketCount * 1.0 / NULLIF(sm_src.SectorBasketCount, 0))
        / NULLIF(sm_tgt.SectorBasketCount * 1.0 / NULLIF(@total_sector_baskets, 0), 0)
    ) AS Lift_SourceToTarget
INTO #SectorPairLift
FROM #SectorPairCooccurrence AS spc
INNER JOIN #SectorMarginals AS sm_src ON sm_src.SectorID = spc.SourceSectorID
INNER JOIN #SectorMarginals AS sm_tgt ON sm_tgt.SectorID = spc.TargetSectorID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_SectorPairLift ON #SectorPairLift(SourceSectorID, TargetSectorID);

SELECT COUNT_BIG(*) AS SectorPairCount FROM #SectorPairLift;


/*==============================================================
  11c. CUSTOMER-SECTOR AFFINITY SCORE (CROSS-SELL SIGNAL)

  For each (FanID, PeriodIndex, TargetSectorID), a spend-share-weighted
  average of Lift(S -> TargetSectorID) across every sector S the
  customer already has spend in during that feature window. This is
  the "people who buy what you buy also buy here" signal -- it's the
  main thing this panel was missing for scoring propensity into
  sectors a customer has never used, since every other feature only
  looks at the customer's OWN history in the target sector itself.

  Coalesced to 1 (not 0) downstream when no pair evidence exists --
  1 is the neutral "no observed association" value for a lift ratio;
  0 would wrongly read as "strong negative signal".
==============================================================*/

RAISERROR('Stage 11c: Calculating customer-sector affinity scores', 10, 1) WITH NOWAIT;

SELECT
    psl.FanID,
    psl.PeriodIndex,
    spl.TargetSectorID AS SectorID,
    CONVERT(DECIMAL(18,6), SUM(psl.SectorSpendPct * spl.Lift_SourceToTarget) / NULLIF(SUM(psl.SectorSpendPct), 0)) AS SectorCoOccurrenceAffinityScore
INTO #CustomerSectorAffinity
FROM #PeriodSectorLong AS psl
INNER JOIN #SectorPairLift AS spl ON spl.SourceSectorID = psl.SectorID
GROUP BY psl.FanID, psl.PeriodIndex, spl.TargetSectorID
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_CustomerSectorAffinity ON #CustomerSectorAffinity(FanID, PeriodIndex, SectorID);

SELECT COUNT_BIG(*) AS CustomerSectorAffinityRows FROM #CustomerSectorAffinity;


/*==============================================================
  11d. CUSTOMER SPEND DIVERSITY / ENTROPY SCORE

  Shannon entropy (base 2) of a customer's spend split across sectors
  within the feature window: 0 = all spend in one sector (fully
  concentrated), higher = spend spread evenly across more sectors.
  This is a sharper "how exploratory is this customer" signal than
  UniqueSectors_90d alone -- two customers can both touch 3 sectors,
  but one puts 90% of spend in one of them and the other splits it
  evenly; entropy tells them apart, which matters because spread-out
  spenders are generally better cross-sell targets than loyal ones.
==============================================================*/

RAISERROR('Stage 11d: Calculating customer spend diversity/entropy', 10, 1) WITH NOWAIT;

SELECT
    FanID, PeriodIndex,
    CONVERT(DECIMAL(18,6), -SUM(CASE WHEN SectorSpendPct > 0 THEN SectorSpendPct * LOG(SectorSpendPct, 2) ELSE 0 END)) AS SpendEntropyBits_FeatureWindow
INTO #CustomerSpendEntropy
FROM #PeriodSectorLong
GROUP BY FanID, PeriodIndex
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_CustomerSpendEntropy ON #CustomerSpendEntropy(FanID, PeriodIndex);


/*==============================================================
  12. GROUP-LEVEL CONTEXT FEATURES PER PERIOD (same pattern)
==============================================================*/

RAISERROR('Stage 10: Calculating group-level period features', 10, 1) WITH NOWAIT;

;WITH GroupAgg AS
(
    SELECT
        FanID, PeriodIndex, SectorGroupID,
        SUM(Spend) AS GroupSpend,
        COUNT_BIG(*) AS GroupPurchases,
        MAX(TranDate) AS LastGroupPurchaseDate
    FROM #PeriodFeatureTransactions
    GROUP BY FanID, PeriodIndex, SectorGroupID
)
SELECT
    FanID, PeriodIndex, SectorGroupID, GroupSpend, GroupPurchases, LastGroupPurchaseDate,
    CONVERT(DECIMAL(18,6), GroupSpend / NULLIF(SUM(GroupSpend) OVER (PARTITION BY FanID, PeriodIndex), 0)) AS GroupSpendPct,
    CONVERT(DECIMAL(18,6), 1.0 * GroupPurchases / NULLIF(SUM(GroupPurchases) OVER (PARTITION BY FanID, PeriodIndex), 0)) AS GroupTxnAffinity,
    CONVERT(BIT, 1) AS HasGroupTransaction_Feature,
    CASE WHEN ROW_NUMBER() OVER (PARTITION BY FanID, PeriodIndex ORDER BY GroupPurchases DESC, GroupSpend DESC, SectorGroupID) = 1
         THEN 1 ELSE 0 END AS IsFavouriteGroupInWindow
INTO #PeriodGroupLong
FROM GroupAgg
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_PeriodGroupLong_FanPeriodGroup ON #PeriodGroupLong(FanID, PeriodIndex, SectorGroupID);


/*==============================================================
  13. LABEL: SPEND IN SECTOR IN THE NEXT @label_window_days DAYS
==============================================================*/

RAISERROR('Stage 11: Constructing labels', 10, 1) WITH NOWAIT;

SELECT
    FanID, SectorID, PeriodIndex,
    SUM(Spend) AS SectorSpend_Next30d,
    COUNT_BIG(*) AS SectorPurchases_Next30d,
    CONVERT(BIT, 1) AS HasSectorSpend_Next30d
INTO #PeriodLabel
FROM #PeriodLabelTransactions
GROUP BY FanID, SectorID, PeriodIndex;

CREATE UNIQUE CLUSTERED INDEX IX_PeriodLabel_FanSectorPeriod ON #PeriodLabel(FanID, SectorID, PeriodIndex);

SELECT PeriodIndex, COUNT(*) AS SectorPositives, SUM(SectorSpend_Next30d) AS TotalSpend
FROM #PeriodLabel GROUP BY PeriodIndex ORDER BY PeriodIndex;


/*==============================================================
  13a. GROUP LABEL: SPEND IN GROUP IN THE NEXT @label_window_days DAYS

  Same construction as stage 13, one level up: lets the group-level
  model (predict "will they spend in this group next") train directly
  off this panel too, alongside the sector-level target above -- useful
  given the two-stage sector/group -> brand approach being taken.
  Column names follow the same underscore convention as the Sector
  target (SectorSpend_Next30d etc).
==============================================================*/

RAISERROR('Stage 13a: Constructing group-level labels', 10, 1) WITH NOWAIT;

SELECT
    FanID, SectorGroupID, PeriodIndex,
    SUM(Spend) AS GroupSpend_Next30d,
    COUNT_BIG(*) AS GroupPurchases_Next30d,
    CONVERT(BIT, 1) AS HasGroupSpend_Next30d
INTO #PeriodGroupLabel
FROM #PeriodLabelTransactions
GROUP BY FanID, SectorGroupID, PeriodIndex;

CREATE UNIQUE CLUSTERED INDEX IX_PeriodGroupLabel_FanGroupPeriod ON #PeriodGroupLabel(FanID, SectorGroupID, PeriodIndex);

SELECT PeriodIndex, COUNT(*) AS GroupPositives, SUM(GroupSpend_Next30d) AS TotalGroupSpend
FROM #PeriodGroupLabel GROUP BY PeriodIndex ORDER BY PeriodIndex;


/*==============================================================
  14. BASE PANEL: CUSTOMER x SECTOR x REFERENCE DATE
==============================================================*/

RAISERROR('Stage 12: Building base panel', 10, 1) WITH NOWAIT;

SELECT
    cl.FanID, rd.PeriodIndex, rd.ReferenceDate,
    sd.SectorID, sd.SectorName, sd.SectorGroupID, sd.GroupName
INTO #BasePanel
FROM #CustomerLatest AS cl
CROSS JOIN #ReferenceDates AS rd
CROSS JOIN #SectorDimension AS sd
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX IX_BasePanel_FanPeriodSector ON #BasePanel(FanID, PeriodIndex, SectorID);

SELECT COUNT_BIG(*) AS BasePanelRowCount FROM #BasePanel;


/*==============================================================
  15. FINAL ASSEMBLY
==============================================================*/

RAISERROR('Stage 13: Assembling final modelling panel', 10, 1) WITH NOWAIT;

SELECT
    bp.FanID, bp.PeriodIndex, bp.ReferenceDate,
    DATEADD(DAY, -@feature_window_days, bp.ReferenceDate) AS FeatureWindowStart,
    bp.ReferenceDate AS FeatureWindowEnd,
    DATEADD(DAY, @label_window_days, bp.ReferenceDate) AS LabelWindowEnd,
    bp.SectorID, bp.SectorName, bp.SectorGroupID, bp.GroupName,

    /* Customer attributes -- current snapshot, see header note.
       PublisherType/PublisherID/PublisherName are for post-training
       slicing & interpretability ONLY -- exclude them from the actual
       model feature set (see note at @publisher_filter_active). */
    cl.PublisherType, cl.PublisherID, pubn.PublisherName,
    cl.AccountType, cl.City, cl.County, cl.Region, cl.PostalSector,
    cl.PostCodeDistrict, cl.PostArea, cl.CAMEOCode, cl.Gender, cl.AgeCurrent, cl.AgeCurrentBandText,
    cl.CashbackPending, cl.CashbackAvailable, cl.CashbackLTV, cl.Unsubscribed, cl.Hardbounced,
    cl.EmailTracking, cl.MarketableByEmail, cl.MarketableByPush, cl.CurrentlyActive,
    cl.RegistrationDate, cl.DeactivatedDate, cl.IsDebit,
    tenure.TenureDays AS CustomerTenureDays_AsOfReferenceDate,

    /* Lifecycle stage as of ReferenceDate, bucketed by
       @new_customer_tenure_days / @established_customer_tenure_days. */
    CASE WHEN tenure.TenureDays IS NULL THEN NULL
         WHEN tenure.TenureDays < @new_customer_tenure_days THEN 1
         ELSE 0 END AS IsNewCustomer,
    CASE WHEN tenure.TenureDays IS NULL THEN 'Unknown'
         WHEN tenure.TenureDays < @new_customer_tenure_days THEN 'New'
         WHEN tenure.TenureDays < @established_customer_tenure_days THEN 'Established'
         ELSE 'Mature' END AS CustomerLifecycleStage,

    /* Calendar / seasonality -- replaces the 365d seasonal block, see header note */
    MONTH(bp.ReferenceDate) AS ReferenceMonth,
    DATEPART(QUARTER, bp.ReferenceDate) AS ReferenceQuarter,
    CONVERT(DECIMAL(9,6), SIN(2 * PI() * MONTH(bp.ReferenceDate) / 12.0)) AS ReferenceMonthSin,
    CONVERT(DECIMAL(9,6), COS(2 * PI() * MONTH(bp.ReferenceDate) / 12.0)) AS ReferenceMonthCos,

    /* Key-retail-event seasonality: does the window whose spend we're
       predicting (or the recent history window) sit around Black
       Friday/Christmas/etc, and how far away is the nearest one? */
    COALESCE(pke.LabelWindowOverlapsKeyEvent, 0) AS LabelWindowOverlapsKeyEvent,
    COALESCE(pke.FeatureWindowOverlapsKeyEvent, 0) AS FeatureWindowOverlapsKeyEvent,
    pke.LabelWindowNearestKeyEventName,
    pke.LabelWindowDaysToNearestKeyEvent,

    /* Customer-period features (sector-agnostic) */
    COALESCE(cpm.Spend_7d, 0) AS Spend_7d,
    COALESCE(cpm.Spend_30d, 0) AS Spend_30d,
    COALESCE(cpm.Spend_90d, 0) AS Spend_90d,
    COALESCE(cpm.Purchases_7d, 0) AS Purchases_7d,
    COALESCE(cpm.Purchases_30d, 0) AS Purchases_30d,
    COALESCE(cpm.Purchases_90d, 0) AS Purchases_90d,
    COALESCE(cpm.AvgBasketSize_30d, 0) AS AvgBasketSize_30d,
    COALESCE(cpm.AvgBasketSize_90d, 0) AS AvgBasketSize_90d,
    COALESCE(cpm.StdDevBasketSize_90d, 0) AS StdDevBasketSize_90d,
    cpm.LastPurchaseDate,
    CASE WHEN cpm.LastPurchaseDate IS NULL THEN NULL
         ELSE DATEDIFF(DAY, cpm.LastPurchaseDate, bp.ReferenceDate) END AS DaysSinceLastPurchase_CappedAtWindow,
    COALESCE(cpm.ActivePurchaseDays_7d, 0) AS ActivePurchaseDays_7d,
    COALESCE(cpm.ActivePurchaseDays_30d, 0) AS ActivePurchaseDays_30d,
    COALESCE(cpm.ActivePurchaseDays_90d, 0) AS ActivePurchaseDays_90d,
    COALESCE(cpm.AvgDaysBetweenPurchases, 0) AS AvgDaysBetweenPurchases,
    COALESCE(cpm.StdDevDaysBetweenPurchases, 0) AS StdDevDaysBetweenPurchases,
    COALESCE(cpm.MinDaysBetweenPurchases, 0) AS MinDaysBetweenPurchases,
    COALESCE(cpm.MaxDaysBetweenPurchases, 0) AS MaxDaysBetweenPurchases,
    COALESCE(cpm.ActiveWeeks_InWindow, 0) AS ActiveWeeks_InWindow,
    COALESCE(cpm.MaxConsecutiveActiveWeeks_InWindow, 0) AS MaxConsecutiveActiveWeeks_InWindow,
    COALESCE(cpm.LatestActivityStreakWeeks, 0) AS LatestActivityStreakWeeks,
    COALESCE(cpm.UniqueBrands_90d, 0) AS UniqueBrands_90d,
    COALESCE(cpm.UniqueSectors_90d, 0) AS UniqueSectors_90d,
    COALESCE(cpm.UniqueGroups_90d, 0) AS UniqueGroups_90d,
    COALESCE(cpm.OnlineSpend_90d, 0) AS OnlineSpend_90d,
    COALESCE(cpm.OnlinePurchases_90d, 0) AS OnlinePurchases_90d,
    CONVERT(DECIMAL(18,6), COALESCE(cpm.OnlineSpend_90d, 0) / NULLIF(cpm.Spend_90d, 0)) AS OnlineSpendPct_90d,
    COALESCE(cpm.AMSpend_90d, 0) AS AMSpend_90d,
    COALESCE(cpm.AMPurchases_90d, 0) AS AMPurchases_90d,
    COALESCE(cpm.PMSpend_90d, 0) AS PMSpend_90d,
    COALESCE(cpm.PMPurchases_90d, 0) AS PMPurchases_90d,
    COALESCE(cpm.WeekendSpend_90d, 0) AS WeekendSpend_90d,
    COALESCE(cpm.WeekendPurchases_90d, 0) AS WeekendPurchases_90d,
    COALESCE(cpm.WeekdaySpend_90d, 0) AS WeekdaySpend_90d,
    COALESCE(cpm.WeekdayPurchases_90d, 0) AS WeekdayPurchases_90d,
    CONVERT(DECIMAL(18,6), COALESCE(cpm.WeekendSpend_90d, 0) / NULLIF(cpm.Spend_90d, 0)) AS WeekendSpendPct_90d,

    /* Momentum within the 90-day feature window */
    CONVERT(DECIMAL(19,4), COALESCE(cpm.Spend_30d, 0) / 30.0 - COALESCE(cpm.Spend_Prior30d, 0) / 30.0) AS SpendAccelerationAbsolute_30vPrior30,
    CONVERT(DECIMAL(19,6),
        CASE WHEN COALESCE(cpm.Spend_Prior30d, 0) = 0 THEN NULL
             ELSE (cpm.Spend_30d - cpm.Spend_Prior30d) / NULLIF(ABS(cpm.Spend_Prior30d), 0) END
    ) AS SpendAccelerationPct_30vPrior30,
    CONVERT(DECIMAL(19,6),
        CASE WHEN COALESCE(cpm.Purchases_Prior30d, 0) = 0 THEN NULL
             ELSE 1.0 * (cpm.Purchases_30d - cpm.Purchases_Prior30d) / NULLIF(cpm.Purchases_Prior30d, 0) END
    ) AS PurchaseAccelerationPct_30vPrior30,

    /* Sector-level features -- the (customer x sector x period) grain */
    COALESCE(psl.HasSectorTransaction_Feature, 0) AS HasSectorTransaction_Last90d,
    COALESCE(psl.SectorSpend, 0) AS SectorSpend_Last90d,
    COALESCE(psl.SectorPurchases, 0) AS SectorPurchases_Last90d,
    COALESCE(psl.SectorSpendPct, 0) AS SectorSpendPct_Last90d,
    COALESCE(psl.SectorTxnAffinity, 0) AS SectorTxnAffinity_Last90d,
    psl.LastSectorPurchaseDate,
    CASE WHEN psl.LastSectorPurchaseDate IS NULL THEN NULL
         ELSE DATEDIFF(DAY, psl.LastSectorPurchaseDate, bp.ReferenceDate) END AS DaysSinceLastSectorPurchase_CappedAtWindow,
    COALESCE(psl.IsFavouriteSectorInWindow, 0) AS IsFavouriteSectorInWindow,

    /* Group-level context (the row's parent group) */
    COALESCE(pgl.HasGroupTransaction_Feature, 0) AS HasGroupTransaction_Last90d,
    COALESCE(pgl.GroupSpend, 0) AS GroupSpend_Last90d,
    COALESCE(pgl.GroupPurchases, 0) AS GroupPurchases_Last90d,
    COALESCE(pgl.GroupSpendPct, 0) AS GroupSpendPct_Last90d,
    COALESCE(pgl.GroupTxnAffinity, 0) AS GroupTxnAffinity_Last90d,
    pgl.LastGroupPurchaseDate,
    CASE WHEN pgl.LastGroupPurchaseDate IS NULL THEN NULL
         ELSE DATEDIFF(DAY, pgl.LastGroupPurchaseDate, bp.ReferenceDate) END AS DaysSinceLastGroupPurchase_CappedAtWindow,
    COALESCE(pgl.IsFavouriteGroupInWindow, 0) AS IsFavouriteGroupInWindow,

    /* Sector/group popularity priors -- "how common is this sector/group
       right now, across the population" (see stage 11a). Lets the model
       separate general popularity from customer-specific propensity. */
    COALESCE(spop.SectorPopularityPrior, 0) AS SectorPopularityPrior,
    COALESCE(gpop.GroupPopularityPrior, 0) AS GroupPopularityPrior,

    /* Per-publisher sector popularity -- ONLY populated when @publisher_ids
       selects a specific subset (@publisher_filter_active = 1); NULL
       otherwise, since splitting an unfiltered/all-publisher sample this
       way is more likely to add noise than signal (see stage 11a). */
    CASE WHEN @publisher_filter_active = 1 THEN psp.PublisherSectorPopularityPrior ELSE NULL END AS PublisherSectorPopularityPrior,

    /* Sector-sector co-occurrence/lift-based cross-sell affinity (stage
       11c). Coalesced to 1 (neutral/no-association), not 0 -- see that
       stage's note on why 0 would misrepresent "no evidence either way". */
    COALESCE(csa.SectorCoOccurrenceAffinityScore, 1) AS SectorCoOccurrenceAffinityScore,

    /* Spend diversity/entropy across sectors this period (stage 11d).
       Evenness normalises entropy to 0-1 by the customer's own sector
       count so it's comparable across customers with different reach;
       0 when the customer has activity in 0 or 1 sectors (no diversity
       possible), consistent with entropy itself being 0 in that case. */
    COALESCE(cse.SpendEntropyBits_FeatureWindow, 0) AS CustomerSpendEntropyBits_FeatureWindow,
    CASE WHEN COALESCE(cpm.UniqueSectors_90d, 0) > 1
         THEN CONVERT(DECIMAL(18,6), COALESCE(cse.SpendEntropyBits_FeatureWindow, 0) / LOG(cpm.UniqueSectors_90d, 2))
         ELSE 0 END AS CustomerSpendEvennessScore_FeatureWindow,

    /* TARGET: spend in this sector in the next @label_window_days days.
       HasSectorSpend_Next30d is the classifier target; the spend/purchase
       magnitudes are diagnostics/a secondary regression target only --
       never use them as model features. */
    COALESCE(pl.HasSectorSpend_Next30d, 0) AS HasSectorSpend_Next30d,
    COALESCE(pl.SectorSpend_Next30d, 0) AS SectorSpend_Next30d,
    COALESCE(pl.SectorPurchases_Next30d, 0) AS SectorPurchases_Next30d,

    /* TARGET (group grain): same idea, one level up, for a group-level
       model. HasGroupSpend_Next30d is that classifier's target; the
       spend/purchase magnitudes are diagnostics only -- same caution
       as the sector target above, never use them as model features. */
    COALESCE(pglabel.HasGroupSpend_Next30d, 0) AS HasGroupSpend_Next30d,
    COALESCE(pglabel.GroupSpend_Next30d, 0) AS GroupSpend_Next30d,
    COALESCE(pglabel.GroupPurchases_Next30d, 0) AS GroupPurchases_Next30d

FROM #BasePanel AS bp
INNER JOIN #CustomerLatest AS cl ON cl.FanID = bp.FanID
CROSS APPLY
(
    SELECT CASE WHEN cl.RegistrationDate IS NULL THEN NULL
                ELSE DATEDIFF(DAY, cl.RegistrationDate, bp.ReferenceDate) END AS TenureDays
) AS tenure
LEFT JOIN #PublisherNames AS pubn ON pubn.PublisherID = cl.PublisherID
LEFT JOIN #PeriodKeyEventFeatures AS pke ON pke.PeriodIndex = bp.PeriodIndex
LEFT JOIN #CustomerPeriodMetrics AS cpm ON cpm.FanID = bp.FanID AND cpm.PeriodIndex = bp.PeriodIndex
LEFT JOIN #PeriodSectorLong AS psl ON psl.FanID = bp.FanID AND psl.PeriodIndex = bp.PeriodIndex AND psl.SectorID = bp.SectorID
LEFT JOIN #PeriodGroupLong AS pgl ON pgl.FanID = bp.FanID AND pgl.PeriodIndex = bp.PeriodIndex AND pgl.SectorGroupID = bp.SectorGroupID
LEFT JOIN #SectorPopularityByPeriod AS spop ON spop.PeriodIndex = bp.PeriodIndex AND spop.SectorID = bp.SectorID
LEFT JOIN #GroupPopularityByPeriod AS gpop ON gpop.PeriodIndex = bp.PeriodIndex AND gpop.SectorGroupID = bp.SectorGroupID
LEFT JOIN #PublisherSectorPopularityByPeriod AS psp ON psp.PublisherID = cl.PublisherID AND psp.PeriodIndex = bp.PeriodIndex AND psp.SectorID = bp.SectorID
LEFT JOIN #CustomerSectorAffinity AS csa ON csa.FanID = bp.FanID AND csa.PeriodIndex = bp.PeriodIndex AND csa.SectorID = bp.SectorID
LEFT JOIN #CustomerSpendEntropy AS cse ON cse.FanID = bp.FanID AND cse.PeriodIndex = bp.PeriodIndex
LEFT JOIN #PeriodLabel AS pl ON pl.FanID = bp.FanID AND pl.PeriodIndex = bp.PeriodIndex AND pl.SectorID = bp.SectorID
LEFT JOIN #PeriodGroupLabel AS pglabel ON pglabel.FanID = bp.FanID AND pglabel.PeriodIndex = bp.PeriodIndex AND pglabel.SectorGroupID = bp.SectorGroupID
OPTION (RECOMPILE);

RAISERROR('Stage 13 complete: final modelling panel returned', 10, 1) WITH NOWAIT;

/*
  Time-based split for training: hold out PeriodIndex = 0 (most
  recent, fully-labelled period) as an out-of-time test set; train
  on PeriodIndex >= 1. Never split randomly across rows -- rows from
  the same FanID/period are correlated and a random split will leak.
*/


/*==============================================================
  OPTIONAL: find which dimension table has duplicate keys
==============================================================*/

/*
  Uncomment to see which table(s) caused the duplicate-key error
  and how many keys are affected, e.g. to decide on a better
  tiebreaker than ORDER BY (SELECT NULL) in stages 5 and 6.

SELECT 'ConsumerCombination' AS TableName, ConsumerCombinationID AS KeyValue, COUNT(*) AS DupCount
FROM [WH_AllPublishers].[Trans].[ConsumerCombination]
GROUP BY ConsumerCombinationID HAVING COUNT(*) > 1

UNION ALL

SELECT 'Brand', BrandID, COUNT(*)
FROM [WH_AllPublishers].[Trans].[Brand]
GROUP BY BrandID HAVING COUNT(*) > 1

UNION ALL

SELECT 'BrandSector', SectorID, COUNT(*)
FROM [WH_AllPublishers].[Trans].[BrandSector]
GROUP BY SectorID HAVING COUNT(*) > 1
UNION ALL

SELECT 'BrandSectorGroup', SectorGroupID, COUNT(*)
FROM [WH_AllPublishers].[Trans].[BrandSectorGroup]
GROUP BY SectorGroupID HAVING COUNT(*) > 1;

*/