SELECT TOP (1000)
    i.[IronOfferID],
    i.[IronOfferName],
    i.[HydraOfferID],
    i.[StartDate],
    i.[EndDate],
    i.[PartnerID],
    i.[IsAboveTheLine],
    i.[AutoAddToNewRegistrants],
    i.[IsDefaultCollateral],
    i.[IsSignedOff],
    i.[AreEligibleMembersCommitted],
    i.[AreControlMembersCommitted],
    i.[IsTriggerOffer],
    i.[Continuation],
    i.[TopCashBackRate],
    i.[AboveBase],
    i.[Clubs],
    i.[CampaignType],
    i.[SegmentName],
    i.[ClubID],
    i.[EarningType],
    o.[OfferID],
    o.[OfferName],
    o.[OfferCode],
    o.[OfferGUID]
FROM [WH_NWG].[Derived].[IronOffer] AS i
LEFT JOIN [WH_AllPublishers].[Derived].[Offer] AS o
    ON i.[IronOfferID] = o.[IronOfferID];