# credit-card-fraud-detection-sql-server
Rule-based credit card fraud detection in SQL Server.

# Credit Card Fraud Detection in SQL Server

## Overview
A rule-based fraud detection system built in Microsoft SQL Server on 40,000+
synthetic card transactions with 230 planted fraud cases.

## Tools
SQL Server 2022, SSMS, Power BI

## Data model
(insert ER diagram)

## Fraud rules
| Rule | Logic | Points |
|---|---|---|
| High amount | Amount > card avg + 3 std dev | 40 |
| Velocity | 4+ transactions in 10 minutes | 30 |
| Foreign country | Country differs from home | 20 |
| Impossible travel | Country change within 60 min | 40 |
| Odd hour | 12 AM to 4:59 AM | 10 |

Risk levels: High 70+, Medium 40-69, Low below 40.

## SQL concepts used
Window functions (LAG, AVG, STDEV), CROSS/OUTER APPLY, views,
stored procedures, indexing, constraints.

## Results
Precision: X | Recall: Y (add your numbers and screenshot)

## Dashboard
(insert screenshot)

## How to run
Run the scripts in the sql/ folder in order, 01 to 07.

## Limitations and next steps
Synthetic data; country-level travel check; next: real dataset,
Python model comparison.
