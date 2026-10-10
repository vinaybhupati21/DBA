# SQL Server 2022 Transaction Log Monitor

A DBA utility for sampling transaction log utilization and active transaction log consumption across online, writable user databases.

## Files
- [Install-TransactionLogMonitor.sql](sql/Install-TransactionLogMonitor.sql) — creates history tables, a capture procedure, performs a manual sample, and configures a SQL Server Agent job that samples every minute.

## Installation
1. Review the SQL file before running it.
2. Ensure a database named `DBA` exists. Update the script if you use a different repository database.
3. Run in SQL Server Management Studio with an appropriately privileged login.
4. Confirm SQL Server Agent is running.
5. Verify data in `DBA.dbo.TransactionLogUsageSample` and `DBA.dbo.ActiveTransactionLogSample`.

## Captured fields
- Database log file size (MB)
- Used log space (MB and percentage)
- UTC sample timestamp
- Active transaction ID and begin time
- Session ID, login, host, program
- Transaction log bytes consumed (MB)
- Current SQL text when available

## Permissions
SQL Server 2022 may require `VIEW SERVER PERFORMANCE STATE` for relevant server DMVs. Actual requirements depend on the execution context and security configuration. SQL Server Agent permissions are also required to install the scheduled job.

## Important limitations
- No monitoring solution can guarantee zero performance impact. This is periodic DMV sampling; test it and monitor overhead before production use.
- The active transaction table can grow continuously. Define and implement a retention policy suitable for your environment.
- Query text can be NULL when a session has an open transaction but no current request.
- This captures log usage and transaction log consumption, not a complete audit of physical log-file autogrowth events.
- Samples are timestamped in UTC.
- The job runs once per minute by default.
