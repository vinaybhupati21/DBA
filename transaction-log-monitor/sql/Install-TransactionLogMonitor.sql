/*
SQL Server 2022 Transaction Log Monitor
Review and test before production deployment.

Captures:
  - Per-database log file size, used MB, and used percentage
  - Active transaction log consumption and transaction begin time
  - Session/login/host/program and current SQL text when available

Requires a database named DBA, suitable DMV permissions, and SQL Server Agent
for scheduled collection. No monitoring script can guarantee zero performance impact.
This is log usage sampling, not a complete physical autogrowth audit.
*/

USE [master];
GO
IF DB_ID(N'DBA') IS NULL
BEGIN
    RAISERROR('Create database DBA first, or change DBA references in this script.',16,1);
    RETURN;
END;
GO

USE [DBA];
GO

IF OBJECT_ID(N'dbo.TransactionLogUsageSample',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.TransactionLogUsageSample
    (
        SampleID BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_TransactionLogUsageSample PRIMARY KEY,
        SampleTime DATETIME2(3) NOT NULL,
        DatabaseName SYSNAME NOT NULL,
        LogFileSizeMB DECIMAL(19,2) NULL,
        LogSpaceUsedMB DECIMAL(19,2) NULL,
        LogSpaceUsedPct DECIMAL(9,2) NULL
    );
    CREATE INDEX IX_TransactionLogUsageSample_DbTime
        ON dbo.TransactionLogUsageSample(DatabaseName, SampleTime DESC);
END;
GO

IF OBJECT_ID(N'dbo.ActiveTransactionLogSample',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ActiveTransactionLogSample
    (
        SampleID BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ActiveTransactionLogSample PRIMARY KEY,
        SampleTime DATETIME2(3) NOT NULL,
        DatabaseName SYSNAME NOT NULL,
        SessionID INT NOT NULL,
        TransactionID BIGINT NOT NULL,
        TransactionBeginTime DATETIME NULL,
        TransactionLogMB DECIMAL(19,2) NULL,
        SessionStatus NVARCHAR(30) NULL,
        LoginName NVARCHAR(128) NULL,
        HostName NVARCHAR(128) NULL,
        ProgramName NVARCHAR(128) NULL,
        QueryText NVARCHAR(MAX) NULL
    );
    CREATE INDEX IX_ActiveTransactionLogSample_DbTime
        ON dbo.ActiveTransactionLogSample(DatabaseName, SampleTime DESC);
    CREATE INDEX IX_ActiveTransactionLogSample_Transaction
        ON dbo.ActiveTransactionLogSample(TransactionID, SampleTime DESC);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CaptureTransactionLogSample
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SampleTime DATETIME2(3) = SYSUTCDATETIME(),
            @DatabaseName SYSNAME,
            @SQL NVARCHAR(MAX);

    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = N'ONLINE'
          AND source_database_id IS NULL
          AND is_read_only = 0;

    OPEN dbs;
    FETCH NEXT FROM dbs INTO @DatabaseName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = N'
        USE ' + QUOTENAME(@DatabaseName) + N';

        INSERT INTO DBA.dbo.TransactionLogUsageSample
        (
            SampleTime, DatabaseName, LogFileSizeMB,
            LogSpaceUsedMB, LogSpaceUsedPct
        )
        SELECT
            @pSampleTime,
            DB_NAME(),
            CONVERT(DECIMAL(19,2),
                SUM(CONVERT(BIGINT, df.size)) * 8.0 / 1024),
            CONVERT(DECIMAL(19,2),
                ls.used_log_space_in_bytes / 1048576.0),
            CONVERT(DECIMAL(9,2), ls.used_log_space_in_percent)
        FROM sys.dm_db_log_space_usage AS ls
        CROSS JOIN sys.database_files AS df
        WHERE df.type_desc = N''LOG''
        GROUP BY ls.used_log_space_in_bytes, ls.used_log_space_in_percent;

        INSERT INTO DBA.dbo.ActiveTransactionLogSample
        (
            SampleTime, DatabaseName, SessionID, TransactionID,
            TransactionBeginTime, TransactionLogMB, SessionStatus,
            LoginName, HostName, ProgramName, QueryText
        )
        SELECT
            @pSampleTime,
            DB_NAME(),
            st.session_id,
            dt.transaction_id,
            at.transaction_begin_time,
            CONVERT(DECIMAL(19,2),
                dt.database_transaction_log_bytes_used / 1048576.0),
            s.status,
            s.login_name,
            s.host_name,
            s.program_name,
            txt.text
        FROM sys.dm_tran_database_transactions AS dt
        INNER JOIN sys.dm_tran_session_transactions AS st
            ON st.transaction_id = dt.transaction_id
        INNER JOIN sys.dm_tran_active_transactions AS at
            ON at.transaction_id = dt.transaction_id
        LEFT JOIN sys.dm_exec_sessions AS s
            ON s.session_id = st.session_id
        LEFT JOIN sys.dm_exec_requests AS r
            ON r.session_id = st.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
        WHERE dt.database_id = DB_ID()
          AND st.session_id <> @@SPID;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pSampleTime DATETIME2(3)',
            @pSampleTime = @SampleTime;

        FETCH NEXT FROM dbs INTO @DatabaseName;
    END;

    CLOSE dbs;
    DEALLOCATE dbs;
END;
GO

-- Run one sample manually
EXEC dbo.usp_CaptureTransactionLogSample;
GO

-- Review log usage history
SELECT TOP (500)
    SampleTime, DatabaseName, LogFileSizeMB, LogSpaceUsedMB, LogSpaceUsedPct
FROM dbo.TransactionLogUsageSample
ORDER BY SampleID DESC;
GO

-- Review active transaction samples
SELECT TOP (500)
    SampleTime, DatabaseName, SessionID, TransactionID,
    TransactionBeginTime, TransactionLogMB, SessionStatus,
    LoginName, HostName, ProgramName, QueryText
FROM dbo.ActiveTransactionLogSample
ORDER BY SampleID DESC;
GO

/* SQL Server Agent job: run sampling every minute. */
USE [msdb];
GO

IF NOT EXISTS
(
    SELECT 1 FROM dbo.sysjobs
    WHERE name = N'Transaction Log Monitor - Capture'
)
BEGIN
    EXEC dbo.sp_add_job
        @job_name = N'Transaction Log Monitor - Capture',
        @enabled = 1,
        @description = N'Samples transaction log utilization and active transaction log consumption.';
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.sysjobsteps AS st
    INNER JOIN dbo.sysjobs AS j ON j.job_id = st.job_id
    WHERE j.name = N'Transaction Log Monitor - Capture'
      AND st.step_name = N'Capture transaction log sample'
)
BEGIN
    EXEC dbo.sp_add_jobstep
        @job_name = N'Transaction Log Monitor - Capture',
        @step_name = N'Capture transaction log sample',
        @subsystem = N'TSQL',
        @database_name = N'DBA',
        @command = N'EXEC dbo.usp_CaptureTransactionLogSample;',
        @retry_attempts = 2,
        @retry_interval = 1;
END;
GO

DECLARE @Today INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

IF NOT EXISTS
(
    SELECT 1 FROM dbo.sysschedules
    WHERE name = N'Transaction Log Monitor - Every Minute'
)
BEGIN
    EXEC dbo.sp_add_schedule
        @schedule_name = N'Transaction Log Monitor - Every Minute',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 1,
        @active_start_date = @Today,
        @active_start_time = 000000;
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.sysjobs AS j
    INNER JOIN dbo.sysjobschedules AS js ON js.job_id = j.job_id
    INNER JOIN dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
    WHERE j.name = N'Transaction Log Monitor - Capture'
      AND s.name = N'Transaction Log Monitor - Every Minute'
)
BEGIN
    EXEC dbo.sp_attach_schedule
        @job_name = N'Transaction Log Monitor - Capture',
        @schedule_name = N'Transaction Log Monitor - Every Minute';
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.sysjobservers AS jsv
    INNER JOIN dbo.sysjobs AS j ON j.job_id = jsv.job_id
    WHERE j.name = N'Transaction Log Monitor - Capture'
)
BEGIN
    EXEC dbo.sp_add_jobserver
        @job_name = N'Transaction Log Monitor - Capture';
END;
GO
