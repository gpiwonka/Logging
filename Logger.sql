-- First, create a table to store the event logs

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Logging')
BEGIN
    EXEC('CREATE SCHEMA Logging')
END;

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID('Logging.EventLog') AND type = 'U')
BEGIN
CREATE TABLE Logging.EventLog (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    EventTime DATETIME NOT NULL DEFAULT GETDATE(),
    ProcedureName NVARCHAR(128) NOT NULL,
    EventType NVARCHAR(50) NOT NULL,
    Severity NVARCHAR(20) NOT NULL,
    Message NVARCHAR(MAX) NULL,
    Username NVARCHAR(128) NOT NULL DEFAULT SUSER_SNAME(),
    AdditionalInfo NVARCHAR(MAX) NULL
);


-- Create index for faster querying
CREATE NONCLUSTERED INDEX IX_EventLog_Severity
ON Logging.EventLog(Severity, EventTime DESC);

CREATE NONCLUSTERED INDEX IX_EventLog_ProcedureName
ON Logging.EventLog(ProcedureName, EventTime DESC);

END

-- Base stored procedure for logging events
CREATE OR ALTER PROCEDURE Logging.LogEvent
    @ProcedureName NVARCHAR(128) = NULL,
    @EventType NVARCHAR(50),
    @Severity NVARCHAR(20),
    @Message NVARCHAR(MAX) = NULL,
    @AdditionalInfo NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @CallerProcedure NVARCHAR(128) = @ProcedureName;
    DECLARE @CallerInfo NVARCHAR(MAX) = NULL;
    
    -- Auto-detect the caller if requested and procedure name not specified
    IF @AutoDetectCaller = 1 AND (@ProcedureName IS NULL OR @ProcedureName = '')
    BEGIN
        -- Try to get caller info from call stack
        WITH CallStack AS (
            SELECT 
                OBJECT_NAME(caller_id) AS caller_name,
                OBJECT_SCHEMA_NAME(caller_id) AS caller_schema,
                ROW_NUMBER() OVER (ORDER BY call_stack_id DESC) as stack_level
            FROM sys.dm_exec_calls
            WHERE caller_id IS NOT NULL
        )
        SELECT 
            @CallerProcedure = ISNULL(caller_schema + '.' + caller_name, 'Unknown'),
            @CallerInfo = 'Auto-detected from call stack at level ' + CAST(stack_level AS NVARCHAR(10))
        FROM CallStack
        WHERE stack_level = 2;  -- Our direct caller (level 1 would be this procedure)
        
        -- If we couldn't get it from the call stack, try simpler method
        IF @CallerProcedure IS NULL OR @CallerProcedure = 'Unknown' OR @CallerProcedure = '.'
        BEGIN
            SET @CallerProcedure = ISNULL(OBJECT_SCHEMA_NAME(@@PROCID) + '.' + OBJECT_NAME(@@PROCID), 'Unknown');
            SET @CallerInfo = 'Detected using @@PROCID';
        END
        
        -- Append caller info to additional info
        IF @CallerInfo IS NOT NULL
        BEGIN
            IF @AdditionalInfo IS NOT NULL
                SET @AdditionalInfo = @AdditionalInfo + CHAR(13) + CHAR(10) + 'Caller Info: ' + @CallerInfo;
            ELSE
                SET @AdditionalInfo = 'Caller Info: ' + @CallerInfo;
        END
    END;
    
    -- Insert the event into the log table
    INSERT INTO EventLog (
        ProcedureName, 
        EventType,
        Severity,
        Message, 
        AdditionalInfo
    )
    VALUES (
        @CallerProcedure,
        @EventType,
        @Severity,
        @Message,
        @AdditionalInfo
    );
    
    -- Return the ID of the newly created log entry
    SELECT SCOPE_IDENTITY() AS NewLogID;
END;
GO

-- Create specialized procedures for different severity levels
CREATE OR ALTER PROCEDURE Logging.Debug
    @ProcedureName NVARCHAR(128) = NULL,
    @EventType NVARCHAR(50),
    @Message NVARCHAR(MAX) = NULL,
    @AdditionalInfo NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    EXEC Logging.LogEvent 
        @ProcedureName = @ProcedureName,
        @EventType = @EventType,
        @Severity = 'DEBUG',
        @Message = @Message,
        @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Info
    @ProcedureName NVARCHAR(128) = NULL,
    @EventType NVARCHAR(50),
    @Message NVARCHAR(MAX) = NULL,
    @AdditionalInfo NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    EXEC Logging.LogEvent 
        @ProcedureName = @ProcedureName,
        @EventType = @EventType,
        @Severity = 'INFO',
        @Message = @Message,
        @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Warn
    @ProcedureName NVARCHAR(128) = NULL,
    @EventType NVARCHAR(50),
    @Message NVARCHAR(MAX) = NULL,
    @AdditionalInfo NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    EXEC Logging.LogEvent 
        @ProcedureName = @ProcedureName,
        @EventType = @EventType,
        @Severity = 'WARNING',
        @Message = @Message,
        @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Error
    @ProcedureName NVARCHAR(128) = NULL,
    @EventType NVARCHAR(50),
    @Message NVARCHAR(MAX) = NULL,
    @AdditionalInfo NVARCHAR(MAX) = NULL,
    @IncludeErrorDetails BIT = 1,
    @AutoDetectCaller BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ErrorDetails NVARCHAR(MAX) = NULL;
    
    -- Capture error information if requested and in an error state
    IF @IncludeErrorDetails = 1 AND ERROR_NUMBER() IS NOT NULL
    BEGIN
        SET @ErrorDetails = CONCAT(
            'Error Number: ', ERROR_NUMBER(), 
            ', Line: ', ERROR_LINE(),
            ', State: ', ERROR_STATE(),
            ', Severity: ', ERROR_SEVERITY(),
            ', Procedure: ', ERROR_PROCEDURE(),
            CHAR(13), CHAR(10),
            'Error Message: ', ERROR_MESSAGE()
        );
        
        -- Append to additional info if it exists, otherwise use as additional info
        IF @AdditionalInfo IS NOT NULL
            SET @AdditionalInfo = CONCAT(@AdditionalInfo, CHAR(13), CHAR(10), 'Error Details: ', @ErrorDetails);
        ELSE
            SET @AdditionalInfo = @ErrorDetails;
    END;
    
    EXEC LogEvent 
        @ProcedureName = @ProcedureName,
        @EventType = @EventType,
        @Severity = 'ERROR',
        @Message = @Message,
        @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller;
END;
GO
