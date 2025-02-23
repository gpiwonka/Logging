# SQL Server Logger

A comprehensive logging solution for SQL Server stored procedures that provides structured logging with different severity levels, automatic caller detection, and detailed error tracking.

## Features

- **Multiple Severity Levels**: DEBUG, INFO, WARNING, and ERROR level logging
- **Automatic Caller Detection**: Automatically identifies the calling stored procedure
- **Structured Logging**: Consistent log format with timestamp, severity, and context
- **Error Details**: Comprehensive error information capture for debugging
- **Schema Organization**: All components organized in a dedicated 'Logger' schema
- **Performance Optimized**: Includes appropriate indexes for efficient log querying

## Installation

1. Execute the installation script in your database:

```sql
-- Create Logger schema
CREATE SCHEMA Logger;
GO

-- Create logging table and procedures
-- [Copy the full installation script here]
```

## Basic Usage

### Simple Logging

```sql
-- Info logging
EXEC Logger.Info
    @EventType = 'PROCESS_START',
    @Message = 'Starting data import process';

-- Warning logging
EXEC Logger.Warn
    @EventType = 'DATA_VALIDATION',
    @Message = 'Missing optional fields';

-- Error logging
EXEC Logger.Error
    @EventType = 'PROCESS_FAILURE',
    @Message = 'Failed to update records',
    @IncludeErrorDetails = 1;

-- Debug logging
EXEC Logger.Debug
    @EventType = 'DETAILED_INFO',
    @Message = 'Processing batch 123',
    @AdditionalInfo = 'Batch size: 500 records';
```

### Integration Example

```sql
CREATE PROCEDURE dbo.ImportData
    @BatchId INT,
    @EnableDebug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @StartTime DATETIME = GETDATE();
    
    -- Log start
    EXEC Logger.Info
        @EventType = 'IMPORT_START',
        @Message = 'Starting import process',
        @AdditionalInfo = CONCAT('BatchId: ', @BatchId);
    
    BEGIN TRY
        -- Debug logging (if enabled)
        IF @EnableDebug = 1
        BEGIN
            EXEC Logger.Debug
                @EventType = 'IMPORT_DETAIL',
                @Message = 'Validating batch data';
        END
        
        -- Your import logic here
        
        -- Log completion
        EXEC Logger.Info
            @EventType = 'IMPORT_COMPLETE',
            @Message = 'Import process completed',
            @AdditionalInfo = CONCAT(
                'BatchId: ', @BatchId, 
                ', Duration: ', 
                DATEDIFF(MILLISECOND, @StartTime, GETDATE()), 'ms'
            );
    END TRY
    BEGIN CATCH
        -- Log error
        EXEC Logger.Error
            @EventType = 'IMPORT_ERROR',
            @Message = 'Import process failed',
            @IncludeErrorDetails = 1;
            
        THROW;
    END CATCH
END;
```

## Querying Logs

### Recent Errors

```sql
SELECT TOP 100 *
FROM Logger.EventLog
WHERE Severity = 'ERROR'
ORDER BY EventTime DESC;
```

### Logs by Procedure

```sql
SELECT *
FROM Logger.EventLog
WHERE ProcedureName = 'dbo.ImportData'
ORDER BY EventTime DESC;
```

### Last Hour's Warnings and Errors

```sql
SELECT *
FROM Logger.EventLog
WHERE Severity IN ('WARNING', 'ERROR')
AND EventTime > DATEADD(HOUR, -1, GETDATE())
ORDER BY EventTime DESC;
```

## Table Structure

The `Logger.EventLog` table includes:

- `LogID` (INT, Identity) - Primary Key
- `EventTime` (DATETIME) - When the event occurred
- `ProcedureName` (NVARCHAR(128)) - Name of the calling procedure
- `EventType` (NVARCHAR(50)) - Type of event
- `Severity` (NVARCHAR(20)) - DEBUG/INFO/WARNING/ERROR
- `Message` (NVARCHAR(MAX)) - Log message
- `Username` (NVARCHAR(128)) - Database user
- `AdditionalInfo` (NVARCHAR(MAX)) - Extra context information

## Best Practices

1. **Use Appropriate Severity Levels**
   - DEBUG: Detailed information for troubleshooting
   - INFO: General operational events
   - WARNING: Potential issues that aren't errors
   - ERROR: Error conditions that need attention

2. **Structured Event Types**
   - Use consistent event type names (e.g., PROCESS_START, VALIDATION_ERROR)
   - Include relevant context in AdditionalInfo

3. **Error Handling**
   - Always use ERROR severity with try-catch blocks
   - Enable IncludeErrorDetails for comprehensive error information

4. **Log Maintenance**
   - Implement a retention policy for old logs
   - Archive logs before deletion if needed
   - Monitor log table size

## Performance Considerations

1. The logging table includes indexes on:
   - Severity and EventTime
   - ProcedureName and EventTime

2. Consider archiving old logs to maintain performance

## License

MIT License - Feel free to use and modify as needed.
