/* =====================================================================
   Logging Framework - Setup 2.0.0
   Ein Script fuer: Neuinstallation, Upgrade von v1, optionale Migration
   vom Schema "Logger", Extended-Events-Fehlersession, rollback-sicheren
   Puffer und Retention. Idempotent: beliebig oft ausfuehrbar.

   AUSFUEHREN: in der Anwendungsdatenbank, das GESAMTE Script (F5).
   Kein SQLCMD-Modus noetig.

   KONFIGURATION: nur der Block direkt unter diesem Kommentar.

   SZENARIEN (werden automatisch erkannt und in Logging.SetupHistory notiert)
   - Neuinstallation         : nichts vorhanden.
   - Upgrade von v1          : Logging.EventLog ohne RunID -> Spalten/Indizes werden
                               ergaenzt, Prozeduren ersetzt, vorhandene Zeilen bleiben.
   - Migration vom Schema    : nur mit @MigrateLoggerSchema = 1 und wenn Logger.EventLog
     Logger                    existiert und Logging.EventLog NICHT: Tabelle wird per
                               ALTER SCHEMA TRANSFER verschoben, die alten Prozeduren
                               Logger.LogEvent/Debug/Info/Warn/Error werden GEDROPPT und
                               durch Synonyme auf Logging.* ersetzt (alte Aufrufer laufen
                               weiter). VORHER eigene Anpassungen sichern (sp_helptext).
                               Existieren beide Tabellen, migriert das Script NICHT
                               (Daten muessten manuell zusammengefuehrt werden).
   - Update (bereits v2)     : Objekte werden neu erstellt, Daten bleiben.

   VORAUSSETZUNGEN: SQL Server 2016 SP1+ (CREATE OR ALTER, AT TIME ZONE),
   Kompatibilitaetsgrad der Datenbank >= 130. Fuer die XE-Session:
   ALTER ANY EVENT SESSION; schlaegt das fehl, wird nur gewarnt.
   Verhalten bei Abbruch der Voraussetzungen: es wird nichts veraendert.

   AENDERUNGEN GEGENUEBER v1 (Kurzfassung)
   - Bugfix Aufruferkennung (sys.dm_exec_calls existiert nicht): @ProcId = @@PROCID
     oder StartRun/EndRun. Bugfix fehlender Schemas/GO. LogEvent liefert kein
     Resultset mehr (@NewLogID OUTPUT).
   - Neu: RunID/ParentRunID, DurationMs, strukturierte Fehlerspalten, StartRun/EndRun.
   - Neu: XE-Session error_reported + Import, rollback-sicherer Puffer, Cleanup.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

/* ---------------------------------------------------------------------
   KONFIGURATION
   --------------------------------------------------------------------- */
DECLARE @MigrateLoggerSchema BIT           = 0;      -- 1 = vorhandenes Schema "Logger" nach "Logging" migrieren (siehe oben)
DECLARE @InstallXe           BIT           = 1;      -- 1 = XE-Session fuer Fehler anlegen und starten
DECLARE @XeDir               NVARCHAR(260) = NULL;   -- NULL = Verzeichnis des ERRORLOG, sonst z. B. N'D:\SQLXE\' (mit Backslash am Ende)
DECLARE @XeMaxFileMB         INT           = 50;     -- Groesse je .xel-Datei
DECLARE @XeRolloverFiles     INT           = 4;      -- Anzahl Dateien
DECLARE @XeCaptureSqlText    BIT           = 1;      -- 1 = sql_text mitschneiden (kann personenbezogene Daten enthalten!)

/* ---------------------------------------------------------------------
   Konfiguration in Temp-Tabelle sichern (ueberlebt die GO-Batches)
   und Voraussetzungen pruefen
   --------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#LoggingSetup') IS NOT NULL DROP TABLE #LoggingSetup;
CREATE TABLE #LoggingSetup (Name NVARCHAR(50) NOT NULL PRIMARY KEY, Value NVARCHAR(400) NULL);

INSERT INTO #LoggingSetup (Name, Value) VALUES
    (N'MigrateLoggerSchema', CAST(@MigrateLoggerSchema AS NVARCHAR(1))),
    (N'InstallXe',           CAST(@InstallXe AS NVARCHAR(1))),
    (N'XeDir',               @XeDir),
    (N'XeMaxFileMB',         CAST(@XeMaxFileMB AS NVARCHAR(10))),
    (N'XeRolloverFiles',     CAST(@XeRolloverFiles AS NVARCHAR(10))),
    (N'XeCaptureSqlText',    CAST(@XeCaptureSqlText AS NVARCHAR(1))),
    (N'XeStatus',            N'nicht angefordert'),
    (N'Scenario',            N'unbekannt'),
    (N'Abort',               N'0');

DECLARE @Major  INT = TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);
DECLARE @Compat INT = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());

IF ISNULL(@Major, 0) < 13 OR ISNULL(@Compat, 0) < 130
BEGIN
    RAISERROR(N'ABBRUCH: benoetigt SQL Server 2016+ und Datenbank-Kompatibilitaetsgrad >= 130 (gefunden: Version %d, Kompatibilitaet %d). Es wurde nichts veraendert.',
              16, 1, @Major, @Compat);
    UPDATE #LoggingSetup SET Value = N'1' WHERE Name = N'Abort';
    SET NOEXEC ON;   -- alle folgenden Batches werden nur kompiliert, nicht ausgefuehrt
END
GO

/* ---------------------------------------------------------------------
   1) Szenario erkennen und ggf. Migration vom Schema Logger
   --------------------------------------------------------------------- */
DECLARE @Migrate  BIT = CAST((SELECT Value FROM #LoggingSetup WHERE Name = N'MigrateLoggerSchema') AS BIT);
DECLARE @Migrated BIT = 0;
DECLARE @Scenario NVARCHAR(100);

IF OBJECT_ID(N'Logger.EventLog', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'Logging.EventLog', N'U') IS NOT NULL
        PRINT N'WARNUNG: Logger.EventLog UND Logging.EventLog existieren. Keine automatische Migration (Daten manuell zusammenfuehren).';
    ELSE IF @Migrate = 0
        PRINT N'HINWEIS: Logger.EventLog gefunden. Mit @MigrateLoggerSchema = 1 wird es nach Logging migrieren (alte Prozeduren werden ersetzt).';
    ELSE
    BEGIN
        IF SCHEMA_ID(N'Logging') IS NULL EXEC(N'CREATE SCHEMA Logging');

        BEGIN TRAN;
            ALTER SCHEMA Logging TRANSFER Logger.EventLog;

            IF OBJECT_ID(N'Logger.LogEvent', N'P') IS NOT NULL DROP PROCEDURE Logger.LogEvent;
            IF OBJECT_ID(N'Logger.Debug',    N'P') IS NOT NULL DROP PROCEDURE Logger.Debug;
            IF OBJECT_ID(N'Logger.Info',     N'P') IS NOT NULL DROP PROCEDURE Logger.Info;
            IF OBJECT_ID(N'Logger.Warn',     N'P') IS NOT NULL DROP PROCEDURE Logger.Warn;
            IF OBJECT_ID(N'Logger.Error',    N'P') IS NOT NULL DROP PROCEDURE Logger.Error;

            -- Kompatibilitaets-Synonyme: alte Aufrufe Logger.Info usw. laufen weiter
            CREATE SYNONYM Logger.EventLog FOR Logging.EventLog;
            CREATE SYNONYM Logger.LogEvent FOR Logging.LogEvent;
            CREATE SYNONYM Logger.Debug    FOR Logging.Debug;
            CREATE SYNONYM Logger.Info     FOR Logging.Info;
            CREATE SYNONYM Logger.Warn     FOR Logging.Warn;
            CREATE SYNONYM Logger.Error    FOR Logging.Error;
        COMMIT;

        SET @Migrated = 1;
        PRINT N'Migration Logger -> Logging durchgefuehrt (Synonyme angelegt).';
    END
END

IF @Migrated = 1
    SET @Scenario = N'Migration vom Schema Logger';
ELSE IF OBJECT_ID(N'Logging.EventLog', N'U') IS NULL
    SET @Scenario = N'Neuinstallation';
ELSE IF COL_LENGTH(N'Logging.EventLog', N'RunID') IS NULL
    SET @Scenario = N'Upgrade von v1';
ELSE
    SET @Scenario = N'Update (bereits v2)';

UPDATE #LoggingSetup SET Value = @Scenario WHERE Name = N'Scenario';
PRINT N'Szenario: ' + @Scenario;
GO

/* ---------------------------------------------------------------------
   2) Schema, Tabellen
   --------------------------------------------------------------------- */
IF SCHEMA_ID(N'Logging') IS NULL EXEC(N'CREATE SCHEMA Logging');
GO

IF OBJECT_ID(N'Logging.EventLog', N'U') IS NULL
BEGIN
    CREATE TABLE Logging.EventLog (
        LogID          INT IDENTITY(1,1) PRIMARY KEY,
        EventTime      DATETIME      NOT NULL DEFAULT GETDATE(),
        ProcedureName  NVARCHAR(128) NOT NULL,
        EventType      NVARCHAR(50)  NOT NULL,
        Severity       NVARCHAR(20)  NOT NULL,
        Message        NVARCHAR(MAX) NULL,
        Username       NVARCHAR(128) NOT NULL DEFAULT SUSER_SNAME(),
        AdditionalInfo NVARCHAR(MAX) NULL
    );
END

IF OBJECT_ID(N'Logging.SetupHistory', N'U') IS NULL
BEGIN
    CREATE TABLE Logging.SetupHistory (
        SetupID   INT IDENTITY(1,1) PRIMARY KEY,
        Version   NVARCHAR(20)   NOT NULL,
        AppliedAt DATETIME       NOT NULL DEFAULT GETDATE(),
        AppliedBy NVARCHAR(128)  NOT NULL DEFAULT SUSER_SNAME(),
        Notes     NVARCHAR(1000) NULL
    );
END
GO

/* Upgrade: neue Spalten (bei Neuinstallation ebenfalls) */
IF COL_LENGTH(N'Logging.EventLog', N'RunID')          IS NULL ALTER TABLE Logging.EventLog ADD RunID          UNIQUEIDENTIFIER NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ParentRunID')    IS NULL ALTER TABLE Logging.EventLog ADD ParentRunID    UNIQUEIDENTIFIER NULL;
IF COL_LENGTH(N'Logging.EventLog', N'DurationMs')     IS NULL ALTER TABLE Logging.EventLog ADD DurationMs     INT              NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ErrorNumber')    IS NULL ALTER TABLE Logging.EventLog ADD ErrorNumber    INT              NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ErrorSeverity')  IS NULL ALTER TABLE Logging.EventLog ADD ErrorSeverity  INT              NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ErrorState')     IS NULL ALTER TABLE Logging.EventLog ADD ErrorState     INT              NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ErrorLine')      IS NULL ALTER TABLE Logging.EventLog ADD ErrorLine      INT              NULL;
IF COL_LENGTH(N'Logging.EventLog', N'ErrorProcedure') IS NULL ALTER TABLE Logging.EventLog ADD ErrorProcedure NVARCHAR(128)   NULL;
GO

/* Indizes. Bewusst KEINE gefilterten Indizes: Sessions mit QUOTED_IDENTIFIER OFF
   (aeltere Clients/ODBC-Defaults) wuerden beim INSERT scheitern - ein Logger darf
   seinen Aufrufer nicht zum Absturz bringen. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_Severity' AND object_id = OBJECT_ID(N'Logging.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_Severity      ON Logging.EventLog (Severity, EventTime DESC);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_ProcedureName' AND object_id = OBJECT_ID(N'Logging.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_ProcedureName ON Logging.EventLog (ProcedureName, EventTime DESC);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_RunID' AND object_id = OBJECT_ID(N'Logging.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_RunID         ON Logging.EventLog (RunID) INCLUDE (EventTime, EventType, Severity);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_ErrorNumber' AND object_id = OBJECT_ID(N'Logging.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_ErrorNumber   ON Logging.EventLog (ErrorNumber, EventTime DESC);
GO

/* ---------------------------------------------------------------------
   3) Logging.CurrentRun - oberster Lauf vom Stack (SESSION_CONTEXT 'Logging.RunStack')
      Eintrag: RunID(36) | Startzeit(23, Stil 121) | RunName | ProcName ; naechster ...
      Der Session-Context wird beim Rueckgeben der Verbindung an den Pool geleert.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION Logging.CurrentRun()
RETURNS TABLE
AS
RETURN
(
    WITH S AS (
        SELECT Stack = CONVERT(NVARCHAR(4000), SESSION_CONTEXT(N'Logging.RunStack'))
    ),
    T AS (
        SELECT
            TopEntry = CASE WHEN CHARINDEX(N';', Stack) > 0 THEN LEFT(Stack, CHARINDEX(N';', Stack) - 1) END,
            Rest     = CASE WHEN CHARINDEX(N';', Stack) > 0 THEN SUBSTRING(Stack, CHARINDEX(N';', Stack) + 1, 4000) END
        FROM S
    ),
    U AS (
        SELECT TopEntry, Rest,
               RnEnd = NULLIF(CHARINDEX(N'|', TopEntry, 62), 0)
        FROM T
    )
    SELECT
        RunID       = TRY_CAST(NULLIF(LEFT(TopEntry, 36), N'') AS UNIQUEIDENTIFIER),
        ParentRunID = TRY_CAST(NULLIF(LEFT(Rest, 36), N'')     AS UNIQUEIDENTIFIER),
        StartTime   = TRY_CONVERT(DATETIME2(3), SUBSTRING(TopEntry, 38, 23), 121),
        RunName     = CASE WHEN RnEnd > 62 THEN SUBSTRING(TopEntry, 62, RnEnd - 62) END,
        ProcName    = CASE WHEN RnEnd IS NOT NULL THEN SUBSTRING(TopEntry, RnEnd + 1, 128) END
    FROM U
);
GO

/* ---------------------------------------------------------------------
   4) Logging.LogEvent - einziger Insert-Punkt (ausser FlushBuffer)
      ProcedureName-Aufloesung: @ProcedureName -> @ProcId -> laufender Lauf
      (nur bei @AutoDetectCaller = 1) -> '(unbekannt)'.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE Logging.LogEvent
    @ProcedureName    NVARCHAR(128) = NULL,
    @EventType        NVARCHAR(50),
    @Severity         NVARCHAR(20),
    @Message          NVARCHAR(MAX) = NULL,
    @AdditionalInfo   NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT           = 1,
    @ProcId           INT           = NULL,      -- Aufrufer: @ProcId = @@PROCID
    @DurationMs       INT           = NULL,
    @ErrorNumber      INT           = NULL,
    @ErrorSeverity    INT           = NULL,
    @ErrorState       INT           = NULL,
    @ErrorLine        INT           = NULL,
    @ErrorProcedure   NVARCHAR(128) = NULL,
    @NewLogID         INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunID UNIQUEIDENTIFIER, @ParentRunID UNIQUEIDENTIFIER, @RunProc NVARCHAR(128);
    SELECT @RunID = RunID, @ParentRunID = ParentRunID, @RunProc = ProcName
    FROM Logging.CurrentRun();

    DECLARE @Resolved NVARCHAR(128) = NULLIF(@ProcedureName, N'');

    IF @Resolved IS NULL AND @ProcId IS NOT NULL
        SET @Resolved = OBJECT_SCHEMA_NAME(@ProcId) + N'.' + OBJECT_NAME(@ProcId);

    IF @Resolved IS NULL AND @AutoDetectCaller = 1
        SET @Resolved = NULLIF(@RunProc, N'');

    INSERT INTO Logging.EventLog
        (ProcedureName, EventType, Severity, Message, AdditionalInfo,
         RunID, ParentRunID, DurationMs,
         ErrorNumber, ErrorSeverity, ErrorState, ErrorLine, ErrorProcedure)
    VALUES
        (ISNULL(@Resolved, N'(unbekannt)'), @EventType, @Severity, @Message, @AdditionalInfo,
         @RunID, @ParentRunID, @DurationMs,
         @ErrorNumber, @ErrorSeverity, @ErrorState, @ErrorLine, @ErrorProcedure);

    SET @NewLogID = CAST(SCOPE_IDENTITY() AS INT);
END;
GO

/* ---------------------------------------------------------------------
   5) Severity-Wrapper (Signatur abwaertskompatibel, neue Parameter am Ende)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE Logging.Debug
    @ProcedureName    NVARCHAR(128) = NULL,
    @EventType        NVARCHAR(50),
    @Message          NVARCHAR(MAX) = NULL,
    @AdditionalInfo   NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT           = 1,
    @ProcId           INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC Logging.LogEvent
        @ProcedureName = @ProcedureName, @EventType = @EventType, @Severity = N'DEBUG',
        @Message = @Message, @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller, @ProcId = @ProcId;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Info
    @ProcedureName    NVARCHAR(128) = NULL,
    @EventType        NVARCHAR(50),
    @Message          NVARCHAR(MAX) = NULL,
    @AdditionalInfo   NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT           = 1,
    @ProcId           INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC Logging.LogEvent
        @ProcedureName = @ProcedureName, @EventType = @EventType, @Severity = N'INFO',
        @Message = @Message, @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller, @ProcId = @ProcId;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Warn
    @ProcedureName    NVARCHAR(128) = NULL,
    @EventType        NVARCHAR(50),
    @Message          NVARCHAR(MAX) = NULL,
    @AdditionalInfo   NVARCHAR(MAX) = NULL,
    @AutoDetectCaller BIT           = 1,
    @ProcId           INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC Logging.LogEvent
        @ProcedureName = @ProcedureName, @EventType = @EventType, @Severity = N'WARNING',
        @Message = @Message, @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller, @ProcId = @ProcId;
END;
GO

CREATE OR ALTER PROCEDURE Logging.Error
    @ProcedureName       NVARCHAR(128) = NULL,
    @EventType           NVARCHAR(50),
    @Message             NVARCHAR(MAX) = NULL,
    @AdditionalInfo      NVARCHAR(MAX) = NULL,
    @IncludeErrorDetails BIT           = 1,
    @AutoDetectCaller    BIT           = 1,
    @ProcId              INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ERROR_*() zuerst sichern; ausserhalb eines CATCH-Blocks sind alle NULL
    DECLARE @ErrNo    INT            = ERROR_NUMBER();
    DECLARE @ErrSev   INT            = ERROR_SEVERITY();
    DECLARE @ErrState INT            = ERROR_STATE();
    DECLARE @ErrLine  INT            = ERROR_LINE();
    DECLARE @ErrProc  NVARCHAR(128)  = ERROR_PROCEDURE();
    DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();

    DECLARE @WithDetails BIT = CASE WHEN @IncludeErrorDetails = 1 AND @ErrNo IS NOT NULL THEN 1 ELSE 0 END;

    IF @WithDetails = 1
    BEGIN
        -- Textformat wie in v1 (Abwaertskompatibilitaet fuer bestehende Auswertungen)
        DECLARE @ErrorDetails NVARCHAR(MAX) = CONCAT(
            N'Error Number: ', @ErrNo,
            N', Line: ', @ErrLine,
            N', State: ', @ErrState,
            N', Severity: ', @ErrSev,
            N', Procedure: ', @ErrProc,
            CHAR(13), CHAR(10),
            N'Error Message: ', @ErrMsg);

        -- CONCAT behandelt NULL als leer: ohne vorhandenes AdditionalInfo bleibt nur @ErrorDetails
        SET @AdditionalInfo = CONCAT(@AdditionalInfo + CHAR(13) + CHAR(10) + N'Error Details: ', @ErrorDetails);
    END;

    -- EXEC erlaubt keine Ausdruecke als Parameterwert: vorher in Variablen berechnen
    DECLARE @pErrNo    INT           = CASE WHEN @WithDetails = 1 THEN @ErrNo    END;
    DECLARE @pErrSev   INT           = CASE WHEN @WithDetails = 1 THEN @ErrSev   END;
    DECLARE @pErrState INT           = CASE WHEN @WithDetails = 1 THEN @ErrState END;
    DECLARE @pErrLine  INT           = CASE WHEN @WithDetails = 1 THEN @ErrLine  END;
    DECLARE @pErrProc  NVARCHAR(128) = CASE WHEN @WithDetails = 1 THEN @ErrProc  END;

    EXEC Logging.LogEvent
        @ProcedureName = @ProcedureName, @EventType = @EventType, @Severity = N'ERROR',
        @Message = @Message, @AdditionalInfo = @AdditionalInfo,
        @AutoDetectCaller = @AutoDetectCaller, @ProcId = @ProcId,
        @ErrorNumber    = @pErrNo,
        @ErrorSeverity  = @pErrSev,
        @ErrorState     = @pErrState,
        @ErrorLine      = @pErrLine,
        @ErrorProcedure = @pErrProc;
END;
GO

/* ---------------------------------------------------------------------
   6) Logging.StartRun / Logging.EndRun
      @Name max. 30 Zeichen: Name + '_ABGESCHLOSSEN' (14) muss in EventType(50) passen.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE Logging.StartRun
    @Name            NVARCHAR(30),
    @ProcId          INT              = NULL,      -- @ProcId = @@PROCID
    @ProcedureName   NVARCHAR(128)    = NULL,
    @Message         NVARCHAR(MAX)    = NULL,
    @AdditionalInfo  NVARCHAR(MAX)    = NULL,
    @RunID           UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Proc NVARCHAR(128) = COALESCE(
        NULLIF(@ProcedureName, N''),
        OBJECT_SCHEMA_NAME(@ProcId) + N'.' + OBJECT_NAME(@ProcId),
        N'(unbekannt)');

    DECLARE @Stack     NVARCHAR(4000) = CONVERT(NVARCHAR(4000), SESSION_CONTEXT(N'Logging.RunStack'));
    DECLARE @EventType NVARCHAR(50);

    SET @RunID = NEWID();
    SET @Name  = REPLACE(REPLACE(REPLACE(UPPER(@Name), N'|', N'_'), N';', N'_'), N' ', N'_');
    SET @Proc  = REPLACE(REPLACE(@Proc, N'|', N'_'), N';', N'_');

    -- Push; bei Ueberlauf faellt der aelteste Eintrag hinten weg
    SET @Stack = LEFT(CONCAT(
        CONVERT(NVARCHAR(36), @RunID), N'|',
        CONVERT(NVARCHAR(23), CAST(SYSDATETIME() AS DATETIME2(3)), 121), N'|',
        @Name, N'|', @Proc, N';', @Stack), 4000);

    EXEC sys.sp_set_session_context N'Logging.RunStack', @Stack;

    SET @EventType = @Name + N'_START';
    SET @Message   = ISNULL(@Message, N'Start ' + @Name);

    EXEC Logging.LogEvent
        @ProcedureName = @Proc, @EventType = @EventType, @Severity = N'INFO',
        @Message = @Message, @AdditionalInfo = @AdditionalInfo;
END;
GO

CREATE OR ALTER PROCEDURE Logging.EndRun
    @ProcId          INT           = NULL,
    @ProcedureName   NVARCHAR(128) = NULL,
    @Success         BIT           = 1,
    @Message         NVARCHAR(MAX) = NULL,
    @AdditionalInfo  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ERROR_*() zuerst sichern
    DECLARE @ErrNo    INT            = ERROR_NUMBER();
    DECLARE @ErrSev   INT            = ERROR_SEVERITY();
    DECLARE @ErrState INT            = ERROR_STATE();
    DECLARE @ErrLine  INT            = ERROR_LINE();
    DECLARE @ErrProc  NVARCHAR(128)  = ERROR_PROCEDURE();
    DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();

    DECLARE @RunName NVARCHAR(30), @Start DATETIME2(3), @Dauer INT;
    DECLARE @EventType NVARCHAR(50), @Severity NVARCHAR(20);
    DECLARE @WithErr BIT = CASE WHEN @Success = 0 AND @ErrNo IS NOT NULL THEN 1 ELSE 0 END;

    SELECT @RunName = RunName, @Start = StartTime FROM Logging.CurrentRun();
    SET @RunName = ISNULL(NULLIF(@RunName, N''), N'RUN');

    IF @Start IS NOT NULL
    BEGIN
        DECLARE @Big BIGINT = DATEDIFF_BIG(MILLISECOND, @Start, SYSDATETIME());
        SET @Dauer = CASE WHEN @Big > 2147483647 THEN 2147483647 ELSE CAST(@Big AS INT) END;
    END

    SET @EventType = @RunName + CASE WHEN @Success = 1 THEN N'_ABGESCHLOSSEN' ELSE N'_FEHLER' END;
    SET @Severity  = CASE WHEN @Success = 1 THEN N'INFO' ELSE N'ERROR' END;
    SET @Message   = COALESCE(@Message, CASE WHEN @Success = 1 THEN N'Ende ' + @RunName ELSE @ErrMsg END);

    IF @WithErr = 1
    BEGIN
        DECLARE @ErrorDetails NVARCHAR(MAX) = CONCAT(
            N'Error Number: ', @ErrNo, N', Line: ', @ErrLine, N', State: ', @ErrState,
            N', Severity: ', @ErrSev, N', Procedure: ', @ErrProc,
            CHAR(13), CHAR(10), N'Error Message: ', @ErrMsg);
        SET @AdditionalInfo = CONCAT(@AdditionalInfo + CHAR(13) + CHAR(10) + N'Error Details: ', @ErrorDetails);
    END

    -- EXEC erlaubt keine Ausdruecke als Parameterwert: vorher in Variablen berechnen
    DECLARE @pErrNo    INT           = CASE WHEN @WithErr = 1 THEN @ErrNo    END;
    DECLARE @pErrSev   INT           = CASE WHEN @WithErr = 1 THEN @ErrSev   END;
    DECLARE @pErrState INT           = CASE WHEN @WithErr = 1 THEN @ErrState END;
    DECLARE @pErrLine  INT           = CASE WHEN @WithErr = 1 THEN @ErrLine  END;
    DECLARE @pErrProc  NVARCHAR(128) = CASE WHEN @WithErr = 1 THEN @ErrProc  END;

    -- Loggen, solange der Lauf noch oben auf dem Stack liegt
    EXEC Logging.LogEvent
        @ProcedureName = @ProcedureName, @EventType = @EventType, @Severity = @Severity,
        @Message = @Message, @AdditionalInfo = @AdditionalInfo,
        @ProcId = @ProcId, @DurationMs = @Dauer,
        @ErrorNumber    = @pErrNo,
        @ErrorSeverity  = @pErrSev,
        @ErrorState     = @pErrState,
        @ErrorLine      = @pErrLine,
        @ErrorProcedure = @pErrProc;

    -- Pop
    DECLARE @Stack NVARCHAR(4000) = CONVERT(NVARCHAR(4000), SESSION_CONTEXT(N'Logging.RunStack'));
    IF CHARINDEX(N';', @Stack) > 0
    BEGIN
        SET @Stack = NULLIF(SUBSTRING(@Stack, CHARINDEX(N';', @Stack) + 1, 4000), N'');
        EXEC sys.sp_set_session_context N'Logging.RunStack', @Stack;
    END
END;
GO

/* ---------------------------------------------------------------------
   7) Rollback-sicherer Puffer
      Table-Variablen sind vom ROLLBACK nicht betroffen. Die Prozedur sammelt in
      einer Variable vom Typ Logging.LogBuffer und schreibt NACH COMMIT/ROLLBACK
      per Logging.FlushBuffer. Grenzen: gilt nur fuer die Prozedur, die den Puffer
      besitzt (TVP-Parameter sind READONLY); schuetzt nicht gegen KILL/Verbindungs-
      abbruch/Client-Timeout (dafuer die XE-Session). Erst flushen, dann EndRun.
      Ein Typ laesst sich nicht ALTERn: bei Aenderung Typ + FlushBuffer neu anlegen.
   --------------------------------------------------------------------- */
IF TYPE_ID(N'Logging.LogBuffer') IS NULL
    CREATE TYPE Logging.LogBuffer AS TABLE
    (
        Seq            INT IDENTITY(1,1) PRIMARY KEY,
        EventTime      DATETIME      NOT NULL DEFAULT GETDATE(),
        Severity       NVARCHAR(20)  NOT NULL DEFAULT N'INFO',
        EventType      NVARCHAR(50)  NOT NULL,
        Message        NVARCHAR(MAX) NULL,
        AdditionalInfo NVARCHAR(MAX) NULL,
        DurationMs     INT           NULL
    );
GO

CREATE OR ALTER PROCEDURE Logging.FlushBuffer
    @Buffer         Logging.LogBuffer READONLY,
    @ProcId         INT           = NULL,      -- @ProcId = @@PROCID
    @ProcedureName  NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunID UNIQUEIDENTIFIER, @ParentRunID UNIQUEIDENTIFIER, @RunProc NVARCHAR(128);
    SELECT @RunID = RunID, @ParentRunID = ParentRunID, @RunProc = ProcName
    FROM Logging.CurrentRun();

    DECLARE @Proc NVARCHAR(128) = COALESCE(
        NULLIF(@ProcedureName, N''),
        OBJECT_SCHEMA_NAME(@ProcId) + N'.' + OBJECT_NAME(@ProcId),
        NULLIF(@RunProc, N''),
        N'(unbekannt)');

    INSERT INTO Logging.EventLog
        (EventTime, ProcedureName, EventType, Severity, Message, AdditionalInfo, RunID, ParentRunID, DurationMs)
    SELECT EventTime, @Proc, EventType, Severity, Message, AdditionalInfo, @RunID, @ParentRunID, DurationMs
    FROM @Buffer
    ORDER BY Seq;
END;
GO

/* ---------------------------------------------------------------------
   8) XE-Fehlerimport: Tabelle + Prozedur (immer installiert; ohne XE-Session ungenutzt)
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'Logging.XeError', N'U') IS NULL
BEGIN
    CREATE TABLE Logging.XeError (
        XeErrorID     INT IDENTITY(1,1) PRIMARY KEY,
        EventTimeUtc  DATETIME2(3)   NOT NULL,
        EventTime     DATETIME       NOT NULL,          -- Lokalzeit (wie Logging.EventLog.EventTime)
        ErrorNumber   INT            NOT NULL,
        Severity      INT            NOT NULL,
        State         INT            NULL,
        IsIntercepted BIT            NULL,              -- 1 = von TRY/CATCH gefangen, 0 = ungefangen bzw. erneut geworfen
        DatabaseName  NVARCHAR(128)  NULL,
        SessionID     INT            NULL,
        ClientApp     NVARCHAR(256)  NULL,
        ClientHost    NVARCHAR(128)  NULL,
        UserName      NVARCHAR(128)  NULL,
        Message       NVARCHAR(4000) NULL,
        SqlText       NVARCHAR(MAX)  NULL,
        FileName      NVARCHAR(400)  NOT NULL,
        FileOffset    BIGINT         NOT NULL
    );
END

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_XeError_File' AND object_id = OBJECT_ID(N'Logging.XeError'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_XeError_File ON Logging.XeError (FileName, FileOffset);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_XeError_Time' AND object_id = OBJECT_ID(N'Logging.XeError'))
    CREATE NONCLUSTERED INDEX IX_XeError_Time ON Logging.XeError (EventTime DESC) INCLUDE (ErrorNumber, IsIntercepted);
GO

/* Inkrementeller Import .xel -> Logging.XeError, dedupliziert ueber Dateiname + Offset.
   Per SQL-Agent-Job alle paar Minuten:  EXEC Logging.ImportXeErrors;
   Die .xel-Dateien rollieren; ohne regelmaessigen Import gehen aeltere Fehler verloren.
   Rechte: VIEW SERVER STATE (ab 2022: VIEW SERVER PERFORMANCE STATE). */
CREATE OR ALTER PROCEDURE Logging.ImportXeErrors
    @DatabaseName sysname       = NULL,                          -- Default: aktuelle DB
    @TimeZone     NVARCHAR(128) = N'W. Europe Standard Time'     -- fuer EventTime (Lokalzeit)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SessionName NVARCHAR(128) = N'Logging_Errors_' + REPLACE(ISNULL(@DatabaseName, DB_NAME()), N' ', N'_');
    DECLARE @File NVARCHAR(400);

    -- Dateiname aus der Session-Definition holen
    SELECT @File = CAST(f.value AS NVARCHAR(400))
    FROM sys.server_event_sessions s
    JOIN sys.server_event_session_targets t
         ON t.event_session_id = s.event_session_id AND t.name = N'event_file'
    JOIN sys.server_event_session_fields f
         ON f.event_session_id = t.event_session_id AND f.object_id = t.target_id AND f.name = N'filename'
    WHERE s.name = @SessionName;

    IF @File IS NULL
    BEGIN
        RAISERROR(N'XE-Session %s nicht gefunden.', 16, 1, @SessionName);
        RETURN;
    END

    DECLARE @Pattern NVARCHAR(400) = REPLACE(@File, N'.xel', N'*.xel');

    ;WITH Raw AS (
        SELECT f.file_name, f.file_offset, f.timestamp_utc, CAST(f.event_data AS XML) AS x
        FROM sys.fn_xe_file_target_read_file(@Pattern, NULL, NULL, NULL) f
        WHERE f.object_name = N'error_reported'
          AND NOT EXISTS (SELECT 1 FROM Logging.XeError e
                          WHERE e.FileName = f.file_name AND e.FileOffset = f.file_offset)
    )
    INSERT INTO Logging.XeError
        (EventTimeUtc, EventTime, ErrorNumber, Severity, State, IsIntercepted,
         DatabaseName, SessionID, ClientApp, ClientHost, UserName, Message, SqlText,
         FileName, FileOffset)
    SELECT
        CAST(r.timestamp_utc AS DATETIME2(3)),
        CAST(CAST(r.timestamp_utc AS DATETIMEOFFSET) AT TIME ZONE @TimeZone AS DATETIME),
        r.x.value('(event/data[@name="error_number"]/value)[1]', 'int'),
        r.x.value('(event/data[@name="severity"]/value)[1]',     'int'),
        r.x.value('(event/data[@name="state"]/value)[1]',        'int'),
        CASE r.x.value('(event/data[@name="is_intercepted"]/value)[1]', 'nvarchar(10)')
             WHEN N'true' THEN 1 WHEN N'false' THEN 0 END,
        r.x.value('(event/action[@name="database_name"]/value)[1]',    'nvarchar(128)'),
        r.x.value('(event/action[@name="session_id"]/value)[1]',       'int'),
        r.x.value('(event/action[@name="client_app_name"]/value)[1]',  'nvarchar(256)'),
        r.x.value('(event/action[@name="client_hostname"]/value)[1]',  'nvarchar(128)'),
        r.x.value('(event/action[@name="username"]/value)[1]',         'nvarchar(128)'),
        r.x.value('(event/data[@name="message"]/value)[1]',            'nvarchar(4000)'),
        r.x.value('(event/action[@name="sql_text"]/value)[1]',         'nvarchar(max)'),
        r.file_name,
        r.file_offset
    FROM Raw r;

    SELECT @@ROWCOUNT AS Importiert;
END;
GO

/* ---------------------------------------------------------------------
   9) Retention (nicht automatisch geplant; per Agent-Job aufrufen, z. B. taeglich)
      NULL bei einem Parameter ueberspringt die jeweilige Kategorie.
      Loescht in Batches, um lange Sperren und Log-Wachstum zu vermeiden.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE Logging.Cleanup
    @EventLogDays INT = 90,     -- alle Eintraege aelter als n Tage
    @DebugDays    INT = 14,     -- DEBUG-Eintraege aelter als n Tage
    @XeErrorDays  INT = 30,     -- importierte XE-Fehler (enthalten ggf. sql_text)
    @BatchSize    INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows INT;

    IF @DebugDays IS NOT NULL
    BEGIN
        SET @Rows = 1;
        WHILE @Rows > 0
        BEGIN
            DELETE TOP (@BatchSize) FROM Logging.EventLog
            WHERE Severity = N'DEBUG' AND EventTime < DATEADD(DAY, -@DebugDays, GETDATE());
            SET @Rows = @@ROWCOUNT;
        END
    END

    IF @EventLogDays IS NOT NULL
    BEGIN
        SET @Rows = 1;
        WHILE @Rows > 0
        BEGIN
            DELETE TOP (@BatchSize) FROM Logging.EventLog
            WHERE EventTime < DATEADD(DAY, -@EventLogDays, GETDATE());
            SET @Rows = @@ROWCOUNT;
        END
    END

    IF @XeErrorDays IS NOT NULL
    BEGIN
        SET @Rows = 1;
        WHILE @Rows > 0
        BEGIN
            DELETE TOP (@BatchSize) FROM Logging.XeError
            WHERE EventTime < DATEADD(DAY, -@XeErrorDays, GETDATE());
            SET @Rows = @@ROWCOUNT;
        END
    END
END;
GO

/* ---------------------------------------------------------------------
   10) XE-Session anlegen und starten (nur bei @InstallXe = 1)
       Server-Ebene, gefiltert auf diese Datenbank, Severity >= 11. Eine bestehende
       Session bleibt unveraendert (zum Neuanlegen mit anderen Einstellungen vorher
       DROP EVENT SESSION [Logging_Errors_<DB>] ON SERVER ausfuehren).
       Fehler hier (z. B. fehlende Rechte, Azure SQL DB) fuehren nur zu einer Warnung.
   --------------------------------------------------------------------- */
DECLARE @InstallXe BIT = CAST((SELECT Value FROM #LoggingSetup WHERE Name = N'InstallXe') AS BIT);

IF @InstallXe = 1
BEGIN
    BEGIN TRY
        DECLARE @XeDir     NVARCHAR(260) = (SELECT Value FROM #LoggingSetup WHERE Name = N'XeDir');
        DECLARE @MaxMB     INT           = CAST((SELECT Value FROM #LoggingSetup WHERE Name = N'XeMaxFileMB') AS INT);
        DECLARE @Roll      INT           = CAST((SELECT Value FROM #LoggingSetup WHERE Name = N'XeRolloverFiles') AS INT);
        DECLARE @CapSql    BIT           = CAST((SELECT Value FROM #LoggingSetup WHERE Name = N'XeCaptureSqlText') AS BIT);
        DECLARE @SessionName NVARCHAR(128) = N'Logging_Errors_' + REPLACE(DB_NAME(), N' ', N'_');
        DECLARE @DbId      INT           = DB_ID();

        IF @XeDir IS NULL
        BEGIN
            DECLARE @ErrLog NVARCHAR(260) = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(260));
            SET @XeDir = LEFT(@ErrLog, LEN(@ErrLog) - CHARINDEX(N'\', REVERSE(@ErrLog)) + 1);
        END

        DECLARE @File NVARCHAR(400) = @XeDir + @SessionName + N'.xel';

        IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName)
        BEGIN
            DECLARE @sql NVARCHAR(MAX) = N'
CREATE EVENT SESSION ' + QUOTENAME(@SessionName) + N' ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION (sqlserver.database_name, sqlserver.client_app_name, sqlserver.client_hostname,
            sqlserver.username, sqlserver.session_id' + CASE WHEN @CapSql = 1 THEN N', sqlserver.sql_text' ELSE N'' END + N')
    WHERE ([severity] >= 11 AND [sqlserver].[database_id] = ' + CAST(@DbId AS NVARCHAR(10)) + N')
)
ADD TARGET package0.event_file
(
    SET filename = N''' + REPLACE(@File, N'''', N'''''') + N''',
        max_file_size = (' + CAST(@MaxMB AS NVARCHAR(10)) + N'),
        max_rollover_files = (' + CAST(@Roll AS NVARCHAR(10)) + N')
)
WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
      MAX_DISPATCH_LATENCY = 30 SECONDS, STARTUP_STATE = ON);';
            EXEC sys.sp_executesql @sql;
            UPDATE #LoggingSetup SET Value = LEFT(N'neu angelegt: ' + @File, 400) WHERE Name = N'XeStatus';
        END
        ELSE
            UPDATE #LoggingSetup SET Value = N'bereits vorhanden (unveraendert)' WHERE Name = N'XeStatus';

        IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @SessionName)
        BEGIN
            DECLARE @start NVARCHAR(400) = N'ALTER EVENT SESSION ' + QUOTENAME(@SessionName) + N' ON SERVER STATE = START;';
            EXEC sys.sp_executesql @start;
        END
    END TRY
    BEGIN CATCH
        DECLARE @XeMsg NVARCHAR(400) = LEFT(ERROR_MESSAGE(), 380);
        UPDATE #LoggingSetup SET Value = N'FEHLER: ' + @XeMsg WHERE Name = N'XeStatus';
        PRINT N'WARNUNG: XE-Session konnte nicht angelegt werden: ' + @XeMsg;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   11) Setup-Historie
   --------------------------------------------------------------------- */
INSERT INTO Logging.SetupHistory (Version, Notes)
SELECT N'2.0.0',
       LEFT(CONCAT((SELECT Value FROM #LoggingSetup WHERE Name = N'Scenario'),
                   N'; XE: ', (SELECT Value FROM #LoggingSetup WHERE Name = N'XeStatus')), 1000);
GO

/* ---------------------------------------------------------------------
   12) Abschluss
   --------------------------------------------------------------------- */
SET NOEXEC OFF;

IF EXISTS (SELECT 1 FROM #LoggingSetup WHERE Name = N'Abort' AND Value = N'1')
    PRINT N'Installation wurde abgebrochen (siehe Meldung oben). Es wurde nichts veraendert.';
ELSE
BEGIN
    SELECT TOP (1) SetupID, Version, AppliedAt, AppliedBy, Notes
    FROM Logging.SetupHistory ORDER BY SetupID DESC;

    SELECT o.name AS Objekt, o.type_desc AS Typ
    FROM sys.objects o
    WHERE o.schema_id = SCHEMA_ID(N'Logging') AND o.is_ms_shipped = 0
      AND o.type IN ('U', 'P', 'IF', 'FN', 'SN')
    ORDER BY o.type_desc, o.name;
END
GO
