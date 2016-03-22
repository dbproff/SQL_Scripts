USE [DBA_Tools]
GO
/****** Object:  UserDefinedFunction [dbo].[FN_UTC_from_Local]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FN_UTC_from_Local] ( @Local_Time datetime )
returns datetime
as
Begin
	return DateAdd(hour, DateDiff(hour, getdate(), getutcdate()), @Local_Time)
End


GO
/****** Object:  UserDefinedFunction [dbo].[FN_UTC_to_Local]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE FUNCTION [dbo].[FN_UTC_to_Local] ( @UCT_Time datetime )
returns datetime
as
Begin
	return DateAdd(hour, DateDiff(hour, getutcdate(), getdate()), @UCT_Time)
End


GO
/****** Object:  UserDefinedFunction [dbo].[FNTB_XE_Actions]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FNTB_XE_Actions] (  )
Returns table
as
Return
(
	Select 
		 p.name as Package
		,o.name as [Action]
	from 
		sys.dm_xe_objects o 
		inner join sys.dm_xe_packages p on o.package_guid = p.guid
	where 
		o.object_type='action'
)


GO
/****** Object:  UserDefinedFunction [dbo].[FNTB_XE_Current]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FNTB_XE_Current] (  )
Returns table
as
Return
(
	select * from sys.server_event_sessions (nolock)
)


GO
/****** Object:  UserDefinedFunction [dbo].[FNTB_XE_Current_Events]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FNTB_XE_Current_Events] (  )
Returns table
as
Return
(
	select * from sys.dm_xe_session_events (nolock)
)


GO
/****** Object:  UserDefinedFunction [dbo].[FNTB_XE_Events]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FNTB_XE_Events] (  )
Returns table
as
Return
(
	-- From SQLPass 2008
	-- SQL Server Extended Events have static attributes that identify 
	-- what component produces the event (keyword) and the intended audience 
	-- for that event.

	-- Admin events would be interesting to database administrators, and indicate
	--	a potentially unhealthy condition on the server that an adminstrator can remedy

	-- Operational events are targeted toward ops engineers, and typically indicate 
	--	situations that need immediate attention

	-- Analytic events are published in high volume and typcially used during
	--	performance investigations.

	-- Debug events track low level operations, and are intended for advanced
	--	users only.  These events may be fired in extremly high volume.
	Select 
		 p.name as package
		,c.event
		,k.keyword
		,c.channel
		,c.description  
	from
		(
			select event_package=o.package_guid, o.description, 
				event=c.object_name, channel=v.map_value
			from sys.dm_xe_objects o
				left join sys.dm_xe_object_columns c on o.name = c.object_name
				inner join sys.dm_xe_map_values v on c.type_name = v.name 
					and c.column_value = cast(v.map_key as nvarchar)
			where object_type='event' and (c.name = 'channel' or c.name is null)
		) c 
		left join 
		(
			select event_package=c.object_package_guid, event=c.object_name, 
				keyword=v.map_value
			from sys.dm_xe_object_columns c inner join sys.dm_xe_map_values v 
			on c.type_name = v.name and c.column_value = v.map_key 
				and c.type_package_guid = v.object_package_guid
			inner join sys.dm_xe_objects o on o.name = c.object_name 
				and o.package_guid=c.object_package_guid
			where object_type='event' and c.name = 'keyword' 
		) k on
				k.event_package = c.event_package 
			and ( k.event = c.event or k.event is null )
		inner join sys.dm_xe_packages p on p.guid=c.event_package
	where 
		p.name in ('sqlserver', 'sqlos', 'package0')
)


GO
/****** Object:  UserDefinedFunction [dbo].[FNTB_XE_Predicates]    Script Date: 16/12/2015 11:22:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create function [dbo].[FNTB_XE_Predicates] (  )
Returns table
as
Return
(
	Select 
		 p.name as Package
		,o.name as Predicate
	from 
		sys.dm_xe_objects o 
		inner join sys.dm_xe_packages p on o.package_guid = p.guid
	where 
		(o.object_type='pred_compare' and (o.name like '%min%' or o.name like '%max%'))
		or o.object_type='pred_source'	
)


GO
