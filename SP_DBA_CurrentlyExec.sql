USE [master]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF EXISTS (SELECT * FROM sys.objects WHERE name = 'SP_DBA_CurrentlyExec')
	DROP PROCEDURE [dbo].[SP_DBA_CurrentlyExec] 
GO
CREATE PROCEDURE [dbo].[SP_DBA_CurrentlyExec] 
	@Filter_Name varchar(100)=NULL -- 'Login_Name','Host_Name','Program_Name'
	,@Filter_Value varchar(100)=NULL -- 'User1','WRKTS01','SQLCMD'
	,@IncludeSystem Bit = 0
	,@Critical Bit = 0
	,@OrderBy varchar(20)=NULL -- 'SID', 'SPID', Status', 'T.CPU','CPU','Start_Time', 'Elap_Time','Object_Name' ,'T.RD','T.WD','W.TDB', 'Wait_Time', 'Host_Name', 'Program_Name', 'Login_Name'
	,@IncludeTrnLog Bit = 0
	,@OpenTran Bit = 0
	,@Info Bit = 0
AS
-- Change Log
-- v4.1 . 2013-08-23
-- v4.2 . 2014-04-23 - Now is a SP
-- v4.3 . 2014-04-25 - Automatically Include Blocking Reports, Open Trans and Server Info
-- v4.31. 2014-05-14 - Fix Elap_Time = 23:59:59
-- v4.32. 2014-05-27 - Fix OpenTran
-- v4.4	. 2014-06-10 - Elap_Time includes Days. Default Sort is Elap_Time / Start_Time
-- v4.41. 2014-06-22 - Minor Fixes
-- v4.42. 2014-07-28 - Fix Transaction log usage on named instances
-- v4.43. 2014-08-04 - Add "Rollback" Status
-- v4.5 . 2015-10-25 - Add Object schema and databases.state=0 // Filters

SET NOCOUNT ON    
SET ANSI_PADDING ON 
SET QUOTED_IDENTIFIER ON

 IF (object_id( 'tempdb..#TMP_CEXEC' ) IS NOT NULL) DROP TABLE #TMP_CEXEC ;    

DECLARE @record_id int, @SQLProcessUtilization int, @CPU int,@EventTime datetime

-- Get CPU usage
select  top 1  @record_id =record_id, 
      @EventTime=dateadd(ms, -1 * ((SELECT ms_ticks from sys.dm_os_sys_info) - [timestamp]), GetDate()),-- as EventTime,
      @SQLProcessUtilization=SQLProcessUtilization,
      @CPU=SQLProcessUtilization + (100 - SystemIdle - SQLProcessUtilization) --as CPU_Usage
from (
      select 
            record.value('(./Record/@id)[1]', 'int') as record_id,
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') as SystemIdle,
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') as SQLProcessUtilization,
            timestamp
      from (
            select timestamp, convert(xml, record) as record 
            from sys.dm_os_ring_buffers 
            where ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
            and record like '%<SystemHealth>%') as x
      ) as y 
order by record_id desc  

SELECT 
		x.session_id as [Sid],
		COALESCE(x.blocking_session_id, 0) as BSid,
		@CPU as CPU,    
		@SQLProcessUtilization as SQL,    
		x.Status,	
		x.TotalCPU as [T.CPU],
		x.Start_time,	
		Coalesce( Convert(varchar(5),abs(DateDiff(day, (getdate()-x.Start_Time),'1900-01-01')))  + ':'
		 + Convert(varchar(10),(getdate()-x.Start_Time), 108),'00:00:00:00') as Elap_time,
	
		x.totalReads as [T.RD], -- total reads
		x.totalWrites as [T.WR], --total writes	    
		x.Writes_in_tempdb as [W.TDB],
		(
			SELECT substring(text,x.statement_start_offset/2, 
				(case when x.statement_end_offset = -1 
				then 100000000
				else x.statement_end_offset end - x.statement_start_offset+3)/2)
			FROM sys.dm_exec_sql_text(x.sql_handle)
			FOR XML PATH(''), TYPE
		) AS Sql_text,
		db_name(x.database_id)+' ('+cast(XD.cntr_value as varchar(3))+')' as [DBName / %LogUsed],
		
		space(300) as Object_Name,		
		ZZZ.dbid,
		ZZZ.objectid,
		x.Wait_type,
		x.Wait_time,
		x.Login_name, 
		x.Host_name,
		CASE LEFT(x.program_name,15) 
		WHEN 'SQLAgent - TSQL' THEN  
		(	select top 1 'SQL Job = '+j.name from msdb.dbo.sysjobs (nolock) j
			inner join msdb.dbo.sysjobsteps (nolock) s on j.job_id=s.job_id
			where right(cast(s.job_id as nvarchar(50)),10) = RIGHT(substring(x.program_name,30,34),10) )+' - ('+ substring(x.program_name,charindex(': Step',program_name,1)+1,100)
		WHEN 'SQL Server Prof' THEN 'SQL Server Profiler'
		ELSE x.program_name
		END as Program_name,		
		(
			SELECT 
				p.text
			FROM 
			(
				SELECT 
					sql_handle,statement_start_offset,statement_end_offset
				FROM sys.dm_exec_requests r2
				WHERE 
					r2.session_id = x.blocking_session_id
			) AS r_blocking
			CROSS APPLY
			(
			SELECT substring(text,r_blocking.statement_start_offset/2, 
				(case when r_blocking.statement_end_offset = -1 
				then len(convert(nvarchar(max), text)) * 2 
				else r_blocking.statement_end_offset end - r_blocking.statement_start_offset+3)/2)
			FROM sys.dm_exec_sql_text(r_blocking.sql_handle)
			FOR XML PATH(''), TYPE
			) p (text)
		)  as blocking_text,
		(SELECT object_name(objectid) FROM sys.dm_exec_sql_text(
		(select top 1 sql_handle FROM sys.dm_exec_requests r3 WHERE r3.session_id = x.blocking_session_id))) as blocking_obj,

		x.percent_complete
	INTO #TMP_CEXEC	
	FROM
	(
		SELECT 
			r.session_id,
			s.host_name,
			s.login_name,
			r.start_time,
			r.sql_handle,
			r.database_id,
			r.blocking_session_id,
			r.wait_type,
			r.Wait_time,
			r.status,
			r.statement_start_offset,
			r.statement_end_offset,	
			s.program_name,
			r.percent_complete,			
			SUM(cast(r.total_elapsed_time as bigint)) /1000 as totalElapsedTime, --CAST AS BIGINT to fix invalid data convertion when high activity
			SUM(cast(r.reads as bigint)) AS totalReads,
			SUM(cast(r.writes as bigint)) AS totalWrites,
			SUM(cast(r.cpu_time as bigint)) AS totalCPU,
			SUM(tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) AS writes_in_tempdb
		FROM sys.dm_exec_requests r
		JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
		JOIN sys.dm_db_task_space_usage tsu ON s.session_id = tsu.session_id and r.request_id = tsu.request_id
		WHERE r.status IN ('running', 'runnable', 'suspended','rollback')
		GROUP BY
			r.session_id,
			s.host_name,
			s.login_name,
			r.start_time,
			r.sql_handle,
			r.database_id,
			r.blocking_session_id,
			r.wait_type,
			r.Wait_time,
			r.status,
			r.statement_start_offset,
			r.statement_end_offset,
			s.program_name,
			r.percent_complete
	) x
	OUTER APPLY sys.dm_exec_sql_text(x.sql_handle) as ZZZ		
	LEFT JOIN (
		select object_name,counter_name,instance_name,cntr_value from sys.dm_os_performance_counters
		where object_name like '%Databases%'
		and counter_name in ('Percent Log Used')	
	) XD on XD.instance_name = db_name(x.database_id)
	where x.session_id <> @@spid
	and (@IncludeSystem = 1 OR ((x.wait_type not in ('WAITFOR','SP_SERVER_DIAGNOSTICS_SLEEP','TRACEWRITE','BROKER_RECEIVE_WAITFOR'))) or x.wait_type IS NULL)
	order by x.totalCPU desc

-- Fix Elap_Time issue
UPDATE  #TMP_CEXEC
SET Elap_time = '0.00:00:00'
WHERE Elap_time like '%23:59:59%'
	
DECLARE curObj CURSOR -- can also add READ_ONLY or SCROLL CURSOR
	FOR Select Distinct [dbid],db_name([dbid]), objectid from #TMP_CEXEC where dbid is not null

Declare @Cmd varchar(max)
Declare @DBID2 int
Declare @DBName sysname
Declare @objid int
OPEN curObj

WHILE (1=1)
BEGIN
	FETCH NEXT FROM curObj INTO  @DBID2, @DBName,@objid
	IF (@@fetch_status <> 0)
		break
	Set @Cmd = 'Update T set Object_name =  SC.name+''.''+O.name from #TMP_CEXEC T inner join ' + @DBName + '.sys.objects O (nolock) on O.object_ID = T.objectid inner join ' + @DBName + '.sys.schemas SC (NOLOCK)  on  O.schema_id=SC.schema_id         where t.dbid = ' + convert(varchar,@DBID2) 
		exec ( @Cmd )
END

CLOSE curObj
DEALLOCATE curObj

-- Server Info
IF @Info = 1
BEGIN
		SET NOCOUNT ON
		DECLARE @Builds TABLE ([Version] varchar(200),[Build] varchar(50))

		DECLARE 
			@date datetime,
			@start int,
			@ver varchar(13),
			@msc_version80 varchar(20),
			@msc_version90 varchar(20),
			@XALink varchar(20),
			@itps varchar(20),
			@eImage_version varchar(20),
			@config_value varchar(20),
			@run_value varchar(20),
			@dtx55 varchar(20),
			@sqlstart datetime,
			@dtx55_path varchar (1000),
			@Last_MSCLink_upgrade datetime,
			@hyperthread_ratio int,
			@optimal_maxdop int,
			@SalesLink varchar(20),
			@allowlogin bit,
			@mars varchar(20),
			@Server_Type varchar(20),
			@VersionNr varchar (200),
			@MirrorServer varchar(50),
			@IPAddress varchar(50),
			@maxsrvmemory bigint

		declare @OSname varchar(100),@OSversion varchar(100)

		declare @t table (line1 varchar(255))

		SELECT @date = getdate()

		SELECT @start = CHARINDEX ( 'Microsoft SQL Server 2005',@@version) 
		if @start = 1
		SELECT @ver = rtrim(substring(@@version,29,13))
		if @start = 0
		SELECT @ver = rtrim(substring(@@version,30,9))

		SELECT @start = CHARINDEX ( 'Microsoft SQL Server 2008',@@version) 
		if @start = 1
		SELECT @ver = rtrim(substring(@@version,35,12))

		SELECT @start = CHARINDEX ( 'Microsoft SQL Server 2008 R2',@@version) 
		if @start = 1
		SELECT @ver = rtrim(substring(@@version,38,12))

		IF @@version like 'Microsoft SQL Server 2012%' or @@version like 'Microsoft SQL Server 2014%' or @@version like 'Microsoft SQL Server 2016%'
		BEGIN
			SELECT @ver = rtrim(substring(@@version,charindex(' - ',@@version)+3,12))
			--SELECT rtrim(substring(@@version,charindex(' - ',@@version)+3,12)),@@version
		END

		-- MAX DEGREE OF PARALLELISM
		--Note: sp_configure 'Show advanced Options',1; RECONFIGURE

		CREATE TABLE #SPCONFIG 
		(
			name nvarchar(1000),		
			minimun int NOT NULL,
			maximun int NOT NULL,
			config_value int NOT NULL,
			run_value int NOT NULL
		)
		BEGIN TRY
			INSERT INTO #SPCONFIG exec sp_configure 'max degree of parallelism';
		END TRY
		BEGIN CATCH
			-- Execute error retrieval routine.
			PRINT 'sp_configure ''Show advanced options''';
		END CATCH;
 
		IF @Server_Type IS NULL
		SET @Server_Type = 'Other'	


		SELECT  @config_value=rtrim(convert(varchar(8),config_value)) ,@run_value=rtrim(convert(varchar(8),run_value)) from  #SPCONFIG 

		TRUNCATE TABLE #SPCONFIG

		-- MAX Server Memory

		BEGIN TRY
			INSERT INTO #SPCONFIG exec sp_configure 'max server memory (MB)';
		END TRY
		BEGIN CATCH
			-- Execute error retrieval routine.
			PRINT 'sp_configure ''Show advanced options''';
		END CATCH;


		SELECT  @maxsrvmemory=cast(rtrim(convert(varchar(20),run_value)) as bigint) from  #SPCONFIG 

		DROP TABLE #SPCONFIG 

		select	
			@hyperthread_ratio=hyperthread_ratio,@optimal_maxdop=case 
			when cpu_count / hyperthread_ratio > 8 then 4
				else CEILING((cpu_count / hyperthread_ratio)*.5)
				end 
		from sys.dm_os_sys_info;

		select @sqlstart = create_date from sys.databases where name = 'Tempdb' and state=0

		-- CPU and Memory
		DECLARE @CM Table
		(
			[Index] int,		
			Name nvarchar(1000) NOT NULL,
			Internal_Value int,
			Character_Value nvarchar(1000)
		)

		Insert into @CM exec xp_msver

		declare @CPUN int
		declare @Mem int

		select @CPUN = Internal_Value from @CM Where Name = 'ProcessorCount'
		select @Mem = Internal_Value from @CM Where Name = 'PhysicalMemory'


		SELECT @VersionNr = [Version] From @Builds where [Build] = @ver

		SELECT TOP 1 @MirrorServer=  mirroring_partner_instance from msdb.sys.database_mirroring (nolock)
		where mirroring_partner_instance is not null

		--OS
		insert into @t
		exec xp_cmdshell 'systeminfo'

		select @OSname=line1 from @t
		where line1 like 'OS Name:%'

		select @OSname=ltrim(replace(@OSname,'OS Name:',''))

		select @OSversion=line1 from @t
		where line1 like 'OS Version:%'

		select @OSversion=ltrim(replace(@OSversion,'OS Version:',''))

		-- IP Address
		SELECT @IPAddress=dec.local_net_address
		FROM sys.dm_exec_connections AS dec
		WHERE dec.session_id = @@SPID

		--//REPORT
		SELECT @@servername  as servername,getdate() as now,DATEDIFF(HH,GETUTCDATE(),GETDATE()) as TZ, @ver as SQL_Build, serverproperty('Edition') as sql_edition, @msc_version90 as MSCLink90,@msc_version80 as MSCLink80,@XALink as XLink,@itps as ITPS,@eImage_version as eImage,@dtx55 as DTX55,@SalesLink as SalesLink,@mars as MARS,@Server_Type as Server_Type,@allowlogin as Allow_Login,@run_value as MDPrun,@optimal_maxdop as MDP_Optimal,@hyperthread_ratio as HT_Ratio,@sqlstart as sql_srv_start,case serverproperty('IsClustered') when 0 THEN 'NO' when 1 THEN 'YES' end as IsCluster,@CPUN as CPU_Count,@Mem as Memory,@maxsrvmemory as SQL_Max_Srv_Memory,@Last_MSCLink_upgrade as Last_MSCLink_upgrade, @dtx55_path as dtx55_path,@MirrorServer as [DBMirror Server],@OSname as [OS Name],@OSversion as [OS Version],@IPAddress as [IP Address]


END

IF @Filter_Name IS NOT NULL
BEGIN
	IF @Filter_Name NOT IN ('SPID','Program_Name','Login_Name','Host_Name')
	BEGIN
		SELECT 'Filter names can be only these:
								SPID
								Program_Name
								Login_Name
								Host_Name
		
		'
		SET @Filter_Name = NULL
	END
	ELSE
	BEGIN

			SELECT 
			CASE  
				WHEN COALESCE(BSid, 0) > 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))+'('+CAST(BSid as varchar(5))+') *' 
				WHEN COALESCE(BSid, 0) = 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))
				WHEN COALESCE(BSid, 0) > 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+'('+CAST( BSid as varchar(5))+') // PC= '+cast (round(percent_complete,3) as varchar(10))+'% *' 
				WHEN COALESCE(BSid, 0) = 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+' // PC= '+cast (round(percent_complete,3) as varchar(10))+'%'
				END as  SPID,
			cast(CPU as varchar(3))+'/'+cast([SQL] as varchar(3)) as [CPU/SQL],
			[Status],
			[T.CPU],
			Start_Time,
			Elap_time,
			SQL_Text,
			[DBName / %LogUsed],
			object_name,
			Wait_Type,
			Wait_Time,	
			Program_Name,
			Host_name,
			Login_name,
			[T.RD],
			[T.WR],
			[W.TDB],
			blocking_text,
			blocking_obj
			INTO #TMP_CEXEC_FILTER
		from #TMP_CEXEC  
		
		select @Cmd = 'select * from #TMP_CEXEC_FILTER WHERE '+@Filter_Name+' like ''%'+@Filter_Value+'%'' ORDER BY [Start_Time] '
		exec (@cmd)


	END
END

-- All Server Activity
SELECT 
	CASE  
		WHEN COALESCE(BSid, 0) > 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))+'('+CAST(BSid as varchar(5))+') *' 
		WHEN COALESCE(BSid, 0) = 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))
		WHEN COALESCE(BSid, 0) > 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+'('+CAST( BSid as varchar(5))+') // PC= '+cast (round(percent_complete,3) as varchar(10))+'% *' 
		WHEN COALESCE(BSid, 0) = 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+' // PC= '+cast (round(percent_complete,3) as varchar(10))+'%'
		END as  SPID,
	cast(CPU as varchar(3))+'/'+cast([SQL] as varchar(3)) as [CPU/SQL],
	[Status],
	[T.CPU],
	Start_Time,
	Elap_time,
	SQL_Text,
	[DBName / %LogUsed],
	object_name,
	Wait_Type,
	Wait_Time,	
	Program_Name,
	Host_name,
	Login_name,
	[T.RD],
	[T.WR],
	[W.TDB],
	blocking_text,
	blocking_obj
from #TMP_CEXEC  
 ORDER BY 
CASE WHEN @OrderBy = 'Start_Time'
THEN Start_Time END ASC,
CASE WHEN @OrderBy = 'Wait_Time'
THEN Wait_Time END DESC ,
CASE WHEN @OrderBy = 'Elap_Time'
THEN Elap_Time END DESC,
CASE WHEN @OrderBy = 'Status'
THEN [Status] END DESC,
CASE WHEN @OrderBy = 'DB'
THEN [DBName / %LogUsed] END ASC,
CASE WHEN @OrderBy = 'T.RD'
THEN [T.RD] END DESC,
CASE WHEN @OrderBy = 'T.WR'
THEN [T.WR] END DESC,
CASE WHEN @OrderBy = 'W.TDB' or @OrderBy = 'TempDB'
THEN [W.TDB] END DESC,
CASE WHEN @OrderBy = 'T.CPU' or @OrderBy = 'CPU'
THEN [T.CPU] END DESC,
CASE WHEN @OrderBy = 'Login_Name'
THEN Login_Name END ASC,
CASE WHEN @OrderBy = 'Host_Name'
THEN [Host_Name] END ASC,
CASE WHEN @OrderBy = 'Program_Name'
THEN [Program_Name] END ASC,
CASE WHEN @OrderBy = 'Object_Name'
THEN [Object_Name] END ASC,
CASE WHEN @OrderBy = 'SPID' or @OrderBy = 'SPD'
THEN [SID] 
ELSE [Start_Time] END 
 

--Blocking Processes
DECLARE @SPIDB TABLE (SPID int,BSPID INT)	
IF EXISTS(select 1 from #TMP_CEXEC WHERE BSid <> 0)
BEGIN
	--Select 'Blocking processes ...' as [Result Set]
	DELETE FROM @SPIDB
	INSERT INTO @SPIDB (SPID)
	SELECT Distinct
		[Sid]
	from #TMP_CEXEC
	WHERE BSid >0
	UNION
	SELECT Distinct
		BSid
	from #TMP_CEXEC
	WHERE BSid >0

	SELECT --distinct 
		CASE  
			WHEN COALESCE(MA.BSid, 0) > 0 AND percent_complete = 0 THEN CAST(MA.[Sid] as varchar(5))+'('+CAST(MA.BSid as varchar(5))+') *' 
			WHEN COALESCE(MA.BSid, 0) = 0 AND percent_complete = 0 THEN CAST(MA.[Sid] as varchar(5))
			WHEN COALESCE(MA.BSid, 0) > 0 AND percent_complete <> 0 THEN CAST(MA.[Sid] as varchar(5))+'('+CAST( MA.BSid as varchar(5))+') // PC= '+cast (round(percent_complete,3) as varchar(10))+'% *' 
			WHEN COALESCE(MA.BSid, 0) = 0 AND percent_complete <> 0 THEN CAST(MA.[Sid] as varchar(5))+' // PC= '+cast (round(percent_complete,3) as varchar(10))+'%'
			END as  SPID,
		MA.Sid,
		T2.[# Blocking],
		NullIf(MA.[BSid],0) as [BSid],
		cast(CPU as varchar(3))+'/'+cast([SQL] as varchar(3)) as [CPU/SQL],
		[Status],
		[T.CPU],
		Start_Time,
		Elap_time,		
		SQL_Text,
		[DBName / %LogUsed],
		object_name,
		Wait_Type,
		Wait_Time,
		Host_name,
		Program_Name,
		Login_name,
		[T.RD],
		[T.WR],
		[W.TDB]
	from #TMP_CEXEC MA
	INNER JOIN @SPIDB D1 on MA.[SID]=D1.SPID 
	left join (Select X.BSid, count(*) as [# Blocking] from #TMP_CEXEC X where bsid <> 0 group by BSid ) T2 on T2.bsid = MA.sid
where MA.BSid <> 0 or T2.BSid is not null
	ORDER BY Elap_time DESC

END




IF @OpenTran = 1 
BEGIN
	
	IF (object_id( 'tempdb..#OpenTranStatus' ) IS NOT NULL) DROP TABLE #OpenTranStatus ;
	DECLARE @SPID int

	-- Create the temporary table to accept the results.
	CREATE TABLE #OpenTranStatus (
	   ActiveTransaction varchar(25),
	   Details sql_variant 
	   )
	-- Execute the command, putting the results in the table.
	INSERT INTO #OpenTranStatus 
	   EXEC ('USE master;DBCC OPENTRAN WITH TABLERESULTS, NO_INFOMSGS');
	DBCC OPENTRAN 
	-- Display the results.
	IF EXISTS (SELECT * FROM #OpenTranStatus)
	BEGIN 
		SELECT * FROM #OpenTranStatus;

		select @SPID=cast(Details as int) from #OpenTranStatus WHERE [ActiveTransaction] = 'OLDACT_SPID'

		SELECT DATEDIFF(MI,cast(Details as datetime),getdate())  as [Open Trans (Duration)]
		from #OpenTranStatus WHERE [ActiveTransaction] = 'OLDACT_STARTTIME'

		SELECT * FROM sys.sysprocesses P WHERE spid = @SPID
	END
END


IF @Critical=1
BEGIN

	DELETE FROM @SPIDB
	INSERT INTO @SPIDB (SPID,BSPID)
	SELECT 
		[Sid],BSid

	from #TMP_CEXEC
	where cast(sql_text as varchar(max)) not like '%waitfor%'
	AND BSid >0
	OR CAST(substring(Elap_Time,4,2) as int) >1
	AND Elap_Time <> '23:59:59'

	SELECT distinct 
		CASE  
			WHEN COALESCE(BSid, 0) > 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))+'('+CAST(BSid as varchar(5))+') *' 
			WHEN COALESCE(BSid, 0) = 0 AND percent_complete = 0 THEN CAST([Sid] as varchar(5))
			WHEN COALESCE(BSid, 0) > 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+'('+CAST( BSid as varchar(5))+') // PC= '+cast (round(percent_complete,3) as varchar(10))+'% *' 
			WHEN COALESCE(BSid, 0) = 0 AND percent_complete <> 0 THEN CAST([Sid] as varchar(5))+' // PC= '+cast (round(percent_complete,3) as varchar(10))+'%'
			END as  SPID,
		cast(CPU as varchar(3))+'/'+cast([SQL] as varchar(3)) as [CPU/SQL],
		[Status],
		[T.CPU],
		Start_Time,
		Elap_time,
		[T.RD],
		[T.WR],
		[W.TDB],
		cast(SQL_Text as varchar(max)) as SQL_Text,
		[DBName / %LogUsed],
		object_name,
		Wait_Type,
		Wait_Time,
		Login_name,
		Host_name,
		Program_Name
	from #TMP_CEXEC MA
	INNER JOIN @SPIDB D1 on MA.[SID]=D1.SPID OR MA.[SID]=D1.[BSPid]
	 
END

IF @IncludeTrnLog =1
BEGIN
	DECLARE @DBTL TABLE (id int identity,instance_name sysname,cntr_value int)

	INSERT INTO @DBTL (instance_name,cntr_value)
	select instance_name,cntr_value from sys.dm_os_performance_counters
	where counter_name in ('Percent Log Used')--,'Log Growths','Data File(s) Size (KB)','Log File(s) Size (KB)','Log Truncations')
	
	INSERT INTO @DBTL (instance_name,cntr_value)
	select instance_name,cntr_value from sys.dm_os_performance_counters
	where counter_name in ('Percent Log Used')--,'Log Growths','Data File(s) Size (KB)','Log File(s) Size (KB)','Log Truncations')

	SELECT instance_name as DBName,cntr_value as[%LogUsed] FROM @DBTL


END
