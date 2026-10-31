CREATE DATABASE CardFraudDB;
GO
USE CardFraudDB;
GO

CREATE TABLE dbo.Customers (
    CustomerID   INT IDENTITY(1,1) PRIMARY KEY,
    FullName     NVARCHAR(100) NOT NULL,
    HomeCity     NVARCHAR(50)  NOT NULL,
    HomeCountry  CHAR(2)       NOT NULL DEFAULT 'IN',
    CreatedDate  DATE          NOT NULL
);


CREATE TABLE dbo.Cards (
    CardID       INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID   INT NOT NULL REFERENCES dbo.Customers(CustomerID),
    CardLast4    CHAR(4) NOT NULL,
    CreditLimit  DECIMAL(12,2) NOT NULL,
    CardStatus   VARCHAR(10) NOT NULL DEFAULT 'Active'
);

CREATE TABLE dbo.Merchants (
    MerchantID   INT IDENTITY(1,1) PRIMARY KEY,
    MerchantName NVARCHAR(100) NOT NULL,
    Category     VARCHAR(30)   NOT NULL,
    City         NVARCHAR(50)  NOT NULL,
    Country      CHAR(2)       NOT NULL
);

CREATE TABLE dbo.Transactions (
    TransactionID BIGINT IDENTITY(1,1) PRIMARY KEY,
    CardID        INT NOT NULL REFERENCES dbo.Cards(CardID),
    MerchantID    INT NOT NULL REFERENCES dbo.Merchants(MerchantID),
    TxnDateTime   DATETIME2(0) NOT NULL,
    Amount        DECIMAL(12,2) NOT NULL CHECK (Amount > 0),
    Channel       VARCHAR(10) NOT NULL CHECK (Channel IN ('POS','Online','ATM')),
    TxnStatus     VARCHAR(10) NOT NULL CHECK (TxnStatus IN ('Approved','Declined')),
    TxnCity       NVARCHAR(50) NOT NULL,
    TxnCountry    CHAR(2)      NOT NULL,
    IsFraud       BIT NOT NULL DEFAULT 0   -- ground-truth label, used only to evaluate your rules
);

CREATE INDEX IX_Txn_Card_Time
    ON dbo.Transactions (CardID, TxnDateTime) INCLUDE (Amount, TxnCountry);

SELECT * FROM Customers;
SELECT * FROM Merchants;
SELECT * FROM Cards;
SELECT * FROM Transactions;

;WITH n AS (
    SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects
)
INSERT dbo.Customers (FullName, HomeCity, HomeCountry, CreatedDate)
SELECT CONCAT('Customer ', n),
       CHOOSE(n % 5 + 1, 'Chennai','Mumbai','Delhi','Bengaluru','Hyderabad'),
       'IN',
       DATEADD(DAY, -(n * 7 % 1500), '2026-10-01')
FROM n;

INSERT dbo.Cards (CustomerID, CardLast4, CreditLimit)
SELECT CustomerID,
       RIGHT('0000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR(4)), 4),
       50000 + (CustomerID % 10) * 25000
FROM dbo.Customers;

;WITH n AS (
    SELECT TOP (60) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects
)
INSERT dbo.Merchants (MerchantName, Category, City, Country)
SELECT CONCAT('Merchant ', n),
       CHOOSE(n % 6 + 1, 'Grocery','Fuel','Electronics','Travel','Dining','Jewellery'),
       CASE WHEN n > 50 THEN CHOOSE(n % 3 + 1, 'New York','Singapore','London')
            ELSE CHOOSE(n % 5 + 1, 'Chennai','Mumbai','Delhi','Bengaluru','Hyderabad') END,
       CASE WHEN n > 50 THEN CHOOSE(n % 3 + 1, 'US','SG','GB') ELSE 'IN' END
FROM n;   -- merchants 1-50 domestic, 51-60 foreign


SELECT TOP (40000)
    ABS(CHECKSUM(NEWID())) % 200 + 1 AS CardID,
    ABS(CHECKSUM(NEWID())) % 50  + 1 AS MerchantID,
    ABS(CHECKSUM(NEWID())) % 129600  AS MinOffset,   -- ~90 days
    ABS(CHECKSUM(NEWID())) % 5000    AS AmtBase,
    ABS(CHECKSUM(NEWID())) % 3       AS ChanPick,
    ABS(CHECKSUM(NEWID())) % 100     AS DeclPick
INTO #raw
FROM sys.all_objects a CROSS JOIN sys.all_objects b;

INSERT dbo.Transactions (CardID, MerchantID, TxnDateTime, Amount, Channel, TxnStatus, TxnCity, TxnCountry, IsFraud)
SELECT CardID, MerchantID,
       DATEADD(MINUTE, MinOffset, '2026-07-01'),
       100 + AmtBase,
       CASE ChanPick WHEN 0 THEN 'POS' WHEN 1 THEN 'Online' ELSE 'ATM' END,
       CASE WHEN DeclPick < 3 THEN 'Declined' ELSE 'Approved' END,
       N'', 'IN', 0
FROM #raw;


SELECT TOP (25) CardID,
       DATEADD(HOUR, 2, DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 90, '2026-07-01')) AS StartTime
INTO #burst
FROM dbo.Cards ORDER BY NEWID();

INSERT dbo.Transactions (CardID, MerchantID, TxnDateTime, Amount, Channel, TxnStatus, TxnCity, TxnCountry, IsFraud)
SELECT b.CardID, 1 + ABS(CHECKSUM(NEWID())) % 50,
       DATEADD(MINUTE, k.i, b.StartTime),
       2000 + ABS(CHECKSUM(NEWID())) % 7000,
       'Online', 'Approved', N'', 'IN', 1
FROM #burst b CROSS JOIN (VALUES (0),(1),(2),(3),(4),(5)) k(i);


SELECT TOP (80) CardID, TxnDateTime
INTO #base
FROM dbo.Transactions
WHERE IsFraud = 0 AND TxnStatus = 'Approved'
ORDER BY NEWID();

INSERT dbo.Transactions (CardID, MerchantID, TxnDateTime, Amount, Channel, TxnStatus, TxnCity, TxnCountry, IsFraud)
SELECT CardID, 51 + ABS(CHECKSUM(NEWID())) % 10,
       DATEADD(MINUTE, 20, TxnDateTime),
       20000 + ABS(CHECKSUM(NEWID())) % 70000,
       'Online', 'Approved', N'', 'IN', 1
FROM #base;

-- Fill city/country from the merchant
UPDATE t SET TxnCity = m.City, TxnCountry = m.Country
FROM dbo.Transactions t JOIN dbo.Merchants m ON m.MerchantID = t.MerchantID;

-- Sanity check: expect 40,230 rows, 230 fraud
SELECT COUNT(*) AS TotalTxns, SUM(CAST(IsFraud AS INT)) AS FraudTxns FROM dbo.Transactions;

go
CREATE OR ALTER VIEW dbo.vw_TxnFeatures AS
WITH base AS (
    SELECT t.TransactionID, t.CardID, c.CustomerID, cu.HomeCountry, c.CreditLimit,
           t.TxnDateTime, t.Amount, t.Channel, t.TxnStatus, t.TxnCity, t.TxnCountry, t.IsFraud,
           LAG(t.TxnDateTime) OVER (PARTITION BY t.CardID ORDER BY t.TxnDateTime, t.TransactionID) AS PrevTxnTime,
           LAG(t.TxnCountry)  OVER (PARTITION BY t.CardID ORDER BY t.TxnDateTime, t.TransactionID) AS PrevCountry,
           -- history BEFORE this transaction only (avoids data leakage)
           AVG(t.Amount)   OVER (PARTITION BY t.CardID ORDER BY t.TxnDateTime, t.TransactionID
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS CardAvgAmt,
           STDEV(t.Amount) OVER (PARTITION BY t.CardID ORDER BY t.TxnDateTime, t.TransactionID
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS CardStdAmt
    FROM dbo.Transactions t
    JOIN dbo.Cards c      ON c.CardID = t.CardID
    JOIN dbo.Customers cu ON cu.CustomerID = c.CustomerID
)
SELECT b.*,
       DATEDIFF(MINUTE, b.PrevTxnTime, b.TxnDateTime) AS MinsSincePrev,
       v.Txn10Min
FROM base b
OUTER APPLY (            -- velocity: transactions on this card in the last 10 minutes
    SELECT COUNT(*) AS Txn10Min
    FROM dbo.Transactions x
    WHERE x.CardID = b.CardID
      AND x.TxnDateTime BETWEEN DATEADD(MINUTE, -10, b.TxnDateTime) AND b.TxnDateTime
) v;
go
  
CREATE OR ALTER VIEW dbo.vw_TxnScored AS
SELECT f.*, fl.HighAmtFlag, fl.VelocityFlag, fl.ForeignFlag, fl.TravelFlag, fl.NightFlag,
       s.FraudScore, r.RiskLevel
FROM dbo.vw_TxnFeatures f
CROSS APPLY (SELECT
    CASE WHEN f.Amount > f.CardAvgAmt + 3 * f.CardStdAmt THEN 1 ELSE 0 END AS HighAmtFlag,
    CASE WHEN f.Txn10Min >= 4 THEN 1 ELSE 0 END                            AS VelocityFlag,
    CASE WHEN f.TxnCountry <> f.HomeCountry THEN 1 ELSE 0 END              AS ForeignFlag,
    CASE WHEN f.PrevCountry <> f.TxnCountry AND f.MinsSincePrev <= 60 THEN 1 ELSE 0 END AS TravelFlag,
    CASE WHEN DATEPART(HOUR, f.TxnDateTime) BETWEEN 0 AND 4 THEN 1 ELSE 0 END AS NightFlag
) fl
CROSS APPLY (SELECT fl.HighAmtFlag*40 + fl.VelocityFlag*30 + fl.ForeignFlag*20
                  + fl.TravelFlag*40 + fl.NightFlag*10 AS FraudScore) s
CROSS APPLY (SELECT CASE WHEN s.FraudScore >= 70 THEN 'High'
                         WHEN s.FraudScore >= 40 THEN 'Medium'
                         ELSE 'Low' END AS RiskLevel) r;
go

SELECT RiskLevel, COUNT(*) AS Txns, SUM(CAST(IsFraud AS INT)) AS ActualFraud
FROM dbo.vw_TxnScored
GROUP BY RiskLevel;

CREATE TABLE dbo.FraudAlerts (
    AlertID       INT IDENTITY(1,1) PRIMARY KEY,
    TransactionID BIGINT NOT NULL UNIQUE REFERENCES dbo.Transactions(TransactionID),
    FraudScore    INT NOT NULL,
    RiskLevel     VARCHAR(10) NOT NULL,
    RuleFlags     VARCHAR(200) NULL,
    AlertDate     DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    ReviewStatus  VARCHAR(15) NOT NULL DEFAULT 'Open'
        CHECK (ReviewStatus IN ('Open','Confirmed','FalsePositive'))
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GenerateFraudAlerts @MinScore INT = 40
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.FraudAlerts (TransactionID, FraudScore, RiskLevel, RuleFlags)
    SELECT s.TransactionID, s.FraudScore, s.RiskLevel,
           CONCAT_WS(',',
               CASE WHEN s.HighAmtFlag  = 1 THEN 'HIGH_AMT' END,
               CASE WHEN s.VelocityFlag = 1 THEN 'VELOCITY' END,
               CASE WHEN s.ForeignFlag  = 1 THEN 'FOREIGN' END,
               CASE WHEN s.TravelFlag   = 1 THEN 'IMPOSSIBLE_TRAVEL' END,
               CASE WHEN s.NightFlag    = 1 THEN 'ODD_HOUR' END)
    FROM dbo.vw_TxnScored s
    WHERE s.FraudScore >= @MinScore
      AND NOT EXISTS (SELECT 1 FROM dbo.FraudAlerts a WHERE a.TransactionID = s.TransactionID);
END;
GO

EXEC dbo.usp_GenerateFraudAlerts @MinScore = 40;
SELECT TOP 20 * FROM dbo.FraudAlerts ORDER BY FraudScore DESC;


WITH cm AS (
    SELECT
        SUM(CASE WHEN FraudScore >= 40 AND IsFraud = 1 THEN 1 ELSE 0 END) AS TP,
        SUM(CASE WHEN FraudScore >= 40 AND IsFraud = 0 THEN 1 ELSE 0 END) AS FP,
        SUM(CASE WHEN FraudScore <  40 AND IsFraud = 1 THEN 1 ELSE 0 END) AS FN
    FROM dbo.vw_TxnScored
)
SELECT TP, FP, FN,
       CAST(TP * 1.0 / NULLIF(TP + FP, 0) AS DECIMAL(5,3)) AS Precision,
       CAST(TP * 1.0 / NULLIF(TP + FN, 0) AS DECIMAL(5,3)) AS Recall
FROM cm;


-- Fraud by channel and merchant category
SELECT t.Channel, m.Category, COUNT(*) AS Txns,
       SUM(CAST(t.IsFraud AS INT)) AS Fraud,
       CAST(100.0 * SUM(CAST(t.IsFraud AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS FraudPct
FROM dbo.Transactions t JOIN dbo.Merchants m ON m.MerchantID = t.MerchantID
GROUP BY t.Channel, m.Category
ORDER BY FraudPct DESC;

-- Top 10 riskiest cards
SELECT TOP 10 CardID, COUNT(*) AS Alerts, SUM(Amount) AS ExposedAmount
FROM dbo.vw_TxnScored WHERE FraudScore >= 40
GROUP BY CardID ORDER BY Alerts DESC;

-- Alerts by hour of day
SELECT DATEPART(HOUR, TxnDateTime) AS Hr, COUNT(*) AS Alerts
FROM dbo.vw_TxnScored WHERE FraudScore >= 40
GROUP BY DATEPART(HOUR, TxnDateTime) ORDER BY Hr;