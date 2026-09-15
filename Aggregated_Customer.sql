SELECT TOP (20)
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
      ON bs.[SectorGroupID] = bsg.[SectorGroupID];

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

